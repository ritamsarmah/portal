package scenes

import "core:math"
import "core:math/cmplx"
import sdl "vendor:sdl3"

SAMPLE_RATE :: 44100
NUM_SAMPLES :: 1024 // must be power of 2 for FFT
NUM_SAMPLE_BYTES :: NUM_SAMPLES * size_of(f32)
NUM_BINS :: (NUM_SAMPLES / 2) + 1 // Based on Nyquist frequency

LOW_CUTOFF :: 16
HIGH_CUTOFF :: NUM_BINS - 257
NUM_BANDS :: HIGH_CUTOFF - LOW_CUTOFF

AUDIO_SMOOTHING :: 0.2
FREQUENCY_SCALING :: 0.2
SILENCE_THRESHOLD: f32 = 0.2
MIN_DB :: -80.0
MAX_DB :: 0.0
INVERSE_RANGE :: 1.0 / (MAX_DB - MIN_DB)

MIN_RADIUS :: 16.0
MAX_RADIUS :: 172.0
BAND_WINDOW :: 4 // Must evenly divide NUM_BANDS
NUM_MAGNITUDES :: NUM_BANDS / BAND_WINDOW
VISUAL_SMOOTHING :: 0.8
COLOR_CHANGE_RATE :: 0.2

audio_spec := sdl.AudioSpec {
	format   = .F32,
	channels = 1,
	freq     = SAMPLE_RATE,
}

Visualizer_State :: struct {
	audio: struct {
		stream:     ^sdl.AudioStream,
		buffer:     [NUM_SAMPLES]f32,
		fft_buffer: [NUM_SAMPLES]complex64,
		bands:      [NUM_BANDS]f32,
	},
	video: struct {
		center:     sdl.Point,
		magnitudes: [NUM_MAGNITUDES]f32,
		points:     [NUM_MAGNITUDES * 2]sdl.FPoint, // normal + mirrored points
	},
}

visualizer_init :: proc(window_size: sdl.Point) -> ^Visualizer_State {
	assert(NUM_BANDS % BAND_WINDOW == 0)

	state := new(Visualizer_State)
	state.video.center = window_size / 2

	state.audio.stream = sdl.OpenAudioDeviceStream(
		sdl.AUDIO_DEVICE_DEFAULT_RECORDING,
		&audio_spec,
		nil,
		nil,
	)

	// Device starts paused, so must be manually started
	sdl.ResumeAudioStreamDevice(state.audio.stream)

	return state
}

visualizer_iterate :: proc(state: ^Visualizer_State, renderer: ^sdl.Renderer) -> sdl.AppResult {
	/* Audio Processing */
	{
		audio := &state.audio

		if sdl.GetAudioStreamAvailable(audio.stream) >= NUM_SAMPLE_BYTES {
			sdl.GetAudioStreamData(audio.stream, &audio.buffer, NUM_SAMPLE_BYTES)
			mean := math.sum(audio.buffer[:]) / NUM_SAMPLES

			// Preprocess samples
			for i in 0 ..< NUM_SAMPLES {
				// Subtract mean to remove DC bias
				audio.buffer[i] -= mean

				// Apply Hann window to reduce spectral leakage
				audio.buffer[i] *=
					0.5 * (1 - math.cos(2 * math.PI * f32(i) / f32(NUM_SAMPLES - 1)))

				// Convert to complex number
				audio.fft_buffer[i] = complex(audio.buffer[i], 0)
			}

			fft(audio.fft_buffer[:])

			for value, i in audio.fft_buffer[LOW_CUTOFF:HIGH_CUTOFF] {
				real := cmplx.real(value)
				imag := cmplx.imag(value)
				magnitude := math.sqrt(real * real + imag * imag)
				power := 20 * math.log10(magnitude + 1e-6)

				// Normalize to 0–1 range based on expected dB limits
				power = (power - MIN_DB) * INVERSE_RANGE

				if power < SILENCE_THRESHOLD {
					audio.bands[i] = SILENCE_THRESHOLD
					continue
				}

				// power = math.clamp(power, 0, 1)

				// Frequency-dependent scaling
				power *= 1 + math.pow(f32(i) / (NUM_BANDS - 1), FREQUENCY_SCALING)
				audio.bands[i] = AUDIO_SMOOTHING * audio.bands[i] + (1 - AUDIO_SMOOTHING) * power}
		}
	}

	/* Visualizer */
	{
		video := &state.video
		bands := state.audio.bands
		total_angle: f32 = math.PI / NUM_MAGNITUDES

		sdl.SetRenderDrawColor(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
		sdl.RenderClear(renderer)

		for &magnitude, i in video.magnitudes {
			start := i * BAND_WINDOW
			end := start + BAND_WINDOW
			value := math.sum(bands[start:end]) / BAND_WINDOW

			point := &video.points[i]
			mirror := &video.points[len(video.points) - i - 1]

			magnitude = VISUAL_SMOOTHING * magnitude + (1 - VISUAL_SMOOTHING) * value * MAX_RADIUS
			angle := f32(i) * total_angle

			point.x = f32(video.center.x) + math.sin(angle) * (MIN_RADIUS + magnitude)
			point.y = f32(video.center.y) + math.cos(angle) * (MIN_RADIUS + magnitude)

			mirror.x = 2 * f32(video.center.x) - point.x
			mirror.y = point.y
		}

		now := f64(sdl.GetTicks()) / 1000 * COLOR_CHANGE_RATE
		r := f32(0.5 + 0.5 * math.sin(now))
		g := f32(0.5 + 0.5 * math.sin(now + math.PI * 2 / 3))
		b := f32(0.5 + 0.5 * math.sin(now + math.PI * 4 / 3))
		sdl.SetRenderDrawColorFloat(renderer, r, g, b, sdl.ALPHA_OPAQUE_FLOAT)

		sdl.RenderLines(renderer, raw_data(video.points[:]), len(video.points))
		sdl.RenderPresent(renderer)
	}

	return .CONTINUE
}

visualizer_quit :: proc(state: ^Visualizer_State) {
	sdl.Log("quitting visualizer scene")
	sdl.DestroyAudioStream(state.audio.stream)
	free(state)
}

/* Fast Fourier Transform */

bit_reverse :: proc "contextless" (x: int, bits: int) -> int {
	x := x
	y := 0

	for i in 0 ..< bits {
		y = (y << 1) | (x & 1)
		x >>= 1
	}

	return y
}

bit_reversal_permutation :: proc "contextless" (data: []$T) {
	n := len(data)

	// Compute bit length of data length
	bits := 0; for tmp := n; tmp > 1; tmp >>= 1 do bits += 1

	for i in 0 ..< n {
		j := bit_reverse(i, bits)
		if j > i do data[i], data[j] = data[j], data[i]
	}
}

/// In-place radix-2 Cooley-Tukey FFT
/// https://en.wikipedia.org/wiki/Cooley%E2%80%93Tukey_FFT_algorithm
fft :: proc "contextless" (data: []complex64) {
	n := len(data)
	if n <= 1 do return

	bit_reversal_permutation(data)

	for s in 1 ..= math.log2(f32(n)) {
		m := 1 << uint(s)
		half := m >> 1

		angle := -2 * math.PI / f32(m)
		w_m := cmplx.exp(complex64(angle) * 1i) // mth root of unity

		for k := 0; k < n; k += m {
			w: complex64 = 1

			for j in 0 ..< half {
				t := w * data[k + j + half]
				u := data[k + j]

				data[k + j] = u + t
				data[k + j + half] = u - t

				w *= w_m
			}
		}
	}
}

/* Utilities */

rms :: proc "contextless" (values: []f32) -> f32 {
	sum: f32 = 0
	for value in values {
		sum += value * value
	}

	return math.sqrt(sum / f32(len(values)))
}

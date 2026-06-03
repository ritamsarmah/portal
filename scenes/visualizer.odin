package scenes

import "core:fmt"
import "core:math"
import "core:math/cmplx"
import "core:slice"
import ma "vendor:miniaudio"
import rl "vendor:raylib"

SAMPLES_LEN :: 1024 // Must be power of 2 for FFT
BINS_LEN :: (SAMPLES_LEN / 2) + 1 // Based on Nyquist frequency
FRAMES_LEN :: 2 // Number of seconds

BARS_LEN :: 80
MIN_RADIUS :: 90.0
MAX_RADIUS :: 260.0
GLOW_LAYERS :: 4 // Number of glow passes per bar
BASS_BARS :: 12
HUE_RATE :: 15.0
BAR_AUDIO_ATTACK :: 0.6
BAR_AUDIO_DECAY :: 0.15 // Slow decay with audio
BAR_SILENCE_DECAY :: 0.9 // Fast decay for silence
BASS_DECAY :: 0.85
DB_FLOOR :: 80 // -80db is silence

LO_CUTOFF :: 10
HI_CUTOFF :: BARS_LEN - 5

Visualizer_State :: struct {
	audio: struct {
		device:  ma.device,
		buffer:  [SAMPLES_LEN]f32,
		samples: []f32,
		fft:     [SAMPLES_LEN]complex64,
	},
	video: struct {
		origin:     rl.Vector2,
		bars:       [BARS_LEN]f32,
		points:     [HI_CUTOFF - LO_CUTOFF + 1]rl.Vector2,
		hue_offset: f32,
		bass_pulse: f32,
		last_bass:  f32,
	},
}

visualizer_init :: proc() -> ^Visualizer_State {
	fmt.printfln("initializing visualizer scene")

	window_width := f32(rl.GetScreenWidth())
	window_height := f32(rl.GetScreenHeight())

	state := new(Visualizer_State)
	state.video.origin = {window_width, window_height} / 2

	// miniaudio

	config := ma.device_config_init(.capture)
	config.capture.format = .f32
	config.capture.channels = 1
	config.sampleRate = 48000
	config.dataCallback = capture_callback
	config.pUserData = state

	if ma.device_init(nil, &config, &state.audio.device) != .SUCCESS {
		fmt.eprintln("failed to initialize capture device")
		return nil
	}

	// Device sleeps by default and must be manually started
	if ma.device_start(&state.audio.device) != .SUCCESS {
		fmt.eprintln("failed to start capture device")
		ma.device_uninit(&state.audio.device)
		return nil
	}

	return state
}

visualizer_quit :: proc(state: ^Visualizer_State) {
	fmt.println("quitting visualizer scene")

	ma.device_uninit(&state.audio.device)
	free(state)
}

visualizer_update :: proc(state: ^Visualizer_State) {
	audio := &state.audio
	video := &state.video
	dt := rl.GetFrameTime()
	count := len(audio.samples)

	// Decay rapidly when no audio
	if count == 0 {
		video.bars *= BAR_SILENCE_DECAY
		video.bass_pulse *= BASS_DECAY
		video.hue_offset += dt * HUE_RATE
		return
	}

	sample_mean := math.sum(audio.samples) / f32(count)

	// Preprocess
	for &sample, i in audio.samples {
		sample -= sample_mean // Remove DC bias
		window := 0.5 * (1 - math.cos(2 * math.PI * f32(i) / f32(count - 1))) // Apply Hann window
		audio.fft[i] = complex(sample * window, 0)
	}

	slice.zero(audio.fft[count:SAMPLES_LEN]) // Zero-pad remainder

	fft(audio.fft[:])

	// Map FFT bins to bars using log-frequency spacing to mimic how humans perceive pitch.
	// Skip DC at 0. Log spacing gives more resolution to bass.
	bin_low: f32 = 1
	bin_high: f32 = BINS_LEN - 1

	for &bar, i in video.bars {
		// Log-spaced bin range for this bar
		t0 := f32(i) / BARS_LEN
		t1 := f32(i + 1) / BARS_LEN

		// Exponential interpolation
		lo := bin_low * math.pow(bin_high / bin_low, t0)
		hi := bin_low * math.pow(bin_high / bin_low, t1)

		lo = math.clamp(lo, bin_low, bin_high - 1)
		hi = math.clamp(hi, lo, bin_high - 1)

		// Identify peak magnitude across this bin range
		peak: f32 = 0
		for value in audio.fft[int(lo):int(hi) + 1] {
			real := cmplx.real(value)
			imag := cmplx.imag(value)

			// NOTE: Calculate magnitude squared for efficiency, since we only need square root of final peak
			magnitude := (real * real + imag * imag) / (SAMPLES_LEN * SAMPLES_LEN)
			if magnitude > peak do peak = magnitude
		}

		peak = math.sqrt(peak)

		// Convert to dB and normalize
		db := 20 * math.log10(math.max(peak, 1e-6)) // Clamp to avoid log10(0) = -inf
		normalized: f32 = math.clamp((db + DB_FLOOR) / DB_FLOOR, 0, 1)

		// Smooth toward raw values with a fast attack and slow decay
		factor: f32 = normalized > bar ? BAR_AUDIO_ATTACK : BAR_AUDIO_DECAY
		bar = math.lerp(bar, normalized, factor)
	}

	// Detect beat by comparing current bass energy to previous
	bass_mean := math.sum(video.bars[:BASS_BARS]) / BASS_BARS
	if bass_mean > video.last_bass * 1.15 && bass_mean > 0.1 do video.bass_pulse = 1

	video.last_bass = math.lerp(video.last_bass, bass_mean, f32(0.1))
	video.bass_pulse *= BASS_DECAY

	// Rotate hue faster when there's more energy
	magnitude_mean := math.sum(video.bars[:]) / BARS_LEN
	video.hue_offset += dt * (20 + magnitude_mean * 60)
}

visualizer_draw :: proc(state: ^Visualizer_State) {
	video := &state.video
	origin := video.origin
	points := &video.points

	rl.ClearBackground(rl.BLACK)

	// Cutoff end frequencies with too much noise and low signal
	for &bar, i in video.bars[LO_CUTOFF:HI_CUTOFF] {
		t := f32(i) / len(points)
		angle := (t * math.TAU) + math.PI / 2
		radius := f32(MIN_RADIUS) + bar * (MAX_RADIUS - MIN_RADIUS) * 1.4 + video.bass_pulse * 22.0
		points[i] = rl.Vector2 {
			origin.x + math.cos(angle) * radius,
			origin.y + math.sin(angle) * radius,
		}
	}

	points[len(points) - 1] = points[0]

	hue := math.mod(video.hue_offset, 360.0)
	dim := rl.ColorFromHSV(hue, 0.7, 0.5)
	lit := rl.ColorFromHSV(hue, 0.4, 1.0)

	for i in 0 ..< (len(points) - 1) {
		rl.DrawLineEx(points[i], points[i + 1], 4.0, dim)
		rl.DrawLineEx(points[i], points[i + 1], 1.2, lit)
	}
}

capture_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	state := (^Visualizer_State)(device.pUserData)
	samples := cast([^]f32)input

	count := copy(state.audio.buffer[:], samples[:frame_count])
	state.audio.samples = state.audio.buffer[:count]
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

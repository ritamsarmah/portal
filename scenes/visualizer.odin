package scenes

import "core:fmt"
import "core:math"
import "core:math/cmplx"
import ma "vendor:miniaudio"
import rl "vendor:raylib"

SAMPLES_LEN :: 1024 // must be power of 2 for FFT
BINS_LEN :: (SAMPLES_LEN / 2) + 1 // Based on Nyquist frequency
FRAMES_LEN :: 2 // number of seconds

BARS_LEN :: 80
MIN_RADIUS :: 90.0
MAX_RADIUS :: 260.0
GLOW_LAYERS :: 4 // number of glow passes per bar
BASS_MAGNITUDES :: 6
HUE_RATE :: 15.0
MAGNITUDE_DECAY :: 0.9
BEAT_PULSE_DECAY :: 0.85

Visualizer_State :: struct {
	audio: struct {
		device:  ma.device,
		buffer:  [SAMPLES_LEN]f32,
		samples: []f32,
		fft:     [SAMPLES_LEN]complex64,
	},
	video: struct {
		origin:     rl.Vector2,
		magnitudes: [BARS_LEN]f32, // smoothed bar heights [0..1]
		hue_offset: f32, // color rotation over time
		beat_pulse: f32, // flash intensity on beat
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

	fmt.printfln("%v %v", video.hue_offset, video.beat_pulse)

	// Decay toward silence when no audio
	if count == 0 {
		video.magnitudes *= MAGNITUDE_DECAY

		if video.beat_pulse > 0.1 {
			video.beat_pulse *= BEAT_PULSE_DECAY
		} else {
			video.beat_pulse = 0
		}

		video.hue_offset += dt * HUE_RATE
		return
	}

	sample_mean := math.sum(audio.samples) / f32(count)

	// Preprocess
	for i in 0 ..< count {
		sample := audio.samples[i] - sample_mean // Remove DC bias
		window := 0.5 * (1.0 - math.cos(2.0 * math.PI * f32(i) / f32(count - 1))) // Apply Hann window
		audio.fft[i] = complex(sample * window, 0)
	}

	// Zero-pad remainder
	for i in count ..< SAMPLES_LEN {
		audio.fft[i] = 0
	}

	fft(audio.fft[:])

	// Map FFT bins to bars using log-frequency spacing
	// Skip DC at 0. Log spacing gives more resolution to bass.
	bin_low: f32 = 1
	bin_high: f32 = BINS_LEN - 1

	for bar, i in 0 ..< BARS_LEN {
		// Log-spaced bin range for this bar
		t0 := f32(bar) / BARS_LEN
		t1 := f32(bar + 1) / BARS_LEN

		lo := bin_low * math.pow(bin_high / bin_low, t0)
		hi := bin_low * math.pow(bin_high / bin_low, t1)
		if lo < bin_low do lo = bin_low
		if hi < lo do hi = lo
		if hi >= bin_high do hi = bin_high - 1

		// Average magnitude across this bin range
		peak: f32 = 0
		for value, j in audio.fft[int(lo):int(hi) + 1] {
			real := cmplx.real(value)
			imag := cmplx.imag(value)
			magnitude := math.sqrt(real * real + imag * imag) / SAMPLES_LEN
			if magnitude > peak do peak = magnitude
		}

		// Convert to dB and normalize
		db := 20.0 * math.log10(math.max(peak, 1e-6))
		normalized: f32 = math.clamp((db + 80) / 80, 0, 1)

		// Smooth toward raw values with a fast attack and slow decay
		factor: f32 = normalized > video.magnitudes[i] ? 0.6 : 0.15
		video.magnitudes[i] = math.lerp(video.magnitudes[i], normalized, factor)
	}

	// Detect beat by comparing current bass energy to previous
	bass_energy := math.sum(video.magnitudes[:BASS_MAGNITUDES]) / BASS_MAGNITUDES
	if bass_energy > video.last_bass * 1.3 && bass_energy > 0.3 {
		video.beat_pulse = 1.0
	}
	video.last_bass = math.lerp(video.last_bass, bass_energy, f32(0.1))
	video.beat_pulse *= BEAT_PULSE_DECAY

	// Rotate hue faster when there's more energy
	magnitude_mean := math.sum(video.magnitudes[:]) / BARS_LEN
	video.hue_offset += dt * (20.0 + magnitude_mean * 60.0)
}

visualizer_draw :: proc(state: ^Visualizer_State) {
	audio := &state.audio
	video := &state.video
	origin := video.origin

	rl.ClearBackground(rl.BLACK)

	// Pulse background on beat
	if video.beat_pulse > 0.01 {
		pulse_alpha := u8(video.beat_pulse * 18)
		rl.DrawCircleV(origin, MAX_RADIUS + 60, {255, 200, 100, pulse_alpha})
	}

	// Radial frequency bars
	for bar in 0 ..< BARS_LEN {
		mag := video.magnitudes[bar]
		if mag < 0.001 do continue

		angle_deg := f32(bar) / f32(BARS_LEN) * 360.0
		angle_rad := angle_deg * math.PI / 180.0

		// Hue: spread across spectrum + offset rotation
		hue := math.mod(f32(bar) / f32(BARS_LEN) * 300.0 + video.hue_offset, 360.0)
		sat := 0.75 + mag * 0.25
		lit := 0.45 + mag * 0.20

		bar_len := mag * (MAX_RADIUS - MIN_RADIUS)
		r_inner: f32 = MIN_RADIUS
		r_outer: f32 = MIN_RADIUS + bar_len

		cos_a := math.cos(angle_rad)
		sin_a := math.sin(angle_rad)

		p_inner := rl.Vector2{origin.x + cos_a * r_inner, origin.y + sin_a * r_inner}
		p_outer := rl.Vector2{origin.x + cos_a * r_outer, origin.y + sin_a * r_outer}

		// Draw glow layers (thick→thin, transparent→opaque)
		for g in 0 ..< GLOW_LAYERS {
			glow_t := f32(g) / f32(GLOW_LAYERS)
			glow_w := (1.0 - glow_t) * (6.0 + mag * 8.0)
			glow_lit := lit * (0.5 + glow_t * 0.5)
			c := rl.ColorFromHSV(hue, sat, glow_lit)
			rl.DrawLineEx(p_inner, p_outer, glow_w, c)
		}

		// Bright tip dot
		tip_r := 2.5 + mag * 4.0
		tip_c := rl.ColorFromHSV(hue, 0.95, 0.9)
		rl.DrawCircleV(p_outer, tip_r, tip_c)
	}

	// // Outer glow
	// pulse_r := 28.0 + video.beat_pulse * 14.0
	// for g in 0 ..< 5 {
	// 	gr := pulse_r + f32(g) * 6.0
	// 	hue := math.mod(video.hue_offset, 360.0)
	// 	rl.DrawCircleV(origin, gr, rl.ColorFromHSV(hue, 0.9, 0.6))
	// }

	// Core
	// core_hue := math.mod(video.hue_offset, 360.0)
	// rl.DrawCircleV(origin, pulse_r, rl.ColorFromHSV(core_hue, 0.6, 0.3))
	// rl.DrawCircleV(origin, pulse_r * 0.55, rl.ColorFromHSV(core_hue, 0.4, 0.85))
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

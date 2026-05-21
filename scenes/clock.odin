package scenes

import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import sdl "vendor:sdl3"

MARK_COUNT :: 60

PRIMARY_MARK_WIDTH :: 16
PRIMARY_MARK_HEIGHT :: 64
SECONDARY_MARK_WIDTH :: 6
SECONDARY_MARK_HEIGHT :: 32

BG_COLOR :: sdl.FColor{255, 255, 255, sdl.ALPHA_OPAQUE}
FG_COLOR :: sdl.FColor{0, 0, 0, sdl.ALPHA_OPAQUE}
ACCENT_COLOR :: sdl.FColor{255, 0, 0, sdl.ALPHA_OPAQUE}

// Clocks initial position has hands at the top
ANGLE_OFFSET :: math.PI

Clock_State :: struct {
	mark_radius:        f32,
	hour_hand_length:   f32,
	minute_hand_length: f32,
	second_hand_length: f32,
	center:             sdl.Point,
	background:         ^sdl.Texture,
	tz:                 ^datetime.TZ_Region,
}

clock_init :: proc(window_size: sdl.Point, renderer: ^sdl.Renderer) -> ^Clock_State {
	state := new(Clock_State)

	/* Create background texture */

	state.mark_radius = f32(window_size.x) * 0.4
	state.hour_hand_length = f32(window_size.x) * 0.25
	state.minute_hand_length = f32(window_size.x) * 0.35
	state.second_hand_length = f32(window_size.x) * 0.45
	state.center = window_size / 2

	state.background = sdl.CreateTexture(
		renderer,
		.RGBA8888,
		.TARGET,
		window_size.x,
		window_size.y,
	)

	sdl.SetTextureBlendMode(state.background, sdl.BLENDMODE_BLEND)
	sdl.SetRenderTarget(renderer, state.background)
	sdl.SetRenderDrawColorFloat(renderer, BG_COLOR.r, BG_COLOR.g, BG_COLOR.b, BG_COLOR.a)

	sdl.RenderClear(renderer)

	// Render tick marks onto background
	for i in 0 ..< MARK_COUNT {
		is_primary := i % 5 == 0

		width: f32 = is_primary ? PRIMARY_MARK_WIDTH : SECONDARY_MARK_WIDTH
		height: f32 = is_primary ? PRIMARY_MARK_HEIGHT : SECONDARY_MARK_HEIGHT
		angle := f32(i) * math.TAU / MARK_COUNT
		offset := is_primary ? state.mark_radius : state.mark_radius + height

		render_rect(renderer, width, height, angle, offset, FG_COLOR, state.center)
	}

	// Return to main render target
	sdl.SetRenderTarget(renderer, nil)

	/* Load timezone region */

	tz_link, tz_err := os.read_link("/etc/localtime", context.allocator)
	if tz_err != nil {
		sdl.Log("failed to read timezone")
		return nil
	}
	defer delete(tz_link)

	tz_region := string(tz_link)
	tz_region = strings.trim_left(tz_region, ".")
	tz_region = strings.trim_prefix(tz_region, "/usr/share/zoneinfo/")

	tz, tz_region_ok := timezone.region_load(tz_region)
	if !tz_region_ok {
		sdl.Log("failed to load timezone region")
		return nil
	}

	state.tz = tz

	return state
}

clock_iterate :: proc(state: ^Clock_State, renderer: ^sdl.Renderer) -> sdl.AppResult {
	now := time.now()
	utc, _ := time.time_to_datetime(now)
	local, _ := timezone.datetime_to_tz(utc, state.tz)

	hour, minute, second := local.hour, local.minute, local.second
	hour = hour % 12 // Convert from 24-hour to 12-hour

	second_angle := math.TAU * f32(second) / 60
	minute_angle := math.TAU * (f32(minute) + f32(second) / 60) / 60
	hour_angle := math.TAU * (f32(hour) + f32(minute) / 60) / 12

	sdl.RenderTexture(renderer, state.background, nil, nil)

	render_rect(
		renderer,
		8,
		state.hour_hand_length,
		hour_angle + ANGLE_OFFSET,
		0,
		FG_COLOR,
		state.center,
	)

	render_rect(
		renderer,
		8,
		state.minute_hand_length,
		minute_angle + ANGLE_OFFSET,
		0,
		FG_COLOR,
		state.center,
	)

	render_rect(
		renderer,
		4,
		state.second_hand_length,
		second_angle + ANGLE_OFFSET,
		0,
		ACCENT_COLOR,
		state.center,
	)

	sdl.RenderPresent(renderer)

	return .CONTINUE
}

clock_quit :: proc(state: ^Clock_State) {
	sdl.Log("quitting clock scene")
	sdl.DestroyTexture(state.background)
	free(state.tz)
	free(state)
}

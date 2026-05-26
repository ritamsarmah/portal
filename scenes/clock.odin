package scenes

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import rl "vendor:raylib"

MARK_COUNT :: 60

PRIMARY_MARK_WIDTH :: 16
PRIMARY_MARK_HEIGHT :: 64
SECONDARY_MARK_WIDTH :: 6
SECONDARY_MARK_HEIGHT :: 32

BG_COLOR :: rl.WHITE
FG_COLOR :: rl.BLACK
ACCENT_COLOR :: rl.RED

HOUR_HAND_LEN :: 0.25
MINUTE_HAND_LEN :: 0.35
SECOND_HAND_LEN :: 0.4

HOUR_HAND_THICK :: 10.0
MINUTE_HAND_THICK :: 10.0
SECOND_HAND_THICK :: 6.0

Clock_State :: struct {
	origin:     rl.Vector2,
	background: rl.RenderTexture,
	tz:         ^datetime.TZ_Region,
	hours:      struct {
		origin:   rl.Vector2,
		rect:     rl.Rectangle,
		rotation: f32,
	},
	minutes:    struct {
		origin:   rl.Vector2,
		rect:     rl.Rectangle,
		rotation: f32,
	},
	seconds:    struct {
		origin:   rl.Vector2,
		rect:     rl.Rectangle,
		rotation: f32,
	},
}

clock_init :: proc() -> ^Clock_State {
	fmt.println("initializing clock scene")

	state := new(Clock_State)

	window_width := f32(rl.GetScreenWidth())
	window_height := f32(rl.GetScreenHeight())

	state.origin = {window_width, window_height} / 2

	state.hours.rect = {
		state.origin.x,
		state.origin.y,
		window_width * HOUR_HAND_LEN,
		HOUR_HAND_THICK,
	}

	state.minutes.rect = {
		state.origin.x,
		state.origin.y,
		window_width * MINUTE_HAND_LEN,
		MINUTE_HAND_THICK,
	}

	state.seconds.rect = {
		state.origin.x,
		state.origin.y,
		window_width * SECOND_HAND_LEN,
		SECOND_HAND_THICK,
	}

	state.hours.origin = {0, state.hours.rect.height / 2}
	state.minutes.origin = {0, state.minutes.rect.height / 2}
	state.seconds.origin = {0, state.seconds.rect.height / 2}

	{ 	// Create background texture
		state.background = rl.LoadRenderTexture(i32(window_width), i32(window_height))

		rl.BeginTextureMode(state.background)
		defer rl.EndTextureMode()

		rl.ClearBackground(BG_COLOR)

		step := 360.0 / f32(MARK_COUNT)
		mark_radius := window_width * 0.4

		for i in 0 ..< MARK_COUNT {
			is_primary := i % 5 == 0

			w := f32(is_primary ? PRIMARY_MARK_WIDTH : SECONDARY_MARK_WIDTH)
			h := f32(is_primary ? PRIMARY_MARK_HEIGHT : SECONDARY_MARK_HEIGHT)

			angle := f32(i) * step
			rect := rl.Rectangle{state.origin.x, state.origin.y, w, h}
			rl.DrawRectanglePro(rect, rl.Vector2{w / 2, mark_radius}, angle, FG_COLOR)
		}
	}

	{ 	// Load timezone region
		tz_link, tz_err := os.read_link("/etc/localtime", context.allocator)
		if tz_err != nil {
			fmt.eprintln("failed to read timezone:", tz_err)
			return nil
		}
		defer delete(tz_link)

		tz_region := string(tz_link)
		tz_region = strings.trim_left(tz_region, ".")
		tz_region = strings.trim_prefix(tz_region, "/usr/share/zoneinfo/")

		tz, tz_region_ok := timezone.region_load(tz_region)
		if !tz_region_ok {
			fmt.eprintln("failed to load timezone region")
			return nil
		}

		state.tz = tz
	}

	return state
}

clock_quit :: proc(state: ^Clock_State) {
	fmt.println("quitting clock scene")

	rl.UnloadRenderTexture(state.background)
	timezone.region_destroy(state.tz)
	free(state)
}

clock_update :: proc(state: ^Clock_State) {
	now := time.now()
	utc, _ := time.time_to_datetime(now)
	local, _ := timezone.datetime_to_tz(utc, state.tz)
	h := f32(local.hour % 12)
	m := f32(local.minute)
	s := f32(local.second)

	state.seconds.rotation = (s / 60) * 360 - 90
	state.minutes.rotation = ((m + s / 60) / 60) * 360 - 90
	state.hours.rotation = ((h + m / 60) / 12) * 360 - 90
}

clock_draw :: proc(state: ^Clock_State) {
	rl.ClearBackground(BG_COLOR)
	rl.DrawTexture(state.background.texture, 0, 0, rl.WHITE)

	rl.DrawRectanglePro(state.hours.rect, state.hours.origin, state.hours.rotation, FG_COLOR)
	rl.DrawRectanglePro(state.minutes.rect, state.minutes.origin, state.minutes.rotation, FG_COLOR)
	rl.DrawRectanglePro(
		state.seconds.rect,
		state.seconds.origin,
		state.seconds.rotation,
		ACCENT_COLOR,
	)

	rl.DrawCircleV(state.origin, 12, FG_COLOR)
}

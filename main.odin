package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/posix"
import "vendor:curl"
import rl "vendor:raylib"

import "scenes"

APP_NAME :: "portal"
WINDOW_WIDTH :: 800
WINDOW_HEIGHT :: 800
SCENE_COUNT :: 4

Scene :: union {
	^scenes.Idle_State,
	^scenes.Clock_State,
	^scenes.Media_State,
	^scenes.Visualizer_State,
}

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintfln("=== %v allocations not freed: ===", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintfln("- %v bytes @ %v", entry.size, entry.location)
				}
			} else {
				fmt.printfln("=== all allocations freed ===")
			}

			mem.tracking_allocator_destroy(&track)
		}
	}

	// raylib

	rl.SetConfigFlags({.VSYNC_HINT, .MSAA_4X_HINT})
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, APP_NAME)
	defer rl.CloseWindow()

	rl.SetTargetFPS(60)

	// curl

	curl.global_init(curl.GLOBAL_DEFAULT)
	defer curl.global_cleanup()

	// App

	scene: Scene = scenes.idle_init()
	defer quit_scene(scene)

	// Set stdin to non-blocking
	flags := posix.fcntl(posix.STDIN_FILENO, .GETFL, 0)
	posix.fcntl(posix.STDIN_FILENO, .SETFL, flags | posix.O_NONBLOCK)
	input: [1]byte

	for !rl.WindowShouldClose() {
		n, err := os.read(os.stdin, input[:])
		if n > 0 do set_scene(&scene, i32(input[0]))
		if err == .EOF do break

		update(&scene)
		draw(scene)
		free_all(context.temp_allocator)
	}
}

update :: proc(scene: ^Scene) {
	if rl.IsKeyPressed(.ZERO) do set_scene(scene, 0)
	if rl.IsKeyPressed(.ONE) do set_scene(scene, 1)
	if rl.IsKeyPressed(.TWO) do set_scene(scene, 2)
	if rl.IsKeyPressed(.THREE) do set_scene(scene, 3)

	switch &s in scene {
	case ^scenes.Idle_State:
		return
	case ^scenes.Clock_State:
		scenes.clock_update(s)
	case ^scenes.Media_State:
		scenes.media_update(s)
	case ^scenes.Visualizer_State:
		scenes.visualizer_update(s)
	}
}

draw :: proc(scene: Scene) {
	rl.BeginDrawing()
	defer rl.EndDrawing()

	switch &s in scene {
	case ^scenes.Idle_State:
		scenes.idle_draw(s)
	case ^scenes.Clock_State:
		scenes.clock_draw(s)
	case ^scenes.Media_State:
		scenes.media_draw(s)
	case ^scenes.Visualizer_State:
		scenes.visualizer_draw(s)
	}
}

set_scene :: proc(scene: ^Scene, value: i32) {
	switch value {
	case 0:
		if s, ok := scene.(^scenes.Idle_State); !ok {
			quit_scene(scene^)
			scene^ = scenes.idle_init()
		}
	case 1:
		if s, ok := scene.(^scenes.Clock_State); !ok {
			quit_scene(scene^)
			scene^ = scenes.clock_init()
		}
	case 2:
		if s, ok := scene.(^scenes.Media_State); !ok {
			quit_scene(scene^)
			scene^ = scenes.media_init()
		}
	case 3:
		if s, ok := scene.(^scenes.Visualizer_State); !ok {
			quit_scene(scene^)
			scene^ = scenes.visualizer_init()
		}
	case:
		fmt.eprintln("invalid scene value:", value)
	}
}

quit_scene :: proc(scene: Scene) {
	switch s in scene {
	case ^scenes.Idle_State:
		scenes.idle_quit(s)
	case ^scenes.Clock_State:
		scenes.clock_quit(s)
	case ^scenes.Media_State:
		scenes.media_quit(s)
	case ^scenes.Visualizer_State:
		scenes.visualizer_quit(s)
	}
}

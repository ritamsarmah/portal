package main

import "base:runtime"
import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"
import "vendor:curl"
import rl "vendor:raylib"

import "scenes"

APP_NAME :: "portal"
WINDOW_WIDTH :: 800
WINDOW_HEIGHT :: 800
SCENE_COUNT :: 4

App_State :: struct {
	next_scene:       i32,
	next_scene_mutex: sync.RW_Mutex,
	listener:         net.TCP_Socket,
	shutdown:         bool,
}

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

	state := App_State{}

	// Server

	listener, err_listen := net.listen_tcp({address = net.IP4_Address{0, 0, 0, 0}, port = 9041})
	if err_listen != nil {
		fmt.eprintln("failed to start TCP listener", err_listen)
	}

	state.listener = listener
	defer net.close(state.listener)

	server_thread := thread.create_and_start_with_data(&state, start_server)
	defer thread.destroy(server_thread)

	// Loop

	for !rl.WindowShouldClose() {
		// Handle scene changes set by network clients
		// NOTE: Do not allocate next state on server thread since it uses a different allocator!
		if sync.rw_mutex_guard(&state.next_scene_mutex) {
			if state.next_scene != 0 {
				set_scene(&scene, state.next_scene)
				state.next_scene = 0
			}
		}

		update(&scene)
		draw(scene)
		free_all(context.temp_allocator)
	}

	state.shutdown = true
}

update :: proc(scene: ^Scene) {
	if rl.IsKeyPressed(.ONE) do set_scene(scene, 1)
	if rl.IsKeyPressed(.TWO) do set_scene(scene, 2)
	if rl.IsKeyPressed(.THREE) do set_scene(scene, 3)
	if rl.IsKeyPressed(.FOUR) do set_scene(scene, 4)

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

	switch s in scene {
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
	case 1:
		if s, ok := scene.(^scenes.Idle_State); !ok {
			quit_scene(scene^)
			scene^ = scenes.idle_init()
		}
	case 2:
		if s, ok := scene.(^scenes.Clock_State); !ok {
			quit_scene(scene^)
			scene^ = scenes.clock_init()
		}
	case 3:
		if s, ok := scene.(^scenes.Media_State); !ok {
			quit_scene(scene^)
			scene^ = scenes.media_init()
		}
	case 4:
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

start_server :: proc(data: rawptr) {
	state := (^App_State)(data)
	buffer: [4]byte

	net.set_option(state.listener, .Receive_Timeout, time.Second)

	for !state.shutdown {
		client, _, err_accept := net.accept_tcp(state.listener)
		if err_accept != nil do continue
		defer net.close(client)

		bytes_read, err_recv := net.recv_tcp(client, buffer[:])
		if err_recv != nil {
			fmt.eprintln("error receiving data from client:", err_recv)
			continue
		}

		if bytes_read == 4 {
			value, ok := endian.get_i32(buffer[:], .Big)
			if ok {
				if sync.rw_mutex_guard(&state.next_scene_mutex) {
					state.next_scene = value
				}
			}
		}
	}
}

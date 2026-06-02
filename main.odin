package main

import "base:runtime"
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

Scene :: union {
	^scenes.Idle_State,
	^scenes.Clock_State,
	^scenes.Media_State,
	^scenes.Visualizer_State,
}

App_State :: struct {
	scene:      Scene,
	scene_lock: sync.RW_Mutex,
	shutdown:   bool,
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

	state := App_State{}
	state.scene = scenes.idle_init()
	defer quit_scene(state.scene)

	// server_thread := thread.create_and_start_with_data(&state, start_server)
	// defer thread.destroy(server_thread)

	defer state.shutdown = true

	for !rl.WindowShouldClose() {
		if sync.rw_mutex_shared_guard(&state.scene_lock) {
			update(&state)
			draw(state.scene)
		}

		free_all(context.temp_allocator)
	}
}

update :: proc(state: ^App_State) {
	if rl.IsKeyPressed(.ZERO) do set_scene(state, 0)
	if rl.IsKeyPressed(.ONE) do set_scene(state, 1)
	if rl.IsKeyPressed(.TWO) do set_scene(state, 2)
	if rl.IsKeyPressed(.THREE) do set_scene(state, 3)

	switch &s in state.scene {
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

set_scene :: proc(state: ^App_State, value: i32) {
	switch value {
	case 0:
		if s, ok := state.scene.(^scenes.Idle_State); !ok {
			quit_scene(state.scene)
			state.scene = scenes.idle_init()
		}
	case 1:
		if s, ok := state.scene.(^scenes.Clock_State); !ok {
			quit_scene(state.scene)
			state.scene = scenes.clock_init()
		}
	case 2:
		if s, ok := state.scene.(^scenes.Media_State); !ok {
			quit_scene(state.scene)
			state.scene = scenes.media_init()
		}
	case 3:
		if s, ok := state.scene.(^scenes.Visualizer_State); !ok {
			quit_scene(state.scene)
			state.scene = scenes.visualizer_init()
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

/* Remote Control */

start_server :: proc(data: rawptr) {
	state := (^App_State)(data)

	socket, err := net.listen_tcp({address = net.IP4_Address{0, 0, 0, 0}, port = 9041})
	if err != nil {
		fmt.eprintln("failed to start TCP listener")
		return
	}

	fmt.println("started TCP server")
	defer net.close(socket)

	// Set timeout so accept TCP unblocks periodically for shutdown
	net.set_option(socket, .Receive_Timeout, time.Second)

	buffer: [4]u8

	for !state.shutdown {
		client, _, err_accept := net.accept_tcp(socket)
		if err_accept != nil do continue
		defer net.close(client)

		bytes_read, err_recv := net.recv_tcp(client, buffer[:])
		if err_recv != nil {
			fmt.eprintln("failed to receive data from client")
			return
		}

		value := i32(transmute(i32be)buffer)
		if sync.rw_mutex_guard(&state.scene_lock) {
			set_scene(state, value)
		}
	}
}

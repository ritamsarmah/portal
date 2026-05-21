package main

import "base:runtime"
import "core:c"
import "core:net"
import "scenes"
import "vendor:curl"
import sdl "vendor:sdl3"

APP_NAME :: "portal"
APP_ID :: "me.ritam.portal"
WINDOW_SIZE :: sdl.Point{800, 800}

Scene :: enum c.int {
	Idle,
	Clock,
	Media,
	Visualizer,
}

Scene_State :: union {
	^scenes.Idle_State,
	^scenes.Clock_State,
	^scenes.Media_State,
	^scenes.Visualizer_State,
}

App_State :: struct {
	window:        ^sdl.Window,
	renderer:      ^sdl.Renderer,
	scene:         sdl.AtomicInt,
	scene_state:   Scene_State,
	server_thread: ^sdl.Thread,
	last_time:     sdl.Uint64,
}

main :: proc() {
	curl.global_init(curl.GLOBAL_DEFAULT)
	sdl.EnterAppMainCallbacks(0, nil, app_init, app_iterate, app_event, app_quit)
}

app_init :: proc "c" (appstate: ^rawptr, argc: c.int, argv: [^]cstring) -> sdl.AppResult {
	context = runtime.default_context()

	sdl.Log("initializing %s\n", APP_NAME)
	if ok := sdl.SetAppMetadata(APP_NAME, "1.0", APP_ID); !ok {
		sdl.Log("failed to set app metadata: %s", sdl.GetError())
		return .FAILURE
	}

	appstate^ = sdl.malloc(size_of(App_State))
	if appstate^ == nil {
		sdl.Log("failed to initialize app state\n")
		return .FAILURE
	}

	state := cast(^App_State)appstate^
	state.server_thread = sdl.CreateThread(start_server, "Server_Thread", state)

	if ok := sdl.Init({.VIDEO, .AUDIO}); !ok {
		sdl.Log("failed to initialize SDL: %s\n", sdl.GetError())
		return .FAILURE
	}

	if ok := sdl.CreateWindowAndRenderer(
		APP_NAME,
		WINDOW_SIZE.x,
		WINDOW_SIZE.y,
		{.HIGH_PIXEL_DENSITY},
		&state.window,
		&state.renderer,
	); !ok {
		sdl.Log("failed to create window or renderer: %s", sdl.GetError())
		return .FAILURE
	}

	sdl.SetRenderVSync(state.renderer, 1)
	sdl.SetRenderLogicalPresentation(state.renderer, WINDOW_SIZE.x, WINDOW_SIZE.y, .LETTERBOX)

	_ = sdl.SetAtomicInt(&state.scene, i32(Scene.Idle))

	return .CONTINUE
}

start_server :: proc "c" (data: rawptr) -> c.int {
	context = runtime.default_context()
	state := cast(^App_State)data

	socket, err := net.listen_tcp({address = net.IP4_Address{0, 0, 0, 0}, port = 9041})
	if err != nil {
		sdl.Log("failed to start TCP listener")
		return -1
	}

	sdl.Log("started TCP server")
	defer net.close(socket)

	buffer: [4]u8

	for {
		client, _, err_accept := net.accept_tcp(socket)
		defer net.close(client)

		if err_accept != nil {
			sdl.Log("failed to accept connection from client")
			return -1
		}

		bytes_read, err_recv := net.recv_tcp(client, buffer[:])
		if err_recv != nil {
			sdl.Log("failed to receive data from client")
			return -1
		}

		// Validate scene
		scene := i32(transmute(i32be)buffer)
		if scene < 0 || scene >= len(Scene) {
			sdl.Log("invalid scene: %d", scene)
			continue
		}

		// Update scene based on client data
		_ = sdl.SetAtomicInt(&state.scene, i32(transmute(i32be)buffer))
	}
}

app_iterate :: proc "c" (appstate: rawptr) -> sdl.AppResult {
	context = runtime.default_context()
	state := cast(^App_State)appstate

	// Change scene if needed
	current_scene := Scene(sdl.GetAtomicInt(&state.scene))
	next_scene_name := ""
	next_scene_state: Scene_State

	switch current_scene {
	case .Idle:
		if s, ok := state.scene_state.(^scenes.Idle_State); !ok {
			next_scene_state = scenes.idle_init(state.renderer)
			next_scene_name = "idle"
		}
	case .Clock:
		if _, ok := state.scene_state.(^scenes.Clock_State); !ok {
			next_scene_state = scenes.clock_init(WINDOW_SIZE, state.renderer)
			next_scene_name = "clock"
		}
	case .Media:
		if _, ok := state.scene_state.(^scenes.Media_State); !ok {
			next_scene_state = scenes.media_init(WINDOW_SIZE)
			next_scene_name = "media"
		}
	case .Visualizer:
		if _, ok := state.scene_state.(^scenes.Visualizer_State); !ok {
			next_scene_state = scenes.visualizer_init(WINDOW_SIZE)
			next_scene_name = "visualizer"
		}
	}

	if next_scene_name != "" {
		if next_scene_state == nil do return .FAILURE

		sdl.Log("transitioning scene: %s", next_scene_name)

		scene_quit(state.scene_state)
		state.scene_state = next_scene_state

	}

	// Calculate delta time
	now := sdl.GetTicksNS()
	dt := f64(now - state.last_time) / sdl.NS_PER_SECOND
	state.last_time = now

	// Run scene iteration
	switch &s in state.scene_state {
	case ^scenes.Idle_State:
		return .CONTINUE
	case ^scenes.Clock_State:
		return scenes.clock_iterate(s, state.renderer)
	case ^scenes.Media_State:
		return scenes.media_iterate(s, state.renderer, dt)
	case ^scenes.Visualizer_State:
		return scenes.visualizer_iterate(s, state.renderer)
	}

	return .CONTINUE
}

app_event :: proc "c" (appstate: rawptr, event: ^sdl.Event) -> sdl.AppResult {
	context = runtime.default_context()
	state := cast(^App_State)appstate

	#partial switch event.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		return .SUCCESS
	}

	return .CONTINUE
}

app_quit :: proc "c" (appstate: rawptr, result: sdl.AppResult) {
	context = runtime.default_context()
	state := cast(^App_State)appstate

	sdl.Log("quitting %s with result %d", APP_NAME, result)

	scene_quit(state.scene_state)

	sdl.DetachThread(state.server_thread)
	sdl.DestroyRenderer(state.renderer)
	sdl.DestroyWindow(state.window)
	sdl.Quit()

	sdl.free(appstate)

	curl.global_cleanup()
}

scene_quit :: proc(scene_state: Scene_State) {
	switch s in scene_state {
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

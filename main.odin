package main

import "base:runtime"
import "core:c"
import "scenes"
import sdl "vendor:sdl3"

APP_NAME :: "portal"
APP_ID :: "me.ritam.portal"
WINDOW_SIZE :: sdl.Point{800, 800}

Scene :: union {
	scenes.Idle_State,
	scenes.Clock_State,
	scenes.Visualizer_State,
}

App_State :: struct {
	window:            ^sdl.Window,
	renderer:          ^sdl.Renderer,
	current_scene:     Scene,
	next_scene:        Maybe(Scene),
	controller_thread: sdl.Thread,
}

main :: proc() {
	sdl.EnterAppMainCallbacks(0, nil, app_init, app_iterate, app_event, app_quit)
}

app_init :: proc "c" (appstate: ^rawptr, argc: c.int, argv: [^]cstring) -> sdl.AppResult {
	context = runtime.default_context()

	sdl.Log("Initializing %s\n", APP_NAME)
	if ok := sdl.SetAppMetadata(APP_NAME, "1.0", APP_ID); !ok {
		sdl.Log("Failed to set app metadata: %s", sdl.GetError())
		return .FAILURE
	}

	appstate^ = sdl.malloc(size_of(App_State))
	if appstate == nil {
		sdl.Log("Failed to initialize app state\n")
		return .FAILURE
	}

	state := cast(^App_State)appstate^

	if ok := sdl.Init({.VIDEO, .AUDIO}); !ok {
		sdl.Log("Failed to initialize SDL: %s\n", sdl.GetError())
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
		sdl.Log("Failed to create window or renderer: %s", sdl.GetError())
		return .FAILURE
	}

	sdl.SetRenderVSync(state.renderer, 1)
	sdl.SetRenderLogicalPresentation(state.renderer, WINDOW_SIZE.x, WINDOW_SIZE.y, .LETTERBOX)

	// Initialize the default idle state
	state.current_scene = scenes.idle_init(state.renderer)

	// sdl.CreateThread(, "")

	// TODO: create a networking thread that listens for command to change
	// If there i a valid command, Push the change event as a Keyboardevent?
	// event := sdl.Event{.USER, C}
	// sdl.PushEvent()

	return .CONTINUE
}

app_iterate :: proc "c" (appstate: rawptr) -> sdl.AppResult {
	context = runtime.default_context()
	state := cast(^App_State)appstate

	switch &scene in state.current_scene {
	case scenes.Idle_State:
		return .CONTINUE
	case scenes.Clock_State:
		return scenes.clock_iterate(&scene, state.renderer)
	case scenes.Visualizer_State:
		return scenes.visualizer_iterate(&scene, state.renderer)
	}

	return .CONTINUE
}

app_event :: proc "c" (appstate: rawptr, event: ^sdl.Event) -> sdl.AppResult {
	context = runtime.default_context()
	state := cast(^App_State)appstate

	#partial switch event.type {
	case .KEY_UP:
		switch event.key.key {
		case sdl.K_0:
			sdl.Log("Transitioning scene: idle")
			scene_quit(state.current_scene)
			state.current_scene = scenes.idle_init(state.renderer)
		case sdl.K_1:
			sdl.Log("Transitioning scene: clock")
			scene, ok := scenes.clock_init(WINDOW_SIZE, state.renderer).?
			if !ok do return .FAILURE

			scene_quit(state.current_scene)
			state.current_scene = scene
		case sdl.K_2:
			sdl.Log("Transitioning scene: visualizer")
			scene_quit(state.current_scene)
			state.current_scene = scenes.visualizer_init(WINDOW_SIZE)
		}
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		return .SUCCESS
	}

	return .CONTINUE
}

app_quit :: proc "c" (appstate: rawptr, result: sdl.AppResult) {
	context = runtime.default_context()
	state := cast(^App_State)appstate

	sdl.Log("Quitting %s with result %d", APP_NAME, result)

	sdl.DestroyRenderer(state.renderer)
	sdl.DestroyWindow(state.window)
	sdl.Quit()

	sdl.free(appstate)
}

scene_quit :: proc(scene: Scene) {
	switch &scene in scene {
	case scenes.Idle_State:
		return
	case scenes.Clock_State:
		scenes.clock_quit(scene)
	case scenes.Visualizer_State:
		scenes.visualizer_quit(scene)
	}
}

package scenes

import sdl "vendor:sdl3"

Idle_State :: struct {}

idle_init :: proc(renderer: ^sdl.Renderer) -> Idle_State {
	// Draw black background
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
	sdl.RenderClear(renderer)
	sdl.RenderPresent(renderer)

	return {}
}

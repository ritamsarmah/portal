package scenes

import "core:fmt"
import rl "vendor:raylib"

Idle_State :: struct {}

idle_init :: proc() -> ^Idle_State {
	fmt.println("initializing idle scene")

	rl.EnableEventWaiting() // Block on BeginDrawing() until event received for true idling
	return new(Idle_State)
}

idle_quit :: proc(state: ^Idle_State) {
	fmt.println("quitting idle scene")
	rl.DisableEventWaiting()
	free(state)
}

idle_draw :: proc(state: ^Idle_State) {
	rl.ClearBackground(rl.BLACK)
}

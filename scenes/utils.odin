package scenes

import "core:math"
import sdl "vendor:sdl3"

/* Render rectangle relative to center point. */
render_rect :: proc(
	renderer: ^sdl.Renderer,
	width, height, angle, offset: f32,
	color: sdl.FColor,
	center: sdl.Point,
) {
	hw, hh := width / 2, height

	// Rectangle vertices relative to origin (0,0)
	vertices := [4]sdl.Vertex {
		sdl.Vertex{sdl.FPoint{-hw, 0}, color, {}},
		sdl.Vertex{sdl.FPoint{hw, 0}, color, {}},
		sdl.Vertex{sdl.FPoint{hw, hh}, color, {}},
		sdl.Vertex{sdl.FPoint{-hw, hh}, color, {}},
	}

	cos_a := math.cos(angle)
	sin_a := math.sin(angle)

	for i in 0 ..< 4 {
		x := vertices[i].position.x
		y := vertices[i].position.y + offset
		vertices[i].position.x = f32(center.x) + x * cos_a - y * sin_a
		vertices[i].position.y = f32(center.y) + x * sin_a + y * cos_a
	}

	// Two triangles forming the rectangle
	indices := [6]i32{0, 1, 2, 2, 3, 0}

	sdl.RenderGeometry(
		renderer,
		nil,
		raw_data(vertices[:]),
		len(vertices),
		raw_data(indices[:]),
		len(indices),
	)
}

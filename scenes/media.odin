package scenes

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "vendor:curl"
import rl "vendor:raylib"

POLL_RATE_S :: 4
ROTATION_RATE :: 32

Media_State :: struct {
	poll_timer:  f32,
	poll_thread: ^thread.Thread,
	artwork:     struct {
		ready:    bool,
		image:    rl.Image,
		mu:       sync.Mutex,
		texture:  rl.Texture,
		origin:   rl.Vector2,
		dest:     rl.Rectangle,
		rotation: f32,
	},
	ha:          struct {
		url:              string,
		entity:           string,
		authorization:    cstring,
		headers:          ^curl.slist,
		media_content_id: string,
	},
}

Media_Response :: struct {
	attributes:   struct {
		media_title:      string,
		media_artist:     string,
		media_album_name: string,
		media_content_id: string,
		entity_picture:   string,
	},
	last_changed: string,
}

media_init :: proc() -> ^Media_State {
	fmt.println("initializing media scene")

	window_width := f32(rl.GetScreenWidth())
	window_height := f32(rl.GetScreenHeight())
	diameter := math.min(window_width, window_height)

	state := new(Media_State)
	state.poll_timer = POLL_RATE_S // Initialize timer so it immediately fires
	state.artwork.origin = {window_width, window_height} / 2
	state.artwork.dest = {state.artwork.origin.x, state.artwork.origin.y, diameter, diameter}

	state.ha.url = os.get_env("HA_URL", context.allocator)
	state.ha.entity = os.get_env("HA_MEDIA_ENTITY", context.allocator)
	state.ha.authorization = fmt.caprintf(
		"Authorization: Bearer %v",
		os.get_env("HA_TOKEN", context.temp_allocator),
	)
	state.ha.headers = curl.slist_append(state.ha.headers, state.ha.authorization)
	state.ha.headers = curl.slist_append(state.ha.headers, "Content-Type: application/json")

	fmt.printfln("Home Assistant URL: %s", state.ha.url)

	return state
}

media_quit :: proc(state: ^Media_State) {
	fmt.println("quitting media scene")

	curl.slist_free_all(state.ha.headers)

	delete(state.ha.authorization)
	delete(state.ha.entity)
	delete(state.ha.url)
	delete(state.ha.media_content_id)

	rl.UnloadImage(state.artwork.image)
	rl.UnloadTexture(state.artwork.texture)

	free(state)
}

media_update :: proc(state: ^Media_State) {
	// Run poll timer only when we aren't currently checking for updated artwork
	if state.poll_thread == nil do state.poll_timer += rl.GetFrameTime()

	if state.poll_timer >= POLL_RATE_S {
		state.poll_timer = 0
		state.poll_thread = thread.create_and_start_with_data(
			state,
			update_artwork,
			init_context = context,
			self_cleanup = true,
		)
	}
}

media_draw :: proc(state: ^Media_State) {
	rl.ClearBackground(rl.BLANK)

	artwork := &state.artwork

	// Texture must be loaded on the main thread since it runs on GPU
	if sync.mutex_guard(&artwork.mu) {
		if artwork.ready {
			rl.UnloadTexture(artwork.texture)
			artwork.texture = rl.LoadTextureFromImage(artwork.image)
			artwork.ready = false
		}
	}

	if rl.IsTextureValid(artwork.texture) {
		rl.DrawTexturePro(
			artwork.texture,
			{0, 0, f32(artwork.texture.width), f32(artwork.texture.height)},
			artwork.dest,
			artwork.origin,
			artwork.rotation,
			rl.WHITE,
		)

		artwork.rotation += ROTATION_RATE * rl.GetFrameTime()
		artwork.rotation = math.mod(artwork.rotation + 360, 360)
	}
}

@(private)
update_artwork :: proc(data: rawptr) {
	defer free_all(context.temp_allocator)

	state := (^Media_State)(data)
	buffer := make([dynamic]byte, context.temp_allocator)
	defer state.poll_thread = nil

	handle := curl.easy_init()
	defer curl.easy_cleanup(handle)

	// Refresh Spotify entity (since Home Assistant default interval is 30 seconds)

	url := fmt.ctprintf("%v/api/services/script/refresh_spotify", state.ha.url)

	curl.easy_setopt(handle, .URL, url)
	curl.easy_setopt(handle, .HTTPHEADER, state.ha.headers)
	curl.easy_setopt(handle, .POST, 1)
	curl.easy_setopt(handle, .POSTFIELDS, "{}")
	curl.easy_setopt(handle, .WRITEFUNCTION, write_callback)
	curl.easy_setopt(handle, .WRITEDATA, &buffer)

	if result := curl.easy_perform(handle); result != .E_OK {
		fmt.eprintln("error refreshing Spotify:", curl.easy_strerror(result))
		return
	}

	// Fetch media player state

	clear(&buffer)

	url = fmt.ctprintf("%v/api/states/%v", state.ha.url, state.ha.entity)

	curl.easy_reset(handle)
	curl.easy_setopt(handle, .URL, url)
	curl.easy_setopt(handle, .HTTPHEADER, state.ha.headers)
	curl.easy_setopt(handle, .WRITEFUNCTION, write_callback)
	curl.easy_setopt(handle, .WRITEDATA, &buffer)

	if result := curl.easy_perform(handle); result != .E_OK {
		fmt.eprintln("error fetching Home Assistant media state:", curl.easy_strerror(result))
		return
	}

	response: Media_Response
	json.unmarshal(buffer[:], &response, allocator = context.temp_allocator)

	// Check if media changed since last update
	if response.attributes.media_content_id == state.ha.media_content_id ||
	   response.attributes.media_title == "" {
		return
	}

	delete(state.ha.media_content_id)
	state.ha.media_content_id = strings.clone(response.attributes.media_content_id)

	// Download artwork

	clear(&buffer)

	url = fmt.ctprintf("%v%v", state.ha.url, response.attributes.entity_picture)

	curl.easy_reset(handle)
	curl.easy_setopt(handle, .URL, url)
	curl.easy_setopt(handle, .HTTPHEADER, state.ha.headers)
	curl.easy_setopt(handle, .FOLLOWLOCATION, 1)
	curl.easy_setopt(handle, .WRITEFUNCTION, write_callback)
	curl.easy_setopt(handle, .WRITEDATA, &buffer)

	if result := curl.easy_perform(handle); result != .E_OK {
		fmt.eprintln("error downloading artwork:", curl.easy_strerror(result))
		return
	}

	fmt.println("media player state changed:", response.attributes)

	if sync.mutex_guard(&state.artwork.mu) {
		rl.UnloadImage(state.artwork.image)
		state.artwork.image = rl.LoadImageFromMemory(".jpg", raw_data(buffer[:]), i32(len(buffer)))
		state.artwork.ready = true
	}
}

write_callback :: proc "c" (
	buffer: [^]byte,
	size: c.size_t,
	nitems: c.size_t,
	userdata: rawptr,
) -> c.size_t {
	context = runtime.default_context()
	response := (^[dynamic]byte)(userdata)
	total := size * nitems
	append(response, ..buffer[:total])
	return total
}

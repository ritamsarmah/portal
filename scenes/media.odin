package scenes

import "base:runtime"
import "core:c"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "vendor:curl"
import rl "vendor:raylib"

POLL_RATE_S :: 3
ROTATION_RATE :: 32

SUBSONIC_API_VERSION :: "1.16.1"
SUBSONIC_CLIENT :: "portal"

Media_State :: struct {
	poll_timer:  f32,
	poll_thread: ^thread.Thread,
	api_url:     string,
	username:    string,
	password:    string,
	artwork:     struct {
		ready:    bool,
		image:    rl.Image,
		mu:       sync.Mutex,
		texture:  rl.Texture,
		origin:   rl.Vector2,
		dest:     rl.Rectangle,
		rotation: f32,
		id:       string,
	},
}

Now_Playing_Response :: struct {
	subsonic_response: struct {
		now_playing: struct {
			entry: Maybe([]struct {
					id:       string,
					coverArt: string,
				}),
		} `json:"nowPlaying"`,
	} `json:"subsonic-response"`,
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

	state.api_url = os.get_env("SUBSONIC_URL", context.allocator)
	state.username = os.get_env("SUBSONIC_USERNAME", context.allocator)
	state.password = os.get_env("SUBSONIC_PASSWORD", context.allocator)

	fmt.printfln("API URL: %s", state.api_url)

	return state
}

media_quit :: proc(state: ^Media_State) {
	fmt.println("quitting media scene")

	delete(state.api_url)
	delete(state.username)
	delete(state.password)
	delete(state.artwork.id)

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
	defer runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	defer free_all(context.temp_allocator)

	state := (^Media_State)(data)
	buffer := make([dynamic]byte, context.temp_allocator)
	defer state.poll_thread = nil

	handle := curl.easy_init()
	defer curl.easy_cleanup(handle)

	// Fetch media player state

	// NOTE: Skip url encoding since all parameter values are known to be safe in personal use
	// https://subsonic.org/pages/api.jsp#getNowPlaying
	salt, token := salt_password(state.password)
	url := fmt.ctprintf(
		"%v/rest/getNowPlaying.view?u=%v&t=%v&s=%v&v=%v&c=%v&f=json",
		state.api_url,
		state.username,
		token,
		salt,
		SUBSONIC_API_VERSION,
		SUBSONIC_CLIENT,
	)

	curl.easy_setopt(handle, .URL, url)
	curl.easy_setopt(handle, .WRITEFUNCTION, write_callback)
	curl.easy_setopt(handle, .WRITEDATA, &buffer)
	curl.easy_setopt(handle, .SSL_VERIFYPEER, false)
	curl.easy_setopt(handle, .SSL_VERIFYHOST, false)

	if result := curl.easy_perform(handle); result != .E_OK {
		fmt.eprintln("error fetching media player state:", curl.easy_strerror(result))
		return
	}

	response: Now_Playing_Response
	json.unmarshal(buffer[:], &response, allocator = context.temp_allocator)

	entries, is_playing := response.subsonic_response.now_playing.entry.?
	if !is_playing || len(entries) == 0 do return

	artwork_id := entries[0].coverArt

	// Check if cover art has changed since last update
	if artwork_id == state.artwork.id do return

	delete(state.artwork.id)
	state.artwork.id = strings.clone(artwork_id)

	// Download artwork

	clear(&buffer)

	// https://subsonic.org/pages/api.jsp#getCoverArt
	salt, token = salt_password(state.password)
	url = fmt.ctprintf(
		"%v/rest/getCoverArt.view?u=%v&t=%v&s=%v&v=%v&c=%v&id=%v&size=%v",
		state.api_url,
		state.username,
		token,
		salt,
		SUBSONIC_API_VERSION,
		SUBSONIC_CLIENT,
		artwork_id,
		rl.GetScreenWidth(),
	)

	curl.easy_reset(handle)
	curl.easy_setopt(handle, .URL, url)
	curl.easy_setopt(handle, .WRITEFUNCTION, write_callback)
	curl.easy_setopt(handle, .WRITEDATA, &buffer)
	curl.easy_setopt(handle, .SSL_VERIFYPEER, false)
	curl.easy_setopt(handle, .SSL_VERIFYHOST, false)

	if result := curl.easy_perform(handle); result != .E_OK {
		fmt.eprintln("error downloading artwork:", curl.easy_strerror(result))
		return
	}

	fmt.println("album artwork changed")

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

@(private)
salt_password :: proc(password: string, allocator := context.temp_allocator) -> (string, string) {
	salt_bytes: [16]u8
	_ = rand.read(salt_bytes[:])

	salt := string(hex.encode(salt_bytes[:], allocator))
	salted := strings.concatenate({password, salt}, allocator)
	token := hash.hash(.Insecure_MD5, salted, allocator)

	return salt, string(hex.encode(token[:], allocator))
}

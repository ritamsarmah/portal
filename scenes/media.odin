package scenes

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "vendor:curl"
import sdl "vendor:sdl3"
import image "vendor:sdl3/image"

// MusicBrainz API (https://musicbrainz.org/doc/MusicBrainz_API)
MB_API_URL: cstring : "https://musicbrainz.org"
MB_USER_AGENT: cstring : "portal/1.0 ( hello@ritam.me )"
MB_COVER_API_URL :: "https://coverartarchive.org"

ARTWORK_CACHE_DIR :: "artwork"
ARTWORK_CACHE_LIMIT :: 20

POLL_RATE_MS :: 3000
ROTATION_DEG_PER_S :: 32

Artwork_Status :: enum c.int {
	Idle,
	Loading,
	Ready,
}

Media_State :: struct {
	rect:         sdl.FRect,
	angle:        f64,
	mbid:         string,
	last_updated: string,
	poll_timer:   sdl.TimerID,
	artwork:      struct {
		status:   sdl.AtomicInt,
		filename: cstring,
		texture:  ^sdl.Texture,
	},
	ha:           struct {
		url:           cstring,
		authorization: cstring,
		headers:       ^curl.slist,
	},
}

HA_Media_Attributes :: struct {
	media_title:      string,
	media_artist:     string,
	media_album_name: string,
}

HA_Media_Response :: struct {
	attributes:   HA_Media_Attributes,
	last_updated: string,
}

MB_Release_Response :: struct {
	releases: []struct {
		id: string,
	},
}
media_init :: proc(window_size: sdl.Point) -> ^Media_State {
	defer free_all(context.temp_allocator)

	os.make_directory(ARTWORK_CACHE_DIR)

	state := new(Media_State)

	diameter := f32(math.min(window_size.x, window_size.y))
	state.rect = sdl.FRect{0, 0, diameter, diameter}

	state.ha.url = strings.clone_to_cstring(os.get_env("HA_MEDIA_URL", context.temp_allocator))
	state.ha.authorization = fmt.caprintf(
		"Authorization: Bearer %v",
		os.get_env("HA_TOKEN", context.temp_allocator),
	)
	state.ha.headers = curl.slist_append(state.ha.headers, state.ha.authorization)
	state.ha.headers = curl.slist_append(state.ha.headers, "Content-Type: application/json")

	sdl.Log("Home Assistant URL: %s", state.ha.url)

	state.poll_timer = sdl.AddTimer(0, update_artwork, state) // NOTE: Runs on separate thread

	_ = sdl.SetAtomicInt(&state.artwork.status, i32(Artwork_Status.Idle))

	return state
}

media_iterate :: proc(state: ^Media_State, renderer: ^sdl.Renderer, dt: f64) -> sdl.AppResult {
	sdl.SetRenderDrawColor(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
	sdl.RenderClear(renderer)

	artwork_status := Artwork_Status(sdl.GetAtomicInt(&state.artwork.status))

	switch artwork_status {
	case .Idle, .Loading:
		if state.artwork.texture != nil {
			sdl.RenderTextureRotated(
				renderer,
				state.artwork.texture,
				nil,
				&state.rect,
				state.angle,
				nil,
				.NONE,
			)

			state.angle += ROTATION_DEG_PER_S * dt
			state.angle = math.mod(state.angle + 360, 360)
		}
	case .Ready:
		sdl.DestroyTexture(state.artwork.texture)
		state.artwork.texture = image.LoadTexture(renderer, state.artwork.filename)
		_ = sdl.SetAtomicInt(&state.artwork.status, i32(Artwork_Status.Idle))
	}

	sdl.RenderPresent(renderer)

	return .CONTINUE
}

media_quit :: proc(state: ^Media_State) {
	sdl.Log("quitting media scene")

	_ = sdl.RemoveTimer(state.poll_timer)

	curl.slist_free_all(state.ha.headers)
	delete(state.ha.authorization)
	delete(state.ha.url)

	delete(state.artwork.filename)
	sdl.DestroyTexture(state.artwork.texture)

	free(state)
}

@(private)
update_artwork :: proc "c" (
	userdata: rawptr,
	timer_id: sdl.TimerID,
	interval: sdl.Uint32,
) -> sdl.Uint32 {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	state := cast(^Media_State)userdata
	data := make([dynamic]byte, context.temp_allocator)
	attributes: HA_Media_Attributes

	artwork_status := Artwork_Status(sdl.GetAtomicInt(&state.artwork.status))
	if artwork_status == .Loading do return POLL_RATE_MS

	{ 	// Fetch Home Assistant media player state
		handle := curl.easy_init()
		defer curl.easy_cleanup(handle)

		curl.easy_setopt(handle, .URL, state.ha.url)
		curl.easy_setopt(handle, .HTTPHEADER, state.ha.headers)
		curl.easy_setopt(handle, .WRITEFUNCTION, write_callback)
		curl.easy_setopt(handle, .WRITEDATA, &data)

		if result := curl.easy_perform(handle); result != .E_OK {
			sdl.Log("error fetching Home Assistant media state: %s", curl.easy_strerror(result))
			return 0
		}

		// Check if there is media state change since last update
		response: HA_Media_Response
		json.unmarshal(data[:], &response, allocator = context.temp_allocator)

		if response.last_updated == state.last_updated || response.attributes.media_title == "" {
			return POLL_RATE_MS
		}

		attributes = response.attributes
		state.last_updated = response.last_updated

		sdl.Log("media player state changed")
		_ = sdl.SetAtomicInt(&state.artwork.status, i32(Artwork_Status.Loading))
	}

	{ 	// Fetch release ID from MusicBrainz API
		clear(&data)

		url := curl.url()
		defer curl.url_cleanup(url)

		query := fmt.ctprintf(
			"query=release:%v AND artist:%v",
			attributes.media_album_name,
			attributes.media_artist,
		)

		curl.url_set(url, .URL, MB_API_URL, {})
		curl.url_set(url, .PATH, "/ws/2/release", {})
		curl.url_set(url, .QUERY, query, {.APPENDQUERY, .URLENCODE})
		curl.url_set(url, .QUERY, "limit=1", {.APPENDQUERY})
		curl.url_set(url, .QUERY, "fmt=json", {.APPENDQUERY})

		handle := curl.easy_init()
		defer curl.easy_cleanup(handle)

		curl.easy_setopt(handle, .CURLU, url)
		curl.easy_setopt(handle, .USERAGENT, MB_USER_AGENT)
		curl.easy_setopt(handle, .WRITEFUNCTION, write_callback)
		curl.easy_setopt(handle, .WRITEDATA, &data)

		sdl.Log("fetching MusicBrainz release ID")

		if result := curl.easy_perform(handle); result != .E_OK {
			sdl.Log("error fetching MusicBrainz release ID: %s", curl.easy_strerror(result))
			return 0
		}

		response: MB_Release_Response
		json.unmarshal(data[:], &response, allocator = context.temp_allocator)

		// Check if there is available release info
		if len(response.releases) == 0 do return POLL_RATE_MS

		// Check if the album has changed
		// This handles new songs from same album, which have same artwork
		release_id := response.releases[0].id
		if release_id == state.mbid do return POLL_RATE_MS

		state.mbid = release_id
	}

	{ 	// Update album artwork from cache or URL
		filename := fmt.tprintf("%v/%v.jpg", ARTWORK_CACHE_DIR, state.mbid)

		if !os.exists(filename) {
			clear(&data)

			url := curl.url()
			defer curl.url_cleanup(url)

			path := fmt.ctprintf("release/%v/front", state.mbid)

			curl.url_set(url, .URL, MB_COVER_API_URL, {})
			curl.url_set(url, .PATH, path, {})

			handle := curl.easy_init()
			defer curl.easy_cleanup(handle)

			curl.easy_setopt(handle, .CURLU, url)
			curl.easy_setopt(handle, .FOLLOWLOCATION, 1)
			curl.easy_setopt(handle, .USERAGENT, MB_USER_AGENT)
			curl.easy_setopt(handle, .WRITEFUNCTION, write_callback)
			curl.easy_setopt(handle, .WRITEDATA, &data)

			sdl.Log("fetching artwork for release: %s", state.mbid)

			if result := curl.easy_perform(handle); result != .E_OK {
				sdl.Log("error fetching artwork: %s", curl.easy_strerror(result))
				return 0
			}

			err := os.write_entire_file(filename, data[:])
			if err != nil {
				sdl.Log("failed to cache artwork")
				return 0
			}

			evict_artwork_cache()
		} else {
			sdl.Log("using cached artwork for release: %s", state.mbid)
		}

		delete(state.artwork.filename)
		state.artwork.filename = strings.clone_to_cstring(filename)
		_ = sdl.SetAtomicInt(&state.artwork.status, i32(Artwork_Status.Ready))

		sdl.Log("updated artwork for release: %s", state.mbid)
	}

	return POLL_RATE_MS
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
evict_artwork_cache :: proc() {
	entries, err := os.read_directory_by_path(ARTWORK_CACHE_DIR, 0, context.allocator)
	defer delete(entries)

	files := make([dynamic]string)
	defer delete(files)

	for e in entries {
		path := fmt.tprintf("%v/%v", ARTWORK_CACHE_DIR, e.name)
		append(&files, path)
	}

	if len(files) <= ARTWORK_CACHE_LIMIT do return

	slice.sort_by(files[:], proc(a, b: string) -> bool {
		time_a, _ := os.modification_time_by_path(a)
		time_b, _ := os.modification_time_by_path(b)
		return time_a._nsec < time_b._nsec
	})

	excess := len(files) - ARTWORK_CACHE_LIMIT

	sdl.Log("evicting %d images from cache", excess)

	for i in 0 ..< excess do _ = os.remove(files[i])
}

local LIKED = { track = "tracks", album = "albums", artist = "followed" }
local MIXES = 3
local BROWSER_LOGINS = { "/login/google", "/login/facebook", "/login/apple", "accounts.google.com" }

local worker = nari.thread("library.lua")
nari.thread("session.lua", { name = "session" }):on_error(function(problem) nari.log("the session thread stopped: " .. problem) end)
nari.thread("source.lua"):on_error(function(problem) nari.log("the audio thread stopped: " .. problem) end)

local state = {
	account = nari.get("account"),
	library = nari.get("library"),
	loading = false,
	progress = 0,
}
if state.library and state.library.version ~= 2 then
	state.library = nil
end
local index = { tracks = {}, items = {}, covers = state.library and state.library.covers or {} }
local waiting, pending, requests = {}, {}, 0
local me
local refresh, forget, login

local function notify(text)
	local dialog = Dialog.menu("Spotify", text)
	dialog:add_option("OK", function() end)
	dialog:popup()
end

local function ask(message, handler)
	requests = requests + 1
	message.request = requests
	pending[requests] = handler
	worker:send(message)
end

worker:on_message(function(message)
	if message.progress then
		state.progress = message.progress
		return
	end
	if message.signed_in ~= nil then
		if login then
			login:close()
		end
		if not message.signed_in then
			forget()
			return notify(message.problem)
		end
		state.account = message.account
		me.settings_changed:emit()
		return refresh()
	end
	local handler = pending[message.request]
	pending[message.request] = nil
	if handler then
		handler(message)
	end
end)

worker:on_error(function(problem)
	nari.log("the library thread stopped: " .. problem)
end)

local function remember(item)
	if item and item.art then
		index.covers[item.id] = item.art
		if item.album_id and item.album_id ~= "" and not index.covers[item.album_id] then
			index.covers[item.album_id] = item.art
		end
	end
	return item
end

local function remember_all(list)
	for _, item in ipairs(list or {}) do
		remember(item)
		if item.album_id and item.duration then
			index.tracks[item.id] = index.tracks[item.id] or item
		else
			index.items[item.id] = index.items[item.id] or item
		end
	end
	return list or {}
end

local function newest_first(list)
	table.sort(list, function(first, second) return (first.liked_at or 0) > (second.liked_at or 0) end)
end

local function build(library)
	local artists, known = {}, {}
	newest_first(library.tracks)
	newest_first(library.albums)
	for _, track in ipairs(library.tracks) do
		index.tracks[track.id] = track
		remember(track)
	end
	for _, item in ipairs(library.albums) do
		index.items[item.id] = item
		remember(item)
	end
	for _, item in ipairs(library.followed) do
		item.album_count, item.song_count = 0, 0
		index.items[item.id] = item
		known[item.id] = item
		remember(item)
		table.insert(artists, item)
	end
	local function add(id, name, field, cover)
		if not id or id == "" then
			return
		end
		local entry = known[id]
		if not entry then
			entry = { id = id, name = name or "", album_count = 0, song_count = 0, cover_album_id = cover }
			known[id] = entry
			table.insert(artists, entry)
		end
		entry[field] = entry[field] + 1
	end
	for _, track in ipairs(library.tracks) do
		add(track.artist_id, track.artists[1], "song_count", track.album_id)
	end
	for _, item in ipairs(library.albums) do
		add(item.artist_id, item.artists[1], "album_count", item.id)
	end
	local names = {}
	for _, artist in ipairs(artists) do
		names[artist] = artist.name:lower()
	end
	table.sort(artists, function(first, second) return names[first] < names[second] end)
	library.artists = artists
	library.covers = index.covers
	library.version = 2
end

local function finish_waiting()
	local handlers = waiting
	waiting = {}
	for _, handler in ipairs(handlers) do
		handler()
	end
end

local function when_loaded(done, read)
	if state.library or not state.loading then
		return read()
	end
	table.insert(waiting, function() done(read()) end)
end

function refresh()
	if state.loading or not nari.get("refresh_token") then
		return
	end
	state.loading = true
	state.progress = 0
	ask({ action = "library" }, function(message)
		state.loading = false
		if message.error then
			nari.log("the library couldn't be loaded: " .. message.error)
			finish_waiting()
			return me.library_ready:emit(false, message.error)
		end
		build(message.library)
		state.library = message.library
		nari.set("library", state.library)
		finish_waiting()
		me.library_changed:emit()
		me.library_ready:emit(true, "")
	end)
end

function forget()
	for id in pairs(nari.get("offline_keys") or {}) do
		MediaPlayer.downloads:remove("spotify", id)
	end
	for _, key in ipairs({ "refresh_token", "access", "account", "library", "username", "product", "country", "offline_keys", "offline_checked" }) do
		nari.set(key, nil)
	end
	state.account, state.library = nil, nil
	index = { tracks = {}, items = {}, covers = {} }
	me.settings_changed:emit()
	me.library_changed:emit()
end

local function sign_in()
	ask({ action = "sign_in" }, function(message)
		if message.error then
			return notify(message.error)
		end
		login = nari.webview({
			title = "Sign in to Spotify",
			url = message.url,
			incognito = true,
			on_start = function(web, url)
				for _, provider in ipairs(BROWSER_LOGINS) do
					if url:find(provider, 1, true) then
						web:close()
						nari.open_url(message.url)
						return Snackbar.post("Continue in your browser", "Choose the same option there to finish signing in to Spotify")
					end
				end
			end,
			on_close = function() login = nil end,
		})
		if not login then
			nari.open_url(message.url)
		end
	end)
end

local function cover_url(id, thumb)
	local urls = index.covers[id]
	return urls and urls[thumb and 2 or 1] or nil
end

local function cover_file(url)
	return "covers/" .. url:match("[^/]+$"):gsub("[^%w]", "") .. ".jpg"
end

local function failed(what, message)
	nari.log(what .. " failed: " .. message.error)
end

local provider = {
	id = "spotify",
	name = "Spotify",
	description = "Your Spotify library (Premium)",
	color = "#1db954",
	streams = true,
	auto_discover = false,
}

function provider.is_configured()
	return nari.get("refresh_token") ~= nil
end

function provider.is_loading()
	return state.loading and not state.library
end

function provider.is_ready()
	return state.library ~= nil
end

function provider.get_status()
	return Dictionary({ progress = state.progress })
end

function provider.setup_entries()
	return {
		{
			title = "Spotify account",
			description = state.account and ("Signed in as " .. state.account) or "Sign in with your Spotify Premium account",
			icon = "res://assets/icons/artist.svg",
			value = function() return state.account and "Change" or "Sign in" end,
			action = sign_in,
		},
	}
end

function provider.settings_entries()
	local entries = provider.setup_entries()
	if nari.get("refresh_token") then
		table.insert(entries, {
			title = "Refresh library",
			description = state.loading and "Loading your library..." or "Load your songs, albums and artists again",
			icon = "res://assets/icons/repeat.svg",
			action = refresh,
		})
		table.insert(entries, {
			title = "Sign out",
			description = "Forget your Spotify account and library",
			icon = "res://assets/icons/close.svg",
			action = function() Dialog.confirm("Sign out of Spotify?", "Sign out", forget, true) end,
		})
	end
	return entries
end

local function library_list(key)
	return function(self, done)
		return when_loaded(done, function() return state.library and state.library[key] or {} end)
	end
end

provider.get_tracks = library_list("tracks")
provider.get_albums = library_list("albums")
provider.get_artists = library_list("artists")

function provider.get_song(self, id, done)
	if index.tracks[id] then
		return index.tracks[id]
	end
	ask({ action = "song", id = id }, function(message)
		done(message.song and remember_all({ message.song })[1] or Dictionary())
	end)
end

function provider.get_album(self, id, done)
	ask({ action = "album", id = id }, function(message)
		if message.error then
			failed("loading album " .. id, message)
			return done(Dictionary())
		end
		remember(message.album)
		remember_all(message.album.tracks)
		done(message.album)
	end)
end

function provider.get_artist(self, id, done)
	ask({ action = "artist", id = id }, function(message)
		if message.error then
			failed("loading artist " .. id, message)
			return done(Dictionary())
		end
		remember(message.artist)
		remember_all(message.artist.albums)
		remember_all(message.artist.tracks)
		remember_all(message.artist.related)
		done(message.artist)
	end)
end

function provider.get_cover_path(self, kind, id, thumb, done)
	local url = cover_url(id, thumb)
	if not url then
		return ""
	end
	local file = cover_file(url)
	local path = nari.plugin.data .. "/" .. file
	if FileAccess:file_exists(path) then
		return path
	end
	nari.http({ url = url, save = file }, function(response)
		done(response and response.status == 200 and response.path or "")
	end)
end

function provider.playable(self, tracks)
	local list = {}
	for _, track in ipairs(tracks) do
		local url = cover_url(track.album_id ~= "" and track.album_id or track.id, false) or ""
		table.insert(list, {
			id = track.id,
			title = track.title,
			artist = track.artist,
			artist_id = track.artist_id,
			album = track.album,
			album_id = track.album_id,
			duration = track.duration,
			uri = "spotify:" .. track.id,
			file_name = track.id .. ".ogg",
			cover = url ~= "" and (nari.plugin.data .. "/" .. cover_file(url)) or "",
			cover_url = url,
			public_cover_url = url,
			share_url = "https://open.spotify.com/track/" .. track.id,
		})
	end
	return list
end

function provider.search(self, query, filters, done)
	local terms = { query }
	for _, field in ipairs({ "title", "artist", "album", "genre" }) do
		if filters and filters[field] and filters[field] ~= "" then
			table.insert(terms, filters[field])
		end
	end
	local text = table.concat(terms, " "):match("^%s*(.-)%s*$")
	if text == "" then
		return { tracks = {}, albums = {}, artists = {} }
	end
	ask({ action = "search", query = text }, function(message)
		if message.error then
			failed("searching", message)
			return done({ tracks = {}, albums = {}, artists = {} })
		end
		for _, key in ipairs({ "tracks", "albums", "artists" }) do
			remember_all(message.result[key])
		end
		done(message.result)
	end)
end

function provider.get_playlists(self, done)
	ask({ action = "playlists" }, function(message)
		if message.error then
			failed("loading playlists", message)
			return done({})
		end
		for _, playlist in ipairs(message.playlists) do
			index.covers[playlist.id] = playlist.picture or index.covers[playlist.id]
		end
		done(message.playlists)
	end)
end

function provider.get_playlist(self, id, done)
	ask({ action = "playlist", id = id }, function(message)
		if message.error then
			failed("loading playlist " .. id, message)
			return done(Dictionary())
		end
		remember_all(message.playlist.tracks)
		index.covers[id] = message.playlist.picture or index.covers[id]
		done(message.playlist)
	end)
end

local function change(message, done, result)
	ask(message, function(answer)
		if answer.error then
			failed(message.action, answer)
		end
		done(result and result(answer) or true)
	end)
end

function provider.create_playlist(self, name, done)
	change({ action = "create", name = name }, done, function(answer) return answer.id or "" end)
end

function provider.delete_playlist(self, id, done)
	change({ action = "delete", id = id }, done)
end

function provider.rename_playlist(self, id, name, done)
	change({ action = "rename", id = id, name = name }, done)
end

function provider.add_to_playlist(self, id, song_ids, done)
	local songs = {}
	for _, song_id in ipairs(song_ids) do
		table.insert(songs, song_id)
	end
	change({ action = "add", id = id, songs = songs }, done)
end

function provider.remove_from_playlist(self, id, song_id, done)
	change({ action = "remove", id = id, song = song_id }, done)
end

function provider.get_liked(self, kind, done)
	return when_loaded(done, function() return state.library and state.library[LIKED[kind]] or {} end)
end

function provider.set_liked(self, kind, id, on, done)
	ask({ action = "like", kind = kind, id = id, on = on }, function(message)
		if message.error then
			failed("saving the like", message)
			return done(true)
		end
		local library = state.library
		if library and LIKED[kind] then
			local list = library[LIKED[kind]]
			for position = #list, 1, -1 do
				if list[position].id == id then
					table.remove(list, position)
				end
			end
			local item = kind == "track" and index.tracks[id] or index.items[id]
			if on and item then
				item.liked_at = os.time()
				table.insert(list, 1, item)
			end
			build(library)
			nari.set("library", library)
			me.library_changed:emit()
		end
		done(true)
	end)
end

function provider.get_discover(self, done)
	local seeds = {}
	for _, track in ipairs(state.library and state.library.tracks or {}) do
		if #seeds < MIXES then
			table.insert(seeds, { id = track.id, title = track.title })
		end
	end
	if #seeds == 0 then
		return {}
	end
	ask({ action = "discover", seeds = seeds }, function(message)
		if message.error then
			failed("loading Discover", message)
			return done({})
		end
		for _, section in ipairs(message.sections) do
			remember_all(section.items)
		end
		done(message.sections)
	end)
end

me = nari.music_provider(provider)
if state.library then
	build(state.library)
end
refresh()

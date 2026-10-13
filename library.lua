local auth = require("auth")
local proto = require("proto")
local spotify = require("spotify")

local COLLECTION = "application/vnd.collection-v2.spotify.proto"
local ARTIST_ALBUMS = 60
local RELATED_ARTISTS = 12
local RELEASE_GROUPS = { [5] = "album", [6] = "single", [7] = "compilation", [8] = "appears_on" }
local SEARCH_RESULTS = 40
local MIX_SIZE = 20
local PORT = 8989
local REDIRECT = "http://127.0.0.1:" .. PORT .. "/login"
local updates = 0
local server

local function account()
	local username = nari.get("username")
	if username then
		return username
	end
	local answer, problem = nari.ask("session", { account = true }, 40)
	if not answer then
		error(problem, 0)
	end
	return answer.username
end

local function stamp(value)
	if type(value) == "string" then
		return string.unpack(#value == 8 and "<i8" or "<i4", value)
	end
	return value
end

local function collection(set)
	local username = account()
	local found, token = {}, ""
	repeat
		local body = proto.bytes(1, username) .. proto.bytes(2, set) .. proto.bytes(3, token) .. proto.int(4, 300)
		local page = proto.decode(spotify.request("POST", "/collection/v2/paging", body, { ["Content-Type"] = COLLECTION, Accept = COLLECTION }))
		for _, raw in ipairs(proto.list(page, 1)) do
			local item = proto.decode(raw)
			if (proto.path(item, 3) or 0) == 0 and proto.path(item, 1) then
				table.insert(found, { uri = proto.path(item, 1), added_at = stamp(proto.path(item, 2)) })
			end
		end
		token = proto.path(page, 2) or ""
	until token == ""
	return found
end

local function saved(items, prefix, kind, map)
	local uris, added = {}, {}
	for _, item in ipairs(items) do
		if item.uri:sub(1, #prefix) == prefix then
			table.insert(uris, item.uri)
			added[item.uri] = item.added_at
		end
	end
	local list = spotify.load(uris, kind, map)
	for _, entry in ipairs(list) do
		entry.liked_at = added[prefix .. entry.id]
	end
	return list
end

local function uris_of(raws, prefix)
	local uris = {}
	for _, raw in ipairs(raws) do
		local gid = proto.path(proto.decode(raw), 1)
		if gid then
			table.insert(uris, prefix .. proto.base62(gid))
		end
	end
	return uris
end

local function total(tracks)
	local duration = 0
	for _, track in ipairs(tracks) do
		duration = duration + track.duration
	end
	return duration
end

local function picture(attributes)
	local sizes = {}
	for _, raw in ipairs(proto.list(attributes, 13)) do
		local size = proto.decode(raw)
		sizes[proto.path(size, 1) or ""] = proto.path(size, 2)
	end
	local big = sizes.large or sizes.xlarge or sizes.default
	if big then
		return { big, sizes.default or big }
	end
	local raw = proto.path(attributes, 3)
	if raw and raw ~= "" then
		local url = "https://i.scdn.co/image/" .. proto.hex(raw)
		return { url, url }
	end
end

local function playlist_content(id)
	return spotify.protobuf("GET", "/playlist/v2/playlist/" .. id .. "?from=0&length=10000")
end

local function playlist_items(content)
	local items = proto.path(content, 5)
	return items and proto.list(proto.decode(items), 3) or {}
end

local function item_uri(raw)
	return proto.path(proto.decode(raw), 1) or ""
end

local function playlist_tracks(content, limit)
	local uris = {}
	for _, raw in ipairs(playlist_items(content)) do
		local uri = item_uri(raw)
		if uri:match("^spotify:track:") and (not limit or #uris < limit) then
			table.insert(uris, uri)
		end
	end
	return spotify.load(uris, spotify.TRACK, spotify.track)
end

local function rootlist()
	return spotify.protobuf("GET", "/playlist/v2/user/" .. auth.encode(account())
		.. "/rootlist?decorate=revision,attributes,length,owner,capabilities,status_code&from=0&length=10000")
end

local function changes(revision, op)
	local info = proto.bytes(4, proto.bytes(10, proto.int(1, 2)))
	return (revision and proto.bytes(1, revision) or "") .. proto.bytes(2, proto.bytes(2, op) .. info) .. proto.int(3, 1)
end

local function add_op(uris)
	local items = {}
	for _, uri in ipairs(uris) do
		table.insert(items, proto.bytes(2, proto.bytes(1, uri)))
	end
	return proto.int(1, 2) .. proto.bytes(2, table.concat(items) .. proto.int(4, 1))
end

local function remove_op(uri, index)
	return proto.int(1, 3) .. proto.bytes(3, proto.int(1, index) .. proto.int(2, 1) .. proto.bytes(3, proto.bytes(1, uri)) .. proto.int(7, 1))
end

local function attributes_op(attributes)
	return proto.int(1, 6) .. proto.bytes(6, proto.bytes(1, proto.bytes(1, attributes)))
end

local function position(content, uri)
	for index, raw in ipairs(playlist_items(content)) do
		if item_uri(raw) == uri then
			return index - 1
		end
	end
end

local function edit(path, body)
	return spotify.protobuf("POST", path, body)
end

local function rootlist_path()
	return "/playlist/v2/user/" .. auth.encode(account()) .. "/rootlist/changes"
end

local actions = {}

function actions.account(message)
	local answer, problem = nari.ask("session", { account = true, fresh = message and message.fresh }, 40)
	if not answer then
		error(problem, 0)
	end
	if not answer.username then
		error("Spotify didn't say which account signed in, try again.", 0)
	end
	local ok, profile = pcall(spotify.json, "/user-profile-view/v3/profile/" .. auth.encode(answer.username))
	return { username = answer.username, product = answer.product, name = ok and profile.name or answer.username }
end

local function finish_sign_in(verifier, code)
	local response, problem = nari.http({
		method = "POST",
		url = "https://accounts.spotify.com/api/token",
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
		body = auth.form({ grant_type = "authorization_code", code = code, redirect_uri = REDIRECT, client_id = auth.CLIENT_ID, code_verifier = verifier }),
	})
	local body = auth.decode(response)
	if not body.access_token then
		error("Spotify didn't sign you in: " .. tostring(problem or body.error_description or body.error), 0)
	end
	nari.set("username", nil)
	auth.save(body)
	local found = actions.account({ fresh = true })
	if found.product and found.product ~= "" and found.product ~= "premium" then
		error("This plugin needs Spotify Premium.", 0)
	end
	nari.set("account", found.name)
	return found.name
end

local function page(text)
	return "<h1>" .. tostring(text):gsub("[<>&]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" }) .. "</h1>"
end

function actions.sign_in()
	if server then
		server.stop()
	end
	local verifier = nari.base64_encode(nari.random_bytes(48), true)
	local nonce = nari.base64_encode(nari.random_bytes(16), true)
	local ok, started = pcall(nari.serve, function(request)
		if request.path ~= "/login" or request.query.state ~= nonce then
			return { status = 404, body = "Not here" }
		end
		server.stop()
		server = nil
		if not request.query.code then
			nari.send({ signed_in = false, problem = "Spotify sign in was cancelled." })
			return page("Sign in cancelled, you can go back to Nari")
		end
		local signed, result = pcall(finish_sign_in, verifier, request.query.code)
		if not signed then
			nari.set("refresh_token", nil)
			nari.set("access", nil)
			nari.send({ signed_in = false, problem = tostring(result) })
			return page(result)
		end
		nari.send({ signed_in = true, account = result })
		return page("Signed in as " .. result .. ", you can go back to Nari") .. "<script>location.href = 'nari://plugin/spotify/signed-in'</script>"
	end, { port = PORT })
	if not ok then
		error("Port " .. PORT .. " is busy, close the app using it and try again.", 0)
	end
	server = started
	return { url = "https://accounts.spotify.com/authorize?" .. auth.form({
		response_type = "code",
		client_id = auth.CLIENT_ID,
		redirect_uri = REDIRECT,
		scope = auth.SCOPES,
		code_challenge_method = "S256",
		code_challenge = nari.base64_encode(nari.sha256(verifier, true), true),
		state = nonce,
	}) }
end

function actions.library()
	local items = collection("collection")
	nari.send({ progress = 0.15 })
	local tracks = saved(items, "spotify:track:", spotify.TRACK, spotify.track)
	nari.send({ progress = 0.7 })
	local albums = saved(items, "spotify:album:", spotify.ALBUM, spotify.album)
	nari.send({ progress = 0.9 })
	local followed = saved(collection("artist"), "spotify:artist:", spotify.ARTIST, spotify.artist)
	return { library = { tracks = tracks, albums = albums, followed = followed } }
end

function actions.song(message)
	local uri = "spotify:track:" .. message.id
	return { song = spotify.load({ uri }, spotify.TRACK, spotify.track)[1] }
end

function actions.album(message)
	local uri = "spotify:album:" .. message.id
	local fields = spotify.metadata({ uri }, spotify.ALBUM)[uri]
	if not fields then
		error("Spotify has no data for this album", 0)
	end
	local album = spotify.album(fields)
	local uris = {}
	for _, disc in ipairs(proto.list(fields, 11)) do
		for _, uri_of in ipairs(uris_of(proto.list(proto.decode(disc), 3), "spotify:track:")) do
			table.insert(uris, uri_of)
		end
	end
	album.tracks = spotify.load(uris, spotify.TRACK, spotify.track)
	album.duration = total(album.tracks)
	return { album = album }
end

function actions.artist(message)
	local uri = "spotify:artist:" .. message.id
	local fields = spotify.metadata({ uri }, spotify.ARTIST)[uri]
	if not fields then
		error("Spotify has no data for this artist", 0)
	end
	local artist = spotify.artist(fields)
	local albums, kinds = {}, {}
	for _, group in ipairs({ 5, 6, 7, 8 }) do
		for _, raw in ipairs(proto.list(fields, group)) do
			for _, album_uri in ipairs(uris_of(proto.list(proto.decode(raw), 1), "spotify:album:")) do
				if #albums < ARTIST_ALBUMS and not kinds[album_uri] then
					kinds[album_uri] = RELEASE_GROUPS[group]
					table.insert(albums, album_uri)
				end
			end
		end
	end
	local top, country = {}, nari.get("country")
	for _, raw in ipairs(proto.list(fields, 4)) do
		local entry = proto.decode(raw)
		if #top == 0 or proto.path(entry, 1) == country then
			top = uris_of(proto.list(entry, 2), "spotify:track:")
		end
	end
	artist.albums = spotify.load(albums, spotify.ALBUM, spotify.album)
	for _, album in ipairs(artist.albums) do
		album.release_type = kinds["spotify:album:" .. album.id]
	end
	artist.tracks = spotify.load(top, spotify.TRACK, spotify.track)
	artist.top_tracks = artist.tracks
	local related = uris_of(proto.list(fields, 15), "spotify:artist:")
	artist.related = spotify.load({ table.unpack(related, 1, math.min(#related, RELATED_ARTISTS)) }, spotify.ARTIST, spotify.artist)
	for _, raw in ipairs(proto.list(fields, 12)) do
		local text = proto.path(proto.decode(raw), 1)
		if text and text ~= "" then
			artist.bio = text:gsub("<[^>]+>", "")
			break
		end
	end
	artist.album_count = #artist.albums
	artist.song_count = #artist.tracks
	artist.duration = total(artist.tracks)
	return { artist = artist }
end

function actions.search(message)
	local query = message.query:gsub("[^%w%-_%.~ ]", function(char) return string.format("%%%02X", char:byte()) end):gsub(" ", "+")
	local context = spotify.json("/context-resolve/v1/spotify:search:" .. query)
	local uris = {}
	for _, page in ipairs(context.pages or {}) do
		for _, track in ipairs(page.tracks or {}) do
			if (track.uri or ""):match("^spotify:track:") and #uris < SEARCH_RESULTS then
				table.insert(uris, track.uri)
			end
		end
	end
	local tracks = spotify.load(uris, spotify.TRACK, spotify.track)
	local albums, artists, seen = {}, {}, {}
	for _, track in ipairs(tracks) do
		if track.album_id ~= "" and not seen[track.album_id] then
			seen[track.album_id] = true
			table.insert(albums, "spotify:album:" .. track.album_id)
		end
		if track.artist_id ~= "" and not seen[track.artist_id] then
			seen[track.artist_id] = true
			table.insert(artists, "spotify:artist:" .. track.artist_id)
		end
	end
	return { result = {
		tracks = tracks,
		albums = spotify.load({ table.unpack(albums, 1, math.min(#albums, 12)) }, spotify.ALBUM, spotify.album),
		artists = spotify.load({ table.unpack(artists, 1, math.min(#artists, 12)) }, spotify.ARTIST, spotify.artist),
	} }
end

function actions.playlists()
	local content = proto.path(rootlist(), 5)
	local list = {}
	if not content then
		return { playlists = list }
	end
	local fields = proto.decode(content)
	local metas = proto.list(fields, 4)
	for index, raw in ipairs(proto.list(fields, 3)) do
		local id = item_uri(raw):match("^spotify:playlist:(.+)$")
		local meta = metas[index] and proto.decode(metas[index]) or {}
		local attributes = proto.decode(proto.path(meta, 2) or "")
		if id then
			table.insert(list, {
				id = id,
				name = proto.path(attributes, 1) or "",
				song_count = proto.path(meta, 3) or 0,
				duration = 0,
				modified = 0,
				cover_album_ids = { id },
				image = "",
				owner = proto.path(meta, 5) or "",
				picture = picture(attributes),
			})
		end
	end
	return { playlists = list }
end

function actions.playlist(message)
	local content = playlist_content(message.id)
	local attributes = proto.decode(proto.path(content, 3) or "")
	local tracks = playlist_tracks(content)
	return { playlist = {
		id = message.id,
		name = proto.path(attributes, 1) or "",
		song_count = #tracks,
		duration = total(tracks),
		modified = 0,
		cover_album_ids = { message.id },
		image = "",
		tracks = tracks,
		picture = picture(attributes) or (tracks[1] and tracks[1].art),
	} }
end

function actions.create(message)
	local reply = edit("/playlist/v2/playlist", changes(nil, attributes_op(proto.bytes(1, message.name))))
	local id = (proto.path(reply, 1) or ""):match("^spotify:playlist:(.+)$")
	if not id then
		error("Spotify didn't create the playlist", 0)
	end
	edit("/playlist/v2/playlist/" .. id .. "/changes", changes(nil, attributes_op(proto.bytes(1, message.name))))
	edit(rootlist_path(), changes(proto.path(rootlist(), 1), add_op({ "spotify:playlist:" .. id })))
	return { id = id }
end

function actions.rename(message)
	edit("/playlist/v2/playlist/" .. message.id .. "/changes", changes(nil, attributes_op(proto.bytes(1, message.name))))
	return {}
end

function actions.delete(message)
	local root = rootlist()
	local uri = "spotify:playlist:" .. message.id
	local content = proto.path(root, 5)
	local index = 0
	for position_of, raw in ipairs(content and proto.list(proto.decode(content), 3) or {}) do
		if item_uri(raw) == uri then
			index = position_of - 1
		end
	end
	edit(rootlist_path(), changes(proto.path(root, 1), remove_op(uri, index)))
	pcall(edit, "/playlist/v2/playlist/" .. message.id .. "/changes", changes(nil, attributes_op(proto.int(6, 1))))
	return {}
end

function actions.add(message)
	local uris = {}
	for _, id in ipairs(message.songs) do
		table.insert(uris, "spotify:track:" .. id)
	end
	local content = playlist_content(message.id)
	edit("/playlist/v2/playlist/" .. message.id .. "/changes", changes(proto.path(content, 1), add_op(uris)))
	return {}
end

function actions.remove(message)
	local content = playlist_content(message.id)
	local uri = "spotify:track:" .. message.song
	local index = position(content, uri)
	if index then
		edit("/playlist/v2/playlist/" .. message.id .. "/changes", changes(proto.path(content, 1), remove_op(uri, index)))
	end
	return {}
end

function actions.like(message)
	updates = updates + 1
	local item = proto.bytes(1, "spotify:" .. message.kind .. ":" .. message.id)
		.. proto.int(2, message.on and os.time() or 0)
		.. proto.int(3, message.on and 0 or 1)
	local body = proto.bytes(1, account()) .. proto.bytes(2, message.kind == "artist" and "artist" or "collection")
		.. proto.bytes(3, item) .. proto.bytes(4, "nari-" .. os.time() .. "-" .. updates)
	spotify.request("POST", "/collection/v2/write", body, { ["Content-Type"] = COLLECTION, Accept = COLLECTION })
	return {}
end

function actions.discover(message)
	local sections = {}
	for index, seed in ipairs(message.seeds) do
		local ok, tracks = pcall(function()
			local mix = spotify.json("/inspiredby-mix/v2/seed_to_playlist/spotify:track:" .. seed.id .. "?response-format=json")
			for _, item in ipairs(mix.mediaItems or {}) do
				local id = (item.uri or ""):match("^spotify:playlist:(.+)$")
				if id then
					return playlist_tracks(playlist_content(id), MIX_SIZE)
				end
			end
			return {}
		end)
		if ok and #tracks > 0 then
			table.insert(sections, { id = "mix_" .. index, title = "Mix inspired by " .. seed.title, kind = "tracks", order = 10 + index, items = tracks })
		elseif not ok then
			nari.log("mix for " .. seed.title .. " couldn't be loaded: " .. tostring(tracks))
		end
	end
	return { sections = sections }
end

nari.on("message", function(message)
	local ok, result = pcall(actions[message.action], message)
	if not ok then
		result = { error = tostring(result) }
	end
	result.request = message.request
	nari.send(result)
end)

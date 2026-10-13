local auth = require("auth")
local proto = require("proto")

local SPCLIENT = "https://spclient.wg.spotify.com"
local IMAGES = "https://i.scdn.co/image/"
local BATCH = { [8] = 100, [9] = 100, [10] = 400 }

local spotify = { ARTIST = 8, ALBUM = 9, TRACK = 10 }

function spotify.request(method, path, body, headers)
	local token, problem = auth.token()
	if not token then
		error(problem, 0)
	end
	headers = headers or {}
	headers.Authorization = "Bearer " .. token
	local response, failure = nari.http({ method = method, url = path:match("^https://") and path or (SPCLIENT .. path), headers = headers, body = body })
	if not response then
		error(failure, 0)
	end
	if response.status >= 300 then
		error("Spotify answered " .. response.status .. " to " .. (path:match("^/[^/?]+/[^/?]+") or path), 0)
	end
	return response.body
end

function spotify.json(path)
	return nari.json_decode(spotify.request("GET", path, nil, { Accept = "application/json" }))
end

function spotify.protobuf(method, path, body)
	return proto.decode(spotify.request(method, path, body, { Accept = "application/x-protobuf", ["Content-Type"] = "application/x-protobuf" }))
end

function spotify.id(uri)
	return uri:match("([^:]+)$")
end

local function image(groups)
	local sizes = {}
	for _, raw in ipairs(groups) do
		local fields = proto.decode(raw)
		local file = proto.path(fields, 1)
		if file then
			sizes[proto.path(fields, 2) or 0] = IMAGES .. proto.hex(file)
		end
	end
	local big = sizes[2] or sizes[3] or sizes[0] or sizes[1]
	return big and { big, sizes[0] or big } or nil
end

local function images(fields, group, single)
	local grouped = proto.path(fields, group)
	return image(grouped and proto.list(proto.decode(grouped), 1) or proto.list(fields, single))
end

local function artists_of(list)
	local names, ids = {}, {}
	for _, raw in ipairs(list) do
		local fields = proto.decode(raw)
		table.insert(names, proto.path(fields, 2) or "")
		table.insert(ids, proto.base62(proto.path(fields, 1) or ""))
	end
	return names, ids
end

local function year(fields)
	local date = proto.path(fields, 6)
	return date and proto.sint(proto.path(proto.decode(date), 1)) or 0
end

local function track_count(fields)
	local count = 0
	for _, disc in ipairs(proto.list(fields, 11)) do
		count = count + #proto.list(proto.decode(disc), 3)
	end
	return count
end

function spotify.album(raw)
	local fields = type(raw) == "table" and raw or proto.decode(raw)
	local names, ids = artists_of(proto.list(fields, 3))
	return {
		id = proto.base62(proto.path(fields, 1) or ""),
		title = proto.path(fields, 2) or "",
		artist = table.concat(names, ", "),
		artists = names,
		artist_id = ids[1] or "",
		year = year(fields),
		song_count = track_count(fields),
		duration = 0,
		art = images(fields, 17, 9),
	}
end

function spotify.track(raw)
	local fields = type(raw) == "table" and raw or proto.decode(raw)
	local names, ids = artists_of(proto.list(fields, 4))
	local album = proto.decode(proto.path(fields, 3) or "")
	return {
		id = proto.base62(proto.path(fields, 1) or ""),
		title = proto.path(fields, 2) or "",
		artist = table.concat(names, ", "),
		artists = names,
		artist_id = ids[1] or "",
		album = proto.path(album, 2) or "",
		album_id = proto.path(album, 1) and proto.base62(proto.path(album, 1)) or "",
		duration = proto.sint(proto.path(fields, 7)) or 0,
		track_number = proto.sint(proto.path(fields, 5)) or 0,
		disc_number = proto.sint(proto.path(fields, 6)) or 1,
		year = year(album),
		genres = {},
		file_name = "",
		art = images(album, 17, 9),
	}
end

function spotify.artist(raw)
	local fields = type(raw) == "table" and raw or proto.decode(raw)
	return {
		id = proto.base62(proto.path(fields, 1) or ""),
		name = proto.path(fields, 2) or "",
		album_count = 0,
		song_count = 0,
		cover_album_id = proto.base62(proto.path(fields, 1) or ""),
		art = images(fields, 17, 11),
	}
end

function spotify.metadata(uris, kind)
	local found = {}
	local size = BATCH[kind]
	for from = 1, #uris, size do
		local requests = {}
		for index = from, math.min(from + size - 1, #uris) do
			table.insert(requests, proto.bytes(2, proto.bytes(1, uris[index]) .. proto.bytes(2, proto.int(1, kind))))
		end
		local response = spotify.protobuf("POST", "/extended-metadata/v0/extended-metadata", table.concat(requests))
		for _, array in ipairs(proto.list(response, 2)) do
			for _, entry in ipairs(proto.list(proto.decode(array), 3)) do
				local data = proto.decode(entry)
				local value = proto.path(data, 3, 2)
				if value then
					found[proto.path(data, 2)] = proto.decode(value)
				end
			end
		end
	end
	return found
end

function spotify.load(uris, kind, map)
	local found = spotify.metadata(uris, kind)
	local list = {}
	for _, uri in ipairs(uris) do
		if found[uri] then
			local item = map(found[uri])
			if item.id ~= "" then
				table.insert(list, item)
			end
		end
	end
	return list
end

return spotify

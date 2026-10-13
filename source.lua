local proto = require("proto")
local spotify = require("spotify")

local HEADER = 0xa7
local CHUNK = 512 * 1024
local IV = proto.unhex("72e067fbddcbcf77ebe8bc643f630d93")
local FORMATS = { [2] = 1, [1] = 2, [0] = 3 }
local OFFLINE_DAYS = 30

local function best_file(track)
	local best, rank
	for _, raw in ipairs(proto.list(track, 12)) do
		local file = proto.decode(raw)
		local order = FORMATS[proto.path(file, 2) or 0]
		if order and proto.path(file, 1) and (not rank or order < rank) then
			best, rank = proto.path(file, 1), order
		end
	end
	return best
end

local function audio_file(id)
	local uri = "spotify:track:" .. id
	local track = spotify.metadata({ uri }, spotify.TRACK)[uri]
	if not track then
		error("Spotify has no data for this song", 0)
	end
	local candidates = { track }
	for _, raw in ipairs(proto.list(track, 13)) do
		table.insert(candidates, proto.decode(raw))
	end
	for _, candidate in ipairs(candidates) do
		local file = best_file(candidate)
		if file then
			return proto.hex(proto.path(candidate, 1) or proto.unhex(proto.gid(id))), proto.hex(file)
		end
	end
	error("Spotify has no file for this song in your country", 0)
end

local function cdn_url(file)
	local urls = proto.decode(spotify.request("GET", "/storage-resolve/files/audio/interactive/" .. file, nil, { Accept = "application/x-protobuf" }))[2]
	if not urls then
		error("Spotify gave no download address for this song", 0)
	end
	return urls[1]
end

local function fetch(url, from, to)
	local response, problem = nari.http({ url = url, headers = { Range = "bytes=" .. from .. "-" .. to } })
	if not response or (response.status ~= 206 and response.status ~= 200) then
		error("the song couldn't be downloaded: " .. tostring(problem or response.status), 0)
	end
	return response
end

local function play(out, size, key, read)
	local cipher = nari.cipher({ algorithm = "aes-ctr", key = proto.unhex(key), iv = IV })
	out:size(size - HEADER)
	local count = (size + CHUNK - 1) // CHUNK
	local done = {}
	local cursor = 0
	while true do
		local wanted = out:wanted()
		if wanted then
			cursor = (wanted + HEADER) // CHUNK
		end
		local index
		for step = 0, count - 1 do
			local candidate = (cursor + step) % count
			if not done[candidate] then
				index = candidate
				break
			end
		end
		if not index then
			return
		end
		done[index] = true
		cipher:seek(index * CHUNK)
		local plain, start = cipher:update(read(index)), index * CHUNK
		if start < HEADER then
			plain, start = plain:sub(HEADER - start + 1), HEADER
		end
		if out:write(plain, start - HEADER) == false then
			return
		end
		cursor = index + 1
	end
end

local function play_offline(id, path, out)
	local key = (nari.get("offline_keys") or {})[id]
	if not key then
		error("This download can't be opened anymore, download it again", 0)
	end
	if os.time() - (nari.get("offline_checked") or 0) > OFFLINE_DAYS * 86400 then
		error("Go online so Spotify can confirm your Premium account, then your downloads play again", 0)
	end
	local file = io.open(path, "rb")
	if not file then
		error("The downloaded song is missing", 0)
	end
	local size = file:seek("end")
	play(out, size, key, function(index)
		file:seek("set", index * CHUNK)
		return file:read(CHUNK) or ""
	end)
	file:close()
end

local function save(id, key, size, read, out)
	out:size(size)
	for index = 0, (size + CHUNK - 1) // CHUNK - 1 do
		if out:write(read(index)) == false then
			return
		end
	end
	local keys = nari.get("offline_keys") or {}
	keys[id] = key
	nari.set("offline_keys", keys, { private = true })
end

nari.source("spotify", function(raw, out)
	local id, query = raw:match("^([^?]*)%??(.*)$")
	local offline = query:match("^offline=(.+)$")
	if offline then
		return play_offline(id, offline:gsub("%%(%x%x)", function(pair) return string.char(tonumber(pair, 16)) end), out)
	end
	local track, file = audio_file(id)
	local answer, problem = nari.ask("session", { track = track, file = file }, 25)
	if not answer then
		error(problem, 0)
	end
	local url = cdn_url(file)
	local first = fetch(url, 0, CHUNK - 1)
	local size = first.status == 200 and #first.body or tonumber((first.headers["content-range"] or ""):match("/(%d+)"))
	local function read(index)
		if index == 0 or first.status == 200 then
			return first.body:sub(index * CHUNK + 1, (index + 1) * CHUNK)
		end
		return fetch(url, index * CHUNK, math.min(size, (index + 1) * CHUNK) - 1).body
	end
	if query == "save" then
		return save(id, answer.key, size, read, out)
	end
	play(out, size, answer.key, read)
end, { save = "sealed" })

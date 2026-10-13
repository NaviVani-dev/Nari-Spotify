local auth = require("auth")
local proto = require("proto")

local M32 = 0xffffffff
local INITKONST = 0x6996c53a
local KEYP = 13
local VERSION = 124200290
local PRIME = proto.unhex("ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a63a3620ffffffffffffffff")
local FALLBACK_AP = "ap-gew4.spotify.com:4070"
local TIMEOUT = 10
local LOGIN_ERRORS = {
	[0] = "protocol error",
	[2] = "try another access point",
	[9] = "travel restriction",
	[11] = "Spotify Premium is required",
	[12] = "bad credentials",
	[13] = "the credentials couldn't be validated",
	[15] = "extra verification required",
	[17] = "application banned",
}

local function rotl(word, bits)
	return ((word << bits) | (word >> (32 - bits))) & M32
end

local function sbox1(word)
	word = word ~ (rotl(word, 5) | rotl(word, 7))
	return word ~ (rotl(word, 19) | rotl(word, 22))
end

local function sbox2(word)
	word = word ~ (rotl(word, 7) | rotl(word, 22))
	return word ~ (rotl(word, 5) | rotl(word, 19))
end

local function copy(words)
	local result = {}
	for index = 0, 15 do
		result[index] = words[index]
	end
	return result
end

local Shannon = {}
Shannon.__index = Shannon

function Shannon:cycle()
	local R = self.R
	local t = sbox1(R[12] ~ R[13] ~ self.konst) ~ rotl(R[0], 1)
	for index = 1, 15 do
		R[index - 1] = R[index]
	end
	R[15] = t
	t = sbox2(R[2] ~ R[15])
	R[0] = R[0] ~ t
	self.sbuf = t ~ R[8] ~ R[12]
end

function Shannon:diffuse()
	for _ = 1, 16 do
		self:cycle()
	end
end

function Shannon:loadkey(key)
	local R = self.R
	for index = 1, #key, 4 do
		local a, b, c, d = key:byte(index, index + 3)
		R[KEYP] = R[KEYP] ~ ((a or 0) | (b or 0) << 8 | (c or 0) << 16 | (d or 0) << 24)
		self:cycle()
	end
	R[KEYP] = R[KEYP] ~ #key
	self:cycle()
	self.CRC = copy(R)
	self:diffuse()
	for index = 0, 15 do
		R[index] = R[index] ~ self.CRC[index]
	end
end

function Shannon:nonce(number)
	self.R = copy(self.initR)
	self.konst = INITKONST
	self:loadkey(string.pack(">I4", number))
	self.konst = self.R[0]
	self.nbuf = 0
end

function Shannon:macfunc(word)
	local CRC = self.CRC
	local t = CRC[0] ~ CRC[2] ~ CRC[15] ~ word
	for index = 1, 15 do
		CRC[index - 1] = CRC[index]
	end
	CRC[15] = t
	self.R[KEYP] = self.R[KEYP] ~ word
end

function Shannon:byte(value, decrypt)
	local shift = 32 - self.nbuf
	local stream = (self.sbuf >> shift) & 0xff
	if decrypt then
		value = value ~ stream
		self.mbuf = self.mbuf ~ (value << shift)
	else
		self.mbuf = self.mbuf ~ (value << shift)
		value = value ~ stream
	end
	self.nbuf = self.nbuf - 8
	return string.char(value)
end

function Shannon:process(data, decrypt)
	local out, position, size = {}, 1, #data
	if self.nbuf ~= 0 then
		while self.nbuf ~= 0 and position <= size do
			table.insert(out, self:byte(data:byte(position), decrypt))
			position = position + 1
		end
		if self.nbuf ~= 0 then
			return table.concat(out)
		end
		self:macfunc(self.mbuf)
	end
	while position + 3 <= size do
		self:cycle()
		local word = string.unpack("<I4", data, position)
		if decrypt then
			word = word ~ self.sbuf
			self:macfunc(word)
		else
			self:macfunc(word)
			word = word ~ self.sbuf
		end
		table.insert(out, string.pack("<I4", word))
		position = position + 4
	end
	if position <= size then
		self:cycle()
		self.mbuf = 0
		self.nbuf = 32
		while position <= size do
			table.insert(out, self:byte(data:byte(position), decrypt))
			position = position + 1
		end
	end
	return table.concat(out)
end

function Shannon:finish()
	if self.nbuf ~= 0 then
		self:macfunc(self.mbuf)
	end
	self:cycle()
	self.R[KEYP] = self.R[KEYP] ~ (INITKONST ~ (self.nbuf << 3))
	self.nbuf = 0
	for index = 0, 15 do
		self.R[index] = self.R[index] ~ self.CRC[index]
	end
	self:diffuse()
	self:cycle()
	return string.pack("<I4", self.sbuf)
end

local function shannon(key)
	local cipher = setmetatable({ R = { [0] = 1, 1 }, konst = INITKONST, sbuf = 0, mbuf = 0, nbuf = 0 }, Shannon)
	for index = 2, 15 do
		cipher.R[index] = (cipher.R[index - 1] + cipher.R[index - 2]) & M32
	end
	cipher:loadkey(key)
	cipher.konst = cipher.R[0]
	cipher.initR = copy(cipher.R)
	return cipher
end

local conn
local sequence = 0

local function close()
	if conn then
		conn.socket:close()
		conn = nil
	end
end

local function take(socket, count, timeout)
	if count == 0 then
		return ""
	end
	local data, problem = socket:receive(count, timeout or TIMEOUT)
	if not data then
		error("Spotify connection: " .. tostring(problem), 0)
	end
	return data
end

local function send(state, command, payload)
	state.send:nonce(state.send_nonce)
	state.send_nonce = state.send_nonce + 1
	local body = state.send:process(string.char(command) .. string.pack(">I2", #payload) .. payload, false)
	local ok, problem = state.socket:send(body .. state.send:finish())
	if not ok then
		error("Spotify connection: " .. tostring(problem), 0)
	end
end

local function receive(state, timeout)
	local raw = take(state.socket, 3, timeout)
	state.recv:nonce(state.recv_nonce)
	state.recv_nonce = state.recv_nonce + 1
	local header = state.recv:process(raw, true)
	local size = string.unpack(">I2", header, 2)
	local body = state.recv:process(take(state.socket, size), true)
	if state.recv:finish() ~= take(state.socket, 4) then
		error("Spotify connection: bad MAC", 0)
	end
	return header:byte(1), body
end

local function device_id()
	local id = nari.get("device_id")
	if not id then
		id = proto.hex(nari.random_bytes(20))
		nari.set("device_id", id)
	end
	return id
end

local function access_points()
	local response = nari.http({ url = "https://apresolve.spotify.com/?type=accesspoint" })
	local list = response and response.status == 200 and auth.decode(response).accesspoint or {}
	table.insert(list, FALLBACK_AP)
	return list
end

local function handshake(address)
	local host, port = address:match("^(.-):(%d+)$")
	local socket, problem = nari.tcp({ host = host, port = tonumber(port), timeout = TIMEOUT })
	if not socket then
		error("Spotify connection: " .. tostring(problem), 0)
	end
	local private = nari.random_bytes(95)
	local hello = proto.bytes(10, proto.int(10, 0) .. proto.int(20, 0) .. proto.int(30, 8) .. proto.int(40, VERSION))
		.. proto.int(30, 0)
		.. proto.bytes(50, proto.bytes(10, proto.bytes(10, nari.modpow("\2", private, PRIME)) .. proto.int(20, 1)))
		.. proto.bytes(60, nari.random_bytes(16))
		.. proto.bytes(70, "\30")
	local packet = "\0\4" .. string.pack(">I4", 6 + #hello) .. hello
	socket:send(packet)
	local length = take(socket, 4)
	local body = take(socket, string.unpack(">I4", length) - 4)
	local response = proto.decode(body)
	local remote = proto.path(response, 10, 10, 10, 10)
	if not remote then
		socket:close()
		local code = proto.path(response, 30, 10)
		error("Spotify refused the connection: " .. (LOGIN_ERRORS[code] or tostring(code)), 0)
	end
	local accumulator = packet .. length .. body
	local shared = nari.modpow(remote, private, PRIME)
	local keys = {}
	for index = 1, 5 do
		table.insert(keys, nari.hmac("sha1", shared, accumulator .. string.char(index), true))
	end
	keys = table.concat(keys)
	local challenge = nari.hmac("sha1", keys:sub(1, 20), accumulator, true)
	local reply = proto.bytes(10, proto.bytes(10, proto.bytes(10, challenge))) .. proto.bytes(20, "") .. proto.bytes(30, "")
	socket:send(string.pack(">I4", 4 + #reply) .. reply)
	return { socket = socket, send = shannon(keys:sub(21, 52)), recv = shannon(keys:sub(53, 84)), send_nonce = 0, recv_nonce = 0 }
end

local function login(state)
	local token, problem = auth.token()
	if not token then
		error(problem, 0)
	end
	send(state, 0xab, proto.bytes(10, proto.int(20, 3) .. proto.bytes(30, token))
		.. proto.bytes(50, proto.int(10, 2) .. proto.int(60, 5) .. proto.bytes(90, "librespot-nari") .. proto.bytes(100, device_id()))
		.. proto.bytes(70, "librespot 0.8.0"))
	while true do
		local command, body = receive(state)
		if command == 0xac then
			nari.set("username", proto.path(proto.decode(body), 10))
			for _ = 1, 10 do
				local ok, kind, info = pcall(receive, state, 5)
				if not ok then
					return
				end
				if kind == 0x1b then
					nari.set("country", info)
				end
				if kind == 0x50 then
					nari.set("product", info:match("<type>([^<]*)</type>") or "")
					if nari.get("product") == "premium" then
						nari.set("offline_checked", os.time(), { private = true })
					end
					return
				end
			end
			return
		elseif command == 0xad then
			local code = proto.path(proto.decode(body), 10)
			error("Spotify refused the login: " .. (LOGIN_ERRORS[code] or tostring(code)), 0)
		end
	end
end

local function connect()
	local failure
	for _, address in ipairs(access_points()) do
		local ok, state = pcall(handshake, address)
		if ok then
			local signed, problem = pcall(login, state)
			if signed then
				conn = state
				return
			end
			state.socket:close()
			if not tostring(problem):match("try another") then
				error(problem, 0)
			end
			failure = problem
		else
			failure = state
		end
	end
	error(failure, 0)
end

local function request_key(track, file)
	if not conn then
		connect()
	end
	sequence = sequence + 1
	send(conn, 0x0c, proto.unhex(file) .. proto.unhex(track) .. string.pack(">I4", sequence) .. "\0\0")
	local deadline = os.time() + TIMEOUT
	while os.time() <= deadline do
		local command, body = receive(conn)
		if command == 0x04 then
			send(conn, 0x49, "\0\0\0\0")
		elseif (command == 0x0d or command == 0x0e) and string.unpack(">I4", body) == sequence then
			if command == 0x0d then
				return body:sub(5, 20)
			end
			return nil
		end
	end
	error("Spotify didn't send the audio key in time", 0)
end

nari.on("ask", function(question, reply)
	if question.account then
		local ok, problem = pcall(function()
			if question.fresh then
				close()
			end
			if not conn then
				connect()
			end
		end)
		if not ok then
			return reply(nil, tostring(problem))
		end
		return { username = nari.get("username"), product = nari.get("product") }
	end
	for attempt = 1, 2 do
		local ok, key = pcall(request_key, question.track, question.file)
		if ok and key then
			return { key = proto.hex(key) }
		elseif ok then
			return reply(nil, "Spotify refused the audio key for this song")
		end
		close()
		if attempt == 2 then
			return reply(nil, tostring(key))
		end
	end
end)

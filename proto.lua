local proto = {}

local function varint(value)
	local bytes = {}
	repeat
		local byte = value & 0x7f
		value = value >> 7
		table.insert(bytes, value ~= 0 and (byte | 0x80) or byte)
	until value == 0
	return string.char(table.unpack(bytes))
end

function proto.int(number, value)
	return varint(number << 3) .. varint(value)
end

function proto.bytes(number, value)
	return varint((number << 3) | 2) .. varint(#value) .. value
end

function proto.decode(data)
	local fields, position = {}, 1
	local function read()
		local value, shift = 0, 0
		repeat
			local byte = data:byte(position)
			if not byte then
				error("truncated protobuf")
			end
			position = position + 1
			value = value | ((byte & 0x7f) << shift)
			shift = shift + 7
		until byte < 0x80
		return value
	end
	while position <= #data do
		local key = read()
		local number, kind = key >> 3, key & 7
		local value
		if kind == 0 then
			value = read()
		elseif kind == 2 then
			local size = read()
			value = data:sub(position, position + size - 1)
			position = position + size
		elseif kind == 5 then
			value = data:sub(position, position + 3)
			position = position + 4
		elseif kind == 1 then
			value = data:sub(position, position + 7)
			position = position + 8
		else
			error("unsupported protobuf wire type " .. kind)
		end
		fields[number] = fields[number] or {}
		table.insert(fields[number], value)
	end
	return fields
end

function proto.path(fields, ...)
	local path = { ... }
	local value
	for index, number in ipairs(path) do
		value = fields[number] and fields[number][1]
		if value == nil then
			return nil
		end
		if index < #path then
			fields = proto.decode(value)
		end
	end
	return value
end

function proto.hex(data)
	return (data:gsub(".", function(char) return string.format("%02x", char:byte()) end))
end

function proto.unhex(text)
	return (text:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end))
end

local BASE62 = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

function proto.gid(id)
	local bytes = {}
	for index = 1, 16 do
		bytes[index] = 0
	end
	for char in id:gmatch(".") do
		local carry = BASE62:find(char, 1, true) - 1
		for index = 16, 1, -1 do
			local value = bytes[index] * 62 + carry
			bytes[index] = value & 0xff
			carry = value >> 8
		end
	end
	return proto.hex(string.char(table.unpack(bytes)))
end

function proto.base62(raw)
	if raw == "" then
		return ""
	end
	local bytes = { raw:byte(1, -1) }
	local digits = {}
	for _ = 1, 22 do
		local remainder = 0
		for index = 1, #bytes do
			local value = remainder * 256 + bytes[index]
			bytes[index] = value // 62
			remainder = value % 62
		end
		table.insert(digits, 1, BASE62:sub(remainder + 1, remainder + 1))
	end
	return table.concat(digits)
end

function proto.sint(value)
	return value and ((value >> 1) ~ -(value & 1)) or nil
end

function proto.list(fields, number)
	return fields[number] or {}
end

return proto

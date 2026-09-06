--!optimize 2
---------------------------------------------------------------- offsets

local COMPONENT_MAP = 0x38

local ATTRIBUTE_COMPONENT = 10

local SLOT = {
	Pointer = 0x00,
	TypeId  = 0x08,
	Stride  = 0x10,
}


local ATTRIBUTE_MAP = {
	Count   = 0x08,
	Entries = 0x18,
}

local ATTRIBUTE = {
	Key        = 0x00,
	Descriptor = 0x08,
	Payload    = 0x18,
	Stride     = 0x58,
}

local DESCRIPTOR = {
	TypeName = 0x08,
}

local WRAPPED_STRING = {
	Chars    = 0x08,
	Size     = 0x18,
	Capacity = 0x20,
	Header   = 0x28,
}

local PLAIN_STRING = {
	Chars    = 0x00,
	Size     = 0x10,
	Capacity = 0x18,
	Header   = 0x20,
}

local SMALL_STRING = 16
local MAX_STRING = 512
local PAYLOAD_BYTES = 48
local TWO32 = 4294967296

---------------------------------------------------------------- state

local typeNameCache = {}

---------------------------------------------------------------- memory

local function isPointer(address)
	return address > 0x10000 and address < 0x7FFFFFFFFFFF
end

local function readPointer(address)
	local ok, value = pcall(memory.readu64, address)
	return (ok and type(value) == "number") and value or 0
end

local function readCount(address)
	local ok, value = pcall(memory.readu32, address)
	return (ok and type(value) == "number") and value or 0
end

local function readBlock(address, length)
	local ok, block = pcall(memory.readbuffer, address, length)
	return ok and block or nil
end

local function blockPointer(block, offset)
	return buffer.readu32(block, offset) + buffer.readu32(block, offset + 4) * TWO32
end

---------------------------------------------------------------- strings

local function readString(address, layout)
	if not isPointer(address) then
		return nil
	end

	local header = readBlock(address, layout.Header)
	if not header then
		return nil
	end

	local size = blockPointer(header, layout.Size)
	local capacity = blockPointer(header, layout.Capacity)
	if size == 0 or size > MAX_STRING or capacity < size then
		return nil
	end

	if capacity < SMALL_STRING then
		return buffer.readstring(header, layout.Chars, size)
	end

	local chars = readBlock(blockPointer(header, layout.Chars), size)
	return chars and buffer.tostring(chars) or nil
end

---------------------------------------------------------------- containers

local function findAttributeMap(instance)
	local ok, componentMap = pcall(memory.readu64, instance, COMPONENT_MAP)
	if not ok or not isPointer(componentMap) then
		return 0
	end

	local first = readPointer(componentMap)
	local last = readPointer(componentMap + 8)
	if not isPointer(first) or last <= first then
		return 0
	end

	local block = readBlock(first, last - first)
	if not block then
		return 0
	end

	for slot = 0, (last - first) // SLOT.Stride - 1 do
		local base = slot * SLOT.Stride
		if buffer.readu16(block, base + SLOT.TypeId) == ATTRIBUTE_COMPONENT then
			return blockPointer(block, base + SLOT.Pointer)
		end
	end

	return 0
end

local function readAttributeMap(instance)
	local map = findAttributeMap(instance)
	if not isPointer(map) then
		return 0, 0
	end

	local entries = readPointer(map + ATTRIBUTE_MAP.Entries)
	if not isPointer(entries) then
		return 0, 0
	end

	return readCount(map + ATTRIBUTE_MAP.Count), entries
end

local function attributeKey(entry)
	return readString(readPointer(entry + ATTRIBUTE.Key), WRAPPED_STRING)
end

local function attributeType(entry)
	local descriptor = readPointer(entry + ATTRIBUTE.Descriptor)
	if not isPointer(descriptor) then
		return ""
	end

	local cached = typeNameCache[descriptor]
	if cached then
		return cached
	end

	local name = readString(readPointer(descriptor + DESCRIPTOR.TypeName), PLAIN_STRING) or ""
	typeNameCache[descriptor] = name
	return name
end

---------------------------------------------------------------- values

local function decodeValue(entry, typeName)
	local payload = entry + ATTRIBUTE.Payload
	local block = readBlock(payload, PAYLOAD_BYTES)
	if not block then
		return nil
	end

	local function float(offset)
		return buffer.readf32(block, offset)
	end
	local function int(offset)
		return buffer.readi32(block, offset)
	end

	if typeName == "bool" then
		return buffer.readu8(block, 0) ~= 0
	elseif typeName == "double" or typeName == "float" then
		return buffer.readf64(block, 0)
	elseif typeName == "string" or typeName == "Content" then
		return readString(payload, PLAIN_STRING) or ""
	elseif typeName == "Vector3" then
		return vector.create(float(0), float(4), float(8))
	elseif typeName == "Vector2" then
		return vector.create(float(0), float(4))
	elseif typeName == "Color3" then
		return Color3.new(float(0), float(4), float(8))
	elseif typeName == "NumberRange" then
		return { Min = float(0), Max = float(4) }
	elseif typeName == "UDim" then
		return { Scale = float(0), Offset = int(4) }
	elseif typeName == "UDim2" then
		return UDim2.new(float(0), int(4), float(8), int(12))
	elseif typeName == "BrickColor" then
		return buffer.readu32(block, 0)
	elseif typeName == "Rect2D" then
		return {
			Min = vector.create(float(0), float(4)),
			Max = vector.create(float(8), float(12)),
		}
	elseif typeName == "CoordinateFrame" then
		return CFrame.new(float(36), float(40), float(44),
			float(0), float(4), float(8),
			float(12), float(16), float(20),
			float(24), float(28), float(32))
	end

	return blockPointer(block, 0)
end

---------------------------------------------------------------- writing

local function writeBlock(address, block)
	return (pcall(memory.writebuffer, address, block))
end

local function packFloats(values, count)
	local block = buffer.create(count * 4)
	for index = 1, count do
		buffer.writef32(block, (index - 1) * 4, values[index])
	end
	return block
end

local function colorComponents(value)
	local ok, red, green, blue = pcall(function()
		return value.R or value.r or value.x,
			value.G or value.g or value.y,
			value.B or value.b or value.z
	end)

	if ok and type(red) == "number" and type(green) == "number" and type(blue) == "number" then
		return { red, green, blue }
	end
	return nil
end

local function encodeValue(typeName, value)
	if typeName == "bool" then
		local block = buffer.create(1)
		buffer.writeu8(block, 0, value and 1 or 0)
		return block
	elseif typeName == "double" or typeName == "float" then
		local block = buffer.create(8)
		buffer.writef64(block, 0, value)
		return block
	elseif typeName == "BrickColor" then
		local block = buffer.create(4)
		buffer.writeu32(block, 0, value)
		return block
	elseif typeName == "Vector2" then
		return packFloats({ value.x, value.y }, 2)
	elseif typeName == "NumberRange" then
		return packFloats({ value.Min, value.Max }, 2)
	elseif typeName == "Vector3" then
		return packFloats({ value.x, value.y, value.z }, 3)
	elseif typeName == "Color3" then
		local components = colorComponents(value)
		return components and packFloats(components, 3) or nil
	elseif typeName == "Rect2D" then
		return packFloats({ value.Min.x, value.Min.y, value.Max.x, value.Max.y }, 4)
	elseif typeName == "UDim" then
		local block = buffer.create(8)
		buffer.writef32(block, 0, value.Scale)
		buffer.writei32(block, 4, value.Offset)
		return block
	elseif typeName == "UDim2" then
		local block = buffer.create(16)
		buffer.writef32(block, 0, value.X.Scale)
		buffer.writei32(block, 4, value.X.Offset)
		buffer.writef32(block, 8, value.Y.Scale)
		buffer.writei32(block, 12, value.Y.Offset)
		return block
	elseif typeName == "CoordinateFrame" then
		-- GetComponents gives position first; memory wants rotation first
		local components = { value:GetComponents() }
		local block = buffer.create(48)

		for index = 1, 9 do
			buffer.writef32(block, (index - 1) * 4, components[index + 3])
		end
		buffer.writef32(block, 36, components[1])
		buffer.writef32(block, 40, components[2])
		buffer.writef32(block, 44, components[3])

		return block
	end

	return nil
end

local function writeStringValue(payload, text)
	local header = readBlock(payload, PLAIN_STRING.Header)
	if not header then
		return false, "string header unreadable"
	end

	local capacity = blockPointer(header, PLAIN_STRING.Capacity)
	local size = #text

	if capacity < SMALL_STRING then
		if size >= SMALL_STRING then
			return false, string.format("inline buffer holds %d chars, %d given",
				SMALL_STRING - 1, size)
		end

		local chars = buffer.create(SMALL_STRING)
		buffer.writestring(chars, 0, text)
		if not writeBlock(payload + PLAIN_STRING.Chars, chars) then
			return false, "writing chars failed"
		end
	else
		if size > capacity then
			return false, string.format("capacity is %d, %d given", capacity, size)
		end

		local chars = buffer.create(size + 1)
		buffer.writestring(chars, 0, text)
		if not writeBlock(blockPointer(header, PLAIN_STRING.Chars), chars) then
			return false, "writing chars failed"
		end
	end

	local length = buffer.create(8)
	buffer.writeu32(length, 0, size)
	if not writeBlock(payload + PLAIN_STRING.Size, length) then
		return false, "writing length failed"
	end

	return true
end

---------------------------------------------------------------- api

local function getAttributes(instance)
	local result = {}
	local count, entries = readAttributeMap(instance)

	for index = 0, count - 1 do
		local entry = entries + ATTRIBUTE.Stride * index
		local key = attributeKey(entry)
		if key then
			result[key] = decodeValue(entry, attributeType(entry))
		end
	end

	return result
end

local function getAttribute(instance, name)
	local count, entries = readAttributeMap(instance)

	for index = 0, count - 1 do
		local entry = entries + ATTRIBUTE.Stride * index
		if attributeKey(entry) == name then
			return decodeValue(entry, attributeType(entry))
		end
	end

	return nil
end

local function hasAttribute(instance, name)
	return getAttribute(instance, name) ~= nil
end


local function setAttribute(instance, name, value)
	local count, entries = readAttributeMap(instance)

	for index = 0, count - 1 do
		local entry = entries + ATTRIBUTE.Stride * index
		if attributeKey(entry) == name then
			local typeName = attributeType(entry)
			local payload = entry + ATTRIBUTE.Payload

			if typeName == "string" or typeName == "Content" then
				return writeStringValue(payload, value)
			end

			local block = encodeValue(typeName, value)
			if not block then
				return false, string.format("no writer for type %q", typeName)
			end

			if not writeBlock(payload, block) then
				return false, "write failed"
			end
			return true
		end
	end

	return false, "no such attribute"
end

---------------------------------------------------------------- declare

local function declareMethod(name, callback)
	return (pcall(Instance.declare, {
		class = "Instance",
		name = name,
		callback = { method = callback },
	}))
end

local declared = declareMethod("GetAttributes", getAttributes)
	and declareMethod("GetAttribute", getAttribute)
	and declareMethod("HasAttribute", hasAttribute)
	and declareMethod("SetAttribute", setAttribute)

Attributes = {
	GetAttributes = getAttributes,
	GetAttribute = getAttribute,
	HasAttribute = hasAttribute,
	SetAttribute = setAttribute,

	Reset = function()
		typeNameCache = {}
	end,
	Declared = declared,
}
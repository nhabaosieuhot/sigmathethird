local OFF = {
    Instance = {
        ComponentMap = 0x38,
    },
    Attribute = {
        Key      = 0x00,
        Size     = 0x58,
        Value    = 0x08,
        DescName = 0x08,
        Payload  = 0x10,
    },
    AttributesMapShapes = {
        { 0x10, 0x08 },
        { 0x08, 0x18 },
    },
}

local MAX_STRING     = 512
local MAX_RECORDS    = 4096
local MAX_CMAP_BYTES = 0x4000
local MAX_TYPE_NAME  = 32

local BUILD = "r17"

local M = {}


local State = {
    typeId = nil,
    shape  = nil,
}

local AttrMapCache = {}
local TypeCache    = {}

local function rd(kind, addr)
    if type(addr) ~= "number" or addr <= 0 then return nil end
    local ok, v = pcall(memory.Read, kind, addr)
    if not ok then return nil end
    return v
end

local function valid(addr)
    if type(addr) ~= "number" or addr <= 0 then return false end
    local ok, v = pcall(memory.IsValid, addr)
    return ok and v == true
end

local function printable(s)
    if type(s) ~= "string" then return false end
    for i = 1, #s do
        local b = string.byte(s, i)
        if b < 0x20 or b > 0x7E then return false end
    end
    return true
end

local function readStdString(addr)
    if not valid(addr) then return nil end

    local size = rd("uint64", addr + 0x10)
    local cap  = rd("uint64", addr + 0x18)
    if type(size) ~= "number" or type(cap) ~= "number" then return nil end
    if size == 0 or size > MAX_STRING then return nil end
    if cap < size or cap > 0x40000000 then return nil end

    local src = addr
    if cap >= 16 then
        local p = rd("pointer", addr)
        if not valid(p) then return nil end
        src = p
    end

    local s = rd("string", src)
    if type(s) ~= "string" or #s == 0 then return nil end
    if #s > size then s = string.sub(s, 1, size) end
    return s
end

local function readCString(addr)
    local s = valid(addr) and rd("string", addr) or nil
    return (type(s) == "string" and #s >= 3 and #s <= MAX_TYPE_NAME and printable(s)) and s or nil
end

local function readKeyName(addr)
    local s = readStdString(addr)
    if s then return s end
    local c = valid(addr) and rd("string", addr) or nil
    return (type(c) == "string" and #c > 0 and #c <= MAX_STRING and printable(c)) and c or nil
end

local function tagged(ty, ...)
    local n = select("#", ...)
    local out = {}
    for i = 1, n do
        local v = select(i, ...)
        if v == nil then return nil end
        out[i] = v
    end
    out.__type = ty
    return out
end

local function floats(va, count, ty)
    local out = {}
    for i = 1, count do
        local f = rd("float", va + (i - 1) * 4)
        if type(f) ~= "number" then return nil end
        out[i] = f
    end
    out.__type = ty
    return out
end

local DEC = {}

DEC["bool"] = function(va)
    local b = rd("byte", va)
    if type(b) ~= "number" then return nil end
    return b ~= 0
end

DEC["double"] = function(va) return rd("double", va) end
DEC["float"]  = DEC["double"]
DEC["number"] = DEC["double"]

DEC["BrickColor"] = function(va) return rd("uint", va) end
DEC["Font"]       = function(va) return rd("uint", va) end

DEC["UDim"] = function(va)
    return tagged("UDim", rd("float", va), rd("int", va + 4))
end

DEC["UDim2"] = function(va)
    return tagged("UDim2",
        rd("float", va),     rd("int", va + 4),
        rd("float", va + 8), rd("int", va + 12))
end

DEC["Vector2"] = function(va)
    return tagged("Vector2", rd("float", va), rd("float", va + 4))
end

DEC["NumberRange"] = function(va)
    return tagged("NumberRange", rd("float", va), rd("float", va + 4))
end

DEC["Vector3"] = function(va)
    local x, y, z = rd("float", va), rd("float", va + 4), rd("float", va + 8)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return Vector3.new(x, y, z)
end

DEC["Color3"] = function(va)
    local r, g, b = rd("float", va), rd("float", va + 4), rd("float", va + 8)
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return nil end
    return Color3.new(r, g, b)
end

DEC["Rect"]   = function(va) return floats(va, 4, "Rect") end
DEC["Rect2D"] = DEC["Rect"]

DEC["CoordinateFrame"] = function(va) return floats(va, 12, "CFrame") end

DEC["string"] = function(va)
    local c = rd("string", va)
    return readStdString(va) or ((type(c) == "string" and printable(c)) and c or "")
end
DEC["std::string"] = DEC["string"]
DEC["Content"]     = DEC["string"]

DEC["NumberSequence"] = function(va) return tagged("NumberSequence", rd("uint64", va)) end
DEC["ColorSequence"]  = function(va) return tagged("ColorSequence",  rd("uint64", va)) end

local function decode(ent, ty)
    local va = ent + OFF.Attribute.Value + OFF.Attribute.Payload

    local fn = DEC[ty]
    if fn then return fn(va) end

    if ty == nil or ty == "" then
        return tagged("raw", rd("uint64", va))
    end

    return readStdString(va) or tagged("raw", rd("uint64", va))
end

local function instanceAddress(inst)
    if type(inst) ~= "userdata" then return nil end
    local ok, a = pcall(function() return inst.Address end)
    return (ok and type(a) == "number" and a > 0 and valid(a)) and a or nil
end

local function componentSlots(instAddr)
    local cmap = rd("pointer", instAddr + OFF.Instance.ComponentMap)
    if not valid(cmap) then return nil end

    local b = rd("pointer", cmap)
    local e = rd("pointer", cmap + 8)
    if not valid(b) or not valid(e) or e < b then return nil end

    local span = e - b
    if span < 16 or span >= MAX_CMAP_BYTES then return nil end
    return b, math.floor(span / 16)
end

local function amapView(map)
    local shapes = OFF.AttributesMapShapes

    local order, seen = {}, {}
    if State.shape then
        order[1] = State.shape
        seen[State.shape] = true
    end
    for i = 1, #shapes do
        if not seen[shapes[i]] then order[#order + 1] = shapes[i] end
    end

    for _, sh in ipairs(order) do
        local n    = rd("uint",    map + sh[1])
        local ents = rd("pointer", map + sh[2])
        if type(n) == "number" and n > 0 and n <= MAX_RECORDS and valid(ents) then
            local k = rd("pointer", ents + OFF.Attribute.Key)
            if valid(k) then
                local name = readKeyName(k)
                if name and printable(name) then
                    State.shape = sh
                    return n, ents
                end
            end
        end
    end
    return nil
end

local function findAttrMap(instAddr)
    local b, count = componentSlots(instAddr)
    if not b then return nil end

    if State.typeId then
        for i = 0, count - 1 do
            local slot = b + i * 16
            local ptr = rd("pointer", slot)
            if valid(ptr) and rd("ushort", slot + 8) == State.typeId then
                return ptr
            end
        end
    end

    for i = 0, count - 1 do
        local slot = b + i * 16
        local ptr = rd("pointer", slot)
        if valid(ptr) and amapView(ptr) then
            State.typeId = rd("ushort", slot + 8)
            return ptr
        end
    end
    return nil
end

local function attrTypeName(ent)
    local desc = rd("pointer", ent + OFF.Attribute.Value)
    if not valid(desc) then return "" end

    local hit = TypeCache[desc]
    if hit then return hit end

    local np   = rd("pointer", desc + OFF.Attribute.DescName)
    local name = readCString(np) or ""
    TypeCache[desc] = name
    return name
end

local function attrMapFor(inst)
    local addr = instanceAddress(inst)
    if not addr then return nil end

    local cached = AttrMapCache[addr]
    if cached ~= nil then return cached or nil end

    local map = findAttrMap(addr)
    AttrMapCache[addr] = map or false
    return map
end

local function collect(inst)
    local out = {}

    local map = attrMapFor(inst)
    if not map then return out end

    local n, ents = amapView(map)
    if not n then return out end

    local stride = OFF.Attribute.Size
    for i = 0, n - 1 do
        local ent = ents + stride * i
        local k = rd("pointer", ent + OFF.Attribute.Key)
        if valid(k) then
            local name = readKeyName(k)
            if name and #name > 0 then
                local ty = attrTypeName(ent)
                out[name] = { value = decode(ent, ty), type = ty, address = ent }
            end
        end
    end
    return out
end

function M.GetAttributeInfo(inst)
    return collect(inst)
end

function M.GetAttributes(inst)
    local out = {}
    for name, rec in pairs(collect(inst)) do
        out[name] = rec.value
    end
    return out
end

function M.GetAttribute(inst, name)
    if type(name) ~= "string" or name == "" then return nil end

    local result = nil
    local map = attrMapFor(inst)
    if map then
        local n, ents = amapView(map)
        if n then
            local stride = OFF.Attribute.Size
            for i = 0, n - 1 do
                local ent = ents + stride * i
                local k = rd("pointer", ent + OFF.Attribute.Key)
                if valid(k) and readKeyName(k) == name then
                    result = decode(ent, attrTypeName(ent))
                    break
                end
            end
        end
    end

    return result
end

local function wr(kind, addr, v)
    return valid(addr) and pcall(memory.Write, kind, addr, v) == true
end

local function numbersOf(value, want)
    local out = {}
    local t = type(value)

    if t == "number" then
        out[1] = value
    elseif t == "boolean" then
        out[1] = value and 1 or 0
    elseif t == "table" then
        for i = 1, want do out[i] = tonumber(value[i]) end
    elseif t == "userdata" then
        local ok, x = pcall(function() return value.X end)
        if ok and type(x) == "number" then
            out[1] = x
            out[2] = select(2, pcall(function() return value.Y end))
            out[3] = select(2, pcall(function() return value.Z end))
        else
            local ok2, r = pcall(function() return value.R end)
            if ok2 and type(r) == "number" then
                out[1] = r
                out[2] = select(2, pcall(function() return value.G end))
                out[3] = select(2, pcall(function() return value.B end))
            end
        end
    elseif t == "string" then
        for m in string.gmatch(value, "-?%d+%.?%d*") do
            out[#out + 1] = tonumber(m)
        end
    end

    for i = 1, want do
        if type(out[i]) ~= "number" then return nil end
    end
    return out
end

local function writeFloats(va, value, want, label)
    local n = numbersOf(value, want)
    if not n then return false, label .. " wants " .. want .. " numbers" end
    for i = 1, want do
        if not wr("float", va + (i - 1) * 4, n[i]) then return false, "write failed" end
    end
    return true
end

local ENC = {}

ENC["bool"] = function(va, value)
    local b
    if type(value) == "boolean" then
        b = value
    elseif type(value) == "number" then
        b = value ~= 0
    elseif type(value) == "string" then
        local l = string.lower(value)
        if l == "true" or l == "1" then b = true
        elseif l == "false" or l == "0" then b = false end
    end
    if b == nil then return false, "bool wants true or false" end
    return wr("byte", va, b and 1 or 0), "write failed"
end

ENC["double"] = function(va, value)
    local n = tonumber(value)
    if not n then return false, "number expected" end
    return wr("double", va, n), "write failed"
end
ENC["float"]  = ENC["double"]
ENC["number"] = ENC["double"]

ENC["BrickColor"] = function(va, value)
    local n = tonumber(value)
    if not n then return false, "integer expected" end
    return wr("uint", va, math.floor(n)), "write failed"
end
ENC["Font"] = ENC["BrickColor"]

ENC["UDim"] = function(va, value)
    local n = numbersOf(value, 2)
    if not n then return false, "UDim wants scale, offset" end
    if not wr("float", va, n[1]) then return false, "write failed" end
    return wr("int", va + 4, math.floor(n[2])), "write failed"
end

ENC["UDim2"] = function(va, value)
    local n = numbersOf(value, 4)
    if not n then return false, "UDim2 wants xScale, xOffset, yScale, yOffset" end
    if not wr("float", va, n[1]) then return false, "write failed" end
    if not wr("int", va + 4, math.floor(n[2])) then return false, "write failed" end
    if not wr("float", va + 8, n[3]) then return false, "write failed" end
    return wr("int", va + 12, math.floor(n[4])), "write failed"
end

ENC["Vector2"]     = function(va, v) return writeFloats(va, v, 2, "Vector2") end
ENC["NumberRange"] = function(va, v) return writeFloats(va, v, 2, "NumberRange") end
ENC["Vector3"]     = function(va, v) return writeFloats(va, v, 3, "Vector3") end
ENC["Color3"]      = function(va, v) return writeFloats(va, v, 3, "Color3") end
ENC["Rect"]        = function(va, v) return writeFloats(va, v, 4, "Rect") end
ENC["Rect2D"]      = ENC["Rect"]
ENC["CoordinateFrame"] = function(va, v) return writeFloats(va, v, 12, "CFrame") end

ENC["string"] = function(va, value)
    local s = tostring(value)
    if #s > MAX_STRING then return false, "string too long" end

    local size = rd("uint64", va + 0x10)
    local cap  = rd("uint64", va + 0x18)
    if type(size) ~= "number" or type(cap) ~= "number" or cap > 0x40000000 then
        return false, "payload is not a std::string, cannot size the buffer"
    end

    if cap < 16 then
        if #s > 15 then
            return false, "inline buffer holds 15 chars, " .. #s .. " given"
        end
        if not wr("string", va, s) then return false, "write failed" end
    else
        local heap = rd("pointer", va)
        if not valid(heap) then return false, "heap buffer pointer is bad" end
        if #s > cap then
            return false, "capacity is " .. cap .. ", " .. #s .. " given"
        end
        if not wr("string", heap, s) then return false, "write failed" end
    end
    return wr("uint64", va + 0x10, #s), "length write failed"
end
ENC["std::string"] = ENC["string"]
ENC["Content"]     = ENC["string"]

function M.SetAttribute(inst, name, value)
    if type(name) ~= "string" or name == "" then
        return false, "name must be a non-empty string"
    end

    local map = attrMapFor(inst)
    if not map then return false, "instance has no attribute map" end

    local n, ents = amapView(map)
    if not n then return false, "attribute map has no entries" end

    local stride = OFF.Attribute.Size
    for i = 0, n - 1 do
        local ent = ents + stride * i
        local k = rd("pointer", ent + OFF.Attribute.Key)
        if valid(k) and readKeyName(k) == name then
            local ty = attrTypeName(ent)
            local fn = ENC[ty]
            if not fn then
                return false, "no writer for type '" .. tostring(ty) .. "'"
            end
            local ok, err = fn(ent + OFF.Attribute.Value + OFF.Attribute.Payload, value)
            if not ok then return false, err or "write failed" end
            return true, decode(ent, ty)
        end
    end
    return false, "attribute '" .. name .. "' not found, SetAttribute cannot create one"
end

function M.Flush()
    AttrMapCache = {}
    TypeCache    = {}
    State.shape  = nil
    State.typeId = nil
end

local HOOKS = {}
do
    local getAll  = function(self)       return M.GetAttributes(self) end
    local getOne  = function(self, name) return M.GetAttribute(self, name) end
    local getInfo = function(self)       return M.GetAttributeInfo(self) end
    local flush   = function(self)       M.Flush() return true end
    local setOne  = function(self, name, value) return M.SetAttribute(self, name, value) end

    HOOKS.GetAttributes      = getAll
    HOOKS.getAttributes      = getAll
    HOOKS.get_attributes     = getAll
    HOOKS.GetAttribute       = getOne
    HOOKS.getAttribute       = getOne
    HOOKS.get_attribute      = getOne
    HOOKS.GetAttributeInfo   = getInfo
    HOOKS.getAttributeInfo   = getInfo
    HOOKS.get_attribute_info = getInfo
    HOOKS.SetAttribute       = setOne
    HOOKS.setAttribute       = setOne
    HOOKS.set_attribute      = setOne
    HOOKS.FlushAttributes    = flush
    HOOKS.flushAttributes    = flush
    HOOKS.flush_attributes   = flush
end

local function attach(inst)
    if type(inst) ~= "userdata" then return false end

    local ok, mt = pcall(getmetatable, inst)
    if not ok or type(mt) ~= "table" then return false end

    pcall(function()
        for k, fn in pairs(HOOKS) do mt[k] = fn end
    end)

    local okf, f = pcall(function() return inst.GetAttributes end)
    return okf and f == HOOKS.GetAttributes
end

local function install()
    attach(workspace)
end

install()

cheat.register("newPlace", function()
    pcall(M.Flush)
end)

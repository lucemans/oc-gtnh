-- ocgt: what we know about GregTech components, shared by ocdebug and ocdump.
-- machine/NOTES.md records where each of these rules came from.

local component = require("component")
local serialization = require("serialization")

local gt = {}

-- the Minecraft section sign, two bytes in UTF-8
gt.SECTION = "\194\167"
local SECTION = gt.SECTION

gt.MC_COLORS = {
  ["0"] = 0x000000, ["1"] = 0x0000AA, ["2"] = 0x00AA00, ["3"] = 0x00AAAA,
  ["4"] = 0xAA0000, ["5"] = 0xAA00AA, ["6"] = 0xFFAA00, ["7"] = 0xAAAAAA,
  ["8"] = 0x555555, ["9"] = 0x5555FF, ["a"] = 0x55FF55, ["b"] = 0x55FFFF,
  ["c"] = 0xFF5555, ["d"] = 0xFF55FF, ["e"] = 0xFFFF55, ["f"] = 0xFFFFFF,
}

local READABLE = { "get", "is", "has" }

-- a setter sits in the same method list as a getter, so only these are called
function gt.isReadable(name)
  for _, prefix in ipairs(READABLE) do
    if name:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

-- component.methods maps a name to whether the call is direct, so an indirect
-- method is present with the value false; only nil means "not offered"
function gt.has(methods, name)
  return methods ~= nil and methods[name] ~= nil
end

function gt.methodsOf(address)
  local ok, methods = pcall(component.methods, address)
  return ok and methods or nil
end

function gt.call(address, method)
  local results = table.pack(pcall(component.invoke, address, method))
  if not results[1] then
    return nil
  end
  return table.unpack(results, 2, results.n)
end

function gt.strip(text)
  return (text:gsub(SECTION .. "%w", ""))
end

function gt.oneLine(text)
  return (text:gsub("%s+", " "))
end

-- split on colour codes so each run can be drawn in the colour GregTech chose
function gt.segments(text, default)
  local parts = {}
  local color = default
  local index = 1
  while true do
    local start, stop, code = text:find(SECTION .. "(%w)", index)
    if not start then
      if index <= #text then
        parts[#parts + 1] = { text = text:sub(index), color = color }
      end
      return parts
    end
    if start > index then
      parts[#parts + 1] = { text = text:sub(index, start - 1), color = color }
    end
    color = gt.MC_COLORS[code:lower()] or default
    index = stop + 1
  end
end

function gt.formatValue(value)
  local kind = type(value)
  if kind == "string" then
    return gt.oneLine(value)
  elseif kind == "table" then
    local ok, text = pcall(serialization.serialize, value)
    return ok and gt.oneLine(text) or "table"
  end
  return tostring(value)
end

-- reads one method and renders its result; returns nil plus a reason on failure
function gt.readValue(address, name)
  local results = table.pack(pcall(component.invoke, address, name))
  if not results[1] then
    return nil, gt.oneLine(tostring(results[2]))
  end
  if results.n < 2 then
    return "(no return value)"
  end
  local parts = {}
  for index = 2, results.n do
    parts[#parts + 1] = gt.formatValue(results[index])
  end
  return table.concat(parts, ", ")
end

function gt.sensorOf(address)
  if not gt.has(gt.methodsOf(address), "getSensorInformation") then
    return nil
  end
  local lines = gt.call(address, "getSensorInformation")
  if type(lines) ~= "table" or type(lines[1]) ~= "string" then
    return nil
  end
  return lines
end

-- a tank and a battery buffer open their sensor text with a coloured display
-- name, but a multiblock such as a blast furnace opens straight into readings
function gt.looksLikeName(raw)
  if raw:find(SECTION .. "a", 1, true) and raw:find(SECTION .. "e", 1, true) then
    return false
  end
  local plain = gt.strip(raw)
  return plain:match("%S") ~= nil and plain:match("%d") == nil
end

function gt.prettyName(name)
  local spaced = name:gsub("%.", " ")
  return (spaced:gsub("(%a)(%w*)", function(first, rest)
    return first:upper() .. rest
  end))
end

-- the name to show a person, or nil when the component offers nothing better
function gt.friendlyName(address)
  local sensor = gt.sensorOf(address)
  if sensor and gt.looksLikeName(sensor[1]) then
    return gt.strip(sensor[1])
  end
  if gt.has(gt.methodsOf(address), "getName") then
    local name = gt.call(address, "getName")
    if type(name) == "string" and name ~= "" then
      return gt.prettyName(name)
    end
  end
  return nil
end

-- where the sensor text starts reporting, past any display-name line
function gt.firstReading(sensor)
  return gt.looksLikeName(sensor[1]) and 2 or 1
end

local function toNumber(text)
  return tonumber((text:gsub(",", "")))
end

-- GregTech marks the current value green and the maximum yellow, on tanks,
-- energy buffers and multiblock progress alike, so one rule covers them all.
-- Returns the gauge and the text that labels it, or nil for a plain reading.
function gt.gaugeFromSensor(raw)
  local current = raw:match(SECTION .. "a([%d,]+)")
  local maximum = raw:match(SECTION .. "e([%d,]+)")
  if not (current and maximum) then
    return nil
  end
  local value, limit = toNumber(current), toNumber(maximum)
  if not value or not limit or limit <= 0 then
    return nil
  end
  local plain = gt.strip(raw)
  return {
    value = value,
    max = limit,
    current = current,
    maximum = maximum,
    unit = plain:match("(%a+)%s*$") or "",
    -- whatever precedes the first number labels the reading, e.g. "Stored Items:";
    -- a line that opens with the number, as a tank's does, has no label
  }, gt.oneLine((plain:match("^(.-)%d") or ""):gsub("%s+$", ""))
end

return gt

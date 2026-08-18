-- ocgt: what we know about GregTech components, shared by every program here.
-- machine/NOTES.md records where each of these rules came from.

local component = require("component")
local serialization = require("serialization")

local gt = {}

-- the Minecraft section sign, two bytes in UTF-8
gt.SECTION = "\194\167"
local SECTION = gt.SECTION

gt.CONFIG_PATH = "/etc/ocgt.cfg"

gt.MC_COLORS = {
  ["0"] = 0x000000, ["1"] = 0x0000AA, ["2"] = 0x00AA00, ["3"] = 0x00AAAA,
  ["4"] = 0xAA0000, ["5"] = 0xAA00AA, ["6"] = 0xFFAA00, ["7"] = 0xAAAAAA,
  ["8"] = 0x555555, ["9"] = 0x5555FF, ["a"] = 0x55FF55, ["b"] = 0x55FFFF,
  ["c"] = 0xFF5555, ["d"] = 0xFF55FF, ["e"] = 0xFFFF55, ["f"] = 0xFFFFFF,
}

-- names seen in dumps/, where the internal id reads worse than a real name
gt.PROFILES = {
  ["basicgenerator.diesel.tier.02"] = "Diesel Generator",
  ["super.tank.tier.01"] = "Super Tank",
  ["multimachine.blastfurnace"] = "Electric Blast Furnace",
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

-- the one place a method that changes the world may be called. Inspection
-- programs must never reach for this; ocwatch acts through it deliberately.
function gt.setValue(address, method, ...)
  local results = table.pack(pcall(component.invoke, address, method, ...))
  if not results[1] then
    return nil, gt.oneLine(tostring(results[2]))
  end
  return true
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

-------------------------------------------------------------------------------
-- describing values
--
-- serialization.serialize raises on a table holding a function or userdata, and
-- a Logistics Pipes table holds both. These walk anything without failing, and
-- bound themselves so an unexpectedly large table cannot exhaust memory.

local MAX_KEYS = 48
local MAX_DEPTH = 4

local function keyText(key)
  if type(key) == "string" and key:match("^[%a_][%w_]*$") then
    return key
  end
  if type(key) == "string" then
    return "[" .. string.format("%q", key) .. "]"
  end
  return "[" .. tostring(key) .. "]"
end

-- A Logistics Pipes proxy looks like a plain table of {name=, proxy=} entries,
-- but whether those entries can be called lives in the metatable, not in the
-- fields, so a walk over pairs() alone cannot tell you how to use the thing.
local function tableKind(value)
  local ok, meta = pcall(getmetatable, value)
  if not ok or type(meta) ~= "table" then
    return "table"
  end
  local marks = {}
  if rawget(meta, "__call") then
    marks[#marks + 1] = "callable"
  end
  if rawget(meta, "__index") then
    marks[#marks + 1] = "__index"
  end
  if rawget(meta, "__tostring") then
    marks[#marks + 1] = "__tostring"
  end
  if #marks == 0 then
    return "table"
  end
  return "table <" .. table.concat(marks, ", ") .. ">"
end

gt.tableKind = tableKind

local function sortedPairs(value)
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then
      return a < b
    end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function inline(value, depth, seen)
  local kind = type(value)
  if kind == "string" then
    return string.format("%q", gt.oneLine(value))
  elseif kind == "number" or kind == "boolean" or kind == "nil" then
    return tostring(value)
  elseif kind ~= "table" then
    return "<" .. kind .. ">"
  end
  if seen[value] then
    return "<cycle>"
  end
  if depth <= 0 then
    return "{...}"
  end

  seen[value] = true
  local parts = {}
  local keys = sortedPairs(value)
  for index, key in ipairs(keys) do
    if index > MAX_KEYS then
      parts[#parts + 1] = "... " .. (#keys - MAX_KEYS) .. " more"
      break
    end
    parts[#parts + 1] = keyText(key) .. "=" .. inline(value[key], depth - 1, seen)
  end
  seen[value] = nil
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- one line, for a value preview next to a method name
function gt.formatValue(value)
  if type(value) == "string" then
    return gt.oneLine(value)
  end
  return inline(value, 2, {})
end

local function callable(value)
  local ok, meta = pcall(getmetatable, value)
  if not ok or type(meta) ~= "table" then
    return nil
  end
  return meta
end

-- a proxy entry carries its own signature under __tostring, the same way the
-- OpenOS internet library documents its wrapped close
local function callDoc(value)
  local meta = callable(value)
  if not meta or not rawget(meta, "__tostring") then
    return nil
  end
  local ok, text = pcall(tostring, value)
  if not ok or type(text) ~= "string" then
    return nil
  end
  text = gt.oneLine(text)
  if #text > 140 then
    text = text:sub(1, 140) .. "..."
  end
  return "  -- " .. text
end

-- A proxy method is only called when its own name says it reads. sendMessage
-- and setTurtleConnect sit in the same proxy and would change the world.
local function probe(key, item)
  if type(key) ~= "string" or not gt.isReadable(key) then
    return nil
  end
  local meta = callable(item)
  if not meta or not rawget(meta, "__call") then
    return nil
  end
  local results = table.pack(pcall(item))
  if not results[1] then
    return "error: " .. gt.oneLine(tostring(results[2]))
  end
  if results.n < 2 then
    return "(no return value)"
  end
  local parts = {}
  for index = 2, results.n do
    parts[#parts + 1] = inline(results[index], 2, {})
  end
  return table.concat(parts, ", ")
end

-- an indented block, for a dump that someone will read to learn an API
function gt.describeLines(value, prefix)
  local lines = {}
  local seen = {}

  local function walk(current, indent, depth)
    local keys = sortedPairs(current)
    seen[current] = true
    for index, key in ipairs(keys) do
      if index > MAX_KEYS then
        lines[#lines + 1] = indent .. "... " .. (#keys - MAX_KEYS) .. " more keys"
        break
      end
      local item = current[key]
      if type(item) == "table" and not seen[item] and depth < MAX_DEPTH then
        lines[#lines + 1] = indent .. keyText(key) .. " = " .. tableKind(item)
          .. (callDoc(item) or "")
        local result = probe(key, item)
        if result then
          lines[#lines + 1] = indent .. "  -> " .. result
        end
        walk(item, indent .. "  ", depth + 1)
      else
        lines[#lines + 1] = indent .. keyText(key) .. " = " .. inline(item, 1, seen)
      end
    end
    seen[current] = nil
  end

  if type(value) ~= "table" then
    return { prefix .. gt.formatValue(value) }
  end
  lines[#lines + 1] = prefix .. tableKind(value)
  walk(value, prefix:match("^%s*") .. "  ", 1)
  return lines
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

-- the raw values, so a dump can show a table's shape rather than one line
function gt.readRaw(address, name)
  local results = table.pack(pcall(component.invoke, address, name))
  if not results[1] then
    return nil, gt.oneLine(tostring(results[2]))
  end
  return results
end

-------------------------------------------------------------------------------
-- naming

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

-- where the sensor text starts reporting, past any display-name line
function gt.firstReading(sensor)
  return gt.looksLikeName(sensor[1]) and 2 or 1
end

-- the name to show a person. A nickname the user set always wins, then a
-- profile, then whatever the machine says about itself.
function gt.displayName(address, config)
  local nickname = config and config.nicknames and config.nicknames[address]
  if nickname and nickname ~= "" then
    return nickname
  end

  local sensor = gt.sensorOf(address)
  if sensor and gt.looksLikeName(sensor[1]) then
    return gt.strip(sensor[1])
  end

  if gt.has(gt.methodsOf(address), "getName") then
    local name = gt.call(address, "getName")
    if type(name) == "string" and name ~= "" then
      return gt.PROFILES[name] or gt.prettyName(name)
    end
  end
  return nil
end

-------------------------------------------------------------------------------
-- readings

local function toNumber(text)
  return tonumber((text:gsub(",", "")))
end

-- GregTech marks the current value green and the maximum yellow, on tanks,
-- energy buffers and multiblock progress alike, so one rule covers them all.
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

local function comma(number)
  local text = string.format("%d", number)
  local sign, digits = text:match("^(%-?)(%d+)$")
  if not digits then
    return text
  end
  local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return sign .. grouped
end

gt.comma = comma

-- Everything a machine reports, in order, as a list of gauges and text lines.
-- ocdebug draws it, ocwatch draws a chosen subset, alerts index into it.
function gt.readings(address)
  local methods = gt.methodsOf(address) or {}
  local sensor = gt.sensorOf(address)
  local out = {}

  if sensor then
    local lastLabel, lastColor, lastLabelReading = nil, nil, nil
    for index = gt.firstReading(sensor), #sensor do
      local raw = tostring(sensor[index])
      local gauge, label = gt.gaugeFromSensor(raw)
      if gauge then
        gauge.kind = "gauge"
        if label ~= "" then
          gauge.label = label
        else
          -- a tank's gauge carries no label of its own, but the fluid named on
          -- the line above is exactly what the reading is about. That line then
          -- has no reason to be drawn again on its own.
          gauge.label = lastLabel or ""
          if lastLabelReading then
            lastLabelReading.usedAsLabel = true
          end
        end
        gauge.colorCode = lastColor
        out[#out + 1] = gauge
      else
        local plain = gt.oneLine(gt.strip(raw))
        local reading = { kind = "text", raw = raw, plain = plain }
        out[#out + 1] = reading
        if plain:match("%S") then
          lastLabel = (plain:gsub(":%s*$", ""))
          lastLabelReading = reading
          local code = raw:match(SECTION .. "(%w)")
          if code and code:lower() ~= "r" then
            lastColor = code:lower()
          end
        end
      end
    end
    return out
  end

  -- without sensor text the raw counters are all a machine offers
  local function numeric(label, currentMethod, maxMethod, unit)
    if not (gt.has(methods, currentMethod) and gt.has(methods, maxMethod)) then
      return
    end
    local value = gt.call(address, currentMethod)
    local maximum = gt.call(address, maxMethod)
    if type(value) ~= "number" or type(maximum) ~= "number" or maximum <= 0 then
      return
    end
    out[#out + 1] = {
      kind = "gauge",
      label = label,
      value = value,
      max = maximum,
      current = comma(value),
      maximum = comma(maximum),
      unit = unit,
    }
  end

  numeric("Energy", "getEUStored", "getEUMaxStored", "EU")
  numeric("Progress", "getWorkProgress", "getWorkMaxProgress", "")
  return out
end

function gt.statusOf(address, methods)
  methods = methods or gt.methodsOf(address) or {}
  local flags = {}
  if gt.has(methods, "isMachineActive") then
    flags[#flags + 1] = gt.call(address, "isMachineActive") and "active" or "idle"
  end
  if gt.has(methods, "isWorkAllowed") and gt.call(address, "isWorkAllowed") == false then
    flags[#flags + 1] = "disabled"
  end
  if gt.has(methods, "hasWork") and gt.call(address, "hasWork") then
    flags[#flags + 1] = "working"
  end
  return #flags > 0 and table.concat(flags, "  ") or nil
end

-------------------------------------------------------------------------------
-- configuration, shared so a nickname set in ocwatch also shows in ocdebug

local function defaults()
  return { nicknames = {}, watch = {}, alerts = {} }
end

function gt.loadConfig()
  local file = io.open(gt.CONFIG_PATH, "r")
  if not file then
    return defaults()
  end
  local text = file:read("*a")
  file:close()

  local ok, value = pcall(serialization.unserialize, text)
  if not ok or type(value) ~= "table" then
    return defaults()
  end
  value.nicknames = value.nicknames or {}
  value.watch = value.watch or {}
  value.alerts = value.alerts or {}
  return value
end

function gt.saveConfig(config)
  local file, reason = io.open(gt.CONFIG_PATH, "w")
  if not file then
    return nil, tostring(reason)
  end
  file:write(serialization.serialize(config))
  file:close()
  return true
end

return gt

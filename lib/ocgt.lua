-- ocgt: what we know about GregTech machines.
-- machine/NOTES.md records where each of these rules came from.

local core = require("oclib")

local gt = {}

gt.VERSION = "0.7.0"

local SECTION = core.SECTION

-- names seen in dumps/, where the internal id reads worse than a real name
gt.PROFILES = {
  ["basicgenerator.diesel.tier.02"] = "Diesel Generator",
  ["super.tank.tier.01"] = "Super Tank",
  ["multimachine.blastfurnace"] = "Electric Blast Furnace",
}

-- Every GT block worth inspecting has this. It returns the lines the in-game
-- scanner shows, and it is machine-specific in a way the generic getters are
-- not: a super tank still answers getEUStored, it just means nothing.
function gt.sensorOf(address, methods)
  if not core.has(methods or core.methodsOf(address), "getSensorInformation") then
    return nil
  end
  local lines = core.call(address, "getSensorInformation")
  if type(lines) ~= "table" or type(lines[1]) ~= "string" then
    return nil
  end
  return lines
end

-- A tank and a battery buffer open their sensor text with a coloured display
-- name, but a multiblock such as a blast furnace opens straight into readings.
--
-- A reading is either coloured, which the first test catches, or it is a label
-- followed by a number, which the second one does. Rejecting anything with a
-- digit in it was the older rule and it lost every machine somebody had named
-- S1 or EBF2.
function gt.looksLikeName(raw)
  if raw:find(SECTION .. "a", 1, true) and raw:find(SECTION .. "e", 1, true) then
    return false
  end
  local plain = core.strip(raw)
  if plain:match("%a") == nil then
    return false
  end
  return plain:match(":%s*%-?[%d,]") == nil
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

-- the name to show a person, or nil when this is not a GregTech machine
function gt.displayName(address, config, sensor, methods)
  local nickname = core.nickname(config, address)
  if nickname then
    return nickname
  end

  -- a caller that passed the methods has already read the sensor, and a nil
  -- there means the machine has none
  if sensor == nil and methods == nil then
    sensor = gt.sensorOf(address)
  end
  if sensor and gt.looksLikeName(sensor[1]) then
    return core.strip(sensor[1])
  end

  if core.has(methods or core.methodsOf(address), "getName") then
    local name = core.call(address, "getName")
    if type(name) == "string" and name ~= "" then
      return gt.PROFILES[name] or gt.prettyName(name)
    end
  end
  return nil
end

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
  local plain = core.strip(raw)
  return {
    value = value,
    max = limit,
    current = current,
    maximum = maximum,
    unit = plain:match("(%a+)%s*$") or "",
    -- whatever precedes the first number labels the reading, e.g. "Stored Items:";
    -- a line that opens with the number, as a tank's does, has no label
  }, core.oneLine((plain:match("^(.-)%d") or ""):gsub("%s+$", ""))
end

-- Everything a machine reports, in order, as a list of gauges and text lines.
-- ocdebug draws it, ocwatch draws a chosen subset, alerts index into it.
function gt.readings(address, sensor, methods)
  local known = methods ~= nil
  methods = methods or core.methodsOf(address) or {}
  if sensor == nil and not known then
    sensor = gt.sensorOf(address, methods)
  end
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
        local plain = core.oneLine(core.strip(raw))
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
    if not (core.has(methods, currentMethod) and core.has(methods, maxMethod)) then
      return
    end
    local value = core.call(address, currentMethod)
    local maximum = core.call(address, maxMethod)
    if type(value) ~= "number" or type(maximum) ~= "number" or maximum <= 0 then
      return
    end
    out[#out + 1] = {
      kind = "gauge",
      label = label,
      value = value,
      max = maximum,
      current = core.comma(value),
      maximum = core.comma(maximum),
      unit = unit,
    }
  end

  numeric("Energy", "getEUStored", "getEUMaxStored", "EU")
  numeric("Progress", "getWorkProgress", "getWorkMaxProgress", "")
  return out
end

-- A battery buffer is not working because it is switched on, it is working when
-- power is leaving it. It says so itself, as an average over the last ticks,
-- which is the only honest answer for a block that runs no recipe. Returns the
-- amount leaving, or nil when the machine reports no such thing.
local function outflow(readings)
  for _, reading in ipairs(readings or {}) do
    local text = reading.plain
    if not text and reading.raw then
      text = core.strip(reading.raw)
    end
    local amount = text and text:match("^%s*[Aa]v[eg].-[Oo]utput[^:]*:%s*([%d,]+)")
    if amount then
      return toNumber(amount) or 0
    end
  end
  return nil
end

-- What the sensor text alone says about whether a machine is busy, or nil when
-- it says nothing either way.
--
-- This is read rather than asked because every ask is an indirect call that
-- blocks until the next server tick, and because the text is the better
-- witness: a battery buffer answers isMachineActive yes while it sits there
-- passing nothing along.
--
-- A super tank says neither, and that is the right answer for it: it has no
-- work to be idle from. A machine with a recipe running reports a progress
-- gauge; one with nothing running reports "Progress: 0 s / 0 s", which is no
-- gauge at all because its maximum is zero, so the plain line is read too.
local function sensorStatus(readings)
  local leaving = outflow(readings)
  if leaving then
    if leaving > 0 then
      return "working"
    end
    return "idle"
  end

  for _, reading in ipairs(readings or {}) do
    -- matched loosely: a gauge keeps the colon its sensor line had, so the
    -- label reads "Progress:" rather than "Progress"
    if reading.kind == "gauge" and reading.label and reading.label:match("^Progress") then
      return "working"
    end
    if reading.plain and reading.plain:match("^%s*Progress") then
      return "idle"
    end
  end
  return nil
end

-- One word, chosen so a program can colour it without knowing GregTech:
-- "stopped" when work is not allowed, which is what an alert does to a machine,
-- "working" while it is busy, "idle" for a machine that has work to do and is
-- not doing it, and nothing at all for one that has no work to be idle from.
--
-- What counts as busy depends on the machine: power leaving a buffer, a recipe
-- running in a furnace.
function gt.statusOf(address, readings, methods, hasSensor)
  methods = methods or core.methodsOf(address) or {}

  if core.has(methods, "isWorkAllowed")
    and core.call(address, "isWorkAllowed") == false then
    return "stopped"
  end

  local said = sensorStatus(readings)
  if said then
    return said
  end

  -- For a machine that has sensor text, the text is the whole answer: text that
  -- mentions neither progress nor throughput belongs to a block with no work to
  -- be idle from. Asking anyway spent two server ticks per machine per refresh
  -- to learn nothing, and a super tank answers both questions yes regardless.
  if hasSensor then
    return nil
  end

  if core.has(methods, "isMachineActive") and core.call(address, "isMachineActive") then
    return "working"
  end
  if core.has(methods, "hasWork") and core.call(address, "hasWork") then
    return "working"
  end
  return nil
end

-- What each machine calls itself, which does not change while the world runs.
-- A nickname is looked up first and separately, so renaming one in the editor
-- still takes effect at once.
local names = {}

-- One look at a machine: the name, the readings and the status all come out of
-- a single read of the sensor. Reading it three times over, once for each, was
-- most of what made a refresh slow, since every read blocks until the next
-- server tick.
function gt.inspect(address, config)
  local methods = core.methodsOf(address) or {}
  local sensor = gt.sensorOf(address, methods)
  local readings = gt.readings(address, sensor, methods)

  local name = core.nickname(config, address)
  if not name then
    if names[address] == nil then
      names[address] = gt.displayName(address, nil, sensor, methods) or false
    end
    if names[address] then
      name = names[address]
    end
  end

  return {
    name = name,
    status = gt.statusOf(address, readings, methods, sensor ~= nil),
    readings = readings,
  }
end


return gt

-- ocgt: what we know about GregTech machines.
-- machine/NOTES.md records where each of these rules came from.

local core = require("oclib")

local gt = {}

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
function gt.sensorOf(address)
  if not core.has(core.methodsOf(address), "getSensorInformation") then
    return nil
  end
  local lines = core.call(address, "getSensorInformation")
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
  local plain = core.strip(raw)
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

-- the name to show a person, or nil when this is not a GregTech machine
function gt.displayName(address, config)
  local nickname = core.nickname(config, address)
  if nickname then
    return nickname
  end

  local sensor = gt.sensorOf(address)
  if sensor and gt.looksLikeName(sensor[1]) then
    return core.strip(sensor[1])
  end

  if core.has(core.methodsOf(address), "getName") then
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
function gt.readings(address)
  local methods = core.methodsOf(address) or {}
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

function gt.statusOf(address, methods)
  methods = methods or core.methodsOf(address) or {}
  local flags = {}
  if core.has(methods, "isMachineActive") then
    flags[#flags + 1] = core.call(address, "isMachineActive") and "active" or "idle"
  end
  if core.has(methods, "isWorkAllowed") and core.call(address, "isWorkAllowed") == false then
    flags[#flags + 1] = "disabled"
  end
  if core.has(methods, "hasWork") and core.call(address, "hasWork") then
    flags[#flags + 1] = "working"
  end
  return #flags > 0 and table.concat(flags, "  ") or nil
end

return gt

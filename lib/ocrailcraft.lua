-- ocrailcraft: what we know about Railcraft blocks that OpenComputers can see.
--
-- A boiler is two parts and only one of them has a driver. The firebox burns the
-- fuel and holds the heat, and it says how hot it is, how hot it can get, and
-- whether it is burning. The water and the steam sit in the tank blocks above
-- it, which implement Forge's fluid handler and nothing more: an adapter against
-- one exposes no component at all, so they are read through a transposer the way
-- any other driverless tank is. See octank.

local core = require("oclib")

local rc = {}

rc.VERSION = "0.1.0"

-- What identifies a firebox is what it answers rather than what it is called.
-- The solid and the liquid firebox are separate blocks offering the same three
-- methods, and a pack is free to add a third.
local function isFirebox(methods)
  return core.has(methods, "getTemperature") and core.has(methods, "getMaxHeat")
end

function rc.displayName(address, config)
  if not isFirebox(core.methodsOf(address)) then
    return nil
  end
  return core.nickname(config, address) or "Boiler Firebox"
end

-- How hot a boiler can get does not change while the world runs, and reading it
-- blocks until the next server tick like every other call into a firebox. Four
-- boilers on a two second refresh is four ticks a refresh saved.
local ceilings = {}

local function ceilingOf(address)
  if ceilings[address] == nil then
    local most = core.call(address, "getMaxHeat")
    ceilings[address] = type(most) == "number" and most or false
  end
  return ceilings[address] or nil
end

-- Burning is a boiler doing its job. One that is hot and not burning is running
-- down: it goes on making steam out of the heat it already has, which is why
-- the temperature is the reading worth watching rather than this.
local function statusOf(address)
  if core.call(address, "isBurning") then
    return "working"
  end
  return "idle"
end

-- One look at a firebox, in the shape the dashboards already draw. Returns nil
-- for anything that is not one, so a caller asks each vocabulary it understands
-- in turn.
function rc.inspect(address, config)
  if not isFirebox(core.methodsOf(address)) then
    return nil
  end

  local readings = {}
  local temperature = core.call(address, "getTemperature")
  local most = ceilingOf(address)
  if type(temperature) == "number" and most and most > 0 then
    readings[#readings + 1] = {
      kind = "gauge",
      label = "Temperature",
      value = temperature,
      max = most,
      current = core.comma(temperature),
      maximum = core.comma(most),
      unit = "C",
      -- a firebox reports no colour of its own, and heat reads as red
      colorCode = "c",
    }
  end

  return {
    name = rc.displayName(address, config),
    status = statusOf(address),
    readings = readings,
  }
end

return rc

-- octank: reading a fluid tank that has no OpenComputers driver of its own.
--
-- A Railcraft iron or steel tank implements Forge's fluid handler interface and
-- nothing more, so an adapter placed against it exposes no component at all and
-- an MFU has nothing to bind to. What can read it is a transposer, or an
-- adapter carrying a tank controller upgrade: both offer the same methods and
-- both address the tank by which side of themselves it sits on.
--
-- A side is therefore part of what identifies a watched tank, since one
-- transposer can have a different tank on each of its six faces.

local core = require("oclib")

local tank = {}

tank.VERSION = "0.2.0"

-- OpenComputers numbers the sides in this order, and calls them these names
tank.SIDES = { [0] = "down", "up", "north", "south", "west", "east" }

-- Both offer getTankCount, getTankLevel, getTankCapacity and getFluidInTank
-- with the same arguments, so one reader covers them.
local KINDS = { transposer = true, tank_controller = true }

function tank.isReader(kind)
  return KINDS[kind] == true
end

function tank.sideName(side)
  return tank.SIDES[side] or tostring(side)
end

-- Which of the six faces have a tank against them. Six indirect calls, so this
-- belongs in the editor rather than in a refresh.
function tank.sides(address)
  local found = {}
  for side = 0, 5 do
    local count = core.call(address, "getTankCount", side)
    if type(count) == "number" and count > 0 then
      found[#found + 1] = side
    end
  end
  return found
end

-- GregTech colours its own sensor text and we read the colour out of it. A
-- transposer hands over none, so the fluid has to choose one from what it is
-- called. Anything not named here draws in the default gauge colour.
tank.COLORS = {
  water = "b",
  steam = "f",
  lava = "c",
  oil = "8",
  creosote = "6",
  fuel = "e",
  diesel = "e",
  biodiesel = "e",
  lubricant = "e",
  milk = "f",
  honey = "6",
  glass = "7",
  ic2coolant = "b",
  ender = "3",
  redstone = "c",
  glowstone = "e",
}

function tank.colorOf(name)
  if type(name) ~= "string" then
    return nil
  end
  local plain = name:lower():gsub("[^%a]", "")
  if tank.COLORS[plain] then
    return tank.COLORS[plain]
  end
  -- A pack renames fluids more often than it invents them: "densesteam" is
  -- still steam. The longest name wins, or "Creosote Oil" would be whichever of
  -- creosote and oil the table happened to be walked in first.
  local best, longest = nil, 0
  for fluid, code in pairs(tank.COLORS) do
    if #fluid > longest and plain:find(fluid, 1, true) then
      best, longest = code, #fluid
    end
  end
  return best
end

-- One transposer can hold a different tank on each face, so a side is part of
-- what identifies a watched tank: an address alone does not say which one.
function tank.key(address, side)
  return address .. "/" .. side
end

function tank.name(address, side, config)
  return core.nickname(config, tank.key(address, side))
    or ("tank " .. tank.sideName(side))
end

-- What the tank on one side holds, in the shape the dashboards already draw.
-- One indirect call, whatever the tank turns out to contain.
function tank.inspect(address, side, config)
  local readings = {}
  local fluids = core.call(address, "getFluidInTank", side)

  if type(fluids) == "table" then
    for _, fluid in ipairs(fluids) do
      local amount = tonumber(fluid.amount) or 0
      local capacity = tonumber(fluid.capacity) or 0
      if capacity > 0 then
        readings[#readings + 1] = {
          kind = "gauge",
          -- an empty tank reports its capacity and no fluid name, which is a
          -- reading worth showing rather than a machine worth hiding
          label = fluid.label or fluid.name or "empty",
          value = amount,
          max = capacity,
          current = core.comma(amount),
          maximum = core.comma(capacity),
          unit = "L",
          colorCode = tank.colorOf(fluid.name) or tank.colorOf(fluid.label),
        }
      end
    end
  end

  return {
    name = tank.name(address, side, config),
    -- a tank does no work, so it has no status to show: the same answer a
    -- GregTech super tank gives
    status = nil,
    readings = readings,
  }
end

return tank

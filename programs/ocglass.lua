-- ocglass: draw on OpenGlasses.
--
--   ocglass --probe             describe one widget, to learn what it offers
--   ocglass --probe addRect     probe a different widget kind
--   ocglass --list              list the terminal's own methods and bound players
--
-- Every add* method returns a widget object, and none of them start with get,
-- is or has, so nothing has ever called one and no dump has shown what a widget
-- can do. Probing is therefore the first step, not an afterthought: the drawing
-- comes once the real method names are known.

local component = require("component")
local core = require("oclib")

local VERSION = "0.1.0"

local WHITE = 0xFFFFFF
local DIM = 0x999999
local GREEN = 0x66CC66
local RED = 0xCC6666

local gpu = component.isAvailable("gpu") and component.gpu or nil

local function say(text, color)
  if gpu then
    gpu.setForeground(color or WHITE)
  end
  print(text)
end

local function glassesAddress()
  for address, kind in component.list() do
    if kind == "glasses" then
      return address
    end
  end
  return nil
end

-------------------------------------------------------------------------------

local arguments = { ... }
local mode, kind = nil, "addTextLabel"
local index = 1
while arguments[index] do
  if arguments[index] == "--probe" then
    mode = "probe"
    if arguments[index + 1] and arguments[index + 1]:sub(1, 3) == "add" then
      kind = arguments[index + 1]
      index = index + 1
    end
    index = index + 1
  elseif arguments[index] == "--list" then
    mode = "list"
    index = index + 1
  else
    index = index + 1
  end
end

local address = glassesAddress()
if not address then
  io.stderr:write("ocglass: no glasses component found\n")
  return 1
end

local methods = core.methodsOf(address) or {}

if mode == "list" then
  say("ocglass v" .. VERSION .. "   " .. address:sub(1, 8), WHITE)
  local players = core.call(address, "getBindPlayers")
  say("  bound   " .. tostring(players), players and GREEN or RED)
  say("  widgets " .. tostring(core.call(address, "getObjectCount")), DIM)

  local names = {}
  for name in pairs(methods) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    say("  " .. name, DIM)
  end
  return 0
end

if mode ~= "probe" then
  say("ocglass v" .. VERSION, WHITE)
  say("")
  say("  nothing is drawn yet: a widget's methods are still unknown.", DIM)
  say("  find out with:", DIM)
  say("    ocglass --probe", GREEN)
  say("    ocglass --list", GREEN)
  return 0
end

if not core.has(methods, kind) then
  io.stderr:write("ocglass: the glasses offer no " .. kind .. "\n")
  return 1
end

say("ocglass v" .. VERSION .. "   probing " .. kind, WHITE)

-- add* is not a read, so it goes through the write path deliberately: it changes
-- what the wearer sees, and removeAll below puts that back
local widget = core.call(address, kind)
if widget == nil then
  io.stderr:write("ocglass: " .. kind .. " returned nothing\n")
  return 1
end

say("  returned " .. type(widget), DIM)
for _, line in ipairs(core.describeLines(widget, "  ")) do
  say(line, WHITE)
end

-- leave the wearer's view as it was found
core.setValue(address, "removeAll")
say("")
say("  cleared, " .. tostring(core.call(address, "getObjectCount")) .. " widgets left", DIM)

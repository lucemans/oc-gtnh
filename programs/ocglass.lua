-- ocglass: a heads-up display of the base, on OpenGlasses.
--
--   ocglass                     draw the watched machines and keep them fresh
--   ocglass --once              draw one frame, for checking it works
--   ocglass --clear             remove everything this drew
--   ocglass --list              the terminal's own methods and bound players
--   ocglass --probe [addRect]   describe a widget, to learn what it offers
--
-- Widget methods were read off a real pair of glasses, not guessed: colour is
-- three floats from 0 to 1, position is two floats, a rect carries a size and a
-- text label carries a scale. See machine/NOTES.md.

local component = require("component")
local core = require("oclib")
local event = require("event")
local gt = require("ocgt")
local keyboard = require("keyboard")
local lp = require("oclogistics")

local VERSION = "0.2.0"

local REFRESH_SECONDS = 5

-- the coordinate space is the wearer's screen; these suit a 1080p window and
-- are the first thing to change if the display sits awkwardly
local LEFT = 12
local TOP = 12
local LINE_H = 11
local BAR_W = 120
local BAR_H = 6
local TEXT_SCALE = 1.0

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

-- a widget method is callable even though its metatable is protected, so the
-- call is simply attempted and any failure reported once rather than crashing
local function set(widget, method, ...)
  local entry = widget and widget[method]
  if entry == nil then
    return nil
  end
  local ok, reason = pcall(entry, ...)
  if not ok then
    return nil, tostring(reason)
  end
  return true
end

local function rgb(color)
  return ((color >> 16) & 0xFF) / 255,
    ((color >> 8) & 0xFF) / 255,
    (color & 0xFF) / 255
end

-------------------------------------------------------------------------------

local arguments = { ... }
local mode, kind = nil, "addTextLabel"
local index = 1
while arguments[index] do
  local argument = arguments[index]
  if argument == "--probe" then
    mode = "probe"
    if arguments[index + 1] and arguments[index + 1]:sub(1, 3) == "add" then
      kind = arguments[index + 1]
      index = index + 1
    end
  elseif argument == "--list" then
    mode = "list"
  elseif argument == "--clear" then
    mode = "clear"
  elseif argument == "--once" then
    mode = "once"
  end
  index = index + 1
end

local address = glassesAddress()
if not address then
  io.stderr:write("ocglass: no glasses component found\n")
  return 1
end

local methods = core.methodsOf(address) or {}
local config = core.loadConfig()

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

if mode == "clear" then
  core.setValue(address, "removeAll")
  say("cleared, " .. tostring(core.call(address, "getObjectCount")) .. " widgets left", DIM)
  return 0
end

if mode == "probe" then
  if not core.has(methods, kind) then
    io.stderr:write("ocglass: the glasses offer no " .. kind .. "\n")
    return 1
  end
  say("ocglass v" .. VERSION .. "   probing " .. kind, WHITE)

  local widget = core.call(address, kind)
  if widget == nil then
    io.stderr:write("ocglass: " .. kind .. " returned nothing\n")
    return 1
  end
  say("  returned " .. type(widget), DIM)
  for _, line in ipairs(core.describeLines(widget, "  ")) do
    say(line, WHITE)
  end

  core.setValue(address, "removeAll")
  say("")
  say("  cleared, " .. tostring(core.call(address, "getObjectCount")) .. " widgets left", DIM)
  return 0
end

-------------------------------------------------------------------------------

local function targets()
  if #config.watch > 0 then
    return config.watch
  end
  local found = {}
  for machine, machineKind in component.list() do
    if machineKind:sub(1, 3) == "gt_" then
      found[#found + 1] = { address = machine }
    end
  end
  return found
end

-- Widgets are made once and then updated. Rebuilding the scene every refresh
-- would make the wearer's display blink five times a minute.
local scene = {}

local function label(row, text, color, x, y)
  local widget = scene["text" .. row]
  if not widget then
    widget = core.call(address, "addTextLabel")
    scene["text" .. row] = widget
    set(widget, "setScale", TEXT_SCALE)
  end
  set(widget, "setPosition", x, y)
  set(widget, "setText", text)
  set(widget, "setColor", rgb(color))
  return widget
end

local function bar(row, ratio, color, x, y)
  local back = scene["back" .. row]
  if not back then
    back = core.call(address, "addRect")
    scene["back" .. row] = back
    set(back, "setColor", rgb(0x333333))
    set(back, "setAlpha", 0.4)
  end
  set(back, "setPosition", x, y)
  set(back, "setSize", BAR_W, BAR_H)

  local fill = scene["fill" .. row]
  if not fill then
    fill = core.call(address, "addRect")
    scene["fill" .. row] = fill
  end
  set(fill, "setPosition", x, y)
  set(fill, "setSize", math.max(1, math.floor(BAR_W * ratio)), BAR_H)
  set(fill, "setColor", rgb(color))
  set(fill, "setAlpha", 0.9)
end

local function hide(row)
  for _, prefix in ipairs({ "text", "back", "fill" }) do
    local widget = scene[prefix .. row]
    if widget then
      set(widget, "setVisible", false)
    end
  end
end

local function draw()
  local row, y = 1, TOP

  for _, entry in ipairs(targets()) do
    local name = gt.displayName(entry.address, config)
      or lp.displayName(entry.address)
      or entry.address:sub(1, 8)
    local status = gt.statusOf(entry.address)

    label(row, name .. (status and ("  " .. status) or ""), WHITE, LEFT, y)
    set(scene["text" .. row], "setVisible", true)
    row, y = row + 1, y + LINE_H

    for _, reading in ipairs(gt.readings(entry.address)) do
      if reading.kind == "gauge" and reading.max > 0 then
        local ratio = reading.value / reading.max
        if ratio > 1 then
          ratio = 1
        end
        local color = (reading.colorCode and core.MC_COLORS[reading.colorCode])
          or (reading.unit == "EU" and 0xFFFF55)
          or GREEN

        label(row, (reading.label ~= "" and reading.label or "value")
          .. "  " .. reading.current .. " / " .. reading.maximum
          .. (reading.unit ~= "" and (" " .. reading.unit) or ""), DIM, LEFT + 8, y)
        set(scene["text" .. row], "setVisible", true)
        bar(row, ratio, color, LEFT + 8, y + 7)
        row, y = row + 1, y + LINE_H + 4
      end
    end
    y = y + 4
  end

  -- a machine that went away leaves its widgets behind, so they are hidden
  -- rather than deleted: deleting would renumber everything else
  local spare = row
  while scene["text" .. spare] do
    hide(spare)
    spare = spare + 1
  end
  return row - 1
end

if not core.has(methods, "addTextLabel") then
  io.stderr:write("ocglass: these glasses cannot draw text\n")
  return 1
end

local players = core.call(address, "getBindPlayers")
say("ocglass v" .. VERSION .. "   " .. address:sub(1, 8), WHITE)
say("  bound   " .. tostring(players), players and GREEN or RED)
say("  drawing " .. #targets() .. " machines, every " .. REFRESH_SECONDS .. "s", DIM)
say("  [q] to stop, ocglass --clear to wipe the display", DIM)
say("")

local drawn = draw()
say("  " .. drawn .. " lines on the glasses", GREEN)

if mode == "once" then
  return 0
end

while true do
  local name, _, _, code = event.pull(REFRESH_SECONDS)
  if name == "interrupted" then
    break
  elseif name == "key_down" and code == keyboard.keys.q then
    break
  elseif name == nil then
    draw()
  end
end

if gpu then
  gpu.setForeground(WHITE)
end

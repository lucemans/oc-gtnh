-- ockeypad: a PIN lock on an OpenSecurity keypad.
--
--   ockeypad --pin 1234    set the code and store it
--   ockeypad               guard the door
--   ockeypad --probe       print the raw key event, to check its shape
--
-- The keypad has no getter for the key that was pressed. Input arrives as an
-- event whose name the program chooses, so setEventName comes first and the
-- event carries the address, the button id and the button's label.

local component = require("component")
local core = require("oclib")
local event = require("event")
local keyboard = require("keyboard")
local term = require("term")

local VERSION = "0.1.0"

local EVENT = "ockeypad"
-- long enough to finish typing, short enough that a half-entered code does not
-- sit on the pad waiting for someone else to complete it
local ENTRY_TIMEOUT = 8
local OPEN_SECONDS = 5

-- the display takes 0 to 8 characters and a colour of 0 to 7, one bit per
-- channel. Which bit is which is not documented; these read correctly on a
-- keypad but swap the value if a colour comes out wrong.
local WHITE = 7
local RED = 1
local GREEN = 2

local WRITE_COLOR = 0xFFFFFF
local DIM = 0x999999
local OK_COLOR = 0x66CC66
local BAD_COLOR = 0xCC6666

local gpu = component.isAvailable("gpu") and component.gpu or nil

local function say(text, color)
  if gpu then
    gpu.setForeground(color or WRITE_COLOR)
  end
  print(text)
end

local function keypadAddress()
  for address, kind in component.list() do
    if kind == "os_keypad" then
      return address
    end
  end
  return nil
end

local function display(address, text, color)
  -- the display truncates past eight characters, so do it here and know about it
  core.setValue(address, "setDisplay", text:sub(1, 8), color or WHITE)
end

-------------------------------------------------------------------------------

local arguments = { ... }
local config = core.loadConfig()
config.keypad = config.keypad or {}

local probe = false
local index = 1
while arguments[index] do
  if arguments[index] == "--probe" then
    probe = true
    index = index + 1
  elseif arguments[index] == "--pin" and arguments[index + 1] then
    config.keypad.pin = arguments[index + 1]
    core.saveConfig(config)
    index = index + 2
  else
    index = index + 1
  end
end

local address = keypadAddress()
if not address then
  io.stderr:write("ockeypad: no os_keypad component found\n")
  return 1
end

core.setValue(address, "setEventName", EVENT)
core.setValue(address, "setShouldBeep", true)

if probe then
  -- The wiki documents address, button, label after the event name. This prints
  -- what actually arrives, so the assumption is checked rather than trusted.
  say("ockeypad v" .. VERSION .. ": press a key, or wait ten seconds", DIM)
  display(address, "PROBE", WHITE)
  local packed = table.pack(event.pull(10, EVENT))
  if packed.n == 0 then
    say("  no key event arrived", BAD_COLOR)
  else
    for position = 1, packed.n do
      say("  " .. position .. "  " .. type(packed[position])
        .. "  " .. tostring(packed[position]), WRITE_COLOR)
    end
  end
  display(address, "", WHITE)
  return 0
end

local pin = config.keypad.pin
if not pin or pin == "" then
  say("ockeypad v" .. VERSION, WRITE_COLOR)
  say("")
  say("  no code set yet:", DIM)
  say("    ockeypad --pin 1234", OK_COLOR)
  return 1
end

local redstone = component.isAvailable("redstone") and component.getPrimary("redstone") or nil

term.clear()
say("ockeypad v" .. VERSION .. "   guarding with a " .. #pin .. " digit code", WRITE_COLOR)
say("  keypad  " .. address:sub(1, 8), DIM)
if not redstone then
  -- worth saying plainly: the code still works, but nothing physical moves
  say("  no redstone component, so entry is reported but no door opens", BAD_COLOR)
end
say("  [q] or [ctrl+alt+c] to stop", DIM)
say("")

local function grant()
  say("  granted", OK_COLOR)
  display(address, "OPEN", GREEN)
  if redstone then
    for side = 0, 5 do
      pcall(redstone.setOutput, side, 15)
    end
    os.sleep(OPEN_SECONDS)
    for side = 0, 5 do
      pcall(redstone.setOutput, side, 0)
    end
  else
    os.sleep(OPEN_SECONDS)
  end
end

local function deny()
  say("  denied", BAD_COLOR)
  display(address, "NO", RED)
  os.sleep(1)
end

local entry = ""
display(address, "CODE", WHITE)

while true do
  -- pulled unfiltered so the program still answers the keyboard; the timeout is
  -- what clears a code somebody started and walked away from
  local packed = table.pack(event.pull(ENTRY_TIMEOUT))
  local name = packed[1]

  if name == "interrupted" then
    break
  elseif name == "key_down" and packed[4] == keyboard.keys.q then
    break
  elseif name == nil then
    if entry ~= "" then
      entry = ""
      display(address, "CODE", WHITE)
    end
  elseif name == EVENT then
    -- name, address, button, label
    local label = packed[4]
    if type(label) ~= "string" then
      label = tostring(packed[3] or "")
    end

    if label == "*" then
      entry = ""
      display(address, "CODE", WHITE)
    else
      entry = entry .. label
      display(address, string.rep("*", #entry), WHITE)

      if #entry >= #pin then
        if entry == pin then
          grant()
        else
          deny()
        end
        entry = ""
        display(address, "CODE", WHITE)
      end
    end
  end
end

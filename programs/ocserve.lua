-- ocserve: answer status requests from other machines over the network.
--
--   ocserve        listen and answer
--   ocserve --once answer one request, for checking it works
--
-- It serves the machines ocwatch is configured to watch, so the two agree on
-- what matters without a second list to keep in step. With nothing configured
-- it falls back to every GregTech block it can see.
--
-- ocwatch answers the same questions while it draws its dashboard, and answers
-- them from a reading it has already taken. This is for a computer that watches
-- machines with nobody looking at its screen.

local component = require("component")
local core = require("oclib")
local event = require("event")
local keyboard = require("keyboard")
local net = require("ocnet")

local VERSION = "0.3.0"

local WHITE = 0xFFFFFF
local DIM = 0x999999
local GREEN = 0x66CC66

local gpu = component.isAvailable("gpu") and component.gpu or nil

local function say(text, color)
  if gpu then
    gpu.setForeground(color or WHITE)
  end
  print(text)
end

local config = core.loadConfig()

-------------------------------------------------------------------------------

local arguments = { ... }
local once = arguments[1] == "--once"

local modem, reason = net.modem()
if not modem then
  io.stderr:write("ocserve: " .. reason .. "\n")
  return 1
end

say("ocserve v" .. VERSION .. "   port " .. core.PORT, WHITE)
say("  serving " .. #net.machines(config) .. " machines", DIM)
say("  wireless " .. tostring(modem.isWireless()), DIM)
say("  [q] to stop", DIM)
say("")

while true do
  local name, _, remote, port, _, request = event.pull(once and 5 or nil)

  if name == "interrupted" then
    break
  elseif name == "key_down" and port == keyboard.keys.q then
    break
  elseif name == "modem_message" then
    -- read on demand: nothing else here is looking at these machines, so there
    -- is no earlier reading to answer from
    local report = net.report(config, net.machines(config))
    local sent = net.answer(modem, port, remote, request, config, report)
    if sent then
      say("  answered " .. sent, GREEN)
    end
  end

  if once then
    break
  end
end

if gpu then
  gpu.setForeground(WHITE)
end

-- ocserve: answer status requests from other machines over the network.
--
--   ocserve        listen and answer
--   ocserve --once answer one request, for checking it works
--
-- It serves the machines ocwatch is configured to watch, so the two agree on
-- what matters without a second list to keep in step. With nothing configured
-- it falls back to every GregTech block it can see.

local component = require("component")
local core = require("oclib")
local event = require("event")
local gt = require("ocgt")
local keyboard = require("keyboard")
local lp = require("oclogistics")
local serialization = require("serialization")

local VERSION = "0.1.0"

local ASK = "ocstatus?"
local REPLY = "ocstatus!"

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

local function targets()
  if #config.watch > 0 then
    return config.watch
  end
  -- nothing configured, so serve whatever this machine can actually see
  local found = {}
  for address, kind in component.list() do
    if kind:sub(1, 3) == "gt_" then
      found[#found + 1] = { address = address }
    end
  end
  return found
end

local function snapshot()
  local cards = {}
  for _, entry in ipairs(targets()) do
    local card = {
      name = gt.displayName(entry.address, config)
        or lp.displayName(entry.address)
        or entry.address:sub(1, 8),
      status = gt.statusOf(entry.address),
      gauges = {},
    }
    for _, reading in ipairs(gt.readings(entry.address)) do
      if reading.kind == "gauge" then
        card.gauges[#card.gauges + 1] = {
          label = reading.label,
          current = reading.current,
          maximum = reading.maximum,
          unit = reading.unit,
          -- the percentage is computed here so the tablet needs no arithmetic
          -- on numbers that arrived as text
          percent = reading.max > 0 and (reading.value / reading.max * 100) or 0,
        }
      end
    end
    cards[#cards + 1] = card
  end
  return cards
end

-------------------------------------------------------------------------------

local arguments = { ... }
local once = arguments[1] == "--once"

if not component.isAvailable("modem") then
  io.stderr:write("ocserve: no network card installed\n")
  return 1
end

local modem = component.getPrimary("modem")
modem.open(core.PORT)
-- a wireless card sits at zero strength until told otherwise, which looks
-- exactly like a card that is not working
if modem.isWireless() then
  pcall(modem.setStrength, 400)
end

say("ocserve v" .. VERSION .. "   port " .. core.PORT, WHITE)
say("  serving " .. #targets() .. " machines", DIM)
say("  wireless " .. tostring(modem.isWireless()), DIM)
say("  [q] to stop", DIM)
say("")

while true do
  local name, _, remote, port, _, request = event.pull(once and 5 or nil)

  if name == "interrupted" then
    break
  elseif name == "key_down" and port == keyboard.keys.q then
    break
  elseif name == "modem_message" and port == core.PORT and request == ASK then
    local payload = serialization.serialize(snapshot())
    local limit = modem.maxPacketSize and modem.maxPacketSize() or 8192
    if #payload > limit then
      -- better a short answer than a packet the card silently refuses
      payload = serialization.serialize({ { name = "too many machines to send" } })
    end
    modem.send(remote, core.PORT, REPLY, payload)
    say("  answered " .. tostring(remote):sub(1, 8) .. "  " .. #payload .. " bytes", GREEN)
  end

  if once then
    break
  end
end

if gpu then
  gpu.setForeground(WHITE)
end

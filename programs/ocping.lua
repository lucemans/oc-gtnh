-- ocping: is the network working at all?
--
--   ocping --listen   answer pings, and print every packet that arrives
--   ocping            send a ping and print whatever comes back
--
-- Deliberately the smallest thing that uses the network: no config, no machines,
-- no protocol beyond one word. If this cannot get a packet across then nothing
-- built on top of it will, and the fault is the cards or the distance rather
-- than anything in ocwatch or ocview.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")

local VERSION = "0.1.0"

local PING = "ocping?"
local PONG = "ocping!"
local WAIT = 10

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

if not component.isAvailable("modem") then
  io.stderr:write("ocping: no network card\n")
  return 1
end

local modem = component.getPrimary("modem")

-- everything worth knowing about this card, printed before anything is sent, so
-- a silent network can be told from a card that was never going to work
say("ocping v" .. VERSION, WHITE)
say("  card      " .. modem.address:sub(1, 8), DIM)
say("  wireless  " .. tostring(modem.isWireless()), DIM)
say("  wired     " .. tostring(modem.isWired and modem.isWired() or "?"), DIM)

if modem.isWireless() then
  local before = modem.getStrength()
  modem.setStrength(400)
  say("  strength  " .. tostring(before) .. " -> " .. tostring(modem.getStrength()), DIM)
end

local opened = modem.open(core.PORT)
say("  port      " .. core.PORT .. "  open=" .. tostring(opened)
  .. "  isOpen=" .. tostring(modem.isOpen(core.PORT)), DIM)
say("")

local arguments = { ... }

if arguments[1] == "--listen" then
  say("  listening, [ctrl+alt+c] to stop", DIM)
  while true do
    local name, _, remote, port, distance, word = event.pull(nil, "modem_message")
    if name == nil then
      break
    end
    say("  <- " .. tostring(remote):sub(1, 8) .. "  port " .. tostring(port)
      .. "  " .. string.format("%.1f", tonumber(distance) or 0) .. " blocks"
      .. "  " .. tostring(word), WHITE)
    if word == PING then
      modem.send(remote, core.PORT, PONG, computer.address():sub(1, 8))
      say("  -> pong", GREEN)
    end
  end
  return 0
end

say("  broadcasting on " .. core.PORT, DIM)
local sent = modem.broadcast(core.PORT, PING)
say("  broadcast returned " .. tostring(sent), sent and DIM or RED)

local heard = 0
local until_ = computer.uptime() + WAIT
while true do
  local left = until_ - computer.uptime()
  if left <= 0 then
    break
  end
  local name, _, remote, port, distance, word, who = event.pull(left, "modem_message")
  if name == nil then
    break
  end
  heard = heard + 1
  say("  <- " .. tostring(remote):sub(1, 8) .. "  port " .. tostring(port)
    .. "  " .. string.format("%.1f", tonumber(distance) or 0) .. " blocks"
    .. "  " .. tostring(word) .. "  " .. tostring(who), WHITE)
end

say("")
if heard == 0 then
  say("  nothing heard in " .. WAIT .. "s", RED)
  say("  run ocping --listen on the other machine, then try again", DIM)
  say("  if that is already running, the cards are out of range of each other", DIM)
else
  say("  heard " .. heard .. " packets", GREEN)
end

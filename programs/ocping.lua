-- ocping: is the network working at all?
--
--   ocping <host>     send a packet to that machine and time the answer
--   ocping            say what this machine can see of the network
--   ocping --l2       broadcast on the bare modem, ignoring Minitel entirely
--   ocping --listen   answer bare modem broadcasts, and print every packet
--
-- Two layers, two faults. Minitel says whether a packet can be routed to a
-- named machine, which is what everything else here depends on. The bare modem
-- says whether two cards can hear each other at all, which is the fault when
-- the answer to the first question is no.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local net = require("ocnet")

local VERSION = "0.3.0"

local PING = "ocping?"
local PONG = "ocping!"
local WAIT = 10

-- Minitel's own echo: the daemon at the far end acknowledges any reliable
-- packet, so nothing has to be running there to answer this.
local ECHO_PORT = 0
local TIMES = 5

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

local arguments = { ... }
local config = core.loadConfig()

-------------------------------------------------------------------------------
-- the bare modem, for a fault below Minitel

local function layerTwo(listening)
  if not component.isAvailable("modem") then
    io.stderr:write("ocping: no network card\n")
    return 1
  end

  local modem = component.getPrimary("modem")

  -- everything worth knowing about this card, printed before anything is sent,
  -- so a silent network can be told from a card that was never going to work
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

  if listening then
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
  return 0
end

say("ocping v" .. VERSION, WHITE)

if arguments[1] == "--l2" or arguments[1] == "--listen" then
  return layerTwo(arguments[1] == "--listen")
end

-------------------------------------------------------------------------------
-- Minitel

local minitel, reason = net.up()
say("  host      " .. net.hostname(config), DIM)
if minitel and reason then
  say("  minitel   " .. reason, GREEN)
elseif not minitel then
  say("  minitel   " .. reason, RED)
  say("")
  say("  ocping --l2 tests the cards without it", DIM)
  return 1
end
say("  minitel   running", DIM)

-- What the daemon has learned about who is where. A machine that answers here
-- but not to a ping is a routing fault rather than a missing daemon.
local ok, rc = pcall(require, "rc")
if ok and rc.loaded and rc.loaded.minitel and rc.loaded.minitel.route then
  say("  routes", DIM)
  pcall(rc.loaded.minitel.route)
end

local host = arguments[1]
if not host then
  local peers = net.peers(config)
  say("")
  if #peers == 0 then
    say("  no satellites known yet; run ocview once to find them", DIM)
  else
    say("  known satellites: " .. table.concat(peers, ", "), DIM)
  end
  say("  ocping <host> times a packet to one of them", DIM)
  return 0
end

say("")
local answered = 0
for _ = 1, TIMES do
  local sent = computer.uptime()
  local id = minitel.genPacketID()
  computer.pushSignal("net_send", 1, host, ECHO_PORT, "ping", id)

  local seen = nil
  local until_ = computer.uptime() + WAIT
  while computer.uptime() < until_ do
    local name, acked = event.pull(until_ - computer.uptime(), "net_ack")
    if name == nil then
      break
    end
    if acked == id then
      seen = computer.uptime() - sent
      break
    end
  end

  if seen then
    answered = answered + 1
    say("  " .. host .. "  " .. string.format("%.2f", seen) .. "s", GREEN)
  else
    say("  " .. host .. "  no answer in " .. WAIT .. "s", RED)
  end
end

say("")
if answered == 0 then
  say("  nothing came back from " .. host, RED)
  say("  check the name, then check the daemon there: rc minitel start", DIM)
  say("  ocping --l2 says whether the cards can hear each other at all", DIM)
  return 1
end
say("  " .. answered .. " of " .. TIMES .. " answered", GREEN)

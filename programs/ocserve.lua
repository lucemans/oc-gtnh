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
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local keyboard = require("keyboard")
local lp = require("oclogistics")
local net = require("ocnet")
local gtp = require("ocgtp")

local VERSION = "0.7.0"

-- what this machine tells the network it is running, in every report it sends
net.running("ocserve", VERSION)

-- how many items are counted between two questions, and how long the loop
-- listens before it goes back to counting. One count is a server tick.
local PER_TURN = 10
local REST = 0.05
-- how many risers, and how many fallers, are worth sending
local MOVERS = 6
-- how long between reads of the fluid network. One call answers with every name
-- and every amount, so this is a clock rather than a memory question.
local FLUIDS = 10

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

-- A question arrives whenever it arrives, including in the middle of counting
-- items, so it is put here and answered by the loop below rather than from
-- inside whatever event.pull happened to be running.
local pending = {}
-- when this machine next tells the telemetry service what it can see
local telemetryDue = 0
local heard = net.listen(function(from, port, data)
  pending[#pending + 1] = { from = from, port = port, data = data }
end)

local minitel, reason = net.up()
if not minitel then
  net.deafen(heard)
  io.stderr:write("ocserve: " .. reason .. "\n")
  return 1
end

-- A satellite with a request pipe also watches the item network, since nothing
-- else here is using the time between questions. What travels is only what is
-- moving; the list itself is far too large to send and nobody asked for it.
local proxy = lp.requestPipe()
local builder = proxy and lp.builder(proxy)
local items = proxy and lp.available(proxy) or {}
local cursor, movers = 1, {}

-- The fluid network is a pipe of its own and costs one call to read whole, so
-- unlike the items it needs no counting between questions and no memory kept
-- back for it. The amounts travel as well as what is moving.
local fluidProxy = lp.fluidPipe()
local fluids, readAt = {}, 0

local function readFluids()
  readAt = computer.uptime()
  local fresh = lp.fluids(fluidProxy)
  if fresh then
    fluids = lp.merge(fluids, fresh, readAt)
  end
end

if fluidProxy then
  readFluids()
end

say("ocserve v" .. VERSION .. "   " .. net.hostname(config)
  .. " on port " .. core.PORT, WHITE)
say("  serving " .. #net.machines(config) .. " machines", DIM)
if builder then
  say("  counting " .. #items .. " items", DIM)
end
if fluidProxy then
  say("  watching " .. #fluids .. " fluids", DIM)
end
say("  [q] to stop", DIM)
say("")

while true do
  local name, _, _, code = event.pull(once and 5 or REST)

  if name == "interrupted" then
    break
  elseif name == "key_down" and code == keyboard.keys.q then
    break
  end

  local answered = false
  while pending[1] do
    local packet = table.remove(pending, 1)
    -- read on demand: nothing else here is looking at these machines, so there
    -- is no earlier reading to answer from, and a question that is not asking
    -- for one costs no reads at all
    local report = packet.data == net.ASK
      and net.report(config, net.machines(config), movers, fluids) or nil
    local sent, command =
      net.answer(minitel, config, packet.port, packet.from, packet.data, report)
    if sent then
      say("  answered " .. sent, GREEN)
      answered = true
    end
    if command == "update" then
      -- the machine goes down inside this, so nothing after it runs
      net.deafen(heard)
      net.applyUpdate()
    end
  end

  if name == nil and not answered then
    -- Nobody is looking at this machine's screen, so this is the only way what
    -- it watches reaches anybody. The clock is checked before reading, because
    -- reading every machine costs a server tick each and this loop turns over
    -- constantly.
    if gtp.wanted(minitel, config) and computer.uptime() >= telemetryDue then
      telemetryDue = gtp.submit(minitel, config,
        net.report(config, net.machines(config), movers, fluids))
    end

    if fluidProxy and computer.uptime() - readAt >= FLUIDS then
      readFluids()
    end
    if builder and items[1] then
      local finished
      cursor, finished = lp.sweep(proxy, builder, items, cursor, PER_TURN)
      if finished then
        movers = lp.movers(items, MOVERS)
      end
    end
  end

  if once then
    break
  end
end

net.deafen(heard)

if gpu then
  gpu.setForeground(WHITE)
end

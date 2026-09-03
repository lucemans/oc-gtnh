-- ocagent: the base's agent, addressed from chat.
--
--   ocagent                                  connect and serve
--   ocagent --once                           one round, for checking it works
--   ocagent --link host:port secret key      link this machine to the proxy
--   ocagent --link                           say what it is linked to
--
-- A line in chat starting with @c or @computer goes out to the harness, which
-- holds the model. What comes back is words for the chat box, questions for
-- the mesh, or a chunk of Lua to run here. This machine is the only one that
-- talks to the harness; everything else it reaches through Minitel. It also
-- answers everything occonnect answers, so the same link drives its shell.
--
-- Needs an internet card, a tier 2 data card for the sealing, and a chat box
-- on an adapter. The proxy and the keys come from `--link`, or the network
-- screen of `ocwatch --edit`, under `link`.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local keyboard = require("keyboard")
local net = require("ocnet")
local link = require("oclink")

local VERSION = "0.4.0"

net.running("ocagent", VERSION)

-- what a chat line starts with to be for the agent
local TRIGGERS = { "@computer", "@c" }

-- how long the loop listens before it looks at the link again
local REST = 0.1
-- how long a question to the mesh collects answers, unless told otherwise
local ANSWER_WAIT = 5
-- how often the harness hears this machine is alive
local HEARTBEAT = 30
-- below this much free memory after a collection the machine starts over,
-- since a bridge that cannot seal a frame is a bridge that has stopped
local REBOOT_FLOOR = 64 * 1024
-- how many loop errors inside a minute mean starting over rather than going on
local STRIKES = 3
-- how often chat is told the harness is away, at most
local AWAY_EVERY = 30

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

local function log(text, level)
  local ok, syslog = pcall(require, "syslog")
  if ok then
    pcall(syslog, text, level or syslog.info, "ocagent")
  end
end

-- The text after the trigger, or nil when the line is not for the agent. The
-- trigger is the first word, in any case, followed by a space or nothing.
local function trigger(text)
  if type(text) ~= "string" then
    return nil
  end
  local lowered = text:lower()
  for _, word in ipairs(TRIGGERS) do
    if lowered == word then
      return ""
    end
    if lowered:sub(1, #word + 1) == word .. " " then
      return (text:sub(#word + 2):gsub("^%s+", ""))
    end
  end
  return nil
end

-- Puts words in chat, through the chat box specifically. The speech box is not
-- an answer to a typed question.
local function chat(text)
  for address in component.list("chat_box") do
    local ok, said = core.setValue(address, "say", text)
    if ok and said ~= false then
      return true
    end
  end
  return false
end

local config = core.loadConfig()

local arguments = { ... }
local once = arguments[1] == "--once"

if arguments[1] == "--link" then
  if arguments[2] then
    local saved, why = link.configure(config, arguments[2], arguments[3], arguments[4])
    if not saved then
      io.stderr:write("ocagent: " .. tostring(why) .. "\n")
      return 1
    end
    print("linked to " .. link.describe(config.link))
    return 0
  end
  print(link.describe(config.link))
  return 0
end

local settings = config.link or {}
if not settings.host or settings.host == "" or not settings.port
  or not settings.secret or settings.secret == "" or not settings.key or settings.key == "" then
  io.stderr:write("ocagent: not linked, run: ocagent --link host:port <proxy secret> <link key>\n")
  return 1
end

local data = link.card()
if not data then
  io.stderr:write("ocagent: needs a tier 2 data card to seal the link\n")
  return 1
end

-------------------------------------------------------------------------------

-- Everything that arrives is put here and dealt with by the loop. A handler
-- runs inside whatever event.pull is waiting, and a socket write or a machine
-- read from there is how a program locks up around its own listener.
local chats = {}
local packets = {}

local heardChat = function(_, _, player, text)
  chats[#chats + 1] = { player = player, text = text }
end
event.listen("chat_message", heardChat)

local heardNet = net.listen(function(from, port, packet)
  packets[#packets + 1] = { from = from, port = port, data = packet }
end)

local minitel, reason = net.up()
if not minitel then
  event.ignore("chat_message", heardChat)
  net.deafen(heardNet)
  io.stderr:write("ocagent: " .. reason .. "\n")
  return 1
end
if reason then
  say(reason, DIM)
end

local me = link.connect(settings, data, net.hostname(config))

say("ocagent v" .. VERSION .. "   " .. net.hostname(config), WHITE)
say("  proxy " .. settings.host .. ":" .. settings.port, DIM)
if not component.isAvailable("chat_box") then
  say("  no chat box: nothing to hear or answer with", RED)
end
say("  [q] to stop", DIM)
say("")

-- questions to the mesh still collecting answers, by the id the harness gave
local asking = {}
local heartbeatDue = 0
local awaySaid = -AWAY_EVERY
local shown = nil

local function decodeFor(what, packet)
  if what == "run" then
    return net.decodeRun(packet.port, packet.from, packet.data)
  elseif what == "status" then
    return net.decode(packet.port, packet.from, packet.data)
  elseif what == "log" then
    return net.decodeLog(packet.port, packet.from, packet.data)
  elseif what == "versions" then
    return net.decodeVersions(packet.port, packet.from, packet.data)
  end
  return nil
end

local function ask(command)
  local what = command.what
  if what == "status" then
    net.ask(minitel, config)
  elseif what == "log" then
    net.askLog(minitel, config, command.host)
  elseif what == "versions" then
    net.askVersions(minitel, config)
  else
    me.send({ kind = "result", id = command.id, ok = false,
      error = "nothing to ask for " .. tostring(what) })
    return
  end
  asking[#asking + 1] = {
    id = command.id, what = what, hosts = 0,
    until_ = computer.uptime() + (tonumber(command.wait) or ANSWER_WAIT),
  }
  say("ask   " .. what, DIM)
end

-- A chunk for another machine goes over the mesh and is answered like a
-- question; one for this machine runs here like occonnect would run it.
local function runElsewhere(command)
  net.askRun(minitel, command.host, command.id, tostring(command.code or ""))
  asking[#asking + 1] = {
    id = command.id, what = "run", host = command.host, hosts = 0,
    until_ = computer.uptime() + (tonumber(command.wait) or ANSWER_WAIT * 2),
  }
  say("run   on " .. command.host, DIM)
end

local function obey(command)
  if command.kind == "run" and command.host and command.host ~= ""
    and command.host ~= net.hostname(config) then
    runElsewhere(command)
  elseif command.kind == "say" then
    local text = tostring(command.text or "")
    if chat(text) then
      say("say   " .. text, GREEN)
    else
      say("say   nothing to say it with: " .. text, RED)
    end
  elseif command.kind == "ask" then
    ask(command)
  else
    local reply = link.obey(command)
    if reply then
      if reply.kind == "result" then
        say(tostring(command.kind) .. "   " .. (reply.ok and "ok" or tostring(reply.error)),
          reply.ok and GREEN or RED)
      end
      me.send(reply)
    end
  end
end

-- a packet is an answer to whatever is still asking for its kind; a question
-- for this machine is answered like any satellite would, minus the machines
local function heard(packet)
  for index, pending in ipairs(asking) do
    local answer = decodeFor(pending.what, packet)
    if answer and pending.what == "run" then
      if answer.id == pending.id then
        table.remove(asking, index)
        say("run   " .. packet.from .. " " .. (answer.ok and "ok" or tostring(answer.error)),
          answer.ok and GREEN or RED)
        me.send({ kind = "result", id = pending.id, ok = answer.ok,
          output = answer.output, error = answer.error })
        return
      end
    elseif answer then
      pending.hosts = pending.hosts + 1
      net.remember(config, packet.from)
      me.send({ kind = "partial", id = pending.id, host = packet.from, data = answer })
      return
    end
  end
  if packet.data ~= net.ASK then
    local sent, command =
      net.answer(minitel, config, packet.port, packet.from, packet.data, nil)
    if sent then
      say("net   answered " .. sent, DIM)
    end
    if command == "update" then
      event.ignore("chat_message", heardChat)
      net.deafen(heardNet)
      me.close()
      net.applyUpdate()
    end
  end
end

local function finishAsking()
  local now = computer.uptime()
  local index = 1
  while asking[index] do
    local pending = asking[index]
    if now >= pending.until_ and pending.what == "run" then
      me.send({ kind = "result", id = pending.id, ok = false,
        error = pending.host .. " did not answer" })
      say("run   " .. pending.host .. " did not answer", RED)
      table.remove(asking, index)
    elseif now >= pending.until_ then
      me.send({ kind = "result", id = pending.id, ok = true, hosts = pending.hosts })
      say("ask   " .. pending.what .. ", " .. pending.hosts .. " answered", DIM)
      table.remove(asking, index)
    else
      index = index + 1
    end
  end
end

local function forwardChat(line)
  local text = trigger(line.text)
  if not text then
    return
  end
  say("chat  " .. line.player .. ": " .. text, WHITE)
  if me.send({ kind = "chat", player = line.player, text = text }) then
    return
  end
  if computer.uptime() - awaySaid >= AWAY_EVERY then
    awaySaid = computer.uptime()
    chat("the agent is not connected right now"
      .. (me.reason and (": " .. me.reason) or ""))
  end
end

local function tick()
  local name, _, _, code = event.pull(REST)
  if name == "interrupted" or (name == "key_down" and code == keyboard.keys.q) then
    return false
  end

  me.pump()
  if me.state ~= shown then
    shown = me.state
    say("link  " .. shown .. (me.reason and (", " .. me.reason) or ""),
      shown == "open" and GREEN or DIM)
  end

  while chats[1] do
    forwardChat(table.remove(chats, 1))
  end
  while packets[1] do
    heard(table.remove(packets, 1))
  end
  local command = me.take()
  while command do
    obey(command)
    command = me.take()
  end
  finishAsking()

  if me.state == "open" and computer.uptime() >= heartbeatDue then
    heartbeatDue = computer.uptime() + HEARTBEAT
    me.send({ kind = "heartbeat", free = computer.freeMemory(), uptime = computer.uptime() })
  end

  if once and name == nil then
    return false
  end
  return true
end

-- A loop that errors is written down and started again. One that keeps erroring
-- is a machine worth starting again whole, since a reboot lands back here
-- through /home/.shrc and a stuck bridge is worth nothing to anybody.
local strikes = {}
local running = true
while running do
  local ok, result = pcall(tick)
  if ok then
    running = result
  else
    say("error " .. tostring(result), RED)
    log("ocagent: " .. tostring(result), 3)
    local now = computer.uptime()
    strikes[#strikes + 1] = now
    while strikes[1] and now - strikes[1] > 60 do
      table.remove(strikes, 1)
    end
    if #strikes >= STRIKES then
      log("ocagent: " .. STRIKES .. " errors in a minute, rebooting", 2)
      running = false
      computer.shutdown(true)
    end
  end

  if running and computer.freeMemory() < REBOOT_FLOOR
    and require("oclogistics").reclaim() < REBOOT_FLOOR then
    log("ocagent: out of memory, rebooting", 2)
    running = false
    computer.shutdown(true)
  end
end

event.ignore("chat_message", heardChat)
net.deafen(heardNet)
me.close()

if gpu then
  gpu.setForeground(WHITE)
end

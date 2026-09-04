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
local lp = require("oclogistics")
local serialization = require("serialization")

local VERSION = "0.10.0"

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
-- where the board survives a reboot
local BOARD_PATH = "/home/board.cfg"
-- how many lines a board holds, and how many stock lines an answer holds
local BOARD_LINES = 18
local STOCK_LINES = 20

local WHITE = 0xFFFFFF
local DIM = 0x999999
local GREEN = 0x66CC66
local RED = 0xCC6666

local gpu = component.isAvailable("gpu") and component.gpu or nil

-- What the harness put up to be looked at. Kept here for ocview to ask for,
-- and never drawn on this screen, which stays the running log.
local board = nil

local function say(text, color)
  if gpu then
    gpu.setForeground(color or WHITE)
  end
  print(text)
end

local function saveBoard()
  if board then
    local file = io.open(BOARD_PATH, "w")
    if file then
      file:write(serialization.serialize({ title = board.title, lines = board.lines }))
      file:close()
    end
  else
    pcall(require("filesystem").remove, BOARD_PATH)
  end
end

local function loadBoard()
  local file = io.open(BOARD_PATH, "r")
  if not file then
    return
  end
  local text = file:read("*a")
  file:close()
  local ok, saved = pcall(serialization.unserialize, text or "")
  if ok and type(saved) == "table" and type(saved.lines) == "table" and saved.lines[1] then
    board = { title = tostring(saved.title or ""), lines = saved.lines }
  end
end

-- Replaces the board, or takes it down when there are no lines. Lines are cut
-- to what a screen holds, since the harness sends what a model wrote.
local function show(title, lines)
  local kept = {}
  for _, line in ipairs(type(lines) == "table" and lines or {}) do
    if #kept < BOARD_LINES then
      kept[#kept + 1] = tostring(line)
    end
  end
  if kept[1] then
    board = { title = tostring(title or ""), lines = kept }
  else
    board = nil
  end
  saveBoard()
  return #kept
end

-- What the base holds of some things, asked of Applied Energistics and of
-- Logistics Pipes, whichever this computer touches. AE says whether it could
-- craft more; Logistics Pipes says only what is there.
--
-- Every name is answered from one read of each network. Reading the AE
-- network is the slow part, seconds on a full base, so a recipe with five
-- inputs is one read and not five.
local function stock(queries)
  local wanted = {}
  for _, query in ipairs(type(queries) == "table" and queries or {}) do
    local lowered = tostring(query or ""):lower()
    if lowered ~= "" then
      wanted[#wanted + 1] = { asked = tostring(query), lowered = lowered, exact = {}, loose = {} }
    end
  end
  if not wanted[1] then
    return false, "nothing to look for"
  end
  lp.reclaim()

  -- an exact name first, then whatever contains it, a few of each
  local function place(label, line)
    local lowered = label:lower()
    for _, want in ipairs(wanted) do
      if lowered == want.lowered then
        want.exact[#want.exact + 1] = line
      elseif lowered:find(want.lowered, 1, true) and #want.loose < STOCK_LINES then
        want.loose[#want.loose + 1] = line
      end
    end
  end

  for address in component.list("me_") do
    local proxy = component.proxy(address)
    if proxy and proxy.getItemsInNetwork then
      local ok, items = pcall(proxy.getItemsInNetwork)
      if ok and type(items) == "table" then
        for _, item in ipairs(items) do
          local label = tostring(item.label or item.name or "")
          if label ~= "" then
            place(label, string.format("AE %s x%d%s", label, tonumber(item.size) or 0,
              item.isCraftable and " (craftable)" or ""))
          end
        end
      end
      local fine, craftables = pcall(proxy.getCraftables)
      if fine and type(craftables) == "table" then
        for _, craftable in ipairs(craftables) do
          local got, stack = pcall(craftable.getItemStack)
          local label = got and type(stack) == "table" and tostring(stack.label or stack.name or "") or ""
          if label ~= "" then
            place(label, "AE " .. label .. " x0 (craftable)")
          end
        end
      end
      break
    end
  end

  local pipe = lp.requestPipe()
  if pipe then
    local items = lp.available(pipe)
    for _, item in ipairs(items or {}) do
      place(tostring(item.name), string.format("LP %s x%d", item.name, item.amount or 0))
    end
  end

  local out = {}
  for _, want in ipairs(wanted) do
    out[#out + 1] = want.asked .. ":"
    local seen, count = {}, 0
    for _, group in ipairs({ want.exact, want.loose }) do
      for _, line in ipairs(group) do
        if not seen[line] and count < STOCK_LINES then
          seen[line] = true
          count = count + 1
          out[#out + 1] = "  " .. line
        end
      end
    end
    if count == 0 then
      out[#out + 1] = "  nothing in AE or Logistics Pipes"
    end
  end
  return true, table.concat(out, "\n")
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

-- The chat box raises the same line twice within a tick on this server, and
-- one question answered twice costs two turns; the second copy is dropped.
local lastChat = { player = "", text = "", at = -1 }
local heardChat = function(_, _, player, text)
  local now = computer.uptime()
  if player == lastChat.player and text == lastChat.text and now - lastChat.at < 1 then
    return
  end
  lastChat = { player = player, text = text, at = now }
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
loadBoard()

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
  elseif command.kind == "show" then
    local held = show(command.title, command.lines)
    say("board " .. (held > 0 and (held .. " lines") or "cleared"), GREEN)
    -- said to everybody at once rather than waited for: ocview asks every two
    -- seconds, and a board should change the moment it is written
    if board then
      local payload = net.BOARD_REPLY .. "\n"
        .. serialization.serialize({ title = board.title, lines = board.lines })
      minitel.usend(net.EVERYONE, core.PORT, payload)
      for _, host in ipairs(net.peers(config)) do
        minitel.usend(host, core.PORT, payload)
      end
    end
    me.send({ kind = "result", id = command.id, ok = true,
      output = held > 0 and ("showing " .. held .. " lines") or "board cleared" })
  elseif command.kind == "stock" then
    local queries = type(command.queries) == "table" and command.queries or { command.query }
    local ok, text = stock(queries)
    say("stock " .. table.concat(queries, ", "), ok and GREEN or RED)
    if ok then
      me.send({ kind = "result", id = command.id, ok = true, output = text })
    else
      me.send({ kind = "result", id = command.id, ok = false, error = text })
    end
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
  if packet.data == net.BOARD_ASK then
    if board then
      minitel.usend(packet.from, core.PORT, net.BOARD_REPLY .. "\n"
        .. serialization.serialize({ title = board.title, lines = board.lines }))
    end
    return
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

-- Lines for the harness that arrived while the link was down. They wait for
-- it rather than vanish, since a link comes back within a minute and a
-- question typed into the gap was still a question.
local held = {}
local HOLD_SECONDS = 90
local HOLD_LINES = 5

local function forwardChat(line)
  local text = trigger(line.text)
  if not text then
    return
  end
  say("chat  " .. line.player .. ": " .. text, WHITE)
  if me.send({ kind = "chat", player = line.player, text = text }) then
    return
  end
  if #held < HOLD_LINES then
    held[#held + 1] = { player = line.player, text = text, at = computer.uptime() }
  end
  if computer.uptime() - awaySaid >= AWAY_EVERY then
    awaySaid = computer.uptime()
    chat("the agent is reconnecting, one moment"
      .. (me.reason and (": " .. me.reason) or ""))
  end
end

local function flushHeld()
  local now = computer.uptime()
  while held[1] do
    local line = held[1]
    if now - line.at > HOLD_SECONDS then
      table.remove(held, 1)
    elseif me.send({ kind = "chat", player = line.player, text = line.text }) then
      say("chat  sent late: " .. line.player .. ": " .. line.text, DIM)
      table.remove(held, 1)
    else
      return
    end
  end
end

-- How long a phase of the loop may take before it is named on the screen. A
-- loop that reads the keyboard late is a loop with a slow phase in it, and
-- this is how the phase is found rather than guessed at.
local SLOW = 0.25
local complained = {}

local function timed(phase, work)
  local started = computer.uptime()
  work()
  local took = computer.uptime() - started
  if took >= SLOW and computer.uptime() - (complained[phase] or -60) >= 5 then
    complained[phase] = computer.uptime()
    say(string.format("slow  %s took %.2fs", phase, took), RED)
  end
end

local function tick()
  local name, _, _, code = event.pull(REST)
  if name == "interrupted" or (name == "key_down" and code == keyboard.keys.q) then
    return false
  end

  timed("link", me.pump)
  if me.state ~= shown then
    shown = me.state
    say("link  " .. shown .. (me.reason and (", " .. me.reason) or ""),
      shown == "open" and GREEN or DIM)
  end

  timed("chat", function()
    if me.state == "open" then
      flushHeld()
    end
    while chats[1] do
      forwardChat(table.remove(chats, 1))
    end
  end)
  timed("mesh", function()
    while packets[1] do
      heard(table.remove(packets, 1))
    end
  end)
  timed("command", function()
    local command = me.take()
    while command do
      obey(command)
      command = me.take()
    end
  end)
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

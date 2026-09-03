-- oclink: the wire between this computer and whoever drives it from outside
-- the game, and the few things that driver may ask this computer to do.
--
-- Everything goes through one proxy on the public internet, which knows a
-- device by its hostname and joins it to at most one controller: the agent
-- harness, or somebody's shell. The proxy authenticates both ends and forwards
-- frames between them. It never holds the key the frames are sealed with.
--
-- One TCP stream from the internet card, carrying frames both ways:
--
--   u16 length, u8 channel, body
--
-- Channel 0 is the proxy's own: a 16 byte challenge on connect, then messages
-- sealed under keys from the proxy secret and that challenge. Channel 1 is
-- relayed as it is, and holds messages sealed under keys from the link key,
-- which only this computer and its controller have. A sealed body is
--
--   iv .. aes_cbc(key, iv, text) .. hmac_sha256(mac, iv .. ct)[1..16]
--
-- with the data card doing the arithmetic. The text inside is OpenOS
-- serialization in both directions, out of the standard library here and out
-- of a serde dialect on the other side, so nothing is encoded by hand.
--
-- A hello under the static link keys carries a fresh nonce, and everything
-- after it runs under keys derived from that nonce, so a frame recorded off the
-- wire yesterday verifies against nothing today. Every message numbers itself,
-- and a number that does not go up is dropped.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local lp = require("oclogistics")
local serialization = require("serialization")

local link = {}

link.VERSION = "0.1.0"
link.PROTOCOL = 1

link.CONTROL = 0
link.RELAY = 1

-- how long a connect, a challenge or a join may take before the handle is
-- dropped, since the card itself never gives up
local STEP_SECONDS = 10
-- reconnect pauses, doubled after each failure up to the last
local BACKOFF_FIRST = 2
local BACKOFF_LAST = 60
-- how often the proxy hears from a quiet device
local PING_SECONDS = 60
-- how much of a script's output travels back
link.OUTPUT = 4096
-- the longest frame a length prefix can name; a status report is 8 KB
local FRAME_MAX = 65534
-- below this much free memory after a collection, a script is refused
link.FLOOR = 200 * 1024
-- where a shell command's output goes before it is read back
local OUTPUT_PATH = "/tmp/oclink.out"

-- the tier 2 data card is the first with encrypt; a tier 1 has only the hashes
function link.card()
  for address in component.list("data") do
    local methods = core.methodsOf(address)
    if core.has(methods, "encrypt") and core.has(methods, "random") then
      return component.proxy(address)
    end
  end
  return nil
end

-------------------------------------------------------------------------------
-- keys and sealed bodies

-- the card's sha256 takes a key and is then a standard HMAC, checked on a real card
local function hmac(data, key, text)
  return data.sha256(text, key)
end

function link.keys(data, secret)
  return {
    enc = data.sha256(secret .. "\0enc"):sub(1, 16),
    mac = data.sha256(secret .. "\0mac"),
  }
end

function link.session(data, keys, nonce)
  return {
    enc = data.sha256(keys.enc .. nonce):sub(1, 16),
    mac = data.sha256(keys.mac .. nonce),
  }
end

function link.seal(data, keys, text)
  local iv = data.random(16)
  local sealed = data.encrypt(text, keys.enc, iv)
  local tag = hmac(data, keys.mac, iv .. sealed):sub(1, 16)
  return iv .. sealed .. tag
end

function link.open(data, keys, body)
  if type(body) ~= "string" or #body < 33 then
    return nil, "short frame"
  end
  local iv = body:sub(1, 16)
  local sealed = body:sub(17, -17)
  local tag = body:sub(-16)
  if hmac(data, keys.mac, iv .. sealed):sub(1, 16) ~= tag then
    return nil, "bad tag"
  end
  local fine, text = pcall(data.decrypt, sealed, keys.enc, iv)
  if not fine or type(text) ~= "string" then
    return nil, "will not decrypt"
  end
  return text
end

-- one frame as it goes on the wire, or nil when the body is too long to name
function link.frame(channel, body)
  if #body + 1 > FRAME_MAX then
    return nil
  end
  return string.pack(">I2", #body + 1) .. string.char(channel) .. body
end

local function hex(raw)
  return (raw:gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

-------------------------------------------------------------------------------
-- the link

-- One stream through the proxy, pumped from a program's loop and never waited
-- on. Settings are host, port and secret for the proxy, and key for the far
-- end, all out of the configuration.
--
-- States, in the order they happen: idle, connecting, challenge, joining,
-- waiting for a controller, hello sent, open. A failure anywhere goes back to
-- idle with a pause before the next try.
function link.connect(settings, data, hostname)
  local proxyStatic = link.keys(data, settings.secret)
  local farStatic = link.keys(data, settings.key)
  local me = {
    state = "idle",
    -- when the next connect may be tried, and how many have failed in a row
    retryAt = 0,
    failures = 0,
    -- what the last failure was, for the screen
    reason = nil,
    -- numbered both ways on both channels
    seqOut = 0,
    seqIn = 0,
    controlOut = 0,
    controlIn = 0,
  }
  local handle, proxyKeys, keys, deadline, pingAt, buffer, inbox

  local function drop(why)
    if handle then
      pcall(handle.close)
    end
    handle, proxyKeys, keys, buffer, inbox = nil, nil, nil, "", {}
    me.state = "idle"
    me.reason = why
    me.failures = me.failures + 1
    local wait = math.min(BACKOFF_FIRST * 2 ^ (me.failures - 1), BACKOFF_LAST)
    me.retryAt = computer.uptime() + wait
  end

  local function write(channel, sealing, message)
    local frame = link.frame(channel, link.seal(data, sealing, serialization.serialize(message)))
    if not frame then
      me.reason = "a message too long to frame was not sent"
      return false
    end
    local ok, why = pcall(handle.write, frame)
    if not ok then
      drop("write failed: " .. tostring(why))
      return false
    end
    return true
  end

  local function control(message)
    me.controlOut = me.controlOut + 1
    message.seq = me.controlOut
    return write(link.CONTROL, proxyKeys, message)
  end

  local function join(challenge)
    local nonce = data.random(16)
    me.controlOut, me.controlIn = 0, 0
    proxyKeys = proxyStatic
    local said = control({
      kind = "join", role = "device", name = hostname, protocol = link.PROTOCOL,
      challenge = hex(challenge), nonce = hex(nonce),
    })
    if said then
      proxyKeys = link.session(data, proxyStatic, challenge .. nonce)
      me.state = "joining"
      deadline = computer.uptime() + STEP_SECONDS
    end
  end

  local function hello()
    local nonce = data.random(16)
    me.seqOut, me.seqIn = 0, 0
    keys = farStatic
    me.seqOut = 1
    local said = write(link.RELAY, keys, {
      kind = "hello", protocol = link.PROTOCOL, host = hostname,
      nonce = hex(nonce), seq = me.seqOut,
    })
    if said then
      keys = link.session(data, farStatic, nonce)
      me.state = "hello"
    end
  end

  local function connect()
    if not component.isAvailable("internet") then
      drop("no internet card")
      return
    end
    local ok, sock, why = pcall(component.internet.connect, settings.host, settings.port)
    if not ok or not sock then
      drop("connect refused: " .. tostring(ok and why or sock))
      return
    end
    handle = sock
    buffer, inbox = "", {}
    deadline = computer.uptime() + STEP_SECONDS
    me.state = "connecting"
  end

  local function acceptControl(body)
    if me.state == "challenge" then
      if #body ~= 16 then
        drop("the proxy did not challenge")
        return
      end
      join(body)
      return
    end
    local text, why = link.open(data, proxyKeys, body)
    if not text then
      me.reason = "dropped a proxy frame: " .. why
      return
    end
    local ok, message = pcall(serialization.unserialize, text)
    if not ok or type(message) ~= "table" then
      me.reason = "dropped a proxy frame: unreadable"
      return
    end
    if type(message.seq) ~= "number" or message.seq <= me.controlIn then
      me.reason = "dropped a proxy frame: out of order"
      return
    end
    me.controlIn = message.seq
    if message.kind == "joined" then
      me.state = "waiting"
      me.failures = 0
      me.reason = nil
    elseif message.kind == "refused" then
      drop("the proxy refused: " .. tostring(message.why))
    elseif message.kind == "attached" then
      hello()
    elseif message.kind == "detached" then
      keys = nil
      inbox = {}
      me.state = "waiting"
    end
  end

  local function acceptRelay(body)
    if not keys then
      return
    end
    local text, why = link.open(data, keys, body)
    if not text then
      me.reason = "dropped a frame: " .. why
      return
    end
    local ok, message = pcall(serialization.unserialize, text)
    if not ok or type(message) ~= "table" then
      me.reason = "dropped a frame: unreadable"
      return
    end
    if type(message.seq) ~= "number" or message.seq <= me.seqIn then
      me.reason = "dropped a frame: out of order"
      return
    end
    me.seqIn = message.seq
    if message.kind == "welcome" then
      me.state = "open"
      me.reason = nil
      return
    end
    inbox[#inbox + 1] = message
  end

  local function pull()
    local ok, chunk = pcall(handle.read, 4096)
    if not ok then
      drop("read failed: " .. tostring(chunk))
      return
    end
    if chunk == nil then
      drop("closed by the far end")
      return
    end
    if chunk == "" then
      return
    end
    buffer = buffer .. chunk
    while handle and #buffer >= 3 do
      local length = string.unpack(">I2", buffer)
      if #buffer < 2 + length then
        break
      end
      local channel = buffer:byte(3)
      local body = buffer:sub(4, 2 + length)
      buffer = buffer:sub(3 + length)
      if channel == link.CONTROL then
        acceptControl(body)
      elseif channel == link.RELAY then
        acceptRelay(body)
      end
    end
  end

  -- one step: connect, finish connecting, or read what has arrived
  function me.pump()
    if me.state == "idle" then
      if computer.uptime() >= me.retryAt then
        connect()
      end
      return
    end
    if me.state == "connecting" then
      local ok, done, why = pcall(handle.finishConnect)
      if not ok then
        drop("connect failed: " .. tostring(done))
        return
      end
      if done == nil then
        drop("connect failed: " .. tostring(why))
        return
      end
      if not done then
        if computer.uptime() > deadline then
          drop("connect timed out")
        end
        return
      end
      me.state = "challenge"
      deadline = computer.uptime() + STEP_SECONDS
      pingAt = computer.uptime() + PING_SECONDS
      return
    end
    if (me.state == "challenge" or me.state == "joining") and computer.uptime() > deadline then
      drop("the proxy did not answer the " .. (me.state == "joining" and "join" or "connect"))
      return
    end
    if me.state ~= "challenge" and computer.uptime() >= pingAt then
      pingAt = computer.uptime() + PING_SECONDS
      control({ kind = "ping" })
    end
    if handle then
      pull()
    end
  end

  -- sends one message to the controller, numbered; false when there is none
  function me.send(message)
    if me.state ~= "open" then
      return false
    end
    me.seqOut = me.seqOut + 1
    message.seq = me.seqOut
    return write(link.RELAY, keys, message)
  end

  -- the next message the controller sent, or nil
  function me.take()
    if inbox and inbox[1] then
      return table.remove(inbox, 1)
    end
    return nil
  end

  function me.close()
    if handle then
      pcall(handle.close)
    end
    handle = nil
    me.state = "closed"
  end

  return me
end

-------------------------------------------------------------------------------
-- what a controller may have done here

-- Runs a chunk of Lua here, with print collected. Returns whether it ran, and
-- what it printed and returned, or why it did not. The output is bounded so a
-- loop that prints forever fills a buffer rather than the memory.
function link.run(code)
  if lp.reclaim() < link.FLOOR then
    return false, "not enough memory free to run a script"
  end

  local out, size = {}, 0
  local function collect(text)
    if size >= link.OUTPUT then
      return
    end
    local room = link.OUTPUT - size
    if #text > room then
      text = text:sub(1, room) .. "\n... output cut at " .. link.OUTPUT .. " bytes"
      size = link.OUTPUT
    else
      size = size + #text
    end
    out[#out + 1] = text
  end

  local env = setmetatable({
    print = function(...)
      local parts = table.pack(...)
      for index = 1, parts.n do
        parts[index] = tostring(parts[index])
      end
      collect(table.concat(parts, "\t", 1, parts.n))
    end,
  }, { __index = _G })

  local chunk, why = load(code, "=remote", "t", env)
  if not chunk then
    return false, "does not compile: " .. tostring(why)
  end

  local results = table.pack(pcall(chunk))
  if not results[1] then
    return false, tostring(results[2]), table.concat(out, "\n")
  end
  for index = 2, results.n do
    collect(core.formatValue(results[index]))
  end
  return true, table.concat(out, "\n")
end

-- The shell writes to the screen, so the command is redirected to a file and the
-- file is read back. A command that redirects on its own is left alone:
-- appending a second redirect makes the shell apply only one of them, which
-- silently swallowed both the output and the intended file.
function link.shell(command)
  local sh = require("sh")
  local own = command:find(">") ~= nil
  local line = own and command or (command .. " > " .. OUTPUT_PATH)

  local ok, reason = pcall(sh.execute, _ENV, line)
  local output = ""
  if not own then
    local file = io.open(OUTPUT_PATH, "r")
    if file then
      output = file:read("*a") or ""
      file:close()
    end
  else
    output = "(output went to the command's own redirect)"
  end
  if #output > link.OUTPUT then
    output = output:sub(1, link.OUTPUT) .. "\n... output cut at " .. link.OUTPUT .. " bytes"
  end

  if not ok then
    return false, output .. "\n" .. tostring(reason)
  end
  return reason ~= false, output
end

function link.file(path, body)
  local file, reason = io.open(path, "w")
  if not file then
    return false, tostring(reason)
  end
  file:write(body)
  file:close()
  return true, #body .. " bytes written to " .. path
end

-- Carries out what any driven computer answers to, and returns the reply. Nil
-- when the command is somebody else's to handle.
function link.obey(command)
  local ok, output, partial
  if command.kind == "run" then
    ok, output, partial = link.run(tostring(command.code or ""))
  elseif command.kind == "shell" then
    ok, output = link.shell(tostring(command.command or ""))
  elseif command.kind == "file" then
    ok, output = link.file(tostring(command.path or ""), tostring(command.body or ""))
  elseif command.kind == "ping" then
    return { kind = "pong" }
  else
    return nil
  end
  if ok then
    return { kind = "result", id = command.id, ok = true, output = output }
  end
  return { kind = "result", id = command.id, ok = false, error = output, output = partial }
end

return link

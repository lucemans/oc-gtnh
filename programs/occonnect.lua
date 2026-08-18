-- occonnect: lets someone off the machine run commands on it, over ntfy.
--
-- OpenComputers cannot open a TLS socket, so MQTT over wss is out of reach.
-- ntfy is plain HTTPS request and response, which is the one transport this
-- machine already does reliably, and it needs nothing hosted.
--
--   occonnect                       connect and wait for commands
--   occonnect --once                one poll, for checking it works
--   occonnect --reset               issue a new pairing code
--   occonnect --server https://...  use a different ntfy than ntfy.sh
--
-- Commands are published to   <server>/<topic>
-- Output comes back on        <server>/<topic>-out

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local sh = require("sh")
local term = require("term")

local VERSION = "0.2.0"

-- a poll costs an HTTPS round trip, and this machine has other work to do
local POLL_SECONDS = 5
local OUTPUT_PATH = "/tmp/occonnect.out"
-- ntfy.sh rejects a message larger than this
local MAX_RESULT = 3500

local WHITE = 0xFFFFFF
local DIM = 0x999999
local GREEN = 0x66CC66
local CYAN = 0x66CCFF
local RED = 0xCC6666

local gpu = component.isAvailable("gpu") and component.gpu or nil

local function write(text, color)
  if gpu then
    gpu.setForeground(color or WHITE)
  end
  io.write(text)
end

local function say(text, color)
  write(text .. "\n", color)
end

-- not cryptographic: OpenComputers offers no random source worth the name
-- without a data card. It only has to be unguessable by a passer-by.
local function makeCode()
  local alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  local seed = math.floor(computer.uptime() * 1000)
  local address = computer.address()
  for index = 1, #address do
    seed = seed + address:byte(index) * index
  end
  math.randomseed(seed % 2147483647)
  local out = {}
  for _ = 1, 8 do
    local pick = math.random(#alphabet)
    out[#out + 1] = alphabet:sub(pick, pick)
  end
  return table.concat(out)
end

local function request(url, body)
  local handle, reason = component.internet.request(url, body)
  if not handle then
    return nil, tostring(reason)
  end

  while true do
    local ok, connected, connectReason = pcall(handle.finishConnect)
    if not ok then
      handle.close()
      return nil, tostring(connected)
    end
    if connected == nil then
      handle.close()
      return nil, tostring(connectReason)
    end
    if connected then
      break
    end
    os.sleep(0)
  end

  local code = handle.response()
  local chunks = {}
  while true do
    local chunk, readReason = handle.read()
    if chunk == nil then
      handle.close()
      if readReason then
        return nil, tostring(readReason)
      end
      return code, table.concat(chunks)
    end
    if #chunk > 0 then
      chunks[#chunks + 1] = chunk
    else
      os.sleep(0)
    end
  end
end

local function idOf(line)
  return line:match('"id":"([%w_%-]+)"')
end

-- The message is a JSON string, so a quote inside a command is escaped. A
-- pattern would stop at the first one; this walks the escapes properly.
local function messageOf(line)
  local marker = '"message":"'
  local start = line:find(marker, 1, true)
  if not start then
    return nil
  end

  local index = start + #marker
  local out = {}
  while index <= #line do
    local char = line:sub(index, index)
    if char == "\\" then
      local escaped = line:sub(index + 1, index + 1)
      if escaped == "n" then
        out[#out + 1] = "\n"
      elseif escaped == "t" then
        out[#out + 1] = "\t"
      else
        out[#out + 1] = escaped
      end
      index = index + 2
    elseif char == '"' then
      return table.concat(out)
    else
      out[#out + 1] = char
      index = index + 1
    end
  end
  return nil
end

-- The shell writes to the screen, so the command is redirected to a file and the
-- file is read back. A command that writes only to stderr returns nothing.
--
-- A command that redirects on its own is left alone: appending a second redirect
-- makes the shell apply only one of them, which silently swallowed both the
-- output and the intended file.
local function run(command)
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

  if not ok then
    return false, output .. "\n" .. tostring(reason)
  end
  return reason ~= false, output
end

-------------------------------------------------------------------------------

local arguments = { ... }
local config = core.loadConfig()
config.connect = config.connect or {}

local once = false
local index = 1
while arguments[index] do
  if arguments[index] == "--once" then
    once = true
    index = index + 1
  elseif arguments[index] == "--reset" then
    config.connect.code = makeCode()
    index = index + 1
  elseif arguments[index] == "--server" and arguments[index + 1] then
    config.connect.server = arguments[index + 1]:gsub("/$", "")
    index = index + 2
  else
    index = index + 1
  end
end

config.connect.server = config.connect.server or "https://ntfy.sh"
config.connect.code = config.connect.code or makeCode()
-- half the address is 48 bits of topic, which nobody is going to stumble onto
config.connect.topic = config.connect.topic
  or ("oc-" .. computer.address():gsub("%-", ""):sub(1, 12))
core.saveConfig(config)

if not component.isAvailable("internet") then
  io.stderr:write("occonnect: no internet card installed\n")
  return 1
end

local inbox = config.connect.server .. "/" .. config.connect.topic
local outbox = inbox .. "-out"

term.clear()
say("occonnect v" .. VERSION, WHITE)
say("")
say("  topic         " .. config.connect.topic, DIM)
say("  server        " .. config.connect.server, DIM)
say("")
say("  pairing code", DIM)
say("    " .. config.connect.code, GREEN)
say("")
say("  hand the topic and the code to whoever should drive this machine.", DIM)
say("  anything arriving without the code is ignored.", DIM)
say("  [ctrl+alt+c] to stop", DIM)
say("")

-- Whatever is already sitting in the topic is history, not instructions. The
-- first poll only learns where the log has got to, so a restart cannot replay
-- a command that was sent hours ago.
local since = nil
do
  local code, body = request(inbox .. "/json?poll=1")
  if code == 200 and body then
    for line in body:gmatch("[^\n]+") do
      since = idOf(line) or since
    end
  end
  say(since and "  caught up, waiting" or "  waiting", DIM)
end

local failures = 0
while true do
  local url = inbox .. "/json?poll=1" .. (since and ("&since=" .. since) or "")
  local code, body = request(url)

  if not code then
    failures = failures + 1
    -- a server that is down should not fill the screen while it is down
    if failures == 1 or failures % 12 == 0 then
      say("  ntfy unreachable: " .. tostring(body), RED)
    end
  else
    if failures > 0 then
      say("  ntfy back", GREEN)
      failures = 0
    end

    for line in (body or ""):gmatch("[^\n]+") do
      local id = idOf(line)
      if id then
        since = id
      end
      if line:find('"event":"message"', 1, true) then
        local message = messageOf(line)
        -- the topic is a public pipe, so the code travels with the command and
        -- is checked here rather than by anything in the middle
        local given, command = (message or ""):match("^(%S+)%s+(.*)$")
        if given ~= config.connect.code then
          say("  refused a command with the wrong code", RED)
          request(outbox, "refused: wrong pairing code")
        elseif command and command:match("%S") then
          say("  > " .. command, CYAN)
          local ok, output = run(command)
          say(ok and "  done" or "  failed", ok and GREEN or RED)
          if #output > MAX_RESULT then
            output = output:sub(1, MAX_RESULT) .. "\n[truncated]"
          end
          request(outbox, (ok and "ok  " or "failed  ") .. command .. "\n" .. output)
        end
      end
    end
  end

  if once then
    return 0
  end
  os.sleep(POLL_SECONDS)
end

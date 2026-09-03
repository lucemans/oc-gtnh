-- occonnect: lets someone off the machine run commands on it.
--
--   occonnect          connect and wait for commands
--   occonnect --once   one round, for checking it works
--
-- The machine joins the proxy under its hostname and waits for a controller,
-- which is `ocharness shell`, `lua` or `file` on somebody's computer. What
-- arrives is a shell line, a chunk of Lua or a file to write, and what went
-- out is sent back. Nothing here is restricted: whoever holds the link key
-- drives the shell.
--
-- Needs an internet card and a tier 2 data card. The proxy and the keys are
-- set on the network screen of `ocwatch --edit`, under `link`.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local keyboard = require("keyboard")
local link = require("oclink")

local VERSION = "0.4.0"

local REST = 0.1

local WHITE = 0xFFFFFF
local DIM = 0x999999
local GREEN = 0x66CC66
local CYAN = 0x66CCFF
local RED = 0xCC6666

local gpu = component.isAvailable("gpu") and component.gpu or nil

local function say(text, color)
  if gpu then
    gpu.setForeground(color or WHITE)
  end
  print(text)
end

local arguments = { ... }
local once = arguments[1] == "--once"

local config = core.loadConfig()
local settings = config.link or {}

if not settings.host or settings.host == "" or not settings.port
  or not settings.secret or settings.secret == "" or not settings.key or settings.key == "" then
  io.stderr:write("occonnect: no link configured, set it in ocwatch --edit under network\n")
  return 1
end
if not component.isAvailable("internet") then
  io.stderr:write("occonnect: no internet card installed\n")
  return 1
end
local data = link.card()
if not data then
  io.stderr:write("occonnect: needs a tier 2 data card to seal the link\n")
  return 1
end

local function hostname()
  local file = io.open("/etc/hostname", "r")
  if file then
    local name = file:read()
    file:close()
    if name and name ~= "" then
      return name
    end
  end
  return computer.address():sub(1, 8)
end

local me = link.connect(settings, data, hostname())

say("occonnect v" .. VERSION .. "   " .. hostname(), WHITE)
say("  proxy " .. settings.host .. ":" .. settings.port, DIM)
say("  [q] to stop", DIM)
say("")

local shown = nil
while true do
  local name, _, _, code = event.pull(REST)
  if name == "interrupted" or (name == "key_down" and code == keyboard.keys.q) then
    break
  end

  me.pump()
  if me.state ~= shown then
    shown = me.state
    say("link  " .. shown .. (me.reason and (", " .. me.reason) or ""),
      shown == "open" and GREEN or DIM)
  end

  local command = me.take()
  while command do
    local first = tostring(command.command or command.code or command.path or ""):match("^[^\n]*")
    say("  > " .. tostring(command.kind) .. "  " .. first, CYAN)
    local reply = link.obey(command)
    if reply then
      say(reply.ok == false and "  failed" or "  done", reply.ok == false and RED or GREEN)
      me.send(reply)
    end
    command = me.take()
  end

  if once and name == nil then
    break
  end
end

me.close()
if gpu then
  gpu.setForeground(WHITE)
end

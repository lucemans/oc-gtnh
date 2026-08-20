-- ocnotify: how a base tells somebody that something happened.
--
-- Each way of saying it is a channel: a thing that can be switched on and off
-- on its own, and tuned on its own. They are not alternatives to each other.
-- A lamp turning red, a siren, and a line in chat all do different jobs at the
-- same time, and which of them a base wants is a matter of taste and of where
-- the person happens to be standing.
--
-- Three kinds of thing happen here:
--
--   an event      something occurred just now, said once: a chat line, a
--                 spoken phrase, a figure on a note block, a beep
--   a state       something is wrong and still is, held until it is not: a
--                 lamp colour, a siren
--   a record      something is written down whether or not anybody is here to
--                 hear it: a syslog line, kept and relayed to a collector
--
-- Holding a state is why every channel is asked on every change rather than
-- only when trouble starts: an alarm that is never told the trouble ended goes
-- on sounding.
--
-- A record is asked separately, because it is the only one that is not about
-- somebody standing in a room. An alert that switches the fuel over is nobody's
-- emergency and says nothing aloud, and it is exactly what you want written
-- down when you come back and ask what happened.
--
-- What each channel is worth doing is stored under `notify` in the shared
-- configuration, so ocwatch's editor can turn one off without knowing what it
-- is:
--
--   notify = {
--     chat = { on = true },
--     speech = { on = true },
--     note = { on = true, instrument = "harp" },
--     lamp = { on = true, tripped = "ff0000", clear = "00ff00" },
--     siren = { on = false, sound = "klaxon2" },
--     beep = { on = true },
--     syslog = { on = true },
--   }

local computer = require("computer")
local core = require("oclib")
local ct = require("occomputronics")
local sec = require("ocsecurity")
local serialization = require("serialization")

local notify = {}

notify.VERSION = "0.2.0"

-- Every channel, in the order they are offered and asked. Each says what it
-- needs, so the editor can tell a channel that is switched off from one that
-- has nothing to switch on.
notify.CHANNELS = {
  {
    name = "chat",
    what = "a line in Minecraft chat",
    needs = "chat_box",
    kind = "event",
  },
  {
    name = "speech",
    what = "spoken aloud, if the server can",
    needs = "speech_box",
    kind = "event",
  },
  {
    name = "note",
    what = "a falling figure on a note block",
    needs = "iron_noteblock",
    kind = "event",
  },
  {
    name = "lamp",
    what = "a colourful lamp, red while it lasts",
    needs = "colorful_lamp",
    kind = "state",
  },
  {
    name = "siren",
    what = "an alarm, sounding until it clears",
    needs = "os_alarm",
    kind = "state",
  },
  {
    name = "beep",
    what = "the computer's own beep",
    kind = "event",
  },
  {
    name = "syslog",
    what = "a line in the log, kept and sent to a collector",
    kind = "record",
  },
}

-- RFC 5424 severities, which is what a syslog packet carries and what a
-- collector filters on.
notify.ERROR = 3
notify.NOTICE = 5
notify.INFO = 6

function notify.find(name)
  for _, channel in ipairs(notify.CHANNELS) do
    if channel.name == name then
      return channel
    end
  end
  return nil
end

-- What is configured for one channel, with the defaults filled in. A channel
-- nobody has touched is on, because a base that has gone to the trouble of
-- placing a lamp wants the lamp used.
function notify.settings(config, name)
  local kept = config and config.notify and config.notify[name] or {}
  local out = {}
  for key, value in pairs(kept) do
    out[key] = value
  end
  if out.on == nil then
    out.on = true
  end
  return out
end

function notify.set(config, name, key, value)
  config.notify = config.notify or {}
  config.notify[name] = config.notify[name] or {}
  config.notify[name][key] = value
end

-- whether the hardware a channel needs is actually here
function notify.present(channel)
  if not channel.needs then
    return true
  end
  if channel.needs == "os_alarm" then
    return sec.alarms()[1] ~= nil
  end
  return ct.first(channel.needs) ~= nil
end

function notify.usable(config, channel)
  return notify.settings(config, channel.name).on == true
    and notify.present(channel)
end

local function hex(text, fallback)
  local value = tonumber(tostring(text), 16)
  if not value then
    return fallback
  end
  return value
end

-- The colour a lamp is set to, out of a plain "ff0000" in the configuration,
-- packed down to the five bits a channel the lamp actually takes.
function notify.lampColor(config, tripped)
  local kept = notify.settings(config, "lamp")
  local text = kept.clear or "00ff00"
  if tripped then
    text = kept.tripped or "ff0000"
  end
  local rgb = hex(text, tripped and 0xFF0000 or 0x00FF00)
  return ct.rgb(
    math.floor(rgb / 65536) % 256,
    math.floor(rgb / 256) % 256,
    rgb % 256)
end

-- Says that something just happened, on every channel that is on and present.
-- Returns the names of the channels that carried it.
function notify.event(config, text, urgent)
  local used = {}

  if notify.usable(config, notify.find("speech")) then
    local speech = ct.first("speech_box")
    local ok, said = core.setValue(speech, "say", text)
    if ok and said ~= false then
      used[#used + 1] = "speech"
    end
  end

  if notify.usable(config, notify.find("chat")) then
    local chat = ct.first("chat_box")
    local ok, said = core.setValue(chat, "say", text)
    if ok and said ~= false then
      used[#used + 1] = "chat"
    end
  end

  if notify.usable(config, notify.find("note")) then
    local kept = notify.settings(config, "note")
    if ct.play(urgent, kept.instrument) then
      used[#used + 1] = "note"
    end
  end

  -- last, and only when nothing else spoke: a beep beside a spoken phrase is
  -- noise on top of an answer
  if #used == 0 and notify.settings(config, "beep").on then
    local pitch = 440
    if urgent then
      pitch = 880
    end
    if pcall(computer.beep, pitch, 0.2) then
      used[#used + 1] = "beep"
    end
  end

  return used
end

-- Writes something down. A record is not a way of telling somebody in the room,
-- which is why it is not one of the channels notify.event asks: a lamp and a
-- siren are for trouble, and a log is for everything that happened, including
-- the switchovers that are nobody's emergency.
--
-- Nothing here needs a collector to be running. syslogd writes to this machine
-- as well as relaying, and with no daemon at all the event is simply not
-- listened to.
function notify.record(config, text, level, service)
  if not notify.settings(config, "syslog").on then
    return false
  end
  local ok, syslog = pcall(require, "syslog")
  if not ok then
    return false
  end
  return pcall(syslog, text, level or notify.INFO, service or "ocwatch")
end

-- where a machine keeps its own copy of the records, whatever else it does
notify.LOG = "/home/ocgt.log"

-- How much of the log is read to find the last few records. The file grows all
-- week and is never rewritten, so reading it whole to show a dozen lines is how
-- a small computer runs out of memory looking at its own history.
local TAIL = 4096

-- The records this machine has, newest first. On the collector that is the
-- whole base; anywhere else it is this machine's own. Returns nil when there is
-- no log here at all, which is a different answer from a log with nothing in it.
--
-- A line is what syslogd writes: the uptime of the machine that wrote it, the
-- host it came from, the service, the severity, and the text.
function notify.records(limit)
  local file = io.open(notify.LOG, "r")
  if not file then
    return nil
  end
  local size = file:seek("end") or 0
  file:seek("set", math.max(0, size - TAIL))
  local text = file:read("*a") or ""
  file:close()

  -- the first line of a tail is whatever the read landed in the middle of
  if size > TAIL then
    text = text:match("\n(.*)$") or ""
  end

  local out = {}
  for line in text:gmatch("[^\n]+") do
    local at, host, service, level, message =
      line:match("^([%d%.]+)\t([^\t]*)\t([^\t]*)\t(%d+)\t(.*)$")
    if at then
      table.insert(out, 1, {
        at = tonumber(at),
        host = host,
        service = service,
        level = tonumber(level),
        message = message,
      })
    end
  end

  for _ = (limit or 20) + 1, #out do
    table.remove(out)
  end
  return out
end

-- Which machine keeps the base's log, written out as syslogd's own settings.
-- One name settles every machine's part in it: the collector receives and does
-- not relay, and everybody else relays to the collector. A machine still writes
-- its own copy either way, so a satellite that loses the network loses nothing.
--
-- syslogd reads this at start, so it wants "rc syslogd reload" afterwards.
function notify.collect(config, here)
  local collector = notify.settings(config, "syslog").collector or ""
  local file, reason = io.open("/etc/syslogd.cfg", "w")
  if not file then
    return false, tostring(reason)
  end
  file:write(serialization.serialize({
    destination = notify.LOG,
    write = true,
    minlevel = notify.INFO,
    -- a record printed over a dashboard is a record that broke the screen
    displevel = -1,
    beeplevel = -1,
    relay = collector ~= "" and collector ~= here,
    relayhost = collector,
    receive = collector ~= "" and collector == here,
  }))
  file:close()
  return true
end

-- Holds, or stops holding, the fact that something is wrong. Called on every
-- change rather than only when trouble starts, because a siren that is never
-- told it is over keeps sounding.
function notify.state(config, tripped)
  local held = {}

  if notify.usable(config, notify.find("lamp")) then
    if ct.lamps(notify.lampColor(config, tripped)) > 0 then
      held[#held + 1] = "lamp"
    end
  end

  if notify.usable(config, notify.find("siren")) then
    local kept = notify.settings(config, "siren")
    if sec.alarm(tripped, kept.sound) > 0 then
      held[#held + 1] = "siren"
    end
  end

  return held
end

return notify

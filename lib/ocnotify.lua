-- ocnotify: how a base tells somebody that something happened.
--
-- Each way of saying it is a channel: a thing that can be switched on and off
-- on its own, and tuned on its own. They are not alternatives to each other.
-- A lamp turning red, a siren, and a line in chat all do different jobs at the
-- same time, and which of them a base wants is a matter of taste and of where
-- the person happens to be standing.
--
-- Two kinds of thing happen here:
--
--   an event      something occurred just now, said once: a chat line, a
--                 spoken phrase, a figure on a note block, a beep
--   a state       something is wrong and still is, held until it is not: a
--                 lamp colour, a siren
--
-- Holding a state is why every channel is asked on every change rather than
-- only when trouble starts: an alarm that is never told the trouble ended goes
-- on sounding.
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
--   }

local computer = require("computer")
local core = require("oclib")
local ct = require("occomputronics")
local sec = require("ocsecurity")

local notify = {}

notify.VERSION = "0.1.0"

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
}

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

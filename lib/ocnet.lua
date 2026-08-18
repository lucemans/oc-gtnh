-- ocnet: how machines here ask each other for status.
--
-- One satellite watches the machines around it and answers questions about
-- them; a main computer asks every satellite in range and shows the lot. Both
-- halves live here so the question and the answer cannot drift apart.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local gt = require("ocgt")
local lp = require("oclogistics")
local serialization = require("serialization")

local net = {}

net.VERSION = "0.3.0"

net.ASK = "ocstatus?"
net.REPLY = "ocstatus!"

-- An access point relays other people's packets; it is not a network card and
-- offers no open, send or broadcast. Asking for a modem specifically avoids
-- mistaking one for the other.
function net.modem()
  if not component.isAvailable("modem") then
    return nil, "no network card, only a relay or nothing at all"
  end
  local modem = component.getPrimary("modem")
  modem.open(core.PORT)
  -- a wireless card sits at zero range until told otherwise, which looks
  -- exactly like a card that does not work
  if modem.isWireless() then
    pcall(modem.setStrength, 400)
  end
  return modem
end

-- what to call this machine when its readings appear on somebody else's screen
function net.hostname(config)
  local name = config and config.hostname
  if name and name ~= "" then
    return name
  end
  return computer.address():sub(1, 8)
end

-- the machines this computer is responsible for: whatever ocwatch was told to
-- watch, and failing that everything GregTech it can see
local function targets(config)
  if config and config.watch and #config.watch > 0 then
    return config.watch
  end
  local found = {}
  for address, kind in component.list() do
    if kind:sub(1, 3) == "gt_" then
      found[#found + 1] = { address = address }
    end
  end
  return found
end

-- Reads every machine this computer is responsible for. ocwatch calls this once
-- per refresh for its own dashboard and hands the result straight to net.report,
-- so a question costs no machine reads at all: on a busy satellite each one is a
-- server tick, and doing them again per request was most of the delay a tablet
-- saw.
function net.machines(config)
  local cards = {}
  for _, entry in ipairs(targets(config)) do
    cards[#cards + 1] = {
      entry = entry,
      name = gt.displayName(entry.address, config)
        or lp.displayName(entry.address)
        or entry.address:sub(1, 8),
      status = gt.statusOf(entry.address),
      readings = gt.readings(entry.address),
    }
  end
  return cards
end

-- the local maximum chosen for the nth gauge of a machine, kept by position
-- rather than by label because a tank drops its fluid name when it runs dry
function net.limitOf(entry, ordinal)
  return entry and entry.limits and entry.limits[ordinal] or nil
end

-- What travels over the wire. Gauges arrive already rescaled and already
-- formatted, so the asking machine never turns "42,000" back into a number.
function net.report(config, cards)
  local report = { cards = {}, alerts = {} }

  for _, card in ipairs(cards) do
    local out = {
      name = card.name,
      status = card.status,
      alarm = card.alarm,
      gauges = {},
    }
    local ordinal = 0
    for _, reading in ipairs(card.readings) do
      if reading.kind == "gauge" then
        ordinal = ordinal + 1
        local max, isLocal = core.scale(reading, net.limitOf(card.entry, ordinal))
        out.gauges[#out.gauges + 1] = {
          label = reading.label,
          current = reading.current,
          maximum = core.comma(max),
          -- only sent when the bar is drawn against a local maximum, so the
          -- real capacity is still visible somewhere
          capacity = isLocal and reading.maximum or nil,
          unit = reading.unit,
          percent = max > 0 and (reading.value / max * 100) or 0,
        }
      end
    end
    report.cards[#report.cards + 1] = out
  end

  for _, alert in ipairs(config and config.alerts or {}) do
    report.alerts[#report.alerts + 1] = {
      name = alert.name,
      tripped = alert.tripped or false,
    }
  end

  return report
end

-- Answers one request with a report somebody else has already prepared. Returns
-- a description of what was sent, or nil when the message was not a question
-- this understands.
function net.answer(modem, port, remote, request, config, report)
  if port ~= core.PORT or request ~= net.ASK then
    return nil
  end

  local payload = serialization.serialize(report)
  local limit = modem.maxPacketSize and modem.maxPacketSize() or 8192
  if #payload > limit then
    -- better a short answer than a packet the card silently refuses
    payload = serialization.serialize({
      cards = { { name = "too many machines to send", gauges = {} } },
      alerts = {},
    })
  end

  modem.send(remote, core.PORT, net.REPLY, net.hostname(config), payload)
  return tostring(remote):sub(1, 8) .. "  " .. #payload .. " bytes"
end

-- Asks everyone in range and collects every answer within the window, rather
-- than taking the first: a base has more than one satellite.
--
-- The window is real time, not a count of messages, because a satellite that is
-- busy needs a moment to get a word in. Waiting it out every round is what made
-- a tablet feel seconds behind, so once `expected` satellites have answered the
-- round ends immediately. The caller passes what the last round found, so only
-- the first round after a start or a satellite going quiet pays the full wait.
--
-- Also returns what was heard, which is the difference between "nobody
-- answered" and "somebody answered something I could not read".
function net.ask(modem, event, seconds, expected, computerLib)
  modem.broadcast(core.PORT, net.ASK)

  local clock = (computerLib or computer).uptime
  local until_ = clock() + (seconds or 8)
  local answers, heard, unreadable = {}, 0, 0
  -- A relay repeats what it forwards, so one question reaches a satellite over
  -- several paths and every reply comes back over several paths. One card is
  -- one satellite however many copies of its answer arrive.
  local place = {}

  while true do
    local left = until_ - clock()
    if left <= 0 then
      break
    end

    local name, _, remote, port, _, kind, host, payload =
      event.pull(left, "modem_message")
    if name == nil then
      break
    end
    heard = heard + 1

    if port == core.PORT and kind == net.REPLY then
      local ok, report = pcall(serialization.unserialize, payload)
      -- a satellite still on an older ocwatch sends a bare list of machines,
      -- which lands here as unreadable and is reported as a version mismatch
      if ok and type(report) == "table" and type(report.cards) == "table" then
        local answer = {
          host = host or tostring(remote):sub(1, 8),
          address = remote,
          cards = report.cards,
          alerts = report.alerts or {},
        }
        if place[remote] then
          -- the later copy is the fresher reading
          answers[place[remote]] = answer
        else
          place[remote] = #answers + 1
          answers[#answers + 1] = answer
        end
      else
        unreadable = unreadable + 1
      end
    end

    if expected and expected > 0 and #answers >= expected then
      break
    end
  end

  return answers, { heard = heard, unreadable = unreadable }
end

return net

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
local tank = require("octank")

local net = {}

net.VERSION = "0.7.0"

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
    -- a side means a tank read through a transposer, which is how a block with
    -- no driver of its own gets onto the dashboard
    local look
    if entry.side then
      look = tank.inspect(entry.address, entry.side, config)
    else
      look = gt.inspect(entry.address, config)
    end
    cards[#cards + 1] = {
      entry = entry,
      name = look.name or lp.displayName(entry.address) or entry.address:sub(1, 8),
      status = look.status,
      readings = look.readings,
    }
  end
  return cards
end

-- Where the alerts watching a reading sit along its bar, as shares of the
-- maximum. A bar says how full something is; these say how full it has to get
-- before anything happens, which is the other half of the same question.
function net.marksOn(config, reading, max)
  if not max or max <= 0 then
    return nil
  end
  local marks = nil
  for _, alert in ipairs(config and config.alerts or {}) do
    if alert.label == reading.label
      or (alert.unit or "") == (reading.unit or "") then
      for _, at in ipairs({ alert.below, alert.above, alert.over, alert.under }) do
        local share = at / max
        if share > 0 and share <= 1 then
          marks = marks or {}
          marks[#marks + 1] = share
        end
      end
    end
  end
  return marks
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
      -- how it is drawn belongs to the machine, not to whoever is looking
      compact = card.entry and card.entry.compact or nil,
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
          -- the colour travels too, or a bar means one thing on the dashboard
          -- and another on the tablet watching it
          colorCode = reading.colorCode,
          -- which way the reading is going, and how fast
          rate = reading.rate,
          -- where along the bar an alert on this reading sits, as a share of
          -- the maximum it is drawn against
          marks = net.marksOn(config, reading, max),
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

-- Puts the question to everyone in range. The answers come back as ordinary
-- modem messages, which the asker reads in its own event loop through decode:
-- blocking here until a window ran out was what made a tablet ignore the
-- keyboard for seconds at a time.
function net.ask(modem)
  return modem.broadcast(core.PORT, net.ASK)
end

-- Reads one modem message. Returns the answer it carries, or nil, and with nil
-- a reason when the message was an answer that could not be understood. A
-- satellite still on an older ocwatch sends a bare list of machines, which
-- lands here as unreadable and is reported as a version mismatch.
function net.decode(port, remote, kind, host, payload)
  if port ~= core.PORT or kind ~= net.REPLY then
    return nil
  end

  local ok, report = pcall(serialization.unserialize, payload)
  if not ok or type(report) ~= "table" or type(report.cards) ~= "table" then
    return nil, "unreadable"
  end

  return {
    host = host or tostring(remote):sub(1, 8),
    address = remote,
    cards = report.cards,
    alerts = report.alerts or {},
  }
end

return net

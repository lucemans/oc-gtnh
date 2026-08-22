-- ocgtp: submitting readings to the telemetry service, as GTP/1.
--
-- A reading here is a label and a number: "Bio Diesel", 42000, litres. A metric
-- there is a name and a number, where the name says what was measured and
-- labels say what it was measured on. So this is mostly a translation, and the
-- part of it that matters is refusing to guess: a series invented out of a unit
-- nobody recognised is one that sits in the database being wrong forever.
--
-- Nothing here can hold anything up. Every message is unreliable, sent and
-- forgotten, because a lost gauge is replaced by the next one and a telemetry
-- service that has gone away must not stall a machine that is running.

local computer = require("computer")
local serialization = require("serialization")

local gtp = {}

gtp.VERSION = "0.2.0"

-- The service is configuration rather than protocol, so this is only where to
-- look first. The name is the one the specification names as the deployment.
gtp.HOST = "ovw-core-obs-01"
gtp.PORT = 2000
gtp.INTERVAL = 10

-- The specification's ceiling, which sits under Minitel's own. A message that
-- will not fit is split into whole messages rather than left to the transport,
-- which would fragment it into pieces nobody puts back together.
local ROOM = 6144
local PREFIX = "GTP1:"
-- and how many samples travel together before size is even considered
local BATCH = 25

-- Which reading is which, worked out from the unit it came with. A unit that is
-- not here is not sent: see the note at the top.
local UNITS = {
  L = {
    amount = "fluid.amount_liters",
    capacity = "fluid.capacity_liters",
    ratio = "fluid.fill_ratio",
    dimension = "fluid",
  },
  EU = {
    amount = "energy.stored_eu",
    capacity = "energy.capacity_eu",
    ratio = "energy.fill_ratio",
  },
  -- Railcraft answers a firebox in Celsius and the specification names the
  -- measurement in Kelvin, so the reading is converted rather than renamed
  C = {
    amount = "machine.temperature_kelvin",
    offset = 273.15,
  },
}

-- what the telemetry service works out from the sender, and a client must not
-- claim for itself
local RESERVED = { host = true, site = true, area = true }

local session = tostring(math.random(0, 0xFFFFFF))
local sequence = 0
local totals = { messages = 0, samples = 0, errors = 0 }

local function nextId()
  sequence = sequence + 1
  return session .. "-" .. sequence
end

-- What is worth telling anybody, and how often. Off is a real answer: a machine
-- sending to a service that is not there floods the mesh with one unroutable
-- packet every interval, forever.
function gtp.settings(config)
  local kept = config and config.telemetry or {}
  return {
    on = kept.on ~= false,
    host = kept.host ~= nil and kept.host ~= "" and kept.host or gtp.HOST,
    port = tonumber(kept.port) or gtp.PORT,
    interval = tonumber(kept.interval) or gtp.INTERVAL,
  }
end

function gtp.set(config, key, value)
  config.telemetry = config.telemetry or {}
  config.telemetry[key] = value
end

-- A label value, out of whatever a machine happens to be called. Spaces and
-- punctuation are what the specification asks to be kept out of them.
function gtp.slug(text)
  local out = tostring(text or ""):lower():gsub("%s+", "-"):gsub("[^%w%-_%.:/]", "")
  out = out:gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  return out
end

-- Our own numbers arrive grouped for a screen, and a metric value must be a
-- finite number and nothing else.
function gtp.number(value)
  if type(value) == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil
    end
    return value
  end
  if type(value) ~= "string" then
    return nil
  end
  return tonumber((value:gsub(",", "")))
end

-- A dotted name, each part of it lowercase. Checked a part at a time because a
-- Lua pattern cannot repeat a group, so the whole shape is not one pattern.
function gtp.validName(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  if name:sub(1, 1) == "." or name:sub(-1) == "." or name:find("%.%.") then
    return false
  end
  for part in name:gmatch("[^%.]+") do
    if not part:find("^[a-z][a-z0-9_]*$") then
      return false
    end
  end
  return true
end

function gtp.validLabel(key)
  if type(key) ~= "string" or RESERVED[key] then
    return false
  end
  return key:find("^[a-z][a-z0-9_]*$") ~= nil
end

-- One sample, refused rather than corrected when it is not one. A refusal is
-- counted, because telemetry that quietly drops half of itself is worse than
-- telemetry that says how much it dropped.
local function sample(into, name, value, labels, kind)
  local number = gtp.number(value)
  if not gtp.validName(name) or not number then
    totals.errors = totals.errors + 1
    return
  end
  local kept = nil
  for key, text in pairs(labels or {}) do
    if gtp.validLabel(key) and text ~= "" then
      kept = kept or {}
      kept[key] = text
    end
  end
  into[#into + 1] = { name = name, kind = kind or "gauge", value = number,
    labels = kept }
end

-- Everything a machine is worth saying, out of the report ocnet already built
-- for the dashboard. Nothing is read again and nothing is worked out twice:
-- these are the same numbers the screen is showing, said the other way round.
--
-- It takes the report rather than the raw readings because the report is where
-- a gauge has already been scaled and turned into a percentage. Doing that
-- again here is how the screen and the graph come to disagree.
function gtp.samples(report)
  local out = {}
  report = report or {}

  for _, card in ipairs(report.cards or {}) do
    local machine = gtp.slug(card.name)
    if machine ~= "" then
      if card.status then
        sample(out, "machine.active", card.status == "working" and 1 or 0,
          { machine = machine })
      end

      for _, gauge in ipairs(card.gauges or {}) do
        local unit = UNITS[gauge.unit or ""]
        local labels = { machine = machine }
        if unit and unit.dimension then
          labels[unit.dimension] = gtp.slug(gauge.label)
        end

        if unit then
          local value = gtp.number(gauge.current)
          if value and unit.offset then
            value = value + unit.offset
          end
          sample(out, unit.amount, value, labels)
          if unit.capacity then
            sample(out, unit.capacity, gauge.capacity or gauge.maximum, labels)
          end
          if unit.ratio and gauge.percent then
            sample(out, unit.ratio, gauge.percent / 100, labels)
          end
        elseif (gauge.unit or "") == "" and gauge.percent
          and tostring(gauge.label):lower():find("progress", 1, true) then
          sample(out, "machine.progress_ratio", gauge.percent / 100, labels)
        end
      end
    end
  end

  -- The fluid network answers in millibuckets with the amounts already numbers,
  -- so nothing here has to be taken apart first.
  for _, fluid in ipairs(report.fluids or {}) do
    local named = gtp.slug(fluid.name)
    if named ~= "" then
      sample(out, "fluid.amount_liters", fluid.amount, { fluid = named })
    end
  end

  -- An alert is a number that is one or nothing, which is what a boolean is
  -- once it reaches a metric.
  for _, alert in ipairs(report.alerts or {}) do
    local named = gtp.slug(alert.name)
    if named ~= "" then
      sample(out, "alert.tripped", alert.tripped and 1 or 0, { alert = named })
    end
  end

  -- Nothing about the item network travels. A base holds thousands of item
  -- names and each one as a label is a series of its own, which is the one
  -- mistake the specification asks twice not to make.

  -- What this machine is running. A version is not a number and cannot be made
  -- into one, so the series carries a constant and the version rides in a
  -- label, which is how a build stamp reaches a metrics database anywhere. The
  -- point of it is the comparison: one line per machine on a dashboard says at
  -- a glance which of them is behind the rest.
  if report.program then
    sample(out, "software.build_info", 1, {
      program = gtp.slug(report.program.name),
      version = gtp.slug(report.program.version),
      -- short, because that is the form anybody types back into git
      commit = report.commit and gtp.slug(report.commit):sub(1, 7) or nil,
    })
  end

  sample(out, "telemetry.messages_sent_total", totals.messages, nil, "counter")
  sample(out, "telemetry.samples_sent_total", totals.samples, nil, "counter")
  sample(out, "telemetry.encode_errors_total", totals.errors, nil, "counter")

  return out
end

local function body(settings, samples, id)
  return PREFIX .. serialization.serialize({
    type = "metrics",
    id = id,
    interval = settings.interval,
    data = samples,
  })
end

-- Halves a batch until each message fits, rather than sending one that does
-- not. The identifier of a message that gets split is simply never used, which
-- costs nothing: they only have to be unique for long enough to spot a repeat.
local function post(minitel, settings, samples)
  if #samples == 0 then
    return
  end
  local wire = body(settings, samples, nextId())
  if #wire > ROOM and #samples > 1 then
    local half = math.floor(#samples / 2)
    local first, rest = {}, {}
    for index, each in ipairs(samples) do
      if index <= half then
        first[#first + 1] = each
      else
        rest[#rest + 1] = each
      end
    end
    post(minitel, settings, first)
    post(minitel, settings, rest)
    return
  end
  minitel.usend(settings.host, settings.port, wire)
  totals.messages = totals.messages + 1
  totals.samples = totals.samples + #samples
end

function gtp.send(minitel, settings, samples)
  local batch = {}
  for _, each in ipairs(samples) do
    batch[#batch + 1] = each
    if #batch >= BATCH then
      post(minitel, settings, batch)
      batch = {}
    end
  end
  post(minitel, settings, batch)
end

-- Whether there is anywhere to send and anything to send with. Asked before a
-- program reads its machines, because on a satellite each of those reads is a
-- server tick and doing them to find out nobody wanted them is most of what a
-- machine would notice about being watched.
--
-- The clock belongs to the caller. A due time kept here would outlive the
-- program that set it, since a library stays loaded for the whole shell
-- session, and the next program to start would sit out an interval it never
-- asked for.
function gtp.wanted(minitel, config)
  local settings = gtp.settings(config)
  return minitel ~= nil and settings.on and settings.host ~= ""
end

function gtp.submit(minitel, config, report)
  local settings = gtp.settings(config)
  gtp.send(minitel, settings, gtp.samples(report))
  return computer.uptime() + settings.interval
end

function gtp.totals()
  return totals
end

return gtp

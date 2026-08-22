-- ocwatch: a fixed dashboard for the machines you choose, with thresholds that
-- can beep and can stop a machine before a shortage becomes a power failure.
--
--   ocwatch          watch the configured machines
--   ocwatch --edit   choose machines and alerts, and what each one does

local component = require("component")
local computer = require("computer")
local event = require("event")
local core = require("oclib")
local gt = require("ocgt")
local lp = require("oclogistics")
local net = require("ocnet")
local rc = require("ocrailcraft")
local tank = require("octank")
local ct = require("occomputronics")
local sec = require("ocsecurity")
local notify = require("ocnotify")
local gtp = require("ocgtp")
local sh = require("sh")
local keyboard = require("keyboard")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.22.0"

-- what this machine tells the network it is running, in every report it sends
net.running("ocwatch", VERSION)

local REFRESH_SECONDS = 2

local gpu = component.gpu

local W, H, GAUGE_W

local paint = core.painter(gpu)

-- recomputed on a resize: an attached display is often not the size the program
-- started on
local function layout()
  W, H = core.viewport(gpu)
  GAUGE_W = math.max(16, math.min(64, math.floor((W - 34) * 2 / 3)))
  paint.forget()
end

layout()

-- whatever emptied the screen also emptied what this program believes is on it
local function blank()
  term.clear()
  paint.forget()
end

local BG = 0x000000
local FG = 0xFFFFFF
local DIM = 0x999999
local BAR = 0x333333
local OK_COLOR = 0x66CC66
local ALARM = 0xCC6666
local SELECTED = 0x0066CC

local FULL_BLOCK = "\226\150\136"
local LIGHT_BLOCK = "\226\150\145"
-- a thin vertical line, drawn over the bar where an alert sits
local MARK = "\226\148\130"

local config = core.loadConfig()

-- Whether an alert has tripped, and whether its action has been applied, are
-- facts about this run. They used to be written into the configuration by the
-- editor, and a saved `applied = false` then convinced every later run that the
-- machine had already been stopped, so the command was never sent again. The
-- alert looked configured and did nothing.
local RUNTIME = { "tripped", "applied", "warned" }

local function forgetRuntime()
  for _, alert in ipairs(config.alerts) do
    for _, field in ipairs(RUNTIME) do
      alert[field] = nil
    end
  end
end

local function save()
  forgetRuntime()
  return core.saveConfig(config)
end

forgetRuntime()

-- `beep` said whether an alert made a noise, and the lamp and the siren were
-- held to be worth having either way. An alert that shuts the fuel off because
-- the steam tank is full is doing its job rather than reporting trouble, and a
-- base that runs with a red lamp all day has no red lamp left to mean anything.
-- The one switch now decides whether the alert is trouble at all. An alert
-- written before that carries the old name.
local function renameBeep()
  for _, alert in ipairs(config.alerts) do
    if alert.trouble == nil then
      alert.trouble = alert.beep
    end
    alert.beep = nil
  end
end

renameBeep()

local function fit(text, width)
  local length = unicode.len(text)
  if length > width then
    return unicode.sub(text, 1, width)
  end
  return text .. string.rep(" ", width - length)
end

-- green only for a machine that is actually doing something, red for one an
-- alert has stopped, and grey for one that is simply waiting
local function statusColor(status, alarm)
  if status == "stopped" or alarm then
    return ALARM
  end
  if status == "working" then
    return OK_COLOR
  end
  return DIM
end

-- A watched thing is an address, and for a tank read through a transposer also
-- which of its six faces. Alerts and nicknames are keyed the same way, or two
-- tanks on one transposer would be the same thing to both.
local function keyOf(address, side)
  if side then
    return tank.key(address, side)
  end
  return address
end

local function entryName(entry)
  if entry.side then
    return tank.name(entry.address, entry.side, config)
  end
  return gt.displayName(entry.address, config)
    or rc.displayName(entry.address, config)
    or lp.displayName(entry.address)
    or entry.address
end

-------------------------------------------------------------------------------
-- alerts

-- An alert trips at one threshold and only clears back at another, so a reading
-- sitting on the boundary cannot beep on every refresh.
--
-- Which end of the range is the interesting one is the alert's own choice.
-- `below` and `above` watch a tank that must not run out. `over` and `under`
-- watch one that must not fill up: a steam tank at its ceiling is the signal to
-- stop feeding the boilers, and its falling back is the signal to feed them
-- again.
local function evaluate(alert, value)
  if alert.tripped then
    return not ((alert.above and value >= alert.above)
      or (alert.under and value <= alert.under))
  end
  return (alert.below and value < alert.below)
    or (alert.over and value > alert.over)
    or false
end

-- An alert used to stop one machine. One tank feeds both blast furnaces, so it
-- stops a list of them now. A configuration written before that carries a
-- single action, which is the same thing with one entry.
local function actions(alert)
  if not alert.act then
    return {}
  end
  if alert.act.address then
    return { alert.act }
  end
  return alert.act
end

local function act(alert, tripped)
  local list = actions(alert)
  if #list == 0 then
    return nil
  end

  alert.applied = alert.applied or {}
  local done = {}

  for index, action in ipairs(list) do
    -- written out rather than "tripped and onTrip or onClear": onTrip is false
    -- here, and that expression would fall through and enable the machine
    local wanted
    if tripped then
      wanted = action.onTrip
    else
      wanted = action.onClear
    end
    if wanted ~= nil and alert.applied[index] ~= wanted then
      local ok, reason = core.setValue(action.address, action.method, wanted)
      if ok then
        alert.applied[index] = wanted
        done[#done + 1] = action.method .. "(" .. tostring(wanted) .. ")"
      else
        done[#done + 1] = "action failed: " .. tostring(reason)
      end
    end
  end

  if #done == 0 then
    return nil
  end
  return table.concat(done, ", ")
end

-- A tripped alert is worth hearing from another room. Which ways of saying so
-- this base wants is its own choice, kept per channel, so the library is asked
-- rather than each device in turn.
local function announce(alert, text, urgent)
  if alert.trouble == false then
    return nil
  end
  local used = notify.event(config, text, urgent)
  if #used == 0 then
    return nil
  end
  return table.concat(used, ", ")
end

-- whether the lamps and sirens are showing trouble, so they are only set on a
-- change rather than on every refresh
local alarmShown = nil

-- What each gauge read last time, and when, so the dashboard can say which way
-- it is going and how fast.
--
-- This is a rate of change, not a throughput. A tank draining shows exactly how
-- fast it is draining. A pipe carrying a steady flow shows nearly nothing,
-- because what goes in also comes out: for the flow itself, a GregTech pipe has
-- to be read through an adapter of its own, where its sensor reports the
-- amounts the way a cable reports amperage.
-- Measured across this many seconds rather than between two refreshes. A
-- reading taken every two seconds jumps about far too much to read: what a
-- fluid is doing over half a minute is the thing worth knowing.
local RATE_SECONDS = 30
local RATE_LEAST = 10

local history = {}

local function rateOf(key, value, at, leaving)
  local samples = history[key]
  if not samples then
    samples = {}
    history[key] = samples
  end
  samples[#samples + 1] = { value = value, at = at }

  -- everything older than the window is no longer part of the average
  while samples[2] and at - samples[1].at > RATE_SECONDS do
    table.remove(samples, 1)
  end

  local oldest = samples[1]
  local seconds = at - oldest.at
  -- a span of one refresh says almost nothing, so nothing is said until there
  -- is enough of one to mean something
  if seconds < RATE_LEAST then
    return nil
  end

  -- A pipe holds fluid in transit: it is drained by whatever is downstream and
  -- refilled from the tank, so what is in it barely moves however much is going
  -- through. Adding up only the falls, and ignoring the refills, measures what
  -- left, which is the usage of that one pipe. Three pipes counted this way add
  -- up to what the tank feeding them is losing.
  if leaving then
    local gone = 0
    for index = 2, #samples do
      local step = samples[index].value - samples[index - 1].value
      if step < 0 then
        gone = gone - step
      end
    end
    return -gone / seconds
  end

  return (value - oldest.value) / seconds
end

local function rateText(rate, unit)
  if not rate or math.abs(rate) < 1 then
    return nil
  end
  local sign = "+"
  if rate < 0 then
    sign = "-"
  end
  return sign .. core.comma(math.floor(math.abs(rate) + 0.5))
    .. " " .. (unit ~= "" and unit or "") .. "/s"
end

-- Where the alerts watching a reading sit along its bar. A bar says how full
-- something is; this says how full it has to get before anything happens.
local function marksOn(gauge, max, width)
  local marks = {}
  if not max or max <= 0 then
    return marks
  end

  for _, alert in ipairs(config.alerts) do
    if alert.label == gauge.label or (alert.unit or "") == (gauge.unit or "") then
      for _, at in ipairs({ alert.below, alert.above, alert.over, alert.under }) do
        local share = at / max
        if share > 0 and share <= 1 then
          marks[#marks + 1] = {
            at = math.max(1, math.min(width, math.floor(width * share + 0.5))),
            color = alert.tripped and ALARM or FG,
          }
        end
      end
    end
  end
  return marks
end

local notices = {}

local function notice(text)
  notices[#notices + 1] = text
  while #notices > 3 do
    table.remove(notices, 1)
  end
end

-- An alert used to remember which line of the sensor output it watched. GregTech
-- rewrites those lines as a machine changes: a tank drops its fluid name when it
-- runs dry, so the line moved and the alert quietly stopped firing at exactly
-- the moment it was meant to. Match on what the reading is, not where it sits.
local function findReading(alert, readings)
  if not readings then
    return nil
  end

  local gauges = {}
  for _, reading in ipairs(readings) do
    if reading.kind == "gauge" then
      gauges[#gauges + 1] = reading
    end
  end

  if alert.label and alert.label ~= "" then
    for _, gauge in ipairs(gauges) do
      if gauge.label == alert.label then
        return gauge
      end
    end
  end

  -- a tank has one reading in litres however its text is worded
  if alert.unit and alert.unit ~= "" then
    local matches = {}
    for _, gauge in ipairs(gauges) do
      if gauge.unit == alert.unit then
        matches[#matches + 1] = gauge
      end
    end
    if #matches == 1 then
      return matches[1]
    end
  end

  if alert.gauge and gauges[alert.gauge] then
    return gauges[alert.gauge]
  end

  -- alerts written before this carry only a line number
  local legacy = alert.index and readings[alert.index]
  if legacy and legacy.kind == "gauge" then
    return legacy
  end
  return nil
end

local function checkAlerts(readingsByAddress)
  for _, alert in ipairs(config.alerts) do
    local readings = readingsByAddress[keyOf(alert.address, alert.side)]
    local reading = findReading(alert, readings)

    -- Saying nothing was the worse half of the bug: an alert that could not find
    -- its reading looked exactly like an alert that was happy.
    if not reading and readings and not alert.warned then
      alert.warned = true
      notice(alert.name .. ": no reading matches, this alert is watching nothing")
    end

    if reading and reading.kind == "gauge" then
      local was = alert.tripped or false
      alert.tripped = evaluate(alert, reading.value)
      if alert.tripped ~= was then
        local said
        local where = core.comma(reading.value) .. " " .. reading.unit
        if alert.tripped then
          notice(alert.name .. " tripped at " .. core.comma(reading.value))
          said = announce(alert, alert.name .. " tripped at " .. where, true)
        else
          notice(alert.name .. " cleared at " .. core.comma(reading.value))
          said = announce(alert, alert.name .. " cleared", false)
        end
        if said then
          notice("told the " .. said:gsub("_", " "))
        end

        -- Written down whatever the alert is for. An alert that is not trouble
        -- says nothing aloud and is the one you most want a record of, because
        -- nothing else anywhere shows it ever happened.
        local level = notify.INFO
        if alert.trouble ~= false then
          level = alert.tripped and notify.ERROR or notify.NOTICE
        end
        notify.record(config,
          alert.name .. (alert.tripped and " tripped at " or " cleared at ")
            .. where, level)
      end
      local done = act(alert, alert.tripped)
      if done then
        notice(alert.name .. ": " .. done)
      end
    end
  end
end

-------------------------------------------------------------------------------
-- dashboard

local function wanted(entry, reading, index)
  if reading.usedAsLabel then
    return false
  end
  if reading.kind ~= "gauge" and entry.gaugesOnly then
    return false
  end
  if entry.hidden and entry.hidden[index] then
    return false
  end
  return true
end

local function render(cards)
  local write = paint.write

  -- one indented line, the machine's own name in the fluid's colour, and no bar
  local function compactGauge(y, card, gauge, max)
    local share = 0
    if max > 0 then
      share = gauge.value / max * 100
    end
    local color = ALARM
    if not card.alarm then
      color = core.gaugeColor(gauge, FG)
    end
    write(5, y, fit(card.name, 14), color, BG)
    write(19, y, fit(string.format("%s / %s %s   %.0f%%   %s",
      gauge.current, gauge.maximum, gauge.unit, share,
      rateText(gauge.rate, gauge.unit) or ""), math.max(0, W - 20)), DIM, BG)
  end

  local function drawGauge(x, y, gauge, width, max, isLocal)
    local ratio = 0
    if max > 0 then
      ratio = gauge.value / max
    end
    -- the bar cannot go past its own end, but the percentage still says how far
    -- over a local maximum the reading has climbed
    local drawn = ratio
    if drawn < 0 then
      drawn = 0
    elseif drawn > 1 then
      drawn = 1
    end
    local filled = math.floor(width * drawn + 0.5)

    write(x, y, "[", DIM, BG)
    local cursor = x + 1
    if filled > 0 then
      write(cursor, y, string.rep(FULL_BLOCK, filled), core.gaugeColor(gauge, OK_COLOR), BG)
      cursor = cursor + filled
    end
    if width - filled > 0 then
      write(cursor, y, string.rep(LIGHT_BLOCK, width - filled), DIM, BG)
      cursor = cursor + width - filled
    end

    -- Where an alert on this reading trips, marked on the bar itself. Knowing a
    -- tank is at sixty percent says nothing without knowing where the floor is.
    for _, mark in ipairs(marksOn(gauge, max, width)) do
      write(x + mark.at, y, MARK, mark.color, BG)
    end

    write(cursor, y, "]", DIM, BG)
    cursor = cursor + 1

    local unit = gauge.unit ~= "" and (" " .. gauge.unit) or ""
    local text = string.format("  %s / %s%s  %.1f%%",
      gauge.current, core.comma(max), unit, ratio * 100)
    -- the real capacity still belongs on screen, or a local maximum quietly
    -- becomes a lie about how much the tank holds
    if isLocal then
      text = text .. "   of " .. gauge.maximum
    end
    local moving = rateText(gauge.rate, gauge.unit)
    if moving then
      text = text .. "   " .. moving
    end
    write(cursor, y, fit(text, math.max(0, W - cursor)), FG, BG)
  end

  write(1, 1, fit("  ocwatch v" .. VERSION .. "    " .. #cards .. " machines", W), FG, BAR)

  local y = 3
  for _, card in ipairs(cards) do
    if y > H - 2 then
      break
    end

    -- A compact machine is one line a gauge, indented, with no bar and no name
    -- row of its own, so a handful of them sit under the card above them as a
    -- group. Ordering the watch list is what puts them there.
    if not card.entry.compact then
      write(3, y, fit(card.name, W - 22), FG, BG)
      if card.status then
        write(W - 20, y, fit(card.status, 18),
          statusColor(card.status, card.alarm), BG)
      end
      y = y + 1
    end

    local ordinal = 0
    for index, reading in ipairs(card.readings) do
      if y > H - 2 then
        break
      end
      if reading.kind == "gauge" then
        ordinal = ordinal + 1
      end
      if wanted(card.entry, reading, index) then
        if reading.kind == "gauge" then
          local max, isLocal = core.scale(reading, net.limitOf(card.entry, ordinal))
          if card.entry.compact then
            compactGauge(y, card, reading, max)
          else
            local label = reading.label ~= "" and reading.label or "value"
            write(5, y, fit(label, 12), DIM, BG)
            drawGauge(18, y, reading, GAUGE_W, max, isLocal)
          end
          y = y + 1
        elseif not card.entry.compact then
          local x = 5
          for _, part in ipairs(core.segments(reading.raw, DIM)) do
            local space = W - x - 1
            if space <= 0 then
              break
            end
            local text = unicode.sub(part.text, 1, space)
            write(x, y, text, part.color, BG)
            x = x + unicode.len(text)
          end
          y = y + 1
        end
      end
    end

    -- a compact machine belongs to the card above it, so it gets no gap
    if not card.entry.compact then
      y = y + 1
    end
  end

  for index = 1, #notices do
    write(3, H - #notices + index - 1, fit(notices[index], W - 4), ALARM, BG)
  end
  write(1, H, fit("  [e] edit   [r] refresh   [q] quit      live every "
    .. REFRESH_SECONDS .. "s", W), FG, BAR)

  paint.flush(W, H, BG, FG)
end

local function sample()
  -- the same read the network half serves from, so a question costs no further
  -- calls into the machines
  local cards = net.machines(config)
  local byAddress = {}
  for _, card in ipairs(cards) do
    byAddress[keyOf(card.entry.address, card.entry.side)] = card.readings
  end
  local now = computer.uptime()
  for _, card in ipairs(cards) do
    local ordinal = 0
    for _, reading in ipairs(card.readings) do
      if reading.kind == "gauge" then
        ordinal = ordinal + 1
        reading.rate = rateOf(
          keyOf(card.entry.address, card.entry.side) .. "#" .. ordinal,
          reading.value, now, card.entry.usage)
      end
    end
  end

  checkAlerts(byAddress)

  -- Only an alert that counts as trouble reddens anything. One that merely
  -- switches a machine over is at its threshold most of the time, and a lamp
  -- that is red most of the time says nothing when it matters.
  local alarmed = false
  for _, card in ipairs(cards) do
    for _, alert in ipairs(config.alerts) do
      if alert.address == card.entry.address and alert.tripped
        and alert.trouble ~= false then
        card.alarm = true
        alarmed = true
      end
    end
  end

  -- A lamp says from across the room what the screen says up close, and an
  -- alarm says it from outside. Both are set only on a change, since each is a
  -- call into the world, and both stay set while anything is wrong rather than
  -- sounding once and stopping.
  if alarmed ~= alarmShown then
    notify.state(config, alarmed)
    alarmShown = alarmed
  end

  return cards
end

-------------------------------------------------------------------------------
-- editor

local function prompt(message, current)
  term.clear()
  -- printing goes around the painter, which then believes rows it no longer owns
  paint.forget()
  print(message)
  if current ~= nil and current ~= "" then
    print("currently " .. tostring(current))
  end
  io.write("> ")
  return io.read()
end

-- A list you move through with the arrow keys. Returns the row it was on and
-- the key that ended it, so each screen decides what its own keys mean. Rows
-- marked as headings are drawn but never landed on.
-- A drawn, clickable list. Rows marked as headings are shown but never landed
-- on. The buttons along the bottom are what this screen can do: click one, or
-- press the key it names. Clicking a row selects it, and clicking the row that
-- is already selected does whatever the first button does, which is what a
-- second click on a thing is expected to mean.
--
-- Returns the row that was selected and the key of the action chosen, so each
-- screen still decides what its own actions do.
local function menu(title, rows, buttons, start)
  -- Where the cursor was when this screen was last left. Every action returns
  -- to the caller and comes straight back, and starting again at the top each
  -- time moved the selection out from under whoever was pressing the button.
  local cursor, top = start or 1, 1
  if cursor < 1 or cursor > #rows then
    cursor = 1
  end
  while cursor <= #rows and rows[cursor].heading do
    cursor = cursor + 1
  end

  -- moving lands on a row, never on a heading, and never off either end
  local function step(from, delta)
    local index = from
    repeat
      index = index + delta
    until index < 1 or index > #rows or not rows[index].heading
    if index < 1 or index > #rows then
      return from
    end
    return index
  end

  paint.forget()

  while true do
    local body = H - 3
    if cursor < top then
      top = cursor
    end
    if cursor > top + body - 1 then
      top = cursor - body + 1
    end
    if top < 1 then
      top = 1
    end

    paint.write(1, 1, fit("  " .. title, W), FG, BAR)
    paint.write(1, 2, fit("", W), FG, BG)

    for line = 0, body - 1 do
      local index = top + line
      local row = rows[index]
      local y = 3 + line
      if not row then
        paint.write(1, y, fit("", W), FG, BG)
      elseif row.heading then
        paint.write(1, y, fit("  " .. row.text, W), DIM, BG)
      elseif index == cursor then
        paint.write(1, y, fit("  " .. row.text, W), FG, SELECTED)
      else
        paint.write(1, y, fit("  " .. row.text, W), FG, BG)
      end
    end

    -- a screen of nothing but headings has nothing to land on, and saying so is
    -- better than an empty space under each one
    if not rows[cursor] then
      paint.write(3, H - 2, fit("nothing here yet", W - 3), DIM, BG)
    end

    -- where each button sits, so a click can be matched back to one
    local spots = {}
    local x = 2
    for _, button in ipairs(buttons) do
      local label = " " .. button.label .. " "
      spots[#spots + 1] = {
        from = x, to = x + unicode.len(label) - 1, code = button.code,
      }
      paint.write(x, H, label, FG, SELECTED)
      x = x + unicode.len(label) + 1
    end
    paint.write(x, H, fit("", math.max(0, W - x + 1)), FG, BAR)
    paint.flush(W, H, BG, FG)

    local packed = table.pack(event.pull())
    local name = packed[1]

    if name == "interrupted" then
      return nil, keyboard.keys.q, cursor
    elseif name == "key_down" then
      local code = packed[4]
      if code == keyboard.keys.up then
        cursor = step(cursor, -1)
      elseif code == keyboard.keys.down then
        cursor = step(cursor, 1)
      else
        return rows[cursor], code, cursor
      end
    elseif name == "touch" then
      local column, row = packed[3], packed[4]
      if row == H then
        for _, spot in ipairs(spots) do
          if column >= spot.from and column <= spot.to then
            return rows[cursor], spot.code, cursor
          end
        end
      elseif row >= 3 then
        local index = top + row - 3
        local landed = rows[index]
        if landed and not landed.heading then
          if index == cursor and buttons[1] then
            return landed, buttons[1].code, index
          end
          cursor = index
        end
      end
    elseif name == "scroll" then
      if packed[5] > 0 then
        cursor = step(cursor, -1)
      else
        cursor = step(cursor, 1)
      end
    end
  end
end

local function holdsWhat(readings)
  local gauge = readings[1]
  if not gauge then
    return "empty"
  end
  return gauge.label .. "  " .. gauge.current .. " / " .. gauge.maximum
    .. " " .. gauge.unit
end

-- What this computer can watch, which is not the same as what it can see. A
-- transposer is a way of reaching blocks that have no component of their own,
-- so each of its faces that holds a tank is listed in its own right rather than
-- the transposer being listed and then asked about.
--
-- Named things come first, because a name is what anybody is looking for and
-- everything else is an address.
local function chooseComponent(only)
  term.clear()
  paint.forget()
  print("looking at what is attached")

  local rows = {}
  for address, kind in component.list() do
    if not only or only(address, kind) then
      if tank.isReader(kind) then
        for _, side in ipairs(tank.sides(address)) do
          local look = tank.inspect(address, side, config)
          rows[#rows + 1] = {
            address = address, kind = kind, side = side, named = true,
            text = string.format("%-24s %-14s %s  %s", look.name, kind,
              address:sub(1, 8), holdsWhat(look.readings)),
          }
        end
      else
        local name = gt.displayName(address, config)
          or rc.displayName(address, config)
          or lp.displayName(address)
        rows[#rows + 1] = {
          address = address, kind = kind, named = name ~= nil,
          text = string.format("%-24s %-14s %s", name or "", kind,
            address:sub(1, 8)),
        }
      end
    end
  end

  table.sort(rows, function(a, b)
    if a.named ~= b.named then
      return a.named
    end
    return a.text < b.text
  end)

  local row, code = menu("what this computer can watch", rows,
    { { label = "choose", code = keyboard.keys.enter },
      { label = "cancel", code = keyboard.keys.q } })
  if not row or code ~= keyboard.keys.enter then
    return nil
  end
  return row
end

local function watched(address, side)
  for _, entry in ipairs(config.watch) do
    if entry.address == address and entry.side == side then
      return true
    end
  end
  return false
end

local function readingsOf(address, side)
  if side then
    return tank.inspect(address, side, config).readings
  end
  return gt.readings(address)
end

local function gaugesOf(readings)
  local gauges = {}
  for index, reading in ipairs(readings) do
    if reading.kind == "gauge" then
      gauges[#gauges + 1] = { index = index, ordinal = #gauges + 1, reading = reading }
    end
  end
  return gauges
end

local function gaugeText(gauge)
  local reading = gauge.reading
  return string.format("%-16s %s / %s %s",
    reading.label ~= "" and reading.label or "value",
    reading.current, reading.maximum, reading.unit)
end

-------------------------------------------------------------------------------
-- one machine

local function editReadings(entry)
  entry.hidden = entry.hidden or {}
  local at = 1
  while true do
    local readings = readingsOf(entry.address, entry.side)
    local rows = {}
    for index, reading in ipairs(readings) do
      local label = reading.plain
      if reading.kind == "gauge" then
        label = (reading.label ~= "" and reading.label or "value")
          .. "  " .. reading.current .. " / " .. reading.maximum
      end
      rows[#rows + 1] = { index = index,
        text = (entry.hidden[index] and "[ ] " or "[x] ") .. label }
    end

    local row, code
    row, code, at = menu("which readings to show on " .. entryName(entry), rows,
      { { label = "show or hide", code = keyboard.keys.space },
        { label = "done", code = keyboard.keys.q } }, at)
    if not row or code ~= keyboard.keys.space then
      save()
      return
    end
    if entry.hidden[row.index] then
      entry.hidden[row.index] = nil
    else
      entry.hidden[row.index] = true
    end
  end
end

-- A super tank holds four million litres. If its diesel only ever moves between
-- 5,000 and 10,000 then a bar against four million never leaves zero, so the
-- maximum worth drawing against is set per gauge here.
local function editLimits(entry)
  local at = 1
  while true do
    local gauges = gaugesOf(readingsOf(entry.address, entry.side))
    if #gauges == 0 then
      print("this machine reports no gauge")
      os.sleep(2)
      return
    end

    local rows = {}
    for _, gauge in ipairs(gauges) do
      local limit = net.limitOf(entry, gauge.ordinal)
      rows[#rows + 1] = { ordinal = gauge.ordinal,
        text = gaugeText(gauge)
          .. (limit and ("   drawn against " .. core.comma(limit)) or "") }
    end

    local row, code
    row, code, at = menu("the maximum each bar is drawn against", rows,
      { { label = "set", code = keyboard.keys.enter },
        { label = "done", code = keyboard.keys.q } }, at)
    if not row or code ~= keyboard.keys.enter then
      save()
      return
    end

    local answer = prompt("draw the bar against what maximum? (blank clears it)",
      net.limitOf(entry, row.ordinal))
    entry.limits = entry.limits or {}
    entry.limits[row.ordinal] = tonumber(answer)
  end
end

local function editMachine(entry)
  local at = 1
  while true do
    local shown = "a card of its own, with a bar for each reading"
    if entry.compact then
      shown = "one line, no bar, tucked under the card above it"
    end

    local counting = "how much it is gaining or losing overall"
    if entry.usage then
      counting = "only what leaves it, which is what a pipe carries"
    end

    local rows = {
      { what = "nickname", text = "nickname          " .. entryName(entry) },
      { what = "shown", text = "shown as          " .. shown },
      { what = "usage", text = "rate counts       " .. counting },
      { what = "readings", text = "readings          choose which to show" },
      { what = "limits", text = "bar maximum       what each gauge is drawn against" },
    }

    local row, code
    row, code, at = menu(entryName(entry), rows,
      { { label = "change", code = keyboard.keys.enter },
        { label = "back", code = keyboard.keys.q } }, at)
    if not row or code ~= keyboard.keys.enter then
      return
    end

    if row.what == "nickname" then
      local name = prompt("nickname for " .. entry.address .. " (blank clears it)",
        core.nickname(config, keyOf(entry.address, entry.side)))
      config.nicknames[keyOf(entry.address, entry.side)] =
        (name and name ~= "") and name or nil
      save()
    elseif row.what == "shown" then
      if entry.compact then
        entry.compact = nil
      else
        entry.compact = true
      end
      save()
    elseif row.what == "usage" then
      if entry.usage then
        entry.usage = nil
      else
        entry.usage = true
      end
      save()
    elseif row.what == "readings" then
      editReadings(entry)
    else
      editLimits(entry)
    end
  end
end

-------------------------------------------------------------------------------
-- one alert

local function canStop(address)
  return core.has(core.methodsOf(address), "setWorkAllowed")
end

local function actionText(action)
  local name = gt.displayName(action.address, config)
    or lp.displayName(action.address)
    or action.address:sub(1, 8)
  local does = "stops"
  if action.onTrip ~= false then
    does = "starts"
  end
  -- the address as well, or two blast furnaces are the same line twice
  return does .. " " .. name .. "  " .. tostring(action.address):sub(1, 8)
end

local function addAction(alert)
  local target = chooseComponent(function(address)
    return canStop(address)
  end)
  if not target then
    return
  end

  alert.act = actions(alert)
  alert.act[#alert.act + 1] = {
    address = target.address,
    method = "setWorkAllowed",
    onTrip = false,
    onClear = true,
  }
  save()
end

-- One trigger, any number of machines. Two blast furnaces fed by one tank were
-- two identical alerts before this, which then had to be kept in step by hand.
local function editAlert(alert)
  local at = 1
  while true do
    local function threshold(value)
      return value and core.comma(value) or "-"
    end

    local rows = {
      { what = "name", text = "name              " .. tostring(alert.name) },
      { what = "watches", text = "watches           "
        .. entryName({ address = alert.address, side = alert.side })
        .. "  " .. tostring(alert.label ~= "" and alert.label or "value") },
      { what = "trouble", text = "counts as trouble "
        .. (alert.trouble == false
          and "no, it only acts"
          or "yes, said aloud and shown red") },
      { heading = true, text = "WHEN IT RUNS LOW" },
      { what = "below", text = "trips below       " .. threshold(alert.below) },
      { what = "above", text = "clears above      " .. threshold(alert.above) },
      { heading = true, text = "WHEN IT RUNS HIGH" },
      { what = "over", text = "trips above       " .. threshold(alert.over) },
      { what = "under", text = "clears below      " .. threshold(alert.under) },
      { heading = true, text = "MACHINES IT ACTS ON" },
    }
    for index, action in ipairs(actions(alert)) do
      rows[#rows + 1] = { what = "action", index = index, text = actionText(action) }
    end
    rows[#rows + 1] = { what = "add", text = "add a machine to act on" }

    local row, code
    row, code, at = menu("alert: " .. tostring(alert.name), rows,
      { { label = "change", code = keyboard.keys.enter },
        { label = "remove action", code = keyboard.keys.d },
        { label = "back", code = keyboard.keys.q } }, at)
    if not row or code == keyboard.keys.q then
      save()
      return
    end

    if row.what == "action" and code == keyboard.keys.d then
      table.remove(alert.act, row.index)
      save()
    elseif code == keyboard.keys.enter then
      if row.what == "name" then
        alert.name = prompt("name for this alert", alert.name) or alert.name
      elseif row.what == "below" then
        alert.below = tonumber(prompt("trip when the value falls below (blank to clear)",
          alert.below))
      elseif row.what == "above" then
        alert.above = tonumber(prompt("clear when it rises back to (blank to clear)",
          alert.above))
      elseif row.what == "over" then
        alert.over = tonumber(prompt("trip when the value rises above (blank to clear)",
          alert.over))
      elseif row.what == "under" then
        alert.under = tonumber(prompt("clear when it falls back to (blank to clear)",
          alert.under))
      elseif row.what == "trouble" then
        alert.trouble = alert.trouble == false
      elseif row.what == "add" then
        addAction(alert)
      end
      save()
    end
  end
end

local function addAlert()
  local chosen = chooseComponent()
  if not chosen then
    return
  end

  -- the picker already said which face, if it was a face
  local side = chosen.side
  local readings = readingsOf(chosen.address, side)
  local gauges = gaugesOf(readings)
  if #gauges == 0 then
    print("this component reports no gauge to watch")
    os.sleep(2)
    return
  end

  local rows = {}
  for _, gauge in ipairs(gauges) do
    rows[#rows + 1] = { gauge = gauge, text = gaugeText(gauge) }
  end
  local row, code = menu("which reading should it watch", rows,
    { { label = "choose", code = keyboard.keys.enter },
      { label = "cancel", code = keyboard.keys.q } })
  if not row or code ~= keyboard.keys.enter then
    return
  end

  local reading = row.gauge.reading
  -- The thresholds are not asked for here. There are four of them, two for a
  -- reading that must not run out and two for one that must not fill up, and
  -- three blank answers in a row is a worse way to say which pair is meant than
  -- the alert's own screen, which opens next.
  local alert = {
    name = prompt("name for this alert") or "alert",
    address = chosen.address,
    side = side,
    -- the label and the unit are what survive the machine rewording itself;
    -- the ordinal and the line number are only fallbacks
    label = reading.label,
    unit = reading.unit,
    gauge = row.gauge.ordinal,
    index = row.gauge.index,
    trouble = true,
  }

  config.alerts[#config.alerts + 1] = alert
  save()
  editAlert(alert)
end

-- Every way this base can say something, each on and off on its own, because a
-- lamp and a siren and a line in chat are not alternatives: they do different
-- jobs, in different rooms, at the same time.
local function editNotify()
  local at = 1
  while true do
    local rows = {}
    for _, channel in ipairs(notify.CHANNELS) do
      local kept = notify.settings(config, channel.name)
      local state = "[ ] "
      if kept.on then
        state = "[x] "
      end

      local extra = ""
      if not notify.present(channel) then
        extra = "   nothing here to do it with"
      elseif channel.name == "note" then
        extra = "   " .. (kept.instrument or "harp")
      elseif channel.name == "lamp" then
        extra = "   " .. (kept.tripped or "ff0000")
          .. " when tripped, " .. (kept.clear or "00ff00") .. " when clear"
      elseif channel.name == "siren" then
        extra = "   " .. (kept.sound or "klaxon1")
      elseif channel.name == "syslog" then
        extra = "   kept here"
        if kept.collector and kept.collector ~= "" then
          extra = extra .. ", and sent to " .. kept.collector
        end
      end

      rows[#rows + 1] = {
        channel = channel,
        text = string.format("%s%-8s %-40s %s", state, channel.name,
          channel.what, extra),
      }
    end

    local row, code
    row, code, at = menu("how this base says something happened", rows,
      { { label = "on or off", code = keyboard.keys.space },
        { label = "settings", code = keyboard.keys.enter },
        { label = "test it", code = keyboard.keys.t },
        { label = "back", code = keyboard.keys.q } }, at)
    if not row or code == keyboard.keys.q then
      save()
      return
    end

    local name = row.channel.name
    if code == keyboard.keys.space then
      notify.set(config, name, "on", not notify.settings(config, name).on)
      save()
    elseif code == keyboard.keys.t then
      -- a channel nobody can hear is worth finding out about here rather than
      -- when something is actually wrong
      if row.channel.kind == "state" then
        notify.state(config, true)
        os.sleep(2)
        notify.state(config, false)
      elseif row.channel.kind == "record" then
        notify.record(config, "ocwatch test of the syslog channel", notify.NOTICE)
      else
        notify.event(config, "ocwatch test of the " .. name .. " channel", true)
      end
      alarmShown = nil
    elseif code == keyboard.keys.enter then
      if name == "note" then
        notify.set(config, name, "instrument",
          prompt("instrument, one of " .. table.concat(ct.INSTRUMENTS, ", "),
            notify.settings(config, name).instrument or "harp"))
      elseif name == "lamp" then
        notify.set(config, name, "tripped",
          prompt("lamp colour while an alert is tripped, as rrggbb",
            notify.settings(config, name).tripped or "ff0000"))
        notify.set(config, name, "clear",
          prompt("lamp colour while all is well, as rrggbb",
            notify.settings(config, name).clear or "00ff00"))
      elseif name == "siren" then
        local sounds = sec.sounds()
        notify.set(config, name, "sound",
          prompt("alarm sound, one of " .. table.concat(sounds, ", "),
            notify.settings(config, name).sound or "klaxon1"))
      elseif name == "syslog" then
        notify.set(config, name, "collector",
          prompt("machine that keeps the base's log, blank to keep only here",
            notify.settings(config, name).collector))
        if notify.collect(config, net.hostname(config)) then
          notice("reload the log daemon for it to take: rc syslogd reload")
        end
      end
      save()
    end
  end
end

-- Who this machine is, and which satellites it should be hearing from. The list
-- fills itself in as ocview hears from a satellite, so what is edited here is a
-- satellite that has never been in range to be heard.
local function editNetwork()
  local at = 1
  while true do
    local peers = net.peers(config)
    local telemetry = gtp.settings(config)
    local rows = {
      { what = "hostname",
        text = string.format("%-12s %s", "hostname", net.hostname(config)) },
      { what = "gateway",
        text = string.format("%-12s %s", "gateway",
          config.gateway ~= nil and config.gateway ~= "" and config.gateway
          or "whoever answers, for ocup on a machine with no internet card") },
      { what = "telemetry",
        text = string.format("%-12s %s", "telemetry",
          telemetry.on and (telemetry.host .. " every " .. telemetry.interval .. "s")
          or "off") },
      { heading = true, text = "SATELLITES" },
    }
    for index, host in ipairs(peers) do
      rows[#rows + 1] = { what = "peer", index = index, host = host, text = host }
    end
    if #peers == 0 then
      rows[#rows + 1] = { heading = true,
        text = "  none yet; ocview records each one it hears from" }
    end

    local row, code
    row, code, at = menu("ocwatch v" .. VERSION .. "   network", rows,
      { { label = "change", code = keyboard.keys.enter },
        { label = "add a satellite", code = keyboard.keys.n },
        { label = "forget", code = keyboard.keys.d },
        { label = "back", code = keyboard.keys.q } }, at)

    if code == keyboard.keys.q then
      save()
      return
    elseif code == keyboard.keys.n then
      local host = prompt("hostname of a satellite out of range of this one")
      if host and host ~= "" and net.remember(config, host) then
        save()
      end
    elseif row and code == keyboard.keys.d and row.what == "peer" then
      net.forget(config, row.host)
      save()
    elseif row and code == keyboard.keys.enter and row.what == "hostname" then
      local name = prompt("what to call this machine on the network",
        net.hostname(config))
      local fine, why = net.validHostname(name)
      if name and name ~= "" and not fine then
        notice(name .. ": " .. why)
      elseif fine then
        config.hostname = name
        save()
        if net.setHostname(name) then
          -- OpenOS keeps its own copy of the name per shell, and the daemon
          -- reads the file once at start, so neither notices on its own
          pcall(sh.execute, _ENV, "hostname --update")
          notice("named " .. name .. ", restart minitel for it to take: rc minitel restart")
        else
          notice("could not write /etc/hostname")
        end
      end
    elseif row and code == keyboard.keys.enter and row.what == "gateway" then
      config.gateway = prompt("machine ocup fetches through, blank to ask around",
        config.gateway)
      save()
    elseif row and code == keyboard.keys.enter and row.what == "telemetry" then
      local host = prompt("machine collecting metrics, blank to stop sending",
        telemetry.host)
      if host == nil or host == "" then
        gtp.set(config, "on", false)
      else
        gtp.set(config, "on", true)
        gtp.set(config, "host", host)
        local seconds = tonumber(prompt("seconds between readings sent",
          telemetry.interval))
        if seconds and seconds > 0 then
          gtp.set(config, "interval", seconds)
        end
      end
      save()
    end
  end
end

local function addMachine()
  local chosen = chooseComponent()
  if not chosen then
    return
  end

  local side = chosen.side
  if watched(chosen.address, side) then
    print("already watched")
    os.sleep(1)
    return
  end

  config.watch[#config.watch + 1] = {
    address = chosen.address, side = side, hidden = {},
  }
  save()
end

-------------------------------------------------------------------------------

-- the trip points only: the line is narrow, and where an alert clears is on its
-- own screen beside the point it trips at
local function alertSummary(alert)
  local parts = {}
  if alert.below then
    parts[#parts + 1] = "below " .. core.comma(alert.below)
  end
  if alert.over then
    parts[#parts + 1] = "above " .. core.comma(alert.over)
  end
  local acting = #actions(alert)
  if acting > 0 then
    parts[#parts + 1] = "acts on " .. acting
  end
  if alert.tripped then
    parts[#parts + 1] = "TRIPPED"
  end
  return string.format("%-20s %-20s %s", alert.name,
    entryName({ address = alert.address, side = alert.side }),
    table.concat(parts, "   "))
end

local function editor()
  local at = 1
  while true do
    local rows = { { heading = true, text = "MACHINES" } }
    for index, entry in ipairs(config.watch) do
      rows[#rows + 1] = { what = "machine", index = index, entry = entry,
        text = entryName(entry) }
    end
    rows[#rows + 1] = { heading = true, text = "ALERTS" }
    for index, alert in ipairs(config.alerts) do
      rows[#rows + 1] = { what = "alert", index = index, alert = alert,
        text = alertSummary(alert) }
    end

    local row, code
    row, code, at = menu("ocwatch v" .. VERSION .. "   configuration", rows,
      { { label = "open", code = keyboard.keys.enter },
        { label = "move up", code = keyboard.keys.pageUp },
        { label = "move down", code = keyboard.keys.pageDown },
        { label = "watch a machine", code = keyboard.keys.m },
        { label = "new alert", code = keyboard.keys.n },
        { label = "remove", code = keyboard.keys.d },
        { label = "notifications", code = keyboard.keys.t },
        { label = "network", code = keyboard.keys.w },
        { label = "done", code = keyboard.keys.q } }, at)

    -- The action is read before the row, because on a computer with nothing
    -- configured there is no row: both sections are empty, every row is a
    -- heading, and nothing can be selected. Treating that as "the user asked to
    -- leave" is what made adding the very first machine quit to the shell.
    if code == keyboard.keys.q then
      return
    elseif code == keyboard.keys.m then
      addMachine()
    elseif code == keyboard.keys.n then
      addAlert()
    elseif code == keyboard.keys.t then
      editNotify()
    elseif code == keyboard.keys.w then
      editNetwork()
    elseif row and row.what == "machine"
      and (code == keyboard.keys.pageUp or code == keyboard.keys.pageDown) then
      -- the order of the list is the order on the dashboard, which is how a
      -- compact machine ends up under the card it belongs to
      local to = row.index - 1
      if code == keyboard.keys.pageDown then
        to = row.index + 1
      end
      if config.watch[to] then
        config.watch[row.index], config.watch[to] =
          config.watch[to], config.watch[row.index]
        -- the cursor follows the machine, not the position it left: the first
        -- row is the MACHINES heading, so a machine sits one row below its
        -- place in the list
        at = to + 1
        save()
      end
    elseif row and code == keyboard.keys.d and row.what == "machine" then
      table.remove(config.watch, row.index)
      save()
    elseif row and code == keyboard.keys.d and row.what == "alert" then
      table.remove(config.alerts, row.index)
      save()
    elseif row and code == keyboard.keys.enter and row.what == "machine" then
      editMachine(row.entry)
    elseif row and code == keyboard.keys.enter and row.what == "alert" then
      editAlert(row.alert)
    end
  end
end

-------------------------------------------------------------------------------

local arguments = { ... }
if arguments[1] == "--edit" then
  editor()
  return 0
end

if #config.watch == 0 then
  print("ocwatch: nothing configured yet, starting the editor")
  os.sleep(1)
  editor()
  if #config.watch == 0 then
    return 0
  end
end

-- A satellite on the network answers for what it watches; off it, this is
-- simply a local dashboard, which is still useful.
--
-- A question can land in the middle of a refresh, so it is buffered here and
-- answered by the loop. Drawing from inside a listener would redraw the screen
-- halfway through reading a machine.
local pending = {}
-- when this machine next tells the telemetry service what it can see
local telemetryDue = 0
local heard = net.listen(function(from, port, data)
  pending[#pending + 1] = { from = from, port = port, data = data }
end)

local minitel, offline = net.up()
if not minitel then
  net.deafen(heard)
  notice(offline)
end

blank()
term.setCursorBlink(false)

-- what the last refresh read, kept so a question is answered from it rather
-- than by reading every machine again
local latest
local cards = {}
local due = 0

-- Reading the machines is the expensive part of a refresh, so it happens on a
-- clock rather than once per event. The loop used to sample at the top of every
-- turn, which meant a keypress cost a full read of every machine before it was
-- even looked at, and holding a key made the program crawl.
local function refresh()
  cards = sample()
  latest = net.report(config, cards)
  -- the same numbers the dashboard just drew, said the other way round for
  -- whoever is collecting them, on a slower clock of its own
  if gtp.wanted(minitel, config) and computer.uptime() >= telemetryDue then
    telemetryDue = gtp.submit(minitel, config, latest)
  end
  render(cards)
  due = computer.uptime() + REFRESH_SECONDS
end

refresh()

while true do
  local wait = due - computer.uptime()
  if wait <= 0 then
    refresh()
    wait = REFRESH_SECONDS
  end

  -- packed rather than unpacked into fixed names: a key event carries a code
  -- in the fourth slot where other events carry something else, and reading one
  -- as the other is how a dispatch quietly stops matching
  local packed = table.pack(event.pull(wait))
  local name = packed[1]
  local code = packed[4]

  -- a satellite answers for the machines it watches while it is watching them,
  -- so one program does both rather than fighting for the terminal, and it
  -- answers out of the reading the last refresh already took
  while pending[1] do
    local packet = table.remove(pending, 1)
    local sent, command =
      net.answer(minitel, config, packet.port, packet.from, packet.data, latest)
    if sent then
      notice("served " .. sent)
      -- drawing is cheap, and it is the only way the notice reaches the screen
      -- before the next refresh comes round
      render(cards)
    end
    if command == "update" then
      -- the machine goes down inside this, so nothing after it runs
      net.deafen(heard)
      net.applyUpdate()
    end
  end

  if name == "interrupted" then
    break
  elseif name == "screen_resized" then
    layout()
    render(cards)
  elseif name == "key_down" then
    if code == keyboard.keys.q then
      break
    elseif code == keyboard.keys.r then
      refresh()
    elseif code == keyboard.keys.e then
      editor()
      config = core.loadConfig()
      renameBeep()
      blank()
      term.setCursorBlink(false)
      refresh()
    end
  end
end

net.deafen(heard)
gpu.setForeground(FG)
gpu.setBackground(BG)
term.clear()

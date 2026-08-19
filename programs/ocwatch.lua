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
local tank = require("octank")
local ct = require("occomputronics")
local sec = require("ocsecurity")
local keyboard = require("keyboard")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.14.0"
local REFRESH_SECONDS = 2

local gpu = component.gpu

local W, H, GAUGE_W

local paint = core.painter(gpu)

-- recomputed on a resize: an attached display is often not the size the program
-- started on
local function layout()
  W, H = core.viewport(gpu)
  GAUGE_W = math.max(16, math.min(40, math.floor((W - 34) / 2)))
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
    or lp.displayName(entry.address)
    or entry.address
end

-------------------------------------------------------------------------------
-- alerts

-- an alert trips below its floor and only clears back above its ceiling, so a
-- reading sitting on the boundary cannot beep on every refresh
local function evaluate(alert, value)
  local tripped = alert.tripped or false
  if not tripped and alert.below and value < alert.below then
    tripped = true
  elseif tripped and alert.above and value >= alert.above then
    tripped = false
  elseif not tripped and alert.over and value > alert.over then
    tripped = true
  elseif tripped and alert.under and value <= alert.under then
    tripped = false
  end
  return tripped
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

-- A tripped alert is worth hearing from another room, so each thing that can
-- say something is asked in turn: words where words are possible, a noise
-- otherwise, and the computer's own beep when the machine has none of them.
local function announce(alert, text, urgent)
  if alert.beep == false then
    return nil
  end

  local said = ct.speak(text)
  local played = ct.play(urgent)
  if said and played then
    return said .. " and " .. played
  end
  if said or played then
    return said or played
  end

  pcall(computer.beep, urgent and 880 or 440, 0.2)
  return nil
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
local history = {}

local function rateOf(key, value, at)
  local was = history[key]
  history[key] = { value = value, at = at }
  if not was then
    return nil
  end
  local seconds = at - was.at
  if seconds <= 0 then
    return nil
  end
  return (value - was.value) / seconds
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
        if alert.tripped then
          notice(alert.name .. " tripped at " .. core.comma(reading.value))
          said = announce(alert, alert.name .. " tripped at "
            .. core.comma(reading.value) .. " " .. reading.unit, true)
        else
          notice(alert.name .. " cleared at " .. core.comma(reading.value))
          said = announce(alert, alert.name .. " cleared", false)
        end
        if said then
          notice("told the " .. said:gsub("_", " "))
        end
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
    write(3, y, fit(card.name, W - 22), FG, BG)
    if card.status then
      write(W - 20, y, fit(card.status, 18), statusColor(card.status, card.alarm), BG)
    end
    y = y + 1

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
          local label = reading.label ~= "" and reading.label or "value"
          write(5, y, fit(label, 12), DIM, BG)
          local max, isLocal = core.scale(reading, net.limitOf(card.entry, ordinal))
          drawGauge(18, y, reading, GAUGE_W, max, isLocal)
        else
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
        end
        y = y + 1
      end
    end
    y = y + 1
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
          reading.value, now)
      end
    end
  end

  checkAlerts(byAddress)

  local alarmed = false
  for _, card in ipairs(cards) do
    for _, alert in ipairs(config.alerts) do
      if alert.address == card.entry.address and alert.tripped then
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
    if alarmed then
      ct.lamps(ct.rgb(255, 0, 0))
    else
      ct.lamps(ct.rgb(0, 255, 0))
    end
    sec.alarm(alarmed)
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
local function menu(title, rows, buttons)
  local cursor, top = 1, 1
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
      return nil, keyboard.keys.q
    elseif name == "key_down" then
      local code = packed[4]
      if code == keyboard.keys.up then
        cursor = step(cursor, -1)
      elseif code == keyboard.keys.down then
        cursor = step(cursor, 1)
      else
        return rows[cursor], code
      end
    elseif name == "touch" then
      local column, row = packed[3], packed[4]
      if row == H then
        for _, spot in ipairs(spots) do
          if column >= spot.from and column <= spot.to then
            return rows[cursor], spot.code
          end
        end
      elseif row >= 3 then
        local index = top + row - 3
        local landed = rows[index]
        if landed and not landed.heading then
          if index == cursor and buttons[1] then
            return landed, buttons[1].code
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
        local name = gt.displayName(address, config) or lp.displayName(address)
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

    local row, code = menu("which readings to show on " .. entryName(entry), rows,
      { { label = "show or hide", code = keyboard.keys.space },
        { label = "done", code = keyboard.keys.q } })
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

    local row, code = menu("the maximum each bar is drawn against", rows,
      { { label = "set", code = keyboard.keys.enter },
        { label = "done", code = keyboard.keys.q } })
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
  while true do
    local rows = {
      { what = "nickname", text = "nickname          " .. entryName(entry) },
      { what = "readings", text = "readings          choose which to show" },
      { what = "limits", text = "bar maximum       what each gauge is drawn against" },
    }

    local row, code = menu(entryName(entry), rows,
      { { label = "change", code = keyboard.keys.enter },
        { label = "back", code = keyboard.keys.q } })
    if not row or code ~= keyboard.keys.enter then
      return
    end

    if row.what == "nickname" then
      local name = prompt("nickname for " .. entry.address .. " (blank clears it)",
        core.nickname(config, keyOf(entry.address, entry.side)))
      config.nicknames[keyOf(entry.address, entry.side)] =
        (name and name ~= "") and name or nil
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
  while true do
    local rows = {
      { what = "name", text = "name              " .. tostring(alert.name) },
      { what = "watches", text = "watches           "
        .. entryName({ address = alert.address, side = alert.side })
        .. "  " .. tostring(alert.label ~= "" and alert.label or "value") },
      { what = "below", text = "trips below       "
        .. (alert.below and core.comma(alert.below) or "-") },
      { what = "above", text = "clears above      "
        .. (alert.above and core.comma(alert.above) or "-") },
      { what = "announce", text = "announces         "
        .. (alert.beep == false and "no" or "yes, aloud if it can") },
      { heading = true, text = "MACHINES IT ACTS ON" },
    }
    for index, action in ipairs(actions(alert)) do
      rows[#rows + 1] = { what = "action", index = index, text = actionText(action) }
    end
    rows[#rows + 1] = { what = "add", text = "add a machine to act on" }

    local row, code = menu("alert: " .. tostring(alert.name), rows,
      { { label = "change", code = keyboard.keys.enter },
        { label = "remove action", code = keyboard.keys.d },
        { label = "back", code = keyboard.keys.q } })
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
      elseif row.what == "announce" then
        alert.beep = alert.beep == false
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
    below = tonumber(prompt("trip when the value falls below (blank to skip)")),
    above = tonumber(prompt("clear when it rises back to (blank to skip)")),
    beep = true,
  }

  config.alerts[#config.alerts + 1] = alert
  save()
  editAlert(alert)
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

local function alertSummary(alert)
  local parts = {}
  if alert.below then
    parts[#parts + 1] = "below " .. core.comma(alert.below)
  end
  if alert.above then
    parts[#parts + 1] = "above " .. core.comma(alert.above)
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

    local row, code = menu("ocwatch v" .. VERSION .. "   configuration", rows,
      { { label = "open", code = keyboard.keys.enter },
        { label = "watch a machine", code = keyboard.keys.m },
        { label = "new alert", code = keyboard.keys.n },
        { label = "remove", code = keyboard.keys.d },
        { label = "done", code = keyboard.keys.q } })

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

-- a satellite with a network card answers for what it watches; without one it
-- is simply a local dashboard, which is still useful
local modem = net.modem()

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
  -- in the fourth slot where a modem message carries a port, and reading one
  -- as the other is how a dispatch quietly stops matching
  local packed = table.pack(event.pull(wait))
  local name = packed[1]
  local code = packed[4]

  if name == "interrupted" then
    break
  elseif name == "modem_message" then
    -- a satellite answers for the machines it watches while it is watching
    -- them, so one program does both rather than fighting for the terminal
    if modem then
      local sent = net.answer(modem, packed[4], packed[3], packed[6], config, latest)
      if sent then
        notice("served " .. sent)
        -- drawing is cheap, and it is the only way the notice reaches the screen
        -- before the next refresh comes round
        render(cards)
      end
    end
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
      blank()
      term.setCursorBlink(false)
      refresh()
    end
  end
end

gpu.setForeground(FG)
gpu.setBackground(BG)
term.clear()

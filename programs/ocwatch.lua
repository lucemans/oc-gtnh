-- ocwatch: a fixed dashboard for the machines you choose, with thresholds that
-- can beep and can stop a machine before a shortage becomes a power failure.
--
--   ocwatch          watch the configured machines
--   ocwatch --edit   choose machines, nickname them, pick readings, set alerts

local component = require("component")
local computer = require("computer")
local event = require("event")
local core = require("oclib")
local gt = require("ocgt")
local lp = require("oclogistics")
local net = require("ocnet")
local tank = require("octank")
local ct = require("occomputronics")
local keyboard = require("keyboard")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.10.0"
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

local function colorOf(gauge)
  if gauge.colorCode and core.MC_COLORS[gauge.colorCode] then
    return core.MC_COLORS[gauge.colorCode]
  end
  return OK_COLOR
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

-- A tripped alert is worth hearing from another room. Computronics gives three
-- ways to say so and this computer may have none of them, in which case the
-- built-in beep is still better than silence.
local function announce(alert, text, urgent)
  if alert.beep == false then
    return nil
  end
  local used = ct.announce(text, urgent)
  if not used then
    pcall(computer.beep, urgent and 880 or 440, 0.2)
  end
  return used
end

-- whether the lamps are showing an alarm, so they are only set on a change
local lampLit = nil

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
      write(cursor, y, string.rep(FULL_BLOCK, filled), colorOf(gauge), BG)
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

  -- A colourful lamp says from across the room what the screen says up close.
  -- Only on a change, since setting it is a call into the world.
  if alarmed ~= lampLit then
    if alarmed then
      ct.lamps(ct.rgb(255, 0, 0))
    else
      ct.lamps(ct.rgb(0, 255, 0))
    end
    lampLit = alarmed
  end

  return cards
end

-------------------------------------------------------------------------------
-- editor

local function prompt(message)
  term.clear()
  print(message)
  io.write("> ")
  return io.read()
end

local function chooseComponent()
  local list = {}
  for address, kind in component.list() do
    list[#list + 1] = { address = address, kind = kind }
  end
  table.sort(list, function(a, b)
    return a.address < b.address
  end)

  term.clear()
  print("attached components")
  for index, entry in ipairs(list) do
    print(string.format("%3d  %-18s %s  %s", index, entry.kind,
      entry.address:sub(1, 8), gt.displayName(entry.address, config) or lp.displayName(entry.address) or ""))
  end
  io.write("number (blank to cancel) > ")
  local answer = tonumber(io.read())
  return answer and list[answer] or nil
end

local function watched(address)
  for index, entry in ipairs(config.watch) do
    if entry.address == address then
      return index
    end
  end
  return nil
end

-- A transposer is not itself worth watching: what is worth watching is the tank
-- on one of its six faces, which is how a Railcraft tank gets onto the
-- dashboard at all, having no component of its own.
local function chooseSide(address)
  term.clear()
  print("looking for tanks around it")
  local sides = tank.sides(address)
  if #sides == 0 then
    print("no tank on any side of it")
    os.sleep(2)
    return nil
  end

  for index, side in ipairs(sides) do
    local look = tank.inspect(address, side, config)
    local holds = "empty"
    if look.readings[1] then
      holds = look.readings[1].label .. "  " .. look.readings[1].current
        .. " / " .. look.readings[1].maximum .. " L"
    end
    print(string.format("%3d  %-6s %s", index, tank.sideName(side), holds))
  end

  io.write("number (blank to cancel) > ")
  local answer = tonumber(io.read())
  return answer and sides[answer] or nil
end

local function editAdd()
  local chosen = chooseComponent()
  if not chosen then
    return
  end

  local side = nil
  if tank.isReader(chosen.kind) then
    side = chooseSide(chosen.address)
    if not side then
      return
    end
  elseif watched(chosen.address) then
    print("already watched")
    os.sleep(1)
    return
  end

  config.watch[#config.watch + 1] = {
    address = chosen.address, side = side, hidden = {},
  }
  save()
end

local function editRemove()
  term.clear()
  for index, entry in ipairs(config.watch) do
    print(index .. "  " .. entryName(entry))
  end
  io.write("number to remove (blank to cancel) > ")
  local answer = tonumber(io.read())
  if answer and config.watch[answer] then
    table.remove(config.watch, answer)
    save()
  end
end

local function editNickname()
  term.clear()
  for index, entry in ipairs(config.watch) do
    print(index .. "  " .. entryName(entry))
  end
  io.write("number to rename (blank to cancel) > ")
  local answer = tonumber(io.read())
  local entry = answer and config.watch[answer]
  if not entry then
    return
  end
  local name = prompt("nickname for " .. entry.address .. " (blank clears it)")
  config.nicknames[keyOf(entry.address, entry.side)] =
    (name and name ~= "") and name or nil
  save()
end

local function editReadings()
  term.clear()
  for index, entry in ipairs(config.watch) do
    print(index .. "  " .. entryName(entry))
  end
  io.write("number whose readings to toggle (blank to cancel) > ")
  local answer = tonumber(io.read())
  local entry = answer and config.watch[answer]
  if not entry then
    return
  end

  entry.hidden = entry.hidden or {}
  while true do
    term.clear()
    local readings = gt.readings(entry.address)
    print(gt.displayName(entry.address, config) or entry.address)
    for index, reading in ipairs(readings) do
      local shown = entry.hidden[index] and "hidden " or "shown  "
      local label = reading.kind == "gauge"
        and ((reading.label ~= "" and reading.label or "value")
          .. "  " .. reading.current .. " / " .. reading.maximum)
        or reading.plain
      print(string.format("%3d  %s %s", index, shown, label))
    end
    io.write("number to toggle (blank when done) > ")
    local pick = tonumber(io.read())
    if not pick or not readings[pick] then
      break
    end
    entry.hidden[pick] = (not entry.hidden[pick]) or nil
  end
  save()
end

local function editAlert()
  term.clear()
  print("an alert watches one gauge and may stop a machine when it trips")
  local chosen = chooseComponent()
  if not chosen then
    return
  end

  local side, readings
  if tank.isReader(chosen.kind) then
    side = chooseSide(chosen.address)
    if not side then
      return
    end
    readings = tank.inspect(chosen.address, side, config).readings
  else
    readings = gt.readings(chosen.address)
  end

  term.clear()
  print("readings on " .. entryName({ address = chosen.address, side = side }))
  local gauges = {}
  for index, reading in ipairs(readings) do
    if reading.kind == "gauge" then
      gauges[#gauges + 1] = index
      print(string.format("%3d  %s  %s / %s %s", index,
        reading.label ~= "" and reading.label or "value",
        reading.current, reading.maximum, reading.unit))
    end
  end
  if #gauges == 0 then
    print("this component reports no gauge to watch")
    os.sleep(2)
    return
  end

  io.write("gauge number > ")
  local index = tonumber(io.read())
  if not index or not readings[index] or readings[index].kind ~= "gauge" then
    return
  end

  local below = tonumber(prompt("trip when the value falls below (blank to skip)"))
  local above = tonumber(prompt("clear when it rises back to (blank to skip)"))
  local name = prompt("name for this alert") or "alert"

  -- the label and the unit are what survive the machine rewording itself; the
  -- ordinal and the line number are only fallbacks
  local ordinal = 0
  for _, position in ipairs(gauges) do
    if position <= index then
      ordinal = ordinal + 1
    end
  end

  local alert = {
    name = name,
    address = chosen.address,
    side = side,
    label = readings[index].label,
    unit = readings[index].unit,
    gauge = ordinal,
    index = index,
    below = below,
    above = above,
    beep = true,
  }

  -- one tank can feed more than one furnace, so this asks until you say no
  local acts = {}
  while true do
    local question = "stop a machine when this trips? (y/N)"
    if #acts > 0 then
      question = "stop another machine as well? (y/N)   " .. #acts .. " so far"
    end
    local answer = prompt(question)
    if not (answer and answer:lower():sub(1, 1) == "y") then
      break
    end

    local target = chooseComponent()
    if not target then
      break
    end
    if core.has(core.methodsOf(target.address), "setWorkAllowed") then
      acts[#acts + 1] = {
        address = target.address,
        method = "setWorkAllowed",
        onTrip = false,
        onClear = true,
      }
    else
      print("that component has no setWorkAllowed, skipped")
      os.sleep(2)
    end
  end
  if #acts > 0 then
    alert.act = acts
  end

  config.alerts[#config.alerts + 1] = alert
  save()
end

-- A super tank holds four million litres. If its diesel only ever moves between
-- 5,000 and 10,000 then a bar against four million never leaves zero, so the
-- maximum worth drawing against is set per gauge here.
local function editLimit()
  term.clear()
  if #config.watch == 0 then
    print("no machines watched yet")
    os.sleep(1)
    return
  end
  for index, entry in ipairs(config.watch) do
    print(index .. "  " .. (gt.displayName(entry.address, config)
      or lp.displayName(entry.address) or entry.address))
  end
  io.write("machine number (blank to cancel) > ")
  local which = tonumber(io.read())
  local entry = which and config.watch[which]
  if not entry then
    return
  end

  term.clear()
  local gauges = {}
  for _, reading in ipairs(gt.readings(entry.address)) do
    if reading.kind == "gauge" then
      gauges[#gauges + 1] = reading
      local limit = net.limitOf(entry, #gauges)
      print(string.format("%3d  %s  %s / %s %s%s", #gauges,
        reading.label ~= "" and reading.label or "value",
        reading.current, reading.maximum, reading.unit,
        limit and ("   showing against " .. core.comma(limit)) or ""))
    end
  end
  if #gauges == 0 then
    print("this machine reports no gauge")
    os.sleep(2)
    return
  end

  io.write("gauge number (blank to cancel) > ")
  local ordinal = tonumber(io.read())
  if not ordinal or not gauges[ordinal] then
    return
  end

  local limit = tonumber(prompt("draw the bar against what maximum? (blank to clear)"))
  entry.limits = entry.limits or {}
  entry.limits[ordinal] = limit
  save()
end

local function editAlertRemove()
  term.clear()
  if #config.alerts == 0 then
    print("no alerts configured")
    os.sleep(1)
    return
  end
  for index, alert in ipairs(config.alerts) do
    print(index .. "  " .. alert.name)
  end
  io.write("number to remove (blank to cancel) > ")
  local answer = tonumber(io.read())
  if answer and config.alerts[answer] then
    table.remove(config.alerts, answer)
    save()
  end
end

local function editor()
  while true do
    term.clear()
    print("ocwatch v" .. VERSION .. " configuration")
    print("")
    print("  " .. #config.watch .. " machines watched, " .. #config.alerts .. " alerts")
    print("")
    print("  1  add a machine")
    print("  2  remove a machine")
    print("  3  set a nickname")
    print("  4  choose which readings to show")
    print("  5  set the maximum a bar is drawn against")
    print("  6  add an alert")
    print("  7  remove an alert")
    print("  8  done")
    io.write("> ")

    local answer = tonumber(io.read())
    if answer == 1 then
      editAdd()
    elseif answer == 2 then
      editRemove()
    elseif answer == 3 then
      editNickname()
    elseif answer == 4 then
      editReadings()
    elseif answer == 5 then
      editLimit()
    elseif answer == 6 then
      editAlert()
    elseif answer == 7 then
      editAlertRemove()
    else
      return
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

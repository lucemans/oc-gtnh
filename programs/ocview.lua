-- ocview: the base at a glance, on a tablet.
--
--   ocview        ask the network and keep the answer fresh
--   ocview --once ask once and stop, for checking it works
--
-- A tablet cannot see another computer's components, so it asks: ocserve on the
-- base answers with everything ocwatch is configured to watch.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local net = require("ocnet")
local ct = require("occomputronics")
local notify = require("ocnotify")
local keyboard = require("keyboard")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.10.0"

-- How long to give up on before saying so on screen. Answers are absorbed as
-- they arrive rather than waited for, so this is only how long a blank screen
-- may stay blank before it explains itself.
local ANSWER_TIMEOUT = 8
local REFRESH_SECONDS = 2
-- a satellite unheard for this long is shown as stale rather than as current
local QUIET_SECONDS = 12

local BG = 0x000000
local FG = 0xFFFFFF
local DIM = 0x999999
local BAR = 0x333333
local OK_COLOR = 0x66CC66
local ALARM = 0xCC6666

local FULL_BLOCK = "\226\150\136"
local LIGHT_BLOCK = "\226\150\145"
-- a thin vertical line, drawn over the bar where an alert sits
local MARK = "\226\148\130"

local gpu = component.gpu

local W, H

local paint = core.painter(gpu)

-- the same file ocwatch keeps its machines in, so the view a tablet is left in
-- is the view it comes back to
local config = core.loadConfig()

-- recomputed on a resize: a tablet docked to a screen changes size under us
local function layout()
  W, H = core.viewport(gpu)
  paint.forget()
end

layout()

local function fit(text, width)
  local length = unicode.len(text)
  if length > width then
    return unicode.sub(text, 1, width)
  end
  return text .. string.rep(" ", width - length)
end

local write = paint.write

-- What each satellite last said, kept between rounds rather than gathered
-- inside one blocking call. A relay repeats what it forwards, so the same
-- answer arrives several times over different paths: keying on the answering
-- card means one satellite stays one entry however many copies land.
local satellites = {}
local order = {}

-- whether the lamps here are already showing trouble
local shownTripped = nil
local seen = { heard = 0, unreadable = 0 }
local started = computer.uptime()

local function absorb(packed)
  seen.heard = seen.heard + 1
  local answer, why = net.decode(packed[4], packed[3], packed[6], packed[7], packed[8])
  if not answer then
    if why then
      seen.unreadable = seen.unreadable + 1
    end
    return false
  end

  answer.at = computer.uptime()
  if not satellites[answer.address] then
    order[#order + 1] = answer.address
  end
  satellites[answer.address] = answer
  return true
end

-- Saying only "no answer" hides which half is broken. Whether anything at all
-- arrived separates a satellite that never heard the question from one that
-- answered with something unreadable.
local function problem()
  if #order > 0 then
    return nil
  end
  if seen.unreadable > 0 then
    return "heard " .. seen.unreadable .. " unreadable answers: version mismatch?"
  end
  if seen.heard > 0 then
    return "heard " .. seen.heard .. " messages, none of them answers"
  end
  return "no answer yet: is ocwatch running there, and in range?"
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

local function rateText(gauge)
  if not gauge.rate or math.abs(gauge.rate) < 1 then
    return ""
  end
  local sign = "+"
  if gauge.rate < 0 then
    sign = "-"
  end
  return sign .. core.comma(math.floor(math.abs(gauge.rate) + 0.5))
    .. " " .. tostring(gauge.unit or "") .. "/s"
end

-- What a gauge says in words, beside whatever bar is drawn for it. The reading
-- is named only when the machine is not already named after it: "Steam Tank"
-- followed by "Steam" says nothing twice, but a battery buffer has several
-- readings and they have to be told apart.
local function gaugeText(gauge, machine, room)
  local label = ""
  if gauge.label and gauge.label ~= "" and machine then
    if not machine:lower():find(gauge.label:lower(), 1, true) then
      label = gauge.label .. "  "
    end
  end
  local unit = ""
  if gauge.unit and gauge.unit ~= "" then
    unit = " " .. gauge.unit
  end
  local text = label .. string.format("%s / %s%s", tostring(gauge.current),
    tostring(gauge.maximum), unit)
  -- the satellite sends this only when its bar is drawn against a local
  -- maximum, so the real capacity is never lost
  if gauge.capacity then
    text = text .. "  of " .. tostring(gauge.capacity)
  end
  local moving = rateText(gauge)
  if moving ~= "" then
    text = text .. "   " .. moving
  end
  -- the numbers matter more than the name of the reading, so on a narrow screen
  -- the name is what gives way
  if room and label ~= "" and unicode.len(text) > room then
    return (text:sub(#label + 1))
  end
  return text
end

-------------------------------------------------------------------------------
-- how the base is laid out on screen
--
-- A base with a dozen machines on a wide screen was using a quarter of it: one
-- narrow column of blocks down the left and nothing anywhere else. These are
-- three answers to that, because which one is right depends on how much there
-- is to show and what you are looking for.

local MODES = { "columns", "cards", "alerts" }

local MODE_HELP = {
  columns = "every machine, one line each, across as many columns as fit",
  cards = "one machine at a time, roomy, with a wide bar",
  alerts = "what is wrong, and nothing that is not",
}

local mode = config.view
if not MODE_HELP[mode] then
  mode = "columns"
end

local function nextMode()
  for index, name in ipairs(MODES) do
    if name == mode then
      mode = MODES[index % #MODES + 1]
      config.view = mode
      core.saveConfig(config)
      paint.forget()
      return
    end
  end
end

-- A machine is worth showing in the alerts view when something about it is
-- wrong: an alert has it, it has been stopped, or a gauge has run dry.
local function troubled(card)
  if card.alarm or card.status == "stopped" then
    return true
  end
  for _, gauge in ipairs(card.gauges or {}) do
    if (gauge.percent or 0) <= 5 then
      return true
    end
  end
  return false
end

-- One block of rows a satellite, built before anything knows where it lands.
-- A satellite is the natural column: its machines belong together and its name
-- goes at the top of them.
local function planBlocks()
  local blocks = {}
  for _, address in ipairs(order) do
    local rows = {}
    local answer = satellites[address]
    local stale = computer.uptime() - answer.at > QUIET_SECONDS

    local shown = {}
    for _, card in ipairs(answer.cards) do
      if mode ~= "alerts" or troubled(card) then
        shown[#shown + 1] = card
      end
    end

    local alerts = {}
    for _, alert in ipairs(answer.alerts or {}) do
      if mode ~= "alerts" or alert.tripped then
        alerts[#alerts + 1] = alert
      end
    end

    if #shown > 0 or #alerts > 0 or mode ~= "alerts" then
      rows[#rows + 1] = { kind = "host", host = answer.host, stale = stale,
        machines = #answer.cards }
      for _, alert in ipairs(alerts) do
        rows[#rows + 1] = { kind = "alert", alert = alert }
      end
      for _, card in ipairs(shown) do
        if mode == "columns" and not card.compact then
          -- in this view a machine is its gauges, with its own name on each,
          -- because a name on a line of its own is a line not showing a number
          for _, gauge in ipairs(card.gauges or {}) do
            rows[#rows + 1] = { kind = "line", card = card, gauge = gauge }
          end
          if #(card.gauges or {}) == 0 then
            rows[#rows + 1] = { kind = "line", card = card }
          end
        elseif card.compact then
          for _, gauge in ipairs(card.gauges or {}) do
            rows[#rows + 1] = { kind = "line", card = card, gauge = gauge,
              indent = true }
          end
        else
          rows[#rows + 1] = { kind = "name", card = card }
          for _, gauge in ipairs(card.gauges or {}) do
            rows[#rows + 1] = { kind = "gauge", card = card, gauge = gauge }
          end
        end
      end
    end
    if #rows > 0 then
      blocks[#blocks + 1] = rows
    end
  end
  return blocks
end

local function bar(x, y, width, gauge)
  local ratio = (gauge.percent or 0) / 100
  if ratio < 0 then
    ratio = 0
  elseif ratio > 1 then
    ratio = 1
  end
  local filled = math.floor(width * ratio + 0.5)
  write(x, y, "[", DIM, BG)
  if filled > 0 then
    write(x + 1, y, string.rep(FULL_BLOCK, filled),
      core.gaugeColor(gauge, OK_COLOR), BG)
  end
  if width - filled > 0 then
    write(x + 1 + filled, y, string.rep(LIGHT_BLOCK, width - filled), DIM, BG)
  end

  -- where an alert on this reading trips, sent along with it by the satellite
  for _, share in ipairs(gauge.marks or {}) do
    local at = math.max(1, math.min(width, math.floor(width * share + 0.5)))
    write(x + at, y, MARK, FG, BG)
  end

  write(x + 1 + width, y, "]", DIM, BG)
  return x + width + 3
end

local function drawRow(row, x, y, width)
  if row.kind == "blank" then
    write(x, y, fit("", width), FG, BG)
  elseif row.kind == "host" then
    write(x, y, fit(" " .. row.host .. "   " .. row.machines .. " machines"
      .. (row.stale and "   not answering" or ""), width), FG, BAR)
  elseif row.kind == "alert" then
    local mark = "ok"
    local color = DIM
    if row.alert.tripped then
      mark = "!!"
      color = ALARM
    end
    write(x + 1, y, fit(mark .. "  " .. tostring(row.alert.name), width - 1), color, BG)
  elseif row.kind == "name" then
    write(x + 1, y, fit(row.card.name or "?", width - 13), FG, BG)
    if row.card.status then
      write(x + width - 11, y, fit(row.card.status, 11),
        statusColor(row.card.status, row.card.alarm), BG)
    end
  elseif row.kind == "gauge" then
    local at = bar(x + 3, y, math.max(8, math.min(64, width - 34)), row.gauge)
    write(at, y, fit(gaugeText(row.gauge), math.max(0, width - (at - x))), FG, BG)
  else
    -- One line: the machine's name, a bar, the numbers, and how it is doing.
    -- Every part grows with the column it is in, since a wide screen showing
    -- narrow bars against empty space was the whole reason for these views.
    local color = ALARM
    if not row.card.alarm then
      color = core.gaugeColor(row.gauge, FG)
    end
    local nameWidth = math.max(12, math.min(20, math.floor(width / 5)))
    local barWidth = math.max(6, math.min(40, math.floor(width / 4)))

    local left = x + (row.indent and 3 or 1)
    write(left, y, fit(row.card.name or "?", nameWidth), color, BG)

    local at = left + nameWidth + 1
    if row.gauge then
      at = bar(at, y, barWidth, row.gauge)
      -- the status column is only worth reserving when there is a status
      local reserved = 1
      if row.card.status then
        reserved = 12
      end
      local room = math.max(0, width - (at - x) - reserved)
      write(at, y, fit(gaugeText(row.gauge, row.card.name, room), room), DIM, BG)
    end
    if row.card.status then
      write(x + width - 11, y, fit(row.card.status, 11),
        statusColor(row.card.status, row.card.alarm), BG)
    end
  end
end

local function render()
  local trouble = problem()
  local machines, tripped = 0, 0
  for _, address in ipairs(order) do
    machines = machines + #satellites[address].cards
    for _, alert in ipairs(satellites[address].alerts or {}) do
      if alert.tripped then
        tripped = tripped + 1
      end
    end
  end

  -- A lamp beside the tablet says from across the room what the screen says up
  -- close, and this screen is watching the whole base rather than one computer.
  -- Set only on a change, since it is a call into the world.
  if tripped > 0 ~= shownTripped then
    shownTripped = tripped > 0
    if notify.usable(config, notify.find("lamp")) then
      ct.lamps(notify.lampColor(config, shownTripped))
    end
  end

  local heading = "  ocview v" .. VERSION .. "    " .. #order .. " satellites, "
    .. machines .. " machines"
  if #order == 0 then
    heading = "  ocview v" .. VERSION .. "    no data"
  end
  write(1, 1, fit(heading, W - 20), FG, BAR)
  if tripped > 0 then
    write(math.max(1, W - 19), 1, fit(tripped .. " ALERTS TRIPPED", 20), ALARM, BAR)
  else
    write(math.max(1, W - 19), 1, fit("all clear", 20), OK_COLOR, BAR)
  end

  local blocks = planBlocks()
  local body = H - 3

  -- A satellite to a column, as many as the width takes. Splitting one
  -- satellite's machines across two columns would put half a base in each,
  -- so a block stays whole and the shortest column takes the next one.
  local columns = 1
  if mode == "columns" then
    columns = math.max(1, math.min(#blocks, math.floor(W / 58)))
  end
  local width = math.floor((W - 2) / columns)

  local placed = {}
  for index = 1, columns do
    placed[index] = {}
  end
  for _, rows in ipairs(blocks) do
    local shortest = 1
    for index = 2, columns do
      if #placed[index] < #placed[shortest] then
        shortest = index
      end
    end
    for _, row in ipairs(rows) do
      placed[shortest][#placed[shortest] + 1] = row
    end
    placed[shortest][#placed[shortest] + 1] = { kind = "blank" }
  end

  for column = 1, columns do
    local x = 2 + (column - 1) * width
    for line = 0, body - 1 do
      local row = placed[column][line + 1]
      local y = 3 + line
      if row then
        drawRow(row, x, y, width - 1)
      else
        write(x, y, fit("", width - 1), FG, BG)
      end
    end
  end

  -- after the columns, which blank every row they do not fill
  if trouble then
    write(3, 3, fit(trouble, W - 4), ALARM, BG)
  end

  write(1, H, fit("  [v] view: " .. mode .. "   [r] refresh   [q] quit      "
    .. MODE_HELP[mode], W), FG, BAR)
  paint.flush(W, H, BG, FG)
end

-------------------------------------------------------------------------------

local arguments = { ... }
local once = arguments[1] == "--once"

local modem, reason = net.modem()
if not modem then
  io.stderr:write("ocview: " .. reason .. "\n")
  return 1
end

term.clear()
term.setCursorBlink(false)
paint.forget()

-- One loop, so a keypress is read the moment it arrives. Waiting for a whole
-- round of answers inside the ask is what made this ignore the keyboard for
-- seconds at a time, and what kept the screen a round behind the machines.
--
-- Backdated so the first turn of the loop asks rather than waiting a round.
local asked = computer.uptime() - REFRESH_SECONDS

while true do
  local now = computer.uptime()
  if now - asked >= REFRESH_SECONDS then
    net.ask(modem)
    asked = now
  end
  render()

  -- one screen, but not before every satellite in range has had its say
  if once and now - started >= ANSWER_TIMEOUT then
    break
  end

  local wait = math.max(0.1, asked + REFRESH_SECONDS - computer.uptime())
  local packed = table.pack(event.pull(wait))
  local name = packed[1]

  if name == "interrupted" then
    break
  elseif name == "modem_message" then
    absorb(packed)
  elseif name == "screen_resized" then
    layout()
  elseif name == "key_down" then
    local code = packed[4]
    if code == keyboard.keys.q then
      break
    elseif code == keyboard.keys.r then
      asked = 0
    elseif code == keyboard.keys.v then
      nextMode()
    end
  end
end

gpu.setForeground(FG)
-- --once exists to be looked at, so it leaves its one screen up
if not once then
  gpu.setBackground(BG)
  term.clear()
end

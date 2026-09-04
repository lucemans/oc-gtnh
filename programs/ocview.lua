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

local VERSION = "0.18.0"

-- what this machine tells the network it is running, in every report it sends
net.running("ocview", VERSION)

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
-- the view being looked at, and the key that would change it
local ACTIVE = 0x66CCFF
-- quieter than DIM, for the rules between the parts of a bar
local RULE = 0x666666

-- written as bytes rather than \u{} so the file still loads on a Lua 5.2 CPU
local FULL_BLOCK = "\226\150\136"
local LIGHT_BLOCK = "\226\150\145"
-- a thin vertical line, drawn over the bar where an alert sits, and between the
-- parts of the top and bottom bars
local MARK = "\226\148\130"
local DOT = "\226\151\143"
local WARN_MARK = "\226\150\178"

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
-- inside one blocking call. Keyed on the hostname, which is what Minitel names
-- a packet with and what everything on screen calls a satellite.
local satellites = {}
local order = {}

-- whether the lamps here are already showing trouble
local shownTripped = nil
local seen = { heard = 0, unreadable = 0 }
local started = computer.uptime()
-- two machines answering to one name, which otherwise looks like a satellite
-- that keeps going quiet
local clash = nil
-- peers learned this round are written back, so tomorrow's question reaches
-- them by name through the mesh rather than only when they are in range
local learned = false

-- What the base has written down. Fetched only while the log view is open: it
-- is a screenful of history that does not change quickly, and asking for it
-- every round on every screen would cost more than the machines do.
--
-- Kept per answering machine rather than as one list, so a round replaces what
-- that machine said instead of piling another copy of it on top.
local log = { byHost = {}, answered = 0 }

-- What each machine is running, and where it has got to in an update. Asked for
-- only while the update view is open, and answered from what ocup wrote into
-- each machine's configuration, so neither end goes to a disk for any of it.
--
--   state    nil while nothing is happening, then "told", "rebooting", "back"
--   uptime   the machine's own clock, which going backwards is the reboot
local upkeep = { byHost = {}, cursor = 1, queue = {} }

local function keeping(host)
  local kept = upkeep.byHost[host]
  if not kept then
    kept = {}
    upkeep.byHost[host] = kept
  end
  return kept
end

-- Which machine to ask, or nil for all of them. A named collector holds a copy
-- of everybody's records already, so asking it alone is the whole history and
-- asking the satellites too would hear each record twice.
local function collector()
  local named = notify.settings(config, "syslog").collector
  if named and named ~= "" then
    return named
  end
  return nil
end

local function absorbLog(from, port, data)
  local answer = net.decodeLog(port, from, data)
  if not answer then
    return false
  end

  -- An age rather than a stamp. Every machine's uptime is its own and two of
  -- them have no relation, so the only portable thing in a record is how long
  -- ago it was, measured against the clock that came with it.
  local aged = {}
  for _, record in ipairs(answer.records) do
    aged[#aged + 1] = {
      age = math.max(0, (answer.now or 0) - (record.at or 0)),
      host = record.host or answer.host,
      service = record.service,
      level = record.level,
      message = record.message,
    }
  end

  if log.byHost[answer.host] == nil then
    log.answered = log.answered + 1
  end
  log.byHost[answer.host] = aged
  return true
end

-- What the agent has put on its board, as it last answered.
local board = nil

local function absorbBoard(from, port, data)
  local answer = net.decodeBoard(port, from, data)
  if not answer then
    return false
  end
  board = answer
  return true
end

-- Every machine's records in one list, oldest last. Ages are comparable across
-- machines even though the uptimes they were worked out from are not.
local function records()
  local all = {}
  for _, kept in pairs(log.byHost) do
    for _, record in ipairs(kept) do
      all[#all + 1] = record
    end
  end
  table.sort(all, function(a, b)
    return a.age < b.age
  end)
  return all
end

local function duration(seconds)
  seconds = seconds or 0
  if seconds < 90 then
    return math.floor(seconds) .. "s"
  end
  if seconds < 5400 then
    return math.floor(seconds / 60) .. "m"
  end
  return math.floor(seconds / 3600) .. "h"
end

local function ago(record)
  return duration(record.age)
end

-- One row of the frame, drawn in pieces so each piece keeps its own colour. The
-- right hand pieces are measured first and always fit; what runs out of room is
-- the left hand side, which is ordered least important last for that reason.
local function drawBar(y, left, right)
  local width = 0
  for _, piece in ipairs(right) do
    width = width + unicode.len(piece[1])
  end
  local edge = math.max(1, W - width + 1)

  local x = 1
  for _, piece in ipairs(left) do
    if x >= edge then
      break
    end
    local text = piece[1]
    if unicode.len(text) > edge - x then
      -- two characters back, so what is cut off does not end up touching the
      -- right hand side and reading as one word with it
      text = unicode.sub(text, 1, math.max(0, edge - x - 2))
    end
    write(x, y, text, piece[2], BAR)
    x = x + unicode.len(text)
  end
  if x < edge then
    write(x, y, string.rep(" ", edge - x), FG, BAR)
  end

  x = edge
  for _, piece in ipairs(right) do
    write(x, y, piece[1], piece[2], BAR)
    x = x + unicode.len(piece[1])
  end
end

local function rule(pieces)
  pieces[#pieces + 1] = { " " .. MARK .. " ", RULE }
end

local function plural(number, what)
  if number == 1 then
    return what
  end
  return what .. "s"
end

-- A figure and what it counts, so the number is the thing the eye lands on.
local function counted(pieces, number, what)
  pieces[#pieces + 1] = { tostring(number), FG }
  pieces[#pieces + 1] = { " " .. plural(number, what), DIM }
end

-- Error and worse is the red one. Warning and notice are worth reading and
-- nothing more. Info and debug are the ones there are hundreds of.
local function levelColor(level)
  if (level or 6) <= 3 then
    return ALARM
  end
  if (level or 6) <= 5 then
    return FG
  end
  return DIM
end

-- A machine that has been round the houses. Its uptime is its own clock, so the
-- only thing it can be compared with is what the same machine said last time:
-- a number that has gone down is a machine that has been off in between.
local function absorbVersions(from, port, data)
  local answer = net.decodeVersions(port, from, data)
  if not answer then
    return false
  end

  local kept = keeping(from)
  if kept.uptime and answer.uptime < kept.uptime then
    kept.state = "back"
  elseif kept.state == "told" then
    -- it took the order and is still up, which is ocup running
    kept.state = "updating"
  end
  kept.uptime = answer.uptime
  kept.program = answer.program
  kept.installed = answer.installed
  return true
end

local function absorbUpdate(from, port, data)
  local answer = net.decodeUpdate(port, from, data)
  if not answer then
    return false
  end
  local kept = keeping(from)
  kept.state = "told"
  kept.said = answer.word
  return true
end

local function absorb(from, port, data)
  seen.heard = seen.heard + 1
  if absorbLog(from, port, data) then
    return true
  end
  if absorbBoard(from, port, data) then
    return true
  end
  if absorbVersions(from, port, data) then
    return true
  end
  if absorbUpdate(from, port, data) then
    return true
  end
  local answer, why = net.decode(port, from, data)
  if not answer then
    if why then
      seen.unreadable = seen.unreadable + 1
    end
    return false
  end

  local known = satellites[answer.host]
  if known and known.address and answer.address
    and known.address ~= answer.address then
    clash = answer.host
  end

  answer.at = computer.uptime()
  if not known then
    order[#order + 1] = answer.host
  end
  satellites[answer.host] = answer
  if net.remember(config, answer.host) then
    learned = true
  end
  return true
end

-- A satellite on the peer list that has said nothing this run. It was heard
-- from once, so its silence is news rather than a machine that was never there.
local function missing()
  local quiet = {}
  for _, host in ipairs(net.peers(config)) do
    if not satellites[host] then
      quiet[#quiet + 1] = host
    end
  end
  return quiet
end

-- Saying only "no answer" hides which half is broken. Whether anything at all
-- arrived separates a satellite that never heard the question from one that
-- answered with something unreadable.
local function problem()
  if clash then
    return "two machines are both called " .. clash .. ": rename one of them"
  end
  if #order > 0 then
    local quiet = missing()
    if #quiet > 0 then
      return "no answer from " .. table.concat(quiet, ", ")
    end
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

local MODES = { "columns", "cards", "alerts", "log", "board", "update" }

local MODE_HELP = {
  columns = "every machine, one line each, across as many columns as fit",
  cards = "one machine at a time, roomy, with a wide bar",
  alerts = "what is wrong, and nothing that is not",
  log = "what the base has written down, newest first",
  board = "what the agent has put up to be looked at",
  update = "what every machine is running, and the way to move it on",
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

-- The two bars, drawn together because they answer the same question between
-- them: what am I looking at, and what else could I look at.
--
-- The top counts what is on screen and says whether anything is wrong. The
-- bottom is every view there is, with this one lit, which is a good deal more
-- discoverable than naming the current one and leaving the rest to be found.
local function drawBars(tripped, machines)
  local left = { { "  ocview ", DIM }, { VERSION, DIM } }

  if mode == "log" then
    local kept = records()
    local bad = 0
    for _, record in ipairs(kept) do
      if (record.level or 6) <= 3 then
        bad = bad + 1
      end
    end
    rule(left)
    counted(left, #kept, "record")
    rule(left)
    if collector() then
      left[#left + 1] = { "from ", DIM }
      left[#left + 1] = { collector(), FG }
    else
      counted(left, log.answered, "machine")
    end
    if bad > 0 then
      rule(left)
      left[#left + 1] = { bad .. " " .. plural(bad, "error"), ALARM }
    end
  elseif mode == "board" then
    rule(left)
    if board then
      counted(left, #board.lines, "line")
      rule(left)
      left[#left + 1] = { "from ", DIM }
      left[#left + 1] = { board.host, FG }
    else
      left[#left + 1] = { "no board yet", DIM }
    end
  elseif mode == "update" then
    -- how many commits the base is spread across. One is a base that agrees
    -- with itself, which is the only reading anybody wants off this screen.
    local commits, spread = {}, 0
    for _, host in ipairs(order) do
      local at = satellites[host].commit or "?"
      if not commits[at] then
        commits[at] = true
        spread = spread + 1
      end
    end
    rule(left)
    counted(left, #order, "satellite")
    rule(left)
    if spread <= 1 then
      left[#left + 1] = { "all on one commit", DIM }
    else
      left[#left + 1] = { tostring(spread), FG }
      left[#left + 1] = { " different commits", ALARM }
    end
  elseif #order == 0 then
    rule(left)
    left[#left + 1] = { "no data", DIM }
  else
    rule(left)
    counted(left, #order, "satellite")
    rule(left)
    counted(left, machines, "machine")
  end

  local right
  if tripped > 0 then
    right = { { WARN_MARK .. " ", ALARM },
      { tripped .. " " .. plural(tripped, "alert") .. "  ", ALARM } }
  else
    right = { { DOT .. " ", OK_COLOR }, { "all clear  ", DIM } }
  end
  drawBar(1, left, right)

  local bottom = { { "  ", DIM } }
  for index, name in ipairs(MODES) do
    if index > 1 then
      rule(bottom)
    end
    bottom[#bottom + 1] = { name, name == mode and ACTIVE or DIM }
  end
  bottom[#bottom + 1] = { "   " .. MODE_HELP[mode], RULE }

  local keys = {
    { "v", ACTIVE }, { " view  ", DIM },
    { "r", ACTIVE }, { " refresh  ", DIM },
    { "q", ACTIVE }, { " quit  ", DIM },
  }
  if mode == "update" then
    keys = {
      { "u", ACTIVE }, { " update  ", DIM },
      { "a", ACTIVE }, { " all  ", DIM },
      { "v", ACTIVE }, { " view  ", DIM },
      { "q", ACTIVE }, { " quit  ", DIM },
    }
  end
  drawBar(H, bottom, keys)
end

-- Which of two versions is further on. Compared a number at a time rather than
-- as text, because 0.9.0 sorts after 0.10.0 in every comparison of strings and
-- that is exactly the pair this has to get right.
local function newer(a, b)
  local left, right = {}, {}
  for part in tostring(a or ""):gmatch("%d+") do
    left[#left + 1] = tonumber(part)
  end
  for part in tostring(b or ""):gmatch("%d+") do
    right[#right + 1] = tonumber(part)
  end
  for index = 1, math.max(#left, #right) do
    local one, two = left[index] or 0, right[index] or 0
    if one ~= two then
      return one > two
    end
  end
  return false
end

local function filesOf(kept)
  return kept and kept.installed and kept.installed.files or {}
end

-- The furthest-on copy of each file anywhere in the base. This is the closest
-- thing to "the latest" that a tablet can work out without asking GitHub, and
-- it is the useful comparison anyway: a base where every machine agrees is a
-- base that is fine, whatever the repository has moved on to since.
local function latestKnown()
  local best = {}
  for _, kept in pairs(upkeep.byHost) do
    for source, version in pairs(filesOf(kept)) do
      if not best[source] or newer(version, best[source]) then
        best[source] = version
      end
    end
  end
  return best
end

local function behindOn(kept, best)
  local out = {}
  for source, version in pairs(best) do
    local mine = filesOf(kept)[source]
    if mine ~= version then
      out[#out + 1] = { source = source, mine = mine, best = version }
    end
  end
  table.sort(out, function(one, two)
    return one.source < two.source
  end)
  return out
end

-- how long a machine that has taken the order is given to fetch, reboot and
-- answer again before the queue stops waiting for it and moves on
local UPDATE_TIMEOUT = 180

-- Where a machine has got to. Read out of what it last said rather than kept as
-- a state machine: a machine that took the order and then went quiet is one
-- that is rebooting, and that is the same fact as its answers having stopped.
local function stateOf(host)
  local kept = upkeep.byHost[host]
  if not kept or not kept.state then
    return nil
  end
  if kept.state == "back" then
    return "back up", OK_COLOR
  end
  if kept.state == "lost" then
    return "no answer", ALARM
  end
  local answer = satellites[host]
  if not answer or computer.uptime() - answer.at > QUIET_SECONDS then
    return "rebooting", ACTIVE
  end
  return kept.state, ACTIVE
end

local function busy(host)
  local kept = upkeep.byHost[host]
  return kept ~= nil and (kept.state == "told" or kept.state == "updating")
end

-- Every machine this screen can act on: the ones that have answered, and the
-- ones on the peer list that have not, since a satellite that has gone quiet is
-- exactly the one somebody wants to prod.
local function updateRows()
  local rows = {}
  for _, host in ipairs(order) do
    rows[#rows + 1] = { host = host }
  end
  for _, host in ipairs(missing()) do
    rows[#rows + 1] = { host = host }
  end
  return rows
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

local function problematic(alert)
  return alert.tripped and alert.trouble ~= false
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
      if mode ~= "alerts" or problematic(alert) then
        alerts[#alerts + 1] = alert
      end
    end

    if #shown > 0 or #alerts > 0 or mode ~= "alerts" then
      rows[#rows + 1] = { kind = "host", host = answer.host, stale = stale,
        machines = #answer.cards }
      for _, alert in ipairs(alerts) do
        rows[#rows + 1] = { kind = "alert", alert = alert }
      end
      -- what the item network is doing, from a satellite that watches one. The
      -- alerts view is for what is wrong, and a stock moving is not that.
      if mode ~= "alerts" and (answer.items or {})[1] then
        rows[#rows + 1] = { kind = "heading",
          text = "changing, " .. (answer.over or "lately") }
        for _, item in ipairs(answer.items) do
          rows[#rows + 1] = { kind = "item", item = item }
        end
      end
      -- and what the fluid network holds. The whole stock is worth a line where
      -- an item is only worth one while it moves: a base keeps tens of fluids,
      -- and how much lubricant there is left is the question being asked.
      if mode ~= "alerts" and (answer.fluids or {})[1] then
        rows[#rows + 1] = { kind = "heading", text = "fluids, mB" }
        for _, fluid in ipairs(answer.fluids) do
          rows[#rows + 1] = { kind = "fluid", fluid = fluid }
        end
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
    write(x, y, fit(" " .. row.host .. "   " .. row.machines .. " "
      .. plural(row.machines, "machine")
      .. (row.stale and "   not answering" or ""), width), FG, BAR)
  elseif row.kind == "alert" then
    local mark = "ok"
    local color = DIM
    if problematic(row.alert) then
      mark = "!!"
      color = ALARM
    end
    write(x + 1, y, fit(mark .. "  " .. tostring(row.alert.name), width - 1), color, BG)
  elseif row.kind == "heading" then
    write(x + 1, y, fit(row.text, width - 1), DIM, BG)
  elseif row.kind == "item" then
    local rate = row.item.rate or 0
    local said = (rate > 0 and "+" or "") .. core.comma(rate)
    write(x + 1, y, string.rep(" ", math.max(0, 9 - unicode.len(said))) .. said,
      rate > 0 and OK_COLOR or ALARM, BG)
    write(x + 11, y, fit(tostring(row.item.name), math.max(0, width - 11)),
      FG, BG)
  elseif row.kind == "fluid" then
    -- The amount first, because that is the question, and what it is doing
    -- against the right edge where the eye can run down it. A fluid is counted
    -- in millibuckets, so the figure is wider than an item count.
    local amount = core.comma(row.fluid.amount or 0)
    write(x + 1, y, string.rep(" ", math.max(0, 12 - unicode.len(amount)))
      .. amount, FG, BG)
    local rate = row.fluid.rate or 0
    local moving = ""
    if rate ~= 0 then
      moving = (rate > 0 and "+" or "") .. core.comma(rate)
    end
    -- a satellite on its own gets the whole screen for a column, and a rate
    -- pushed to the far edge of that is a figure nobody can tie to its name
    local span = math.min(width, 48)
    local room = math.max(0, span - 14)
    if moving ~= "" then
      room = math.max(0, room - unicode.len(moving) - 1)
    end
    write(x + 14, y, fit(tostring(row.fluid.name), room), DIM, BG)
    if moving ~= "" then
      write(x + span - unicode.len(moving), y, moving,
        rate > 0 and OK_COLOR or ALARM, BG)
    end
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
      if problematic(alert) then
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

  drawBars(tripped, machines)

  -- The same: a list of machines rather than a base of them, read top to bottom
  -- and acted on a row at a time.
  if mode == "update" then
    local best = latestKnown()
    local rows = updateRows()
    upkeep.cursor = math.max(1, math.min(upkeep.cursor, math.max(1, #rows)))

    for line = 0, H - 4 do
      write(2, 3 + line, fit("", W - 2), FG, BG)
    end

    if #rows == 0 then
      write(3, 3, fit("no satellite has answered yet", W - 4), DIM, BG)
      paint.flush(W, H, BG, FG)
      return
    end

    for index, row in ipairs(rows) do
      local y = 2 + index
      if y >= H then
        break
      end
      local here = index == upkeep.cursor
      local word, color = stateOf(row.host)
      local kept = upkeep.byHost[row.host] or {}
      local answer = satellites[row.host] or {}
      local running = answer.program or kept.program
      write(2, y, fit(string.format("%s%-14s %-16s %-8s %-7s %s",
        here and "> " or "  ",
        row.host,
        running and (running.name .. " v" .. running.version) or "-",
        (answer.commit or "-"):sub(1, 7),
        kept.uptime and ("up " .. duration(kept.uptime)) or "",
        word or ""), W - 2), color or (here and FG or DIM), BG)
    end

    -- What the selected machine is behind on, against the furthest-on copy of
    -- each file anywhere in the base. Nothing here knows what the repository
    -- holds, and does not need to: a machine behind the one beside it is the
    -- whole question this screen exists to answer.
    local chosen = rows[upkeep.cursor]
    local detail = 3 + math.min(#rows, H - 4) + 1
    if chosen and detail < H then
      local off = behindOn(upkeep.byHost[chosen.host], best)
      if not upkeep.byHost[chosen.host] or not upkeep.byHost[chosen.host].installed then
        write(3, detail, fit(chosen.host .. " has not said what it is running",
          W - 4), DIM, BG)
      elseif #off == 0 then
        write(3, detail, fit(chosen.host .. " has what the rest of the base has",
          W - 4), OK_COLOR, BG)
      else
        write(3, detail, fit(chosen.host .. " is behind on " .. #off .. " "
          .. plural(#off, "file"), W - 4), ALARM, BG)
        for index, file in ipairs(off) do
          local y = detail + index
          if y >= H then
            break
          end
          write(5, y, fit(string.format("%-26s %-9s base has %s",
            file.source, file.mine or "-", file.best), W - 6), DIM, BG)
        end
      end
    end

    paint.flush(W, H, BG, FG)
    return
  end

  -- The log is a list rather than a base, so it does not go through the block
  -- and column machinery at all: no satellite owns these lines, and they are
  -- read top to bottom rather than scanned.
  if mode == "log" then
    local kept = records()
    for line = 0, H - 4 do
      local record = kept[line + 1]
      local y = 3 + line
      if not record then
        write(2, y, fit("", W - 2), FG, BG)
      else
        write(2, y, fit(string.format("%4s  %-12s %-9s ", ago(record),
          tostring(record.host), tostring(record.service))
          .. tostring(record.message), W - 2), levelColor(record.level), BG)
      end
    end
    if log.answered == 0 then
      write(3, 3, fit("asking " .. (collector() or "every machine")
        .. " what has been written down", W - 4), DIM, BG)
    elseif #kept == 0 then
      write(3, 3, fit(log.answered .. " " .. plural(log.answered, "machine")
        .. " answered, and none of them has "
        .. "written anything down yet", W - 4), DIM, BG)
    end
    paint.flush(W, H, BG, FG)
    return
  end

  -- The board is the agent's, drawn as it wrote it: a title, a rule, and
  -- its lines, and nothing of the base's own.
  if mode == "board" then
    if board then
      write(2, 3, fit(board.title, W - 2), FG, BG)
      write(2, 4, string.rep("-", W - 2), DIM, BG)
      for line = 1, H - 6 do
        write(2, 4 + line, fit(board.lines[line] or "", W - 2), FG, BG)
      end
    else
      write(3, 3, fit("asking the agent what is on its board", W - 4), DIM, BG)
    end
    paint.flush(W, H, BG, FG)
    return
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

  paint.flush(W, H, BG, FG)
end

-------------------------------------------------------------------------------

local arguments = { ... }
local once = arguments[1] == "--once"

-- Answers arrive whenever they arrive, so they are taken in here and drawn by
-- the loop below. A listener that drew would repaint the screen from inside
-- whatever event.pull happened to be running.
local heard = net.listen(absorb)

local minitel, reason = net.up()
if not minitel then
  net.deafen(heard)
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
    net.ask(minitel, config)
    -- only while somebody is looking at it: the history is a screenful that
    -- barely changes, and the machines are what the other views are for
    if mode == "log" then
      net.askLog(minitel, config, collector())
    end
    if mode == "board" then
      net.askBoard(minitel, config)
    end
    -- the same rule: what a machine is running is worth a packet only while
    -- somebody is looking at the screen that shows it
    if mode == "update" then
      net.askVersions(minitel, config)
    end
    asked = now
  end

  -- One machine at a time. Twelve satellites all fetching at once go through
  -- one gateway and one internet card, and a base with every computer rebooting
  -- together is a base watching nothing at all for as long as it takes.
  if upkeep.queue[1] then
    local waiting = upkeep.told ~= nil and busy(upkeep.told)
    -- A machine that fetched through a gateway that went down first, or that
    -- came up into something that does not run, never answers again. Waiting
    -- for it forever is a queue that silently stops, so it is given up on and
    -- said so on the screen.
    if waiting and now - upkeep.sentAt > UPDATE_TIMEOUT then
      keeping(upkeep.told).state = "lost"
      waiting = false
    end
    if not waiting then
      local host = table.remove(upkeep.queue, 1)
      net.tellUpdate(minitel, host)
      keeping(host).state = "told"
      upkeep.told, upkeep.sentAt = host, now
    end
  end
  -- a satellite heard from for the first time is worth keeping, and the round
  -- it was heard in is the only time anything here has a reason to write
  if learned then
    core.saveConfig(config)
    learned = false
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
    elseif mode == "update" then
      local rows = updateRows()
      if code == keyboard.keys.up and upkeep.cursor > 1 then
        upkeep.cursor = upkeep.cursor - 1
      elseif code == keyboard.keys.down and upkeep.cursor < #rows then
        upkeep.cursor = upkeep.cursor + 1
      elseif code == keyboard.keys.u and rows[upkeep.cursor] then
        upkeep.queue[#upkeep.queue + 1] = rows[upkeep.cursor].host
      elseif code == keyboard.keys.a then
        -- The gateway goes last on purpose. Every machine without an internet
        -- card fetches through it, so a gateway that rebooted first would take
        -- the rest of the base's only way of getting anything with it.
        local gateway = config.gateway
        for _, row in ipairs(rows) do
          if row.host ~= gateway then
            upkeep.queue[#upkeep.queue + 1] = row.host
          end
        end
        for _, row in ipairs(rows) do
          if row.host == gateway then
            upkeep.queue[#upkeep.queue + 1] = row.host
          end
        end
      end
    end
  end
end

net.deafen(heard)
gpu.setForeground(FG)
-- --once exists to be looked at, so it leaves its one screen up
if not once then
  gpu.setBackground(BG)
  term.clear()
end

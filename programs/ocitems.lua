-- ocitems: everything the Logistics Pipes network holds, the most of it first.
--
--   ocitems
--
-- There are three ways to bring the counts up to date and the machine picks
-- between them by what it can afford. A read of the network is every count at
-- once; reading the names out of it as well is what takes the time, so most
-- reads are taken as counts alone against the names the last full one
-- established. Either way a read is about 950 KB in a single go, which is why
-- it happens only when the memory is there. Counting one item at a time costs a
-- server tick each and finds nothing new, and is what a machine without that
-- memory is left with.
--
-- The fluid network is a second pipe answering a different question, and it is
-- nothing like the same job: getAvailableFluids brings every name and every
-- amount back in one small call, so it is simply read on a clock.
--
-- A machine with a network card answers for what it is watching as well as
-- showing it, since it is the only one that can see either network at all.
--
-- [r] reads the network again now. It is refused when the memory for it is not
-- there, because asking anyway does not fail the call, it ends the computer.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local keyboard = require("keyboard")
local lp = require("oclogistics")
local net = require("ocnet")
local gtp = require("ocgtp")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.15.0"

-- what this machine tells the network it is running, in every report it sends
net.running("ocitems", VERSION)

local CACHE = "/etc/ocitems.cache"

-- how many items are counted between two draws. Each one costs a server tick,
-- so this is also how long a keypress can be left waiting.
local PER_DRAW = 4
-- how long the loop listens before it goes back to counting
local REST = 0.2
-- how often the screen is drawn anyway, for the memory figure in the bar
local HEARTBEAT = 2
-- What has to be free before the network is read at all, which the library
-- settles because it is also what a scan has to leave behind.
local ROOM = lp.ROOM
-- How long between reads, on a machine with room for them. A counted read is
-- quick — a tenth of a second against three — but it costs the same memory as
-- any other, so how often one can really happen is settled by the guard above
-- rather than by this.
local COUNTED = 5
local NAMED = 120
-- how long between reads of the fluid network, which is one call and answers
-- with the names as well, so nothing about the item side applies to it
local FLUIDS = 10

local gpu = component.gpu
local paint = core.painter(gpu)

-- a count, then the name beside it: three of those and a panel across a
-- 160-wide screen
local NARROWEST = 34
local COUNT_W = 10
local PANEL_W = 34
-- A fluid is measured in millibuckets and a base holds millions of them, so the
-- figure is wider than an item count and the panel it sits in is wider with it.
local FLUID_W = 40
local FLUID_COUNT_W = 12

-- whether there is a fluid network here at all, which settles the layout and is
-- known before the first draw
local fluidProxy

local W, H, TOP, BOTTOM, ROWS, COLUMNS, COLUMN_W, PANEL_X, FLUID_X, MOVERS

local function layout()
  W, H = core.viewport(gpu)
  TOP = 3
  BOTTOM = H - 1
  ROWS = BOTTOM - TOP + 1

  -- a panel only earns its place while a column of items is still left over
  local grid = W - PANEL_W
  PANEL_X = grid >= NARROWEST and grid + 1 or nil
  grid = PANEL_X and grid or W

  -- the fluids go between the items and what is moving, because both of those
  -- are lists of what the base holds and the other panel is a list of news
  FLUID_X = nil
  if fluidProxy and grid - FLUID_W >= NARROWEST then
    grid = grid - FLUID_W
    FLUID_X = grid + 1
  end

  COLUMNS = math.max(1, math.floor(grid / NARROWEST))
  COLUMN_W = math.floor(grid / COLUMNS)
  -- as many risers and fallers as the panel has room for. A short list was
  -- hiding changes on a screen with rows to spare.
  MOVERS = math.max(3, math.floor((ROWS - 1) / 2))
  paint.forget()
end

layout()

local BG = 0x000000
local FG = 0xFFFFFF
local DIM = 0x999999
local BAR = 0x333333
local VALUE = 0x66CC66
local FAILED = 0xCC6666

local function fit(text, width)
  local length = unicode.len(text)
  if length > width then
    return unicode.sub(text, 1, width)
  end
  return text .. string.rep(" ", width - length)
end

local function right(text, width)
  local length = unicode.len(text)
  if length > width then
    return unicode.sub(text, 1, width)
  end
  return string.rep(" ", width - length) .. text
end

local items, total, note = {}, 0, nil
local fluids = {}
local movers = {}
local scroll = 0
local cursor = 1
local lastRead, lastCount, lastFluids = 0, 0, 0
local proxy, builder, minitel
-- questions arrive whenever they arrive, and are answered by the loop
local pending = {}
-- when this machine next tells the telemetry service what it can see
local telemetryDue = 0

-------------------------------------------------------------------------------
-- what was written down last time

local function readCache()
  local file = io.open(CACHE, "r")
  if not file then
    return nil
  end
  local text = file:read("*a") or ""
  file:close()

  local network = text:match("^ocitems (%d+)\n")
  if not network then
    return nil
  end

  local kept = {}
  for line in text:gmatch("[^\n]+") do
    local itemId, itemData, amount, name =
      line:match("^(%d+) (%d+) (%d+) (.*)$")
    if itemId then
      kept[#kept + 1] = {
        itemId = tonumber(itemId),
        itemData = tonumber(itemData),
        key = itemId .. ":" .. itemData,
        amount = tonumber(amount),
        name = name,
      }
    end
  end

  if not kept[1] then
    return nil
  end
  return kept, tonumber(network)
end

local function writeCache()
  local file = io.open(CACHE, "w")
  if not file then
    return
  end
  file:write("ocitems " .. total .. "\n")
  for _, item in ipairs(items) do
    file:write(string.format("%d %d %d %s\n", item.itemId, item.itemData,
      item.amount, item.name))
  end
  file:close()
end

local function order()
  table.sort(items, function(a, b) return a.amount > b.amount end)
end

-- reading the whole network is the slow part of a run and it is silent
local function saying(text)
  paint.write(3, TOP, fit(text, W - 2), DIM, BG)
  paint.flush(W, H, BG, FG)
end

-------------------------------------------------------------------------------

local function scan()
  local fresh, answer = lp.available(proxy)
  if not fresh then
    note = tostring(answer)
    return
  end
  items = lp.merge(items, fresh, computer.uptime())
  total, note = answer, nil
  lastRead = computer.uptime()
  order()
  movers = lp.movers(items, MOVERS)
  writeCache()
end

-- A few items, between draws. The pass runs on round after round, and the order
-- is only settled at the end of one, so rows do not jump about while it is
-- going on.
local function count()
  if not builder or not items[1] then
    return false
  end
  local finished
  cursor, finished = lp.sweep(proxy, builder, items, cursor, PER_DRAW)
  if finished then
    order()
    movers = lp.movers(items, MOVERS)
    writeCache()
  end
  return true
end

-- Three ways to bring the counts up to date, in order of what they cost.
--
-- A counted read is every count in the network for about a tenth of a second,
-- against three seconds for a named one, because reading the names is nearly
-- all of the work. So the counted read is the one that runs often and is what
-- makes a withdrawal show up within seconds rather than within a minute. It
-- only holds while the network answers in the same order, which it says whether
-- it did; when it did not, the list is read properly instead.
--
-- A named read runs on a slower clock. It is the only thing that finds an item
-- nobody has ever had, and it settles where everything sits in the answer,
-- which is what the counted read leans on.
--
-- Counting an item at a time is the slowest by far, a server tick each, and it
-- is only what a machine without the memory for a read is left with. It used to
-- run between reads as well, which was worse than useless: it spent a tick an
-- item to learn what the next read would say in a tenth of a second, for every
-- item at once.
--
-- It is also the way out of running short. Memory comes back only under the
-- pressure of asking for more, so a machine whose last read has not been
-- cleared up counts instead, and the counting is what makes the next read
-- affordable again.
local function readFluids(now)
  local fresh = lp.fluids(fluidProxy)
  if not fresh then
    return false
  end
  -- a read hands back new tables, and the window a rate is measured over lives
  -- on the old ones, exactly as it does for an item
  fluids = lp.merge(fluids, fresh, now)
  return true
end

local function refresh()
  local now = computer.uptime()
  local changed = false

  -- The fluid network is one small call that brings the names and the amounts
  -- back together, so none of what follows about memory applies to it and it
  -- happens whether or not the item side can afford anything.
  if fluidProxy and now - lastFluids >= FLUIDS then
    lastFluids = now
    changed = readFluids(now)
  end

  -- Where a read is out of reach there is nothing else to do, so the counting
  -- runs on. Where a read is affordable the counting is worse than useless: a
  -- read brings every count in the network for a tenth of a second, and the
  -- counting would spend a server tick an item to learn what a read has just
  -- said.
  -- A low reading is usually the last read waiting to be collected rather than
  -- memory that has gone, and nothing here makes the collector run on its own.
  -- Taking the figure at its word is what made a read wait for the one after
  -- it, and a change take twenty seconds to appear instead of five.
  if not proxy then
    return changed
  end

  if computer.freeMemory() < ROOM and lp.reclaim() < ROOM then
    return count() or changed
  end

  if now - lastRead >= NAMED then
    scan()
    return true
  end

  if now - lastCount >= COUNTED then
    lastCount = now
    if lp.recount(proxy, items, total, now) then
      movers = lp.movers(items, MOVERS)
    else
      scan()
    end
    return true
  end

  return changed
end

local function render()
  paint.write(1, 1, fit("  ocitems v" .. VERSION .. "    "
    .. core.comma(total) .. " items in the network"
    .. (minitel and ", answering for it" or ""), W - 22), FG, BAR)
  paint.write(math.max(1, W - 21), 1,
    fit(math.floor(computer.freeMemory() / 1024) .. " KB free", 22), DIM, BAR)

  for row = 0, ROWS - 1 do
    for column = 0, COLUMNS - 1 do
      local item = items[(scroll + row) * COLUMNS + column + 1]
      local x = column * COLUMN_W + 1
      if item then
        paint.write(x, TOP + row, right(core.comma(item.amount), COUNT_W),
          VALUE, BG)
        paint.write(x + COUNT_W + 1, TOP + row,
          fit(item.name, COLUMN_W - COUNT_W - 2), FG, BG)
      end
    end
  end

  -- What the fluid network holds, most of it first. A fluid moving is shown
  -- beside it rather than in the panel next door: an item count and a figure in
  -- millibuckets are not the same size of number, and a row of them sorted
  -- together says nothing.
  if FLUID_X then
    paint.write(FLUID_X, TOP,
      fit("  " .. #fluids .. " fluids, mB", FLUID_W), DIM, BAR)
    for rank = 1, ROWS - 1 do
      local fluid = fluids[rank]
      local y = TOP + rank
      if fluid and y <= BOTTOM then
        local moving = ""
        if fluid.rate and fluid.rate ~= 0 then
          moving = (fluid.rate > 0 and "+" or "") .. core.comma(fluid.rate)
        end
        local room = FLUID_W - FLUID_COUNT_W - 1
        if moving ~= "" then
          room = room - unicode.len(moving) - 1
        end
        paint.write(FLUID_X, y, right(core.comma(fluid.amount), FLUID_COUNT_W),
          VALUE, BG)
        paint.write(FLUID_X + FLUID_COUNT_W + 1, y, fit(fluid.name, room), FG, BG)
        if moving ~= "" then
          paint.write(FLUID_X + FLUID_W - unicode.len(moving), y, moving,
            fluid.rate > 0 and VALUE or FAILED, BG)
        end
      end
    end
  end

  if PANEL_X then
    paint.write(PANEL_X, TOP, fit("  changing, " .. lp.OVER, PANEL_W), DIM, BAR)
    for rank, item in ipairs(movers) do
      local y = TOP + rank
      if y <= BOTTOM then
        paint.write(PANEL_X, y, right((item.rate > 0 and "+" or "")
          .. core.comma(item.rate), COUNT_W), item.rate > 0 and VALUE or FAILED, BG)
        paint.write(PANEL_X + COUNT_W + 1, y,
          fit(item.name, PANEL_W - COUNT_W - 2), FG, BG)
      end
    end
  end

  if note then
    paint.write(3, TOP, fit(note, W - 2), FAILED, BG)
  end

  paint.write(1, H, fit("  [up/down] scroll   [r] read the network again"
    .. "   [q] quit", W - 24), FG, BAR)
  paint.write(math.max(1, W - 23), H,
    fit(core.comma(#items) .. " tracked", 24), DIM, BAR)
  paint.flush(W, H, BG, FG)
end

local function move(rows)
  local last = math.max(0, math.ceil(#items / COLUMNS) - ROWS)
  scroll = math.max(0, math.min(last, scroll + rows))
end

-------------------------------------------------------------------------------

term.clear()
term.setCursorBlink(false)
paint.forget()

-- The machine watching the item network is the only one that can say what it
-- holds, so it answers for it as well as showing it. A network card is not
-- required: without one this is a screen and nothing more.
local config = core.loadConfig()
local heard = net.listen(function(from, port, data)
  pending[#pending + 1] = { from = from, port = port, data = data }
end)
minitel = net.up()
if not minitel then
  net.deafen(heard)
end

proxy = lp.requestPipe()
-- A fluid request pipe is a block of its own, so a base can have one network
-- and not the other. Finding it is what decides whether the screen keeps room
-- for the fluids, which is why the layout is settled again here.
fluidProxy = lp.fluidPipe()
layout()

if not proxy and not fluidProxy then
  note = lp.pipes()[1] and "no request pipe attached"
    or "no Logistics Pipe attached"
end

if proxy then
  builder = lp.builder(proxy)

  local kept, network = readCache()
  if kept then
    items, total = kept, network
  else
    saying("reading the network, this takes a moment")
    scan()
  end
end

if fluidProxy then
  lastFluids = computer.uptime()
  readFluids(lastFluids)
end

-- Drawing is not free: every cell on the screen is built again to find out
-- whether it changed, and doing that twenty times a second to show a list that
-- moves every ten was most of what this program spent its time on. So it draws
-- when something has happened, and once in a while regardless for the clock and
-- the memory in the bar.
local shown = 0
local changed = true

while true do
  if changed or computer.uptime() - shown >= HEARTBEAT then
    render()
    shown, changed = computer.uptime(), false
  end

  local packed = table.pack(event.pull(REST))
  local name = packed[1]

  while pending[1] do
    local packet = table.remove(pending, 1)
    local report = packet.data == net.ASK
      and net.report(config, net.machines(config), movers, fluids) or nil
    local _, command =
      net.answer(minitel, config, packet.port, packet.from, packet.data, report)
    if command == "update" then
      -- the machine goes down inside this, so nothing after it runs
      net.deafen(heard)
      net.applyUpdate()
    end
  end

  if name == nil then
    -- what this machine can see of the fluid network, for whoever collects it.
    -- The clock is checked before reading, because reading every machine costs
    -- a server tick each and this loop turns over constantly.
    if gtp.wanted(minitel, config) and computer.uptime() >= telemetryDue then
      telemetryDue = gtp.submit(minitel, config,
        net.report(config, net.machines(config), movers, fluids))
    end
    changed = refresh()
  elseif name == "interrupted" then
    break
  elseif name == "screen_resized" then
    layout()
    move(0)
    changed = true
  elseif name == "key_down" then
    changed = true
    local code = packed[4]
    if code == keyboard.keys.q then
      break
    elseif code == keyboard.keys.r then
      if fluidProxy then
        lastFluids = computer.uptime()
        readFluids(lastFluids)
      end
      if not proxy then
        note = nil
      elseif computer.freeMemory() < ROOM and lp.reclaim() < ROOM then
        note = "not enough memory to read the whole network again yet"
      else
        note = nil
        saying("reading the network again")
        scan()
      end
    elseif code == keyboard.keys.up then
      move(-1)
    elseif code == keyboard.keys.down then
      move(1)
    elseif code == keyboard.keys.pageUp then
      move(-ROWS)
    elseif code == keyboard.keys.pageDown then
      move(ROWS)
    end
  elseif name == "scroll" then
    move(packed[5] > 0 and -1 or 1)
    changed = true
  end
end

net.deafen(heard)
gpu.setForeground(FG)
gpu.setBackground(BG)
term.clear()

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
-- A machine with a network card answers for what it is watching as well as
-- showing it, since it is the only one that can see the item network at all.
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
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.10.0"

local CACHE = "/etc/ocitems.cache"

-- how many items are counted between two draws. Each one costs a server tick,
-- so this is also how long a keypress can be left waiting.
local PER_DRAW = 4
-- how long the loop listens before it goes back to counting
local REST = 0.2
-- how often the screen is drawn anyway, for the memory figure in the bar
local HEARTBEAT = 2
-- What has to be free before the network is read at all. The read itself is
-- about 950 KB in a single go, and a computer that goes into it with less than
-- that does not fail the call, it dies. The margin over 950 is not spare: three
-- reads in a row killed a server with 3.3 MB free, because the collector had
-- not given the first two back yet, so what this really asks is whether the
-- last read has been cleared up.
local ROOM = 1600 * 1024
-- How long between reads, on a machine with room for them. A counted read is
-- quick — a tenth of a second against three — but it costs the same memory as
-- any other, so how often one can really happen is settled by the guard above
-- rather than by this.
local COUNTED = 10
local NAMED = 120

local gpu = component.gpu
local paint = core.painter(gpu)

-- a count, then the name beside it: three of those and a panel across a
-- 160-wide screen
local NARROWEST = 34
local COUNT_W = 10
local PANEL_W = 34

local W, H, TOP, BOTTOM, ROWS, COLUMNS, COLUMN_W, PANEL_X, MOVERS

local function layout()
  W, H = core.viewport(gpu)
  TOP = 3
  BOTTOM = H - 1
  ROWS = BOTTOM - TOP + 1

  -- the panel only earns its place while a column of items is still left
  local grid = W - PANEL_W
  PANEL_X = grid >= NARROWEST and grid + 1 or nil
  grid = PANEL_X and grid or W
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
local movers = {}
local scroll = 0
local cursor = 1
local lastRead, lastCount = 0, 0
local proxy, builder, modem

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
local function refresh()
  local now = computer.uptime()

  -- Where a read is out of reach there is nothing else to do, so the counting
  -- runs on. Where a read is affordable the counting is worse than useless: a
  -- read brings every count in the network for a tenth of a second, and the
  -- counting would spend a server tick an item to learn what a read has just
  -- said.
  if computer.freeMemory() < ROOM then
    return count()
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

  return false
end

local function render()
  paint.write(1, 1, fit("  ocitems v" .. VERSION .. "    "
    .. core.comma(total) .. " items in the network"
    .. (modem and ", answering for it" or ""), W - 22), FG, BAR)
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
modem = net.modem()

proxy = lp.requestPipe()
if not proxy then
  note = lp.pipes()[1] and "no request pipe attached"
    or "no Logistics Pipe attached"
else
  builder = lp.builder(proxy)

  local kept, network = readCache()
  if kept then
    items, total = kept, network
  else
    saying("reading the network, this takes a moment")
    scan()
  end
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

  if name == nil then
    changed = refresh()
  elseif name == "modem_message" and modem then
    net.answer(modem, packed[4], packed[3], packed[6], config,
      net.report(config, net.machines(config), movers))
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
      if computer.freeMemory() < ROOM then
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

gpu.setForeground(FG)
gpu.setBackground(BG)
term.clear()

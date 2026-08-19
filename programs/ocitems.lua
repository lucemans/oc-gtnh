-- ocitems: everything the Logistics Pipes network holds, the most of it first.
--
--   ocitems
--
-- There are two ways to bring the counts up to date. Reading the whole network
-- is every count at once and the only way an item nobody has ever had appears,
-- and it costs about 950 KB in a single go. Counting one item at a time costs a
-- server tick each and finds nothing new. So the machine decides: with the
-- memory for a read it reads again on a clock, and without it, or in between,
-- it counts an item at a time.
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

local VERSION = "0.8.0"

local CACHE = "/etc/ocitems.cache"

-- how many items are counted between two draws. Each one costs a server tick,
-- so this is also how long a keypress can be left waiting.
local PER_DRAW = 4
-- how long the loop listens before it goes back to counting
local REST = 0.05
-- what one read of the whole network asks for in a single go. A computer that
-- goes into it with less free than this does not fail the call, it dies.
local ROOM = 1100 * 1024
-- how long between reads of the whole network, on a machine with room for them
local REREAD = 30

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
local lastRead = 0
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
    local itemId, itemData, tagged, amount, name =
      line:match("^(%d+) (%d+) ([01]) (%d+) (.*)$")
    if itemId then
      kept[#kept + 1] = {
        itemId = tonumber(itemId),
        itemData = tonumber(itemData),
        tagged = tagged == "1",
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
    file:write(string.format("%d %d %d %d %s\n", item.itemId, item.itemData,
      item.tagged and 1 or 0, item.amount, item.name))
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
    return
  end
  local finished
  cursor, finished = lp.sweep(proxy, builder, items, cursor, PER_DRAW)
  if finished then
    order()
    movers = lp.movers(items, MOVERS)
    writeCache()
  end
end

-- Which way round to refresh, decided by what the machine has rather than by a
-- setting. One read of the network is every count at once and finds kinds of
-- item nobody has ever had; counting an item at a time is a server tick each,
-- which is 250 ticks to go round a small list and a minute to go round a large
-- one. So where there is memory for the read, that is the fast way, and where
-- there is not, the counts are kept up one at a time.
--
-- Counting between reads is not idle work either: memory only comes back under
-- the pressure of asking for more, so it is what makes the next read affordable.
local function refresh()
  if computer.freeMemory() >= ROOM and computer.uptime() - lastRead >= REREAD then
    scan()
  else
    count()
  end
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
  paint.write(math.max(1, W - 23), H, fit(builder
    and ("counting " .. cursor .. " of " .. #items)
    or (core.comma(#items) .. " shown"), 24), DIM, BAR)
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

while true do
  render()
  local packed = table.pack(event.pull(REST))
  local name = packed[1]

  if name == nil then
    refresh()
  elseif name == "modem_message" and modem then
    net.answer(modem, packed[4], packed[3], packed[6], config,
      net.report(config, net.machines(config), movers))
  elseif name == "interrupted" then
    break
  elseif name == "screen_resized" then
    layout()
    move(0)
  elseif name == "key_down" then
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
  end
end

gpu.setForeground(FG)
gpu.setBackground(BG)
term.clear()

-- ocitems: everything the Logistics Pipes network holds, the most of it first.
--
--   ocitems
--
-- Reading the whole network costs about 950 KB on a computer that has 1.4 MB,
-- so it is read once and written down. After that the counts are kept current
-- one item at a time: an item can be named to the network by two numbers, and
-- it answers what it has of that item in one server tick. So the screen goes on
-- moving without the expensive question ever being asked again, and a run that
-- starts from what was written down never asks it at all.
--
-- [r] reads the whole network again, which is the only way an item nobody has
-- ever had appears, and the only way a tool or anything else carrying an NBT
-- tag is counted. It is refused when the memory for it is not there, because
-- asking anyway does not fail the call, it ends the computer.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local keyboard = require("keyboard")
local lp = require("oclogistics")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.6.0"

local CACHE = "/etc/ocitems.cache"

-- how many items are counted between two draws. Each one costs a server tick,
-- so this is also how long a keypress can be left waiting.
local PER_DRAW = 4
-- how long the loop listens before it goes back to counting
local REST = 0.05
-- what one read of the whole network asks for in a single go. A computer that
-- goes into it with less free than this does not fail the call, it dies.
local ROOM = 1100 * 1024

local gpu = component.gpu
local paint = core.painter(gpu)

-- a count, then the name beside it: three of those and a panel across a
-- 160-wide screen
local NARROWEST = 34
local COUNT_W = 10
local PANEL_W = 34
-- how many risers, and how many fallers, are worth a look
local MOVERS = 6

local W, H, TOP, BOTTOM, ROWS, COLUMNS, COLUMN_W, PANEL_X

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
local proxy, builder

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
  local read, answer = lp.available(proxy)
  if not read then
    note = tostring(answer)
    return
  end
  items, total, note = read, answer, nil
  cursor = 1
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

local function render()
  paint.write(1, 1, fit("  ocitems v" .. VERSION .. "    "
    .. core.comma(total) .. " items in the network", W - 22), FG, BAR)
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
    paint.write(PANEL_X, TOP, fit("  changing, a minute", PANEL_W), DIM, BAR)
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
    count()
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

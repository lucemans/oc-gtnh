-- ocitems: everything the Logistics Pipes network holds, the most of it first.
--
--   ocitems
--
-- One request pipe can see the whole network, and asking it what is in there
-- costs about 950 KB on a computer that has 1.4 MB. So the network is read once
-- at the start and the program then lives off what it kept. Asking a second
-- time in one run runs the computer out of memory, which is why there is no
-- refresh: quit and start it again.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local keyboard = require("keyboard")
local lp = require("oclogistics")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.4.0"

local gpu = component.gpu
local paint = core.painter(gpu)

-- a count, then the name beside it: four of those across a 160-wide screen
local NARROWEST = 34
local COUNT_W = 10

local W, H, TOP, BOTTOM, ROWS, COLUMNS, COLUMN_W

local function layout()
  W, H = core.viewport(gpu)
  TOP = 3
  BOTTOM = H - 1
  ROWS = BOTTOM - TOP + 1
  COLUMNS = math.max(1, math.floor(W / NARROWEST))
  COLUMN_W = math.floor(W / COLUMNS)
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
local scroll = 0

local function header()
  paint.write(1, 1, fit("  ocitems v" .. VERSION .. "    "
    .. core.comma(total) .. " items in the network", W - 22), FG, BAR)
  paint.write(math.max(1, W - 21), 1,
    fit(math.floor(computer.freeMemory() / 1024) .. " KB free", 22), DIM, BAR)
end

local function render()
  header()

  for row = 0, ROWS - 1 do
    for column = 0, COLUMNS - 1 do
      local item = items[(scroll + row) * COLUMNS + column + 1]
      local x = column * COLUMN_W + 1
      if item then
        paint.write(x, TOP + row, right(core.comma(item.amount), COUNT_W),
          VALUE, BG)
        paint.write(x + COUNT_W + 1, TOP + row,
          fit(item.name, COLUMN_W - COUNT_W - 2), FG, BG)
      else
        paint.write(x, TOP + row, fit("", COLUMN_W), FG, BG)
      end
    end
  end

  if note then
    paint.write(3, TOP, fit(note, W - 2), FAILED, BG)
  end

  paint.write(1, H, fit("  [up/down] scroll   [q] quit", W - 24), FG, BAR)
  paint.write(math.max(1, W - 23), H,
    fit(core.comma(#items) .. " of " .. core.comma(total) .. " shown", 24),
    DIM, BAR)
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

local proxy = lp.requestPipe()
if not proxy then
  note = lp.pipes()[1] and "no request pipe attached"
    or "no Logistics Pipe attached"
else
  -- the reading is the slow part of the run and it is silent, so say so first
  header()
  paint.write(3, TOP, "reading the network, this takes a moment", DIM, BG)
  paint.flush(W, H, BG, FG)

  local read, answer = lp.available(proxy)
  if read then
    items, total = read, answer
  else
    note = tostring(answer)
  end
end

while true do
  render()
  local packed = table.pack(event.pull())
  local name = packed[1]

  if name == "interrupted" then
    break
  elseif name == "screen_resized" then
    layout()
    move(0)
  elseif name == "key_down" then
    local code = packed[4]
    if code == keyboard.keys.q then
      break
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

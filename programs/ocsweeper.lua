-- ocsweeper: minesweeper on the screen
--
--   ocsweeper                play a 12 by 12 board
--   ocsweeper 21 21 70       width, height and mine count, each clamped to fit

local component = require("component")
local computer = require("computer")
local event = require("event")
local keyboard = require("keyboard")
local term = require("term")

local VERSION = "0.1.0"

-- the board never exceeds this, whatever the screen or the arguments allow
local MAX_SIZE = 21
local CELL_W = 2
local ORIGIN_X = 2
local ORIGIN_Y = 3

local gpu = component.gpu
local W, H = gpu.getResolution()

local BG = 0x000000
local FG = 0xFFFFFF
local DIM = 0x999999
local BAR = 0x333333
local HIDDEN = 0x666666
local OPEN = 0x1A1A1A
local FLAG = 0xFFFF55
local BOOM = 0xAA0000
local WON = 0x66CC66

-- the colours minesweeper has always used for its counts
local COUNTS = {
  [1] = 0x5555FF, [2] = 0x55FF55, [3] = 0xFF5555, [4] = 0x0000AA,
  [5] = 0xAA0000, [6] = 0x00AAAA, [7] = 0xFFFFFF, [8] = 0xAAAAAA,
}

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

local arguments = { ... }

-- two rows for the header, one for the message, one for the controls
local width = clamp(tonumber(arguments[1]) or 12, 2, math.min(MAX_SIZE, math.floor((W - ORIGIN_X) / CELL_W)))
local height = clamp(tonumber(arguments[2]) or 12, 2, math.min(MAX_SIZE, H - ORIGIN_Y - 2))

local mine, revealed, flagged, count
local mineCount, flagCount, openCount, placed, lost, won, startedAt, finishedAt

local function grid(value)
  local rows = {}
  for y = 1, height do
    rows[y] = {}
    for x = 1, width do
      rows[y][x] = value
    end
  end
  return rows
end

local function newGame()
  mine, revealed, flagged, count = grid(false), grid(false), grid(false), grid(0)
  mineCount = clamp(tonumber(arguments[3]) or math.floor(width * height * 0.16), 0, width * height - 1)
  flagCount, openCount = 0, 0
  placed, lost, won = false, false, false
  startedAt, finishedAt = nil, nil
end

local function inside(x, y)
  return x >= 1 and x <= width and y >= 1 and y <= height
end

-- Mines are laid after the first click, never under it or beside it, so the
-- opening move always opens something instead of ending the game.
local function placeMines(safeX, safeY)
  local function candidates(margin)
    local cells = {}
    for y = 1, height do
      for x = 1, width do
        if math.abs(x - safeX) > margin or math.abs(y - safeY) > margin then
          cells[#cells + 1] = { x = x, y = y }
        end
      end
    end
    return cells
  end

  -- keeping the whole neighbourhood clear is what makes an opening click open
  -- an area, but on a board too crowded for that, only the click itself is safe
  local cells = candidates(1)
  if #cells < mineCount then
    cells = candidates(0)
  end

  for index = #cells, 2, -1 do
    local pick = math.random(index)
    cells[index], cells[pick] = cells[pick], cells[index]
  end

  mineCount = math.min(mineCount, #cells)
  for index = 1, mineCount do
    mine[cells[index].y][cells[index].x] = true
  end

  for y = 1, height do
    for x = 1, width do
      local total = 0
      for dy = -1, 1 do
        for dx = -1, 1 do
          if inside(x + dx, y + dy) and mine[y + dy][x + dx] then
            total = total + 1
          end
        end
      end
      count[y][x] = total
    end
  end

  placed = true
  startedAt = computer.uptime()
end

-- an empty cell opens its neighbours, and so on outward; kept on a stack
-- rather than recursing, since a 21 by 21 sweep can run a long way
local function open(startX, startY)
  local stack = { { startX, startY } }
  while #stack > 0 do
    local cell = table.remove(stack)
    local x, y = cell[1], cell[2]
    if inside(x, y) and not revealed[y][x] and not flagged[y][x] then
      revealed[y][x] = true
      openCount = openCount + 1
      if count[y][x] == 0 then
        for dy = -1, 1 do
          for dx = -1, 1 do
            stack[#stack + 1] = { x + dx, y + dy }
          end
        end
      end
    end
  end
end

local function finish(victory)
  won, lost = victory, not victory
  finishedAt = computer.uptime()
  if not victory then
    for y = 1, height do
      for x = 1, width do
        if mine[y][x] then
          revealed[y][x] = true
        end
      end
    end
  end
end

local function click(x, y)
  if lost or won or not inside(x, y) or flagged[y][x] or revealed[y][x] then
    return
  end
  if not placed then
    placeMines(x, y)
  end
  if mine[y][x] then
    revealed[y][x] = true
    finish(false)
    return
  end
  open(x, y)
  if openCount >= width * height - mineCount then
    finish(true)
  end
end

local function flag(x, y)
  if lost or won or not inside(x, y) or revealed[y][x] then
    return
  end
  flagged[y][x] = not flagged[y][x]
  flagCount = flagCount + (flagged[y][x] and 1 or -1)
end

local function write(x, y, text, foreground, background)
  gpu.setForeground(foreground or FG)
  gpu.setBackground(background or BG)
  gpu.set(x, y, text)
end

local function fit(text, size)
  if #text > size then
    return text:sub(1, size)
  end
  return text .. string.rep(" ", size - #text)
end

local function elapsed()
  if not startedAt then
    return 0
  end
  return math.floor((finishedAt or computer.uptime()) - startedAt)
end

local function clock()
  local seconds = elapsed()
  return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function drawCell(x, y)
  local screenX = ORIGIN_X + (x - 1) * CELL_W
  local screenY = ORIGIN_Y + y - 1

  if not revealed[y][x] then
    if flagged[y][x] then
      write(screenX, screenY, " F", FLAG, HIDDEN)
    else
      write(screenX, screenY, "  ", FG, HIDDEN)
    end
    return
  end

  if mine[y][x] then
    write(screenX, screenY, " *", FG, BOOM)
  elseif count[y][x] > 0 then
    write(screenX, screenY, " " .. count[y][x], COUNTS[count[y][x]] or FG, OPEN)
  else
    write(screenX, screenY, "  ", FG, OPEN)
  end
end

local function render()
  gpu.setBackground(BG)
  gpu.fill(1, 1, W, H, " ")

  local header = string.format("  ocsweeper v%s    %d x %d    mines %d    %s",
    VERSION, width, height, mineCount - flagCount, clock())
  write(1, 1, fit(header, W), FG, BAR)

  for y = 1, height do
    for x = 1, width do
      drawCell(x, y)
    end
  end

  local message, color = "", DIM
  if won then
    message = "cleared in " .. elapsed() .. "s"
    color = WON
  elseif lost then
    message = "boom"
    color = 0xFF5555
  end
  write(ORIGIN_X, ORIGIN_Y + height + 1, fit(message, W - ORIGIN_X), color, BG)

  write(1, H, fit("  [click] open   [right click] flag   [r] new game   [q] quit", W), FG, BAR)
end

local function cellAt(screenX, screenY)
  local x = math.floor((screenX - ORIGIN_X) / CELL_W) + 1
  local y = screenY - ORIGIN_Y + 1
  if inside(x, y) then
    return x, y
  end
  return nil
end

math.randomseed(math.floor(computer.uptime() * 1000) + (os.time() or 0))
newGame()

term.clear()
term.setCursorBlink(false)

while true do
  render()
  -- the timeout is what keeps the clock moving while nobody is clicking
  local name, _, arg1, arg2, arg3 = event.pull(1)

  if name == "interrupted" then
    break
  elseif name == "key_down" then
    if arg2 == keyboard.keys.q then
      break
    elseif arg2 == keyboard.keys.r then
      newGame()
    end
  elseif name == "touch" then
    local x, y = cellAt(arg1, arg2)
    if x then
      if arg3 == 1 then
        flag(x, y)
      else
        click(x, y)
      end
    end
  end
end

gpu.setForeground(FG)
gpu.setBackground(BG)
term.clear()

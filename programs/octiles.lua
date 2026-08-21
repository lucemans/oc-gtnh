-- octiles: 2048 on the screen
--
--   octiles                  four tiles a side
--   octiles 5                that many tiles a side, clamped to fit the screen
--
-- A slide pushes every tile as far as it goes and joins two equal tiles into
-- one that is worth both of them. A tile joined this move cannot join again
-- until the next one, so a row of four twos becomes two fours rather than an
-- eight. Every slide that moved something brings one new tile, and the game
-- ends when nothing can move: a full board with two equal neighbours still has
-- a move in it.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local keyboard = require("keyboard")
local term = require("term")

local VERSION = "0.1.0"

local DEFAULT_SIZE = 4
local MIN_SIZE = 2
local MAX_SIZE = 8

-- a tile owns seven columns and two rows: the separators above and to its left,
-- plus six columns for the number
local CELL_W = 7
local CELL_H = 2

local GOAL = 2048

-- a new tile is a two, except now and then
local HIGH_CHANCE = 0.1

local gpu = component.gpu
local paint = core.painter(gpu)

local W, H = core.viewport(gpu)

local BG = 0x000000
local FG = 0xFFFFFF
local DIM = 0x999999
local BAR = 0x333333
local BORDER = 0x555555
local HOLE = 0x1A1A1A
local WON = 0x66CC66
local LOST = 0xFF5555

-- written as bytes rather than \u{} so the file still loads on a Lua 5.2 CPU
local LINE = "\226\148\128"
local PIPE = "\226\148\130"
local TOP_LEFT = "\226\148\140"
local TOP_RIGHT = "\226\148\144"
local BOTTOM_LEFT = "\226\148\148"
local BOTTOM_RIGHT = "\226\148\152"
local TOP_TEE = "\226\148\172"
local BOTTOM_TEE = "\226\148\180"
local LEFT_TEE = "\226\148\156"
local RIGHT_TEE = "\226\148\164"
local CROSS = "\226\148\188"

-- the colours 2048 has always used, dark text on the two lightest tiles
local TILES = {
  [2] = { bg = 0xEEE4DA, fg = 0x776E65 },
  [4] = { bg = 0xEDE0C8, fg = 0x776E65 },
  [8] = { bg = 0xF2B179, fg = 0xFFFFFF },
  [16] = { bg = 0xF59563, fg = 0xFFFFFF },
  [32] = { bg = 0xF67C5F, fg = 0xFFFFFF },
  [64] = { bg = 0xF65E3B, fg = 0xFFFFFF },
  [128] = { bg = 0xEDCF72, fg = 0xFFFFFF },
  [256] = { bg = 0xEDCC61, fg = 0xFFFFFF },
  [512] = { bg = 0xEDC850, fg = 0xFFFFFF },
  [1024] = { bg = 0xEDC53F, fg = 0xFFFFFF },
  [2048] = { bg = 0xEDC22E, fg = 0xFFFFFF },
}
local ABOVE = { bg = 0x3C3A32, fg = 0xFFFFFF }
local HOLE_LOOK = { bg = HOLE, fg = HOLE }

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

local size, boardCols, boardRows
local ORIGIN_X, ORIGIN_Y, MESSAGE_Y

-- Recomputed rather than fixed at startup: a screen can be resized under a
-- running program, and an attached display is often not the size the program
-- began with. Everything positional lives here so one call re-lays it all out.
local function layout()
  W, H = core.viewport(gpu)

  -- the box costs a column for the right edge and a row for the bottom one,
  -- and the header, the message row and the controls bar take three more
  local widest = math.floor((W - 1) / CELL_W)
  local tallest = math.floor((H - 4) / CELL_H)
  local room = clamp(math.min(widest, tallest), MIN_SIZE, MAX_SIZE)

  size = clamp(tonumber(arguments[1]) or DEFAULT_SIZE, MIN_SIZE, room)
  boardCols = size * CELL_W + 1
  boardRows = size * CELL_H + 1

  -- centred: horizontally in the screen, vertically in the rows the header and
  -- the controls bar leave behind
  ORIGIN_X = math.max(1, math.floor((W - boardCols) / 2) + 1)
  ORIGIN_Y = 2 + math.max(0, math.floor(((H - 2) - (boardRows + 1)) / 2))
  MESSAGE_Y = ORIGIN_Y + boardRows
end

local tiles, score, won, over

local function spawn()
  local holes = {}
  for y = 1, size do
    for x = 1, size do
      if tiles[y][x] == 0 then
        holes[#holes + 1] = { x = x, y = y }
      end
    end
  end
  if #holes == 0 then
    return
  end
  local at = holes[math.random(#holes)]
  tiles[at.y][at.x] = (math.random() < HIGH_CHANCE) and 4 or 2
end

local function newGame()
  tiles = {}
  for y = 1, size do
    tiles[y] = {}
    for x = 1, size do
      tiles[y][x] = 0
    end
  end
  score, won, over = 0, false, false
  spawn()
  spawn()
end

-- one row or one column, ordered so the tile nearest the edge being slid
-- towards comes first
local function lineOf(index, dx, dy)
  local cells = {}
  for step = 1, size do
    local along = (dx < 0 or dy < 0) and step or (size + 1 - step)
    if dx ~= 0 then
      cells[step] = { x = along, y = index }
    else
      cells[step] = { x = index, y = along }
    end
  end
  return cells
end

local function slide(dx, dy)
  local moved, gained = false, 0

  for index = 1, size do
    local cells = lineOf(index, dx, dy)
    local packed = {}

    for _, at in ipairs(cells) do
      local value = tiles[at.y][at.x]
      if value ~= 0 then
        local last = packed[#packed]
        if last and last.value == value and not last.joined then
          last.value = value * 2
          last.joined = true
          gained = gained + last.value
        else
          packed[#packed + 1] = { value = value, joined = false }
        end
      end
    end

    for step, at in ipairs(cells) do
      local value = packed[step] and packed[step].value or 0
      if tiles[at.y][at.x] ~= value then
        tiles[at.y][at.x] = value
        moved = true
      end
    end
  end

  return moved, gained
end

local function stuck()
  for y = 1, size do
    for x = 1, size do
      local value = tiles[y][x]
      if value == 0 then
        return false
      end
      if x < size and tiles[y][x + 1] == value then
        return false
      end
      if y < size and tiles[y + 1][x] == value then
        return false
      end
    end
  end
  return true
end

local function reached()
  for y = 1, size do
    for x = 1, size do
      if tiles[y][x] >= GOAL then
        return true
      end
    end
  end
  return false
end

local function move(dx, dy)
  if over then
    return
  end
  local moved, gained = slide(dx, dy)
  if not moved then
    return
  end
  score = score + gained
  won = won or reached()
  spawn()
  over = stuck()
end

-- A click says which way to slide by where it lands: the board is quartered
-- along its diagonals and each quarter points at the edge it touches.
local function touched(screenX, screenY)
  local fromX = (screenX - (ORIGIN_X + boardCols / 2)) / CELL_W
  local fromY = (screenY - (ORIGIN_Y + boardRows / 2)) / CELL_H
  if math.abs(fromX) > math.abs(fromY) then
    move(fromX > 0 and 1 or -1, 0)
  else
    move(0, fromY > 0 and 1 or -1)
  end
end

local function fit(text, width)
  if #text > width then
    return text:sub(1, width)
  end
  return text .. string.rep(" ", width - #text)
end

local function centre(text, width)
  local left = math.floor((width - #text) / 2)
  return string.rep(" ", left) .. text .. string.rep(" ", width - #text - left)
end

local function borderRow(left, tee, right)
  local parts = { left }
  for x = 1, size do
    parts[#parts + 1] = string.rep(LINE, CELL_W - 1)
    parts[#parts + 1] = (x < size) and tee or right
  end
  return table.concat(parts)
end

local function drawBoard()
  paint.write(ORIGIN_X, ORIGIN_Y, borderRow(TOP_LEFT, TOP_TEE, TOP_RIGHT), BORDER, BG)

  local rule = borderRow(LEFT_TEE, CROSS, RIGHT_TEE)
  for y = 1, size do
    local row = ORIGIN_Y + (y - 1) * CELL_H + 1
    for x = 1, size + 1 do
      paint.write(ORIGIN_X + (x - 1) * CELL_W, row, PIPE, BORDER, BG)
    end
    for x = 1, size do
      local value = tiles[y][x]
      local look = (value == 0 and HOLE_LOOK) or TILES[value] or ABOVE
      local text = (value == 0) and "" or tostring(value)
      paint.write(ORIGIN_X + (x - 1) * CELL_W + 1, row,
        centre(text, CELL_W - 1), look.fg, look.bg)
    end
    if y < size then
      paint.write(ORIGIN_X, row + 1, rule, BORDER, BG)
    end
  end

  paint.write(ORIGIN_X, ORIGIN_Y + boardRows - 1,
    borderRow(BOTTOM_LEFT, BOTTOM_TEE, BOTTOM_RIGHT), BORDER, BG)
end

local function render()
  paint.write(1, 1, fit(string.format("  octiles v%s    %d x %d    score %s",
    VERSION, size, size, core.comma(score)), W), FG, BAR)

  drawBoard()

  local message, color = "", DIM
  if over then
    message = "no moves left, score " .. core.comma(score)
    color = LOST
  elseif won then
    message = "2048, and the board is still yours"
    color = WON
  end
  -- the row runs to the screen edge, not to the board edge: a narrow board
  -- would otherwise cut the message short
  paint.write(ORIGIN_X, MESSAGE_Y, fit(message, W - ORIGIN_X + 1), color, BG)

  paint.write(1, H, fit("  [arrows] slide, or click the side to slide towards"
    .. "   [r] new game   [q] quit", W), FG, BAR)
  paint.flush(W, H, BG, FG)
end

math.randomseed(math.floor(computer.uptime() * 1000) + (os.time() or 0))
layout()
newGame()

term.clear()
term.setCursorBlink(false)
paint.forget()

while true do
  render()
  local name, _, arg1, arg2 = event.pull()

  if name == "interrupted" then
    break
  elseif name == "screen_resized" then
    -- The board is sized to the screen, so a resize can leave it too big to
    -- fit. Re-lay out, and start over only when the size actually changed.
    local wasSize = size
    layout()
    paint.forget()
    if size ~= wasSize then
      newGame()
    end
  elseif name == "key_down" then
    if arg2 == keyboard.keys.q then
      break
    elseif arg2 == keyboard.keys.r then
      newGame()
    elseif arg2 == keyboard.keys.left then
      move(-1, 0)
    elseif arg2 == keyboard.keys.right then
      move(1, 0)
    elseif arg2 == keyboard.keys.up then
      move(0, -1)
    elseif arg2 == keyboard.keys.down then
      move(0, 1)
    end
  elseif name == "touch" then
    touched(arg1, arg2)
  end
end

gpu.setForeground(FG)
gpu.setBackground(BG)
term.clear()

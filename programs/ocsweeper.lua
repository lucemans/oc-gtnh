-- ocsweeper: minesweeper on the screen
--
--   ocsweeper                fill the screen, up to 21 by 21
--   ocsweeper 21 21 70       width, height and mine count, each clamped to fit
--
-- Every board can be cleared by reasoning alone. Layouts are generated and then
-- solved by the same logic a player has available; one that would force a guess
-- is thrown away rather than dealt.

local component = require("component")
local computer = require("computer")
local event = require("event")
local keyboard = require("keyboard")
local term = require("term")

local VERSION = "0.3.0"

-- the board never exceeds this, whatever the screen or the arguments allow
local MAX_SIZE = 21

-- a cell owns three columns and two rows: the separators above and to its left,
-- plus two columns for its contents
local CELL_W = 3
local CELL_H = 2

-- how hard to look for a board that needs no guessing before easing the mine
-- count. Each attempt is a full solve, so this is also the time budget.
local ATTEMPTS = 40

local gpu = component.gpu
local W, H = gpu.getResolution()

local BG = 0x000000
local FG = 0xFFFFFF
local DIM = 0x999999
local BAR = 0x333333
local BORDER = 0x555555
local HIDDEN = 0x6E6E6E
local OPEN = 0x1A1A1A
local FLAG = 0xFFFF55
local BOOM = 0xAA0000
local WON = 0x66CC66

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

-- The box costs a column for the right edge, and a row for every separator plus
-- the bottom edge. Above and below the board sit the header, the message row and
-- the controls bar.
local maxWidth = math.max(2, math.min(MAX_SIZE, math.floor((W - 1) / CELL_W)))
local maxHeight = math.max(2, math.min(MAX_SIZE, math.floor((H - 4) / CELL_H)))
local width = clamp(tonumber(arguments[1]) or maxWidth, 2, maxWidth)
local height = clamp(tonumber(arguments[2]) or maxHeight, 2, maxHeight)

local boardCols = width * CELL_W + 1
local boardRows = height * CELL_H + 1

-- centred: horizontally in the screen, vertically in the rows the header and
-- the controls bar leave behind
local ORIGIN_X = math.max(1, math.floor((W - boardCols) / 2) + 1)
local ORIGIN_Y = 2 + math.max(0, math.floor(((H - 2) - (boardRows + 1)) / 2))
local MESSAGE_Y = ORIGIN_Y + boardRows

local mine, revealed, flagged, count, dirty
local mineCount, flagCount, openCount, placed, lost, won, startedAt, finishedAt
local guessFree, attemptsUsed

-- what is already on the screen, so a frame only redraws what moved
local drawnHeader, drawnMessage, drawnFrame

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

local function markAll()
  for y = 1, height do
    for x = 1, width do
      dirty[y][x] = true
    end
  end
end

local function newGame()
  mine, revealed, flagged, count = grid(false), grid(false), grid(false), grid(0)
  dirty = grid(true)
  mineCount = clamp(tonumber(arguments[3]) or math.floor(width * height * 0.16), 0, width * height - 1)
  flagCount, openCount = 0, 0
  placed, lost, won = false, false, false
  startedAt, finishedAt = nil, nil
  guessFree, attemptsUsed = true, 0
  drawnHeader, drawnMessage = nil, nil
end

local function inside(x, y)
  return x >= 1 and x <= width and y >= 1 and y <= height
end

local function setRevealed(x, y)
  revealed[y][x] = true
  dirty[y][x] = true
end

local function countMines()
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
end

-- Mines are laid after the first click, never under it or beside it, so the
-- opening move always opens something instead of ending the game.
local function layMines(safeX, safeY, total)
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
  if #cells < total then
    cells = candidates(0)
  end

  for index = #cells, 2, -1 do
    local pick = math.random(index)
    cells[index], cells[pick] = cells[pick], cells[index]
  end

  mine = grid(false)
  total = math.min(total, #cells)
  for index = 1, total do
    mine[cells[index].y][cells[index].x] = true
  end
  countMines()
  return total
end

-------------------------------------------------------------------------------
-- solving
--
-- Only deductions a player could make themselves. Two local rules cover most
-- boards; the subset rule is what stops the generator rejecting so many that a
-- big board takes forever to deal.

local function neighbours(x, y)
  local cells = {}
  for dy = -1, 1 do
    for dx = -1, 1 do
      if (dx ~= 0 or dy ~= 0) and inside(x + dx, y + dy) then
        cells[#cells + 1] = { x + dx, y + dy }
      end
    end
  end
  return cells
end

local function solvable(startX, startY, total)
  local seen, known = grid(false), grid(false)
  local opened = 0

  local function sweep(x, y)
    local stack = { { x, y } }
    while #stack > 0 do
      local cell = table.remove(stack)
      local cx, cy = cell[1], cell[2]
      if inside(cx, cy) and not seen[cy][cx] and not known[cy][cx] then
        seen[cy][cx] = true
        opened = opened + 1
        if count[cy][cx] == 0 then
          for _, next in ipairs(neighbours(cx, cy)) do
            stack[#stack + 1] = next
          end
        end
      end
    end
  end

  -- the unknowns around a number, and how many of its mines are still unfound
  local function frontier(x, y)
    local unknown, found = {}, 0
    for _, cell in ipairs(neighbours(x, y)) do
      local nx, ny = cell[1], cell[2]
      if known[ny][nx] then
        found = found + 1
      elseif not seen[ny][nx] then
        unknown[#unknown + 1] = cell
      end
    end
    return unknown, count[y][x] - found
  end

  sweep(startX, startY)

  local progress = true
  while progress and opened < width * height - total do
    progress = false

    for y = 1, height do
      for x = 1, width do
        if seen[y][x] and count[y][x] > 0 then
          local unknown, remaining = frontier(x, y)
          if #unknown > 0 then
            if remaining == 0 then
              for _, cell in ipairs(unknown) do
                sweep(cell[1], cell[2])
              end
              progress = true
            elseif remaining == #unknown then
              for _, cell in ipairs(unknown) do
                known[cell[2]][cell[1]] = true
              end
              progress = true
            end
          end
        end
      end
    end

    if not progress then
      -- One number's unknowns contained in another's: the difference is settled
      -- even though neither cell is settled on its own. This is the 1-2-1 rule
      -- and its relatives, and without it too many fair boards look unsolvable.
      for y = 1, height do
        for x = 1, width do
          if seen[y][x] and count[y][x] > 0 then
            local mine1, remaining1 = frontier(x, y)
            local set1 = {}
            for _, cell in ipairs(mine1) do
              set1[cell[2] * width + cell[1]] = true
            end

            for dy = -2, 2 do
              for dx = -2, 2 do
                local ox, oy = x + dx, y + dy
                if (dx ~= 0 or dy ~= 0) and inside(ox, oy)
                  and seen[oy][ox] and count[oy][ox] > 0 then
                  local mine2, remaining2 = frontier(ox, oy)
                  local contained = #mine2 > 0
                  for _, cell in ipairs(mine2) do
                    if not set1[cell[2] * width + cell[1]] then
                      contained = false
                      break
                    end
                  end

                  if contained and #mine2 < #mine1 then
                    local rest = {}
                    local inner = {}
                    for _, cell in ipairs(mine2) do
                      inner[cell[2] * width + cell[1]] = true
                    end
                    for _, cell in ipairs(mine1) do
                      if not inner[cell[2] * width + cell[1]] then
                        rest[#rest + 1] = cell
                      end
                    end

                    if remaining1 - remaining2 == #rest then
                      for _, cell in ipairs(rest) do
                        known[cell[2]][cell[1]] = true
                      end
                      progress = true
                    elseif remaining1 == remaining2 then
                      for _, cell in ipairs(rest) do
                        sweep(cell[1], cell[2])
                      end
                      progress = true
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  return opened >= width * height - total
end

-- Deal until the board can be reasoned out. If a density simply will not yield
-- one, ease it rather than loop forever; the header says so when that happens.
local function placeMines(safeX, safeY)
  local target = mineCount

  while true do
    for _ = 1, ATTEMPTS do
      attemptsUsed = attemptsUsed + 1
      local laid = layMines(safeX, safeY, target)
      if laid == 0 or solvable(safeX, safeY, laid) then
        mineCount = laid
        placed = true
        startedAt = computer.uptime()
        return
      end
      -- a 21 by 21 solve is long enough that the watchdog needs a chance to see
      -- the computer is still cooperating
      if attemptsUsed % 4 == 0 then
        os.sleep(0)
      end
    end

    if target <= 1 then
      mineCount = layMines(safeX, safeY, target)
      guessFree = false
      placed = true
      startedAt = computer.uptime()
      return
    end
    target = target - math.max(1, math.floor(target * 0.1))
  end
end

-------------------------------------------------------------------------------

-- an empty cell opens its neighbours, and so on outward; kept on a stack
-- rather than recursing, since a 21 by 21 sweep can run a long way
local function open(startX, startY)
  local stack = { { startX, startY } }
  while #stack > 0 do
    local cell = table.remove(stack)
    local x, y = cell[1], cell[2]
    if inside(x, y) and not revealed[y][x] and not flagged[y][x] then
      setRevealed(x, y)
      openCount = openCount + 1
      if count[y][x] == 0 then
        for _, next in ipairs(neighbours(x, y)) do
          stack[#stack + 1] = next
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
          setRevealed(x, y)
        end
      end
    end
  end
end

local function checkWon()
  if openCount >= width * height - mineCount then
    finish(true)
  end
end

-- Clicking a number that already carries its full count of flags opens the rest
-- of its neighbours. Unlike the usual chord this never detonates: if a flag is
-- in the wrong place the move is simply refused, so a mistake costs nothing.
local function chord(x, y)
  if count[y][x] == 0 then
    return
  end

  local flags, closed = 0, {}
  for _, cell in ipairs(neighbours(x, y)) do
    local nx, ny = cell[1], cell[2]
    if flagged[ny][nx] then
      flags = flags + 1
    elseif not revealed[ny][nx] then
      closed[#closed + 1] = cell
    end
  end

  if flags ~= count[y][x] then
    return
  end
  for _, cell in ipairs(closed) do
    if mine[cell[2]][cell[1]] then
      return
    end
  end

  for _, cell in ipairs(closed) do
    open(cell[1], cell[2])
  end
  checkWon()
end

local function click(x, y)
  if lost or won or not inside(x, y) or flagged[y][x] then
    return
  end
  if revealed[y][x] then
    chord(x, y)
    return
  end
  if not placed then
    placeMines(x, y)
  end
  if mine[y][x] then
    setRevealed(x, y)
    finish(false)
    return
  end
  open(x, y)
  checkWon()
end

local function flag(x, y)
  if lost or won or not inside(x, y) or revealed[y][x] then
    return
  end
  flagged[y][x] = not flagged[y][x]
  flagCount = flagCount + (flagged[y][x] and 1 or -1)
  dirty[y][x] = true
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

local function borderRow(left, tee, right)
  local parts = { left }
  for x = 1, width do
    parts[#parts + 1] = LINE .. LINE
    parts[#parts + 1] = (x < width) and tee or right
  end
  return table.concat(parts)
end

-- the grid never changes, so it is drawn once and left alone; only the two
-- columns inside each cell are repainted
local function drawFrame()
  gpu.setBackground(BG)
  gpu.fill(1, 1, W, H, " ")

  write(ORIGIN_X, ORIGIN_Y, borderRow(TOP_LEFT, TOP_TEE, TOP_RIGHT), BORDER, BG)
  write(ORIGIN_X, ORIGIN_Y + boardRows - 1,
    borderRow(BOTTOM_LEFT, BOTTOM_TEE, BOTTOM_RIGHT), BORDER, BG)

  local rule = borderRow(LEFT_TEE, CROSS, RIGHT_TEE)
  for y = 1, height do
    local row = ORIGIN_Y + (y - 1) * CELL_H + 1
    for x = 1, width + 1 do
      write(ORIGIN_X + (x - 1) * CELL_W, row, PIPE, BORDER, BG)
    end
    if y < height then
      write(ORIGIN_X, row + 1, rule, BORDER, BG)
    end
  end

  write(1, H, fit("  [click] open, or open around a finished number"
    .. "   [right click] flag   [r] new game   [q] quit", W), FG, BAR)
end

local function drawCell(x, y)
  local screenX = ORIGIN_X + (x - 1) * CELL_W + 1
  local screenY = ORIGIN_Y + (y - 1) * CELL_H + 1

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
  if not drawnFrame then
    drawFrame()
    drawnFrame = true
    markAll()
  end

  for y = 1, height do
    for x = 1, width do
      if dirty[y][x] then
        drawCell(x, y)
        dirty[y][x] = false
      end
    end
  end

  local header = string.format("  ocsweeper v%s    %d x %d    mines %d    %s%s",
    VERSION, width, height, mineCount - flagCount, clock(),
    guessFree and "" or "    guess required")
  if header ~= drawnHeader then
    write(1, 1, fit(header, W), FG, BAR)
    drawnHeader = header
  end

  local message, color = "", DIM
  if won then
    message = "cleared in " .. elapsed() .. "s"
    color = WON
  elseif lost then
    message = "boom"
    color = 0xFF5555
  end
  if message ~= drawnMessage then
    -- the row runs to the screen edge, not to the board edge: a narrow board
    -- would otherwise cut the message short
    write(ORIGIN_X, MESSAGE_Y, fit(message, W - ORIGIN_X + 1), color, BG)
    drawnMessage = message
  end
end

-- a cell owns its content row and the rule beneath it, so clicking either lands
-- on the same square rather than falling between two of them
local function cellAt(screenX, screenY)
  local column = screenX - ORIGIN_X
  local row = screenY - ORIGIN_Y
  if column < 0 or column >= width * CELL_W then
    return nil
  end
  if row < 1 or row > height * CELL_H then
    return nil
  end
  return math.floor(column / CELL_W) + 1, math.ceil(row / CELL_H)
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

-- ocitems: look through what a Logistics Pipe will tell you, one call at a time.
--
--   ocitems   pick a pipe on the left, open its methods on the right
--
-- Logistics Pipes hands over a proxy rather than data, and which methods it
-- carries depends on which pipe it is and on which fork of the mod a pack
-- ships. Nothing is named in advance, so this lists what a pipe offers and
-- calls one method when you ask it to.
--
-- Nothing is called on its own. Reading everything and following whatever came
-- back is what a basic pipe survived and a request pipe did not: it reaches the
-- whole item network, and building that inside a computer with a few hundred
-- kilobytes of memory runs the machine out of it. Free memory is on screen for
-- the same reason.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local lp = require("oclogistics")
local keyboard = require("keyboard")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.3.0"

local gpu = component.gpu
local paint = core.painter(gpu)

local W, H, LIST_W, TOP, BOTTOM, ROWS, DETAIL_X, DETAIL_W

local function layout()
  W, H = core.viewport(gpu)
  LIST_W = math.max(20, math.min(34, math.floor(W / 4)))
  TOP = 3
  BOTTOM = H - 1
  ROWS = BOTTOM - TOP + 1
  DETAIL_X = LIST_W + 3
  DETAIL_W = W - DETAIL_X + 1
  paint.forget()
end

layout()

local BG = 0x000000
local FG = 0xFFFFFF
local DIM = 0x999999
local BAR = 0x333333
local SELECTED = 0x0066CC
local VALUE = 0x66CC66
local FAILED = 0xCC6666

local PIPE = "\226\148\130"

local function fit(text, width)
  local length = unicode.len(text)
  if length > width then
    return unicode.sub(text, 1, width)
  end
  return text .. string.rep(" ", width - length)
end

local pipes = lp.pipes()
local selected = 1

-- named once: asking a pipe its router id reaches into the world, and doing that
-- for every pipe on every redraw is a call a frame for nothing
local names = {}
for _, address in ipairs(pipes) do
  names[address] = lp.displayName(address) or address:sub(1, 8)
end

-- where in the proxy tree we are: the pipe itself, then whatever was opened
local path = {}
local rows = {}
local cursor = 1
local scroll = 0
local note = nil

local function here()
  for index = #path, 1, -1 do
    if path[index].proxy then
      return path[index].proxy
    end
  end
  return nil
end

local function look()
  rows = {}
  cursor = 1
  scroll = 0
  local proxy = here()
  if not proxy then
    return
  end
  for _, entry in ipairs(lp.offers(proxy)) do
    rows[#rows + 1] = { name = entry.name, readable = entry.readable }
  end
end

local function openPipe(index)
  if index < 1 then
    index = 1
  end
  if index > #pipes then
    index = #pipes
  end
  selected = index
  note = nil
  path = {}

  local address = pipes[selected]
  if not address then
    look()
    return
  end
  local proxy = lp.pipe(address)
  if not proxy then
    note = "getPipe answered nothing"
    look()
    return
  end
  path = { { name = names[address], proxy = proxy } }
  look()
end

-- one method, called because somebody asked for it
local function ask()
  local row = rows[cursor]
  local proxy = here()
  if not row or not proxy then
    return
  end

  local answer = lp.read(proxy, row.name)

  if answer.kind == "proxy" then
    path[#path + 1] = { name = row.name, proxy = answer.proxy }
    note = nil
    look()
    return
  end

  -- a list is the thing worth looking at: it is what everything the base owns
  -- comes back as
  if answer.kind == "list" then
    rows = {}
    cursor = 1
    scroll = 0
    for index, text in ipairs(answer.rows) do
      rows[index] = { name = tostring(index), text = text, entry = true }
    end
    if answer.total > #answer.rows then
      rows[#rows + 1] = { name = "",
        text = "and " .. (answer.total - #answer.rows) .. " more, not read",
        entry = true }
    end
    path[#path + 1] = { name = row.name .. "  " .. answer.text, listing = true }
    note = nil
    return
  end

  row.text = answer.text
  row.failed = answer.failed
end

local function back()
  if #path > 1 then
    table.remove(path)
    look()
  end
end


local function trail()
  local parts = {}
  for _, step in ipairs(path) do
    parts[#parts + 1] = step.name
  end
  return table.concat(parts, "  >  ")
end

local function render()
  paint.write(1, 1, fit("  ocitems v" .. VERSION .. "    " .. #pipes
    .. (#pipes == 1 and " pipe" or " pipes") .. " attached", W - 22), FG, BAR)
  paint.write(math.max(1, W - 21), 1,
    fit(math.floor(computer.freeMemory() / 1024) .. " KB free", 22), DIM, BAR)

  for row = TOP, BOTTOM do
    paint.write(LIST_W + 1, row, PIPE, DIM, BG)
  end

  for index, address in ipairs(pipes) do
    local row = TOP + index - 1
    if row <= BOTTOM then
      paint.write(1, row, fit("  " .. names[address], LIST_W),
        FG, index == selected and SELECTED or BG)
    end
  end

  paint.write(DETAIL_X, TOP, fit(trail(), DETAIL_W), DIM, BG)

  for line = 0, ROWS - 3 do
    local row = rows[scroll + line + 1]
    local y = TOP + 2 + line
    if not row then
      paint.write(DETAIL_X, y, fit("", DETAIL_W), FG, BG)
    else
      local shown = scroll + line + 1 == cursor
      paint.write(DETAIL_X, y, fit("  " .. row.name, DETAIL_W),
        row.readable and FG or DIM, shown and SELECTED or BG)

      local text = row.text
      if not text and not row.readable then
        text = "changes something, so it is left alone"
      end
      if text then
        local space = DETAIL_W - unicode.len(row.name) - 4
        if space >= 6 then
          local cut = unicode.sub(text, 1, space)
          paint.write(DETAIL_X + DETAIL_W - unicode.len(cut), y, cut,
            row.failed and FAILED or VALUE, shown and SELECTED or BG)
        end
      end
    end
  end

  if #pipes == 0 then
    paint.write(3, TOP, fit("none", LIST_W - 2), DIM, BG)
    paint.write(DETAIL_X, TOP, fit("no Logistics Pipe attached", DETAIL_W), DIM, BG)
  elseif note then
    paint.write(DETAIL_X, TOP + 2, fit(note, DETAIL_W), FAILED, BG)
  end

  paint.write(1, H, fit("  [enter] call it   [backspace] back   [up/down] move"
    .. "   [r] read the pipe again   [q] quit", W), FG, BAR)
  paint.flush(W, H, BG, FG)
end

local function move(delta)
  cursor = cursor + delta
  if cursor < 1 then
    cursor = 1
  end
  if cursor > #rows then
    cursor = #rows
  end
  if cursor < scroll + 1 then
    scroll = cursor - 1
  end
  if cursor > scroll + ROWS - 2 then
    scroll = cursor - ROWS + 2
  end
  if scroll < 0 then
    scroll = 0
  end
end

-------------------------------------------------------------------------------

term.clear()
term.setCursorBlink(false)
paint.forget()
openPipe(1)

while true do
  render()
  local packed = table.pack(event.pull())
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
      openPipe(selected)
    elseif code == keyboard.keys.enter then
      ask()
    elseif code == keyboard.keys.back then
      back()
    elseif code == keyboard.keys.up then
      move(-1)
    elseif code == keyboard.keys.down then
      move(1)
    elseif code == keyboard.keys.pageUp then
      move(-(ROWS - 2))
    elseif code == keyboard.keys.pageDown then
      move(ROWS - 2)
    end
  elseif name == "touch" then
    local column, row = packed[3], packed[4]
    if column <= LIST_W and row >= TOP and row <= BOTTOM then
      openPipe(row - TOP + 1)
    elseif row >= TOP + 2 then
      local index = scroll + row - TOP - 1
      if rows[index] then
        if index == cursor then
          ask()
        else
          cursor = index
        end
      end
    end
  elseif name == "scroll" then
    if packed[5] > 0 then
      move(-1)
    else
      move(1)
    end
  end
end

gpu.setForeground(FG)
gpu.setBackground(BG)
term.clear()

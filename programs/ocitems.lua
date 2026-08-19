-- ocitems: everything a Logistics Pipe will tell you about itself.
--
--   ocitems   pick a pipe on the left, read what it answers on the right
--
-- Logistics Pipes hands over a proxy rather than data, and which methods that
-- proxy carries depends on which pipe it is and on which fork of the mod a pack
-- ships. So nothing is named in advance: every method that only reads is
-- called, anything that answers with another proxy is walked into, and the
-- whole tree is drawn. What a pipe cannot answer says so rather than vanishing.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local lp = require("oclogistics")
local keyboard = require("keyboard")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.1.0"

-- walking a pipe is many calls into the world, so it is not done on a timer
local REFRESH_SECONDS = 10

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
local scroll = 0
local rows = {}
local read = 0

local function inspect()
  local address = pipes[selected]
  rows = {}
  read = 0
  if not address then
    return
  end

  local proxy = lp.pipe(address)
  if not proxy then
    rows = { { depth = 0, name = "getPipe", text = "- answered nothing" } }
    return
  end

  rows = lp.walk(proxy)
  read = computer.uptime()
end

local function render()
  paint.write(1, 1, fit("  ocitems v" .. VERSION .. "    " .. #pipes
    .. (#pipes == 1 and " pipe" or " pipes") .. " attached", W), FG, BAR)

  for row = TOP, BOTTOM do
    paint.write(LIST_W + 1, row, PIPE, DIM, BG)
  end

  for index, address in ipairs(pipes) do
    local row = TOP + index - 1
    if row <= BOTTOM then
      local name = lp.displayName(address) or address:sub(1, 8)
      paint.write(1, row, fit("  " .. name, LIST_W),
        FG, index == selected and SELECTED or BG)
    end
  end

  for line = 0, ROWS - 1 do
    local entry = rows[scroll + line + 1]
    local row = TOP + line
    if not entry then
      paint.write(DETAIL_X, row, fit("", DETAIL_W), FG, BG)
    else
      local indent = string.rep("  ", entry.depth)
      local name = indent .. entry.name
      paint.write(DETAIL_X, row, fit(name, DETAIL_W), entry.proxy and DIM or FG, BG)

      local space = DETAIL_W - unicode.len(name) - 2
      local text = entry.text
      if entry.proxy then
        text = "and what it answers, below"
      elseif entry.callable then
        text = "does something, so it is left alone"
      end
      if text ~= "" and space >= 6 then
        local shown = unicode.sub(text, 1, space)
        local color = VALUE
        if entry.proxy or entry.callable then
          color = DIM
        elseif text:sub(1, 1) == "-" then
          color = FAILED
        end
        paint.write(DETAIL_X + DETAIL_W - unicode.len(shown), row, shown, color, BG)
      end
    end
  end

  -- after the detail rows, which blank the whole column as they go
  if #pipes == 0 then
    paint.write(3, TOP, fit("none", LIST_W - 2), DIM, BG)
    paint.write(DETAIL_X, TOP,
      fit("no Logistics Pipe attached", DETAIL_W), DIM, BG)
    paint.write(DETAIL_X, TOP + 2,
      fit("A pipe reaches a computer through an adapter placed against it.",
        DETAIL_W), DIM, BG)
  end

  local age = ""
  if read > 0 then
    age = "   read " .. math.floor(computer.uptime() - read) .. "s ago"
  end
  paint.write(1, H, fit("  [click/up/down] pick a pipe   [pgup/pgdn] scroll"
    .. "   [r] read again   [q] quit" .. age, W), FG, BAR)
  paint.flush(W, H, BG, FG)
end

local function select(index)
  if index < 1 then
    index = 1
  end
  if index > #pipes then
    index = #pipes
  end
  if index ~= selected or #rows == 0 then
    selected = index
    scroll = 0
    inspect()
  end
end

local function scrollBy(delta)
  scroll = scroll + delta
  local most = math.max(0, #rows - ROWS)
  if scroll > most then
    scroll = most
  end
  if scroll < 0 then
    scroll = 0
  end
end

-------------------------------------------------------------------------------

term.clear()
term.setCursorBlink(false)
paint.forget()
inspect()

while true do
  render()
  local packed = table.pack(event.pull(REFRESH_SECONDS))
  local name = packed[1]

  if name == "interrupted" then
    break
  elseif name == nil then
    inspect()
  elseif name == "screen_resized" then
    layout()
  elseif name == "key_down" then
    local code = packed[4]
    if code == keyboard.keys.q then
      break
    elseif code == keyboard.keys.r then
      inspect()
    elseif code == keyboard.keys.up then
      select(selected - 1)
    elseif code == keyboard.keys.down then
      select(selected + 1)
    elseif code == keyboard.keys.pageUp then
      scrollBy(-ROWS)
    elseif code == keyboard.keys.pageDown then
      scrollBy(ROWS)
    end
  elseif name == "touch" then
    local column, row = packed[3], packed[4]
    if column <= LIST_W and row >= TOP and row <= BOTTOM then
      select(row - TOP + 1)
    end
  elseif name == "scroll" then
    if packed[3] <= LIST_W then
      select(selected - packed[5])
    else
      scrollBy(-packed[5] * 3)
    end
  end
end

gpu.setForeground(FG)
gpu.setBackground(BG)
term.clear()

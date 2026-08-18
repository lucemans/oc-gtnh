-- ocdebug: browse the attached components and their methods on the screen

local component = require("component")
local event = require("event")
local keyboard = require("keyboard")
local term = require("term")
local unicode = require("unicode")

local gpu = component.gpu
local W, H = gpu.getResolution()

local LIST_W = math.min(28, math.floor(W / 3))
local CONTENT_TOP = 3
local CONTENT_BOTTOM = H - 1
local CONTENT_ROWS = CONTENT_BOTTOM - CONTENT_TOP + 1
local DETAIL_X = LIST_W + 3
local DETAIL_W = W - DETAIL_X + 1
local KIND_W = LIST_W - 8

local BG = 0x000000
local FG = 0xFFFFFF
local DIM = 0x999999
local BAR = 0x333333
local SELECTED = 0x0066CC

local function fit(text, width)
  local length = unicode.len(text)
  if length > width then
    return unicode.sub(text, 1, width)
  end
  return text .. string.rep(" ", width - length)
end

local function write(x, y, text, foreground, background)
  gpu.setForeground(foreground or FG)
  gpu.setBackground(background or BG)
  gpu.set(x, y, text)
end

local function wrap(text, width)
  local lines = {}
  for paragraph in text:gmatch("[^\n]+") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      if line == "" then
        line = word
      elseif unicode.len(line) + 1 + unicode.len(word) <= width then
        line = line .. " " .. word
      else
        lines[#lines + 1] = line
        line = word
      end
    end
    if line ~= "" then
      lines[#lines + 1] = line
    end
  end
  return lines
end

local function collectComponents()
  local entries = {}
  for address, kind in component.list() do
    entries[#entries + 1] = { address = address, kind = kind }
  end
  table.sort(entries, function(a, b)
    if a.kind ~= b.kind then
      return a.kind < b.kind
    end
    return a.address < b.address
  end)
  return entries
end

local function detailLines(entry)
  local lines = {}
  local function add(text, color)
    lines[#lines + 1] = { text = text, color = color }
  end

  add(entry.kind, FG)
  add(entry.address, DIM)
  add("", DIM)

  local ok, methods = pcall(component.methods, entry.address)
  if not ok or not methods then
    add("no methods (" .. tostring(methods) .. ")", DIM)
    return lines
  end

  local names = {}
  for name in pairs(methods) do
    names[#names + 1] = name
  end
  table.sort(names)

  if #names == 0 then
    add("no callable methods", DIM)
  end

  for _, name in ipairs(names) do
    add(name, FG)
    local okDoc, doc = pcall(component.doc, entry.address, name)
    if okDoc and doc then
      for _, line in ipairs(wrap(doc, DETAIL_W - 2)) do
        add("  " .. line, DIM)
      end
    end
  end

  return lines
end

local entries = collectComponents()
local selected = 1
local listScroll = 0
local detailScroll = 0
local lines = {}

local function select(index)
  if index < 1 then
    index = 1
  end
  if index > #entries then
    index = #entries
  end
  selected = index
  detailScroll = 0
  lines = entries[index] and detailLines(entries[index]) or {}

  if selected - listScroll > CONTENT_ROWS then
    listScroll = selected - CONTENT_ROWS
  end
  if selected - listScroll < 1 then
    listScroll = selected - 1
  end
end

local function scrollDetail(delta)
  detailScroll = detailScroll + delta
  local maximum = math.max(0, #lines - CONTENT_ROWS)
  if detailScroll > maximum then
    detailScroll = maximum
  end
  if detailScroll < 0 then
    detailScroll = 0
  end
end

local function render()
  gpu.setBackground(BG)
  gpu.fill(1, 1, W, H, " ")

  write(1, 1, fit("  ocdebug    " .. #entries .. " components attached", W), FG, BAR)
  write(1, H, fit("  [click/up/down] select    [wheel/pgup/pgdn] scroll    [q] quit", W), FG, BAR)

  gpu.setBackground(BG)
  gpu.setForeground(DIM)
  gpu.fill(LIST_W + 1, CONTENT_TOP, 1, CONTENT_ROWS, "│")

  for row = 1, CONTENT_ROWS do
    local entry = entries[listScroll + row]
    if entry then
      local y = CONTENT_TOP + row - 1
      local isSelected = (listScroll + row) == selected
      local background = isSelected and SELECTED or BG
      write(1, y, " " .. fit(entry.kind, KIND_W) .. " ", FG, background)
      write(KIND_W + 3, y, unicode.sub(entry.address, 1, 6), isSelected and FG or DIM, background)
    end
  end

  for row = 1, CONTENT_ROWS do
    local line = lines[detailScroll + row]
    if line then
      write(DETAIL_X, CONTENT_TOP + row - 1, fit(line.text, DETAIL_W), line.color, BG)
    end
  end
end

if #entries == 0 then
  io.stderr:write("ocdebug: no components found\n")
  return 1
end

term.clear()
term.setCursorBlink(false)
select(1)

while true do
  render()
  local name, _, arg1, arg2, arg3 = event.pull()

  if name == "interrupted" then
    break
  elseif name == "key_down" then
    if arg2 == keyboard.keys.q then
      break
    elseif arg2 == keyboard.keys.up then
      select(selected - 1)
    elseif arg2 == keyboard.keys.down then
      select(selected + 1)
    elseif arg2 == keyboard.keys.pageUp then
      scrollDetail(-CONTENT_ROWS)
    elseif arg2 == keyboard.keys.pageDown then
      scrollDetail(CONTENT_ROWS)
    end
  elseif name == "touch" then
    if arg1 <= LIST_W and arg2 >= CONTENT_TOP and arg2 <= CONTENT_BOTTOM then
      local index = listScroll + (arg2 - CONTENT_TOP + 1)
      if entries[index] then
        select(index)
      end
    end
  elseif name == "scroll" then
    if arg1 <= LIST_W then
      select(selected - arg3)
    else
      scrollDetail(-arg3 * 3)
    end
  end
end

gpu.setForeground(FG)
gpu.setBackground(BG)
term.clear()

-- ocdebug: browse the attached components, their methods and their values

local component = require("component")
local event = require("event")
local gt = require("ocgt")
local keyboard = require("keyboard")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.5.0"

-- indirect component calls block until the next server tick, so re-reading a
-- machine costs real time; two seconds keeps the readings live without
-- occupying the computer
local REFRESH_SECONDS = 2

local gpu = component.gpu
local W, H = gpu.getResolution()

local LIST_W = math.min(34, math.floor(W / 3))
local CONTENT_TOP = 3
local CONTENT_BOTTOM = H - 1
local CONTENT_ROWS = CONTENT_BOTTOM - CONTENT_TOP + 1
local DETAIL_X = LIST_W + 3
local DETAIL_W = W - DETAIL_X + 1
local NAME_W = LIST_W - 8
local GAUGE_W = 16

local BG = 0x000000
local FG = 0xFFFFFF
local DIM = 0x999999
local BAR = 0x333333
local SELECTED = 0x0066CC
local VALUE = 0x66CC66
local FAILED = 0xCC6666
local ENERGY = 0xFFFF55

-- written as bytes rather than \u{} so the file still loads on a Lua 5.2 CPU
local FULL_BLOCK = "\226\150\136"
local LIGHT_BLOCK = "\226\150\145"
local LINE = "\226\148\128"
local PIPE = "\226\148\130"

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

local function comma(number)
  local text = string.format("%d", number)
  local sign, digits = text:match("^(%-?)(%d+)$")
  if not digits then
    return text
  end
  local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return sign .. grouped
end

local function friendlyName(entry)
  if entry.friendly == nil then
    entry.friendly = gt.friendlyName(entry.address) or false
  end
  return entry.friendly or entry.kind
end

local function statusOf(address, methods)
  local flags = {}
  if gt.has(methods, "isMachineActive") then
    flags[#flags + 1] = gt.call(address, "isMachineActive") and "active" or "idle"
  end
  if gt.has(methods, "isWorkAllowed") and gt.call(address, "isWorkAllowed") == false then
    flags[#flags + 1] = "disabled"
  end
  if gt.has(methods, "hasWork") and gt.call(address, "hasWork") then
    flags[#flags + 1] = "working"
  end
  return #flags > 0 and table.concat(flags, "  ") or nil
end

local function summaryLines(entry, methods, add)
  local sensor = gt.sensorOf(entry.address)
  local lastColor = nil

  if sensor then
    for index = gt.firstReading(sensor), #sensor do
      local raw = tostring(sensor[index])
      local gauge, label = gt.gaugeFromSensor(raw)
      if gauge then
        gauge.color = lastColor or VALUE
        if label ~= "" then
          add(label, DIM)
        end
        add(nil, nil, nil, nil, gauge)
      else
        local parts = gt.segments(raw, FG)
        if #parts > 0 then
          add(nil, nil, nil, nil, nil, parts)
          for _, part in ipairs(parts) do
            if part.color ~= FG and part.text:match("%S") then
              lastColor = part.color
            end
          end
        end
      end
    end
    return
  end

  -- without sensor text the raw counters are all a machine offers
  local function numeric(label, currentMethod, maxMethod, color)
    if not (gt.has(methods, currentMethod) and gt.has(methods, maxMethod)) then
      return
    end
    local value = gt.call(entry.address, currentMethod)
    local maximum = gt.call(entry.address, maxMethod)
    if type(value) ~= "number" or type(maximum) ~= "number" or maximum <= 0 then
      return
    end
    add(label, DIM)
    add(nil, nil, nil, nil, {
      value = value,
      max = maximum,
      current = comma(value),
      maximum = comma(maximum),
      unit = "",
      color = color,
    })
  end

  numeric("Energy", "getEUStored", "getEUMaxStored", ENERGY)
  numeric("Progress", "getWorkProgress", "getWorkMaxProgress", VALUE)
end

local function detailLines(entry)
  local lines = {}
  local function add(text, color, right, rightColor, gauge, parts)
    lines[#lines + 1] = {
      text = text or "",
      color = color,
      right = right,
      rightColor = rightColor,
      gauge = gauge,
      parts = parts,
    }
  end

  local methods = gt.methodsOf(entry.address) or {}

  add(friendlyName(entry), FG, statusOf(entry.address, methods), VALUE)

  local where = ""
  if gt.has(methods, "getCoordinates") then
    local x, y, z = gt.call(entry.address, "getCoordinates")
    if type(x) == "number" then
      where = "  (" .. x .. ", " .. y .. ", " .. z .. ")"
    end
  end
  add(entry.kind .. "  " .. entry.address .. where, DIM)
  add("")

  local before = #lines
  summaryLines(entry, methods, add)
  if #lines > before then
    add("")
  end

  local names = {}
  for name in pairs(methods) do
    names[#names + 1] = name
  end
  table.sort(names)

  if #names == 0 then
    add("no callable methods", DIM)
    return lines
  end

  add(string.rep(LINE, math.min(DETAIL_W, 20)) .. " methods", DIM)

  for _, name in ipairs(names) do
    if gt.isReadable(name) then
      local text, reason = gt.readValue(entry.address, name)
      add(name, FG, text or reason, text and VALUE or FAILED)
    else
      add(name, FG)
    end
    local ok, doc = pcall(component.doc, entry.address, name)
    if ok and doc then
      for _, text in ipairs(wrap(doc, DETAIL_W - 2)) do
        add("  " .. text, DIM)
      end
    end
  end

  return lines
end

-------------------------------------------------------------------------------

local function collect()
  local list = {}
  for address, kind in component.list() do
    list[#list + 1] = { address = address, kind = kind }
  end
  table.sort(list, function(a, b)
    if a.kind ~= b.kind then
      return a.kind < b.kind
    end
    return a.address < b.address
  end)
  return list
end

local function signature(list)
  local parts = {}
  for _, entry in ipairs(list) do
    parts[#parts + 1] = entry.address
  end
  return table.concat(parts, ",")
end

local entries = collect()
local selected = 1
local listScroll = 0
local detailScroll = 0
local lines = {}

local function refresh()
  local entry = entries[selected]
  lines = entry and detailLines(entry) or {}
  local maximum = math.max(0, #lines - CONTENT_ROWS)
  if detailScroll > maximum then
    detailScroll = maximum
  end
end

local function select(index)
  if index < 1 then
    index = 1
  end
  if index > #entries then
    index = #entries
  end
  selected = index
  detailScroll = 0
  refresh()

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

-- re-read the selected machine, and notice components attached since startup
local function rescan()
  local fresh = collect()
  if signature(fresh) == signature(entries) then
    refresh()
    return
  end

  local address = entries[selected] and entries[selected].address
  local names = {}
  for _, entry in ipairs(entries) do
    names[entry.address] = entry.friendly
  end
  entries = fresh
  for _, entry in ipairs(entries) do
    entry.friendly = names[entry.address]
  end

  local index = 1
  for position, entry in ipairs(entries) do
    if entry.address == address then
      index = position
    end
  end
  select(index)
end

local function renderGauge(y, gauge)
  local ratio = gauge.value / gauge.max
  if ratio < 0 then
    ratio = 0
  elseif ratio > 1 then
    ratio = 1
  end
  local filled = math.floor(GAUGE_W * ratio + 0.5)

  local x = DETAIL_X
  write(x, y, "[", DIM, BG)
  x = x + 1
  if filled > 0 then
    write(x, y, string.rep(FULL_BLOCK, filled), gauge.color, BG)
    x = x + filled
  end
  if GAUGE_W - filled > 0 then
    write(x, y, string.rep(LIGHT_BLOCK, GAUGE_W - filled), DIM, BG)
    x = x + GAUGE_W - filled
  end
  write(x, y, "]", DIM, BG)
  x = x + 1

  local unit = gauge.unit ~= "" and (" " .. gauge.unit) or ""
  local text = string.format("  %s / %s%s  %.1f%%", gauge.current, gauge.maximum, unit, ratio * 100)
  local space = DETAIL_W - (x - DETAIL_X)
  if space > 0 then
    write(x, y, fit(text, space), FG, BG)
  end
end

local function render()
  gpu.setBackground(BG)
  gpu.fill(1, 1, W, H, " ")

  write(1, 1, fit("  ocdebug v" .. VERSION .. "    " .. #entries .. " components attached", W), FG, BAR)
  write(1, H, fit("  [click/up/down] select   [wheel/pgup/pgdn] scroll   [r] refresh   [q] quit"
    .. "      live every " .. REFRESH_SECONDS .. "s", W), FG, BAR)

  gpu.setBackground(BG)
  gpu.setForeground(DIM)
  gpu.fill(LIST_W + 1, CONTENT_TOP, 1, CONTENT_ROWS, PIPE)

  for row = 1, CONTENT_ROWS do
    local entry = entries[listScroll + row]
    if entry then
      local y = CONTENT_TOP + row - 1
      local isSelected = (listScroll + row) == selected
      local background = isSelected and SELECTED or BG
      write(1, y, " " .. fit(friendlyName(entry), NAME_W) .. " ", FG, background)
      write(NAME_W + 3, y, unicode.sub(entry.address, 1, 6), isSelected and FG or DIM, background)
    end
  end

  for row = 1, CONTENT_ROWS do
    local line = lines[detailScroll + row]
    if line then
      local y = CONTENT_TOP + row - 1
      if line.gauge then
        renderGauge(y, line.gauge)
      elseif line.parts then
        local x = DETAIL_X
        for _, part in ipairs(line.parts) do
          local space = DETAIL_W - (x - DETAIL_X)
          if space <= 0 then
            break
          end
          local text = unicode.sub(part.text, 1, space)
          write(x, y, text, part.color, BG)
          x = x + unicode.len(text)
        end
      else
        write(DETAIL_X, y, fit(line.text, DETAIL_W), line.color, BG)
        if line.right then
          local space = DETAIL_W - unicode.len(line.text) - 2
          if space >= 4 then
            local text = unicode.sub(line.right, 1, space)
            write(DETAIL_X + DETAIL_W - unicode.len(text), y, text, line.rightColor, BG)
          end
        end
      end
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
  local name, _, arg1, arg2, arg3 = event.pull(REFRESH_SECONDS)

  if name == nil then
    rescan()
  elseif name == "interrupted" then
    break
  elseif name == "key_down" then
    if arg2 == keyboard.keys.q then
      break
    elseif arg2 == keyboard.keys.r then
      rescan()
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

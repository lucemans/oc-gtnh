-- ocdebug: browse the attached components, their methods and their values

local component = require("component")
local event = require("event")
local keyboard = require("keyboard")
local serialization = require("serialization")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.3.0"

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

-- written as bytes rather than \u{} so the file still loads on a Lua 5.2 CPU
local FULL_BLOCK = "\226\150\136"
local LIGHT_BLOCK = "\226\150\145"
local SECTION = "\194\167"

-- GregTech writes its sensor lines with Minecraft colour codes, so the values
-- can be shown in the colours the game itself uses for them
local MC_COLORS = {
  ["0"] = 0x000000, ["1"] = 0x0000AA, ["2"] = 0x00AA00, ["3"] = 0x00AAAA,
  ["4"] = 0xAA0000, ["5"] = 0xAA00AA, ["6"] = 0xFFAA00, ["7"] = 0xAAAAAA,
  ["8"] = 0x555555, ["9"] = 0x5555FF, ["a"] = 0x55FF55, ["b"] = 0x55FFFF,
  ["c"] = 0xFF5555, ["d"] = 0xFF55FF, ["e"] = 0xFFFF55, ["f"] = 0xFFFFFF,
}

local READABLE = { "get", "is", "has" }

local function isReadable(name)
  for _, prefix in ipairs(READABLE) do
    if name:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

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

local function strip(text)
  return (text:gsub(SECTION .. "%w", ""))
end

local function segments(text, default)
  local parts = {}
  local color = default
  local index = 1
  while true do
    local start, stop, code = text:find(SECTION .. "(%w)", index)
    if not start then
      if index <= #text then
        parts[#parts + 1] = { text = text:sub(index), color = color }
      end
      return parts
    end
    if start > index then
      parts[#parts + 1] = { text = text:sub(index, start - 1), color = color }
    end
    color = MC_COLORS[code:lower()] or default
    index = stop + 1
  end
end

-- component.methods maps a name to whether the call is direct, so an indirect
-- method is present with the value false; only nil means "not offered"
local function has(methods, name)
  return methods ~= nil and methods[name] ~= nil
end

local function try(fn, ...)
  local ok, value = pcall(fn, ...)
  if ok then
    return value
  end
  return nil
end

local function call(address, method)
  local results = table.pack(pcall(component.invoke, address, method))
  if not results[1] then
    return nil
  end
  return table.unpack(results, 2, results.n)
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

local function oneLine(text)
  return (text:gsub("%s+", " "))
end

local function formatValue(value)
  local kind = type(value)
  if kind == "string" then
    return oneLine(value)
  elseif kind == "table" then
    local ok, text = pcall(serialization.serialize, value)
    return ok and oneLine(text) or "table"
  end
  return tostring(value)
end

-- only readable methods are invoked: a setter or an action would change the world
local function preview(address, name)
  local results = table.pack(pcall(component.invoke, address, name))
  if not results[1] then
    return oneLine(tostring(results[2])), FAILED
  end
  if results.n < 2 then
    return nil
  end
  local parts = {}
  for i = 2, results.n do
    parts[#parts + 1] = formatValue(results[i])
  end
  return table.concat(parts, ", "), VALUE
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

local function toNumber(text)
  return tonumber((text:gsub(",", "")))
end

-------------------------------------------------------------------------------
-- what a component says about itself

local function sensorOf(address)
  local methods = try(component.methods, address)
  if not has(methods, "getSensorInformation") then
    return nil
  end
  local lines = call(address, "getSensorInformation")
  if type(lines) ~= "table" or not lines[1] then
    return nil
  end
  return lines
end

local function friendlyName(entry)
  if entry.friendly ~= nil then
    return entry.friendly or entry.kind
  end
  entry.friendly = false

  local sensor = sensorOf(entry.address)
  if sensor then
    entry.friendly = strip(sensor[1])
  else
    local methods = try(component.methods, entry.address)
    if has(methods, "getName") then
      local name = call(entry.address, "getName")
      if type(name) == "string" and name ~= "" then
        entry.friendly = (name:gsub("%.", " "))
      end
    end
  end
  return entry.friendly or entry.kind
end

-- GregTech marks the current value green and the maximum yellow, on both
-- tanks and energy buffers, so one rule covers every machine that reports one
local function gaugeFromSensor(raw, color)
  local current = raw:match(SECTION .. "a([%d,]+)")
  local maximum = raw:match(SECTION .. "e([%d,]+)")
  if not (current and maximum) then
    return nil
  end
  local value, limit = toNumber(current), toNumber(maximum)
  if not value or not limit or limit <= 0 then
    return nil
  end
  local plain = strip(raw)
  return {
    value = value,
    max = limit,
    current = current,
    maximum = maximum,
    unit = plain:match("(%a+)%s*$") or "",
    color = color,
    -- whatever precedes the first number labels the reading, e.g. "Stored Items:";
    -- a line that opens with the number, as a tank's does, has no label
  }, oneLine((plain:match("^(.-)%d") or ""):gsub("%s+$", ""))
end

local function statusOf(address, methods)
  local flags = {}
  if has(methods, "isMachineActive") then
    flags[#flags + 1] = call(address, "isMachineActive") and "active" or "idle"
  end
  if has(methods, "isWorkAllowed") and call(address, "isWorkAllowed") == false then
    flags[#flags + 1] = "disabled"
  end
  if has(methods, "hasWork") and call(address, "hasWork") then
    flags[#flags + 1] = "working"
  end
  return #flags > 0 and table.concat(flags, "  ") or nil
end

local function summaryLines(entry, methods, add)
  local sensor = sensorOf(entry.address)
  local lastColor = nil

  if sensor then
    -- the first line is the machine's display name, already used as the header
    for index = 2, #sensor do
      local raw = tostring(sensor[index])
      local gauge, label = gaugeFromSensor(raw, lastColor or VALUE)
      if gauge then
        if label and label ~= "" then
          add(label, DIM)
        end
        add(nil, nil, nil, nil, gauge)
      else
        local parts = segments(raw, FG)
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
  end

  -- progress is not in the sensor text but matters while a machine runs
  if has(methods, "getWorkMaxProgress") and has(methods, "getWorkProgress") then
    local maximum = call(entry.address, "getWorkMaxProgress")
    local value = call(entry.address, "getWorkProgress")
    if type(maximum) == "number" and type(value) == "number" and maximum > 0 then
      add("Progress", DIM)
      add(nil, nil, nil, nil, {
        value = value,
        max = maximum,
        current = comma(value),
        maximum = comma(maximum),
        unit = "",
        color = VALUE,
      })
    end
  end

  -- with no sensor text there is still a usable energy reading on GT blocks
  if not sensor and has(methods, "getEUStored") and has(methods, "getEUMaxStored") then
    local value = call(entry.address, "getEUStored")
    local maximum = call(entry.address, "getEUMaxStored")
    if type(value) == "number" and type(maximum) == "number" and maximum > 0 then
      add(nil, nil, nil, nil, {
        value = value,
        max = maximum,
        current = comma(value),
        maximum = comma(maximum),
        unit = "EU",
        color = 0xFFFF55,
      })
    end
  end
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

  local methods = try(component.methods, entry.address) or {}

  add(friendlyName(entry), FG, statusOf(entry.address, methods), VALUE)

  local where = ""
  if has(methods, "getCoordinates") then
    local x, y, z = call(entry.address, "getCoordinates")
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

  add(string.rep("\226\148\128", math.min(DETAIL_W, 20)) .. " methods", DIM)

  for _, name in ipairs(names) do
    if isReadable(name) then
      add(name, FG, preview(entry.address, name))
    else
      add(name, FG)
    end
    local doc = try(component.doc, entry.address, name)
    if doc then
      for _, text in ipairs(wrap(doc, DETAIL_W - 2)) do
        add("  " .. text, DIM)
      end
    end
  end

  return lines
end

-------------------------------------------------------------------------------

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
  write(1, H, fit("  [click/up/down] select    [wheel/pgup/pgdn] scroll    [q] quit", W), FG, BAR)

  gpu.setBackground(BG)
  gpu.setForeground(DIM)
  gpu.fill(LIST_W + 1, CONTENT_TOP, 1, CONTENT_ROWS, "\226\148\130")

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

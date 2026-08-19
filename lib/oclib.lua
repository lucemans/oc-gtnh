-- oclib: the parts that are not specific to any mod. Component access, reading
-- values without ever failing, Minecraft colour codes, and shared configuration.
-- ocgt and oclogistics both build on this.

local component = require("component")
local serialization = require("serialization")

local core = {}

core.VERSION = "0.8.0"

-- the Minecraft section sign, two bytes in UTF-8
core.SECTION = "\194\167"
local SECTION = core.SECTION

core.CONFIG_PATH = "/etc/ocgt.cfg"

-- the port ocserve answers on and ocview asks on
core.PORT = 4021

core.MC_COLORS = {
  ["0"] = 0x000000, ["1"] = 0x0000AA, ["2"] = 0x00AA00, ["3"] = 0x00AAAA,
  ["4"] = 0xAA0000, ["5"] = 0xAA00AA, ["6"] = 0xFFAA00, ["7"] = 0xAAAAAA,
  ["8"] = 0x555555, ["9"] = 0x5555FF, ["a"] = 0x55FF55, ["b"] = 0x55FFFF,
  ["c"] = 0xFF5555, ["d"] = 0xFF55FF, ["e"] = 0xFFFF55, ["f"] = 0xFFFFFF,
}

-- "can" is deliberately absent: cancelCrafting starts with it too
local READABLE = { "get", "is", "has" }

-- a setter sits in the same method list as a getter, so only these are called
function core.isReadable(name)
  for _, prefix in ipairs(READABLE) do
    if name:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

-- component.methods maps a name to whether the call is direct, so an indirect
-- method is present with the value false; only nil means "not offered"
function core.has(methods, name)
  return methods ~= nil and methods[name] ~= nil
end

function core.methodsOf(address)
  local ok, methods = pcall(component.methods, address)
  return ok and methods or nil
end

-- Arguments are passed through: a transposer answers nothing useful without
-- being told which of its six sides is meant.
function core.call(address, method, ...)
  local results = table.pack(pcall(component.invoke, address, method, ...))
  if not results[1] then
    return nil
  end
  return table.unpack(results, 2, results.n)
end

-- The one place a method that changes the world may be called. Inspection
-- programs must never reach for this; ocwatch acts through it deliberately.
--
-- Whatever the method returned comes back after the success flag. A call that
-- does not raise has still not necessarily done anything: a speech box with no
-- text-to-speech on the server answers its say with false, and reading that as
-- success is how a silent alert looked like a working one.
function core.setValue(address, method, ...)
  local results = table.pack(pcall(component.invoke, address, method, ...))
  if not results[1] then
    return nil, core.oneLine(tostring(results[2]))
  end
  return true, table.unpack(results, 2, results.n)
end

function core.strip(text)
  return (text:gsub(SECTION .. "%w", ""))
end

function core.oneLine(text)
  return (text:gsub("%s+", " "))
end

-- split on colour codes so each run can be drawn in the colour the game chose
function core.segments(text, default)
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
    color = core.MC_COLORS[code:lower()] or default
    index = stop + 1
  end
end

-- The drawable area, which is not always the resolution. A viewport can be set
-- smaller than the buffer, and OpenOS's own terminal measures itself this way.
-- A screen_resized signal means this has changed and a layout must be redone.
function core.viewport(gpu)
  local ok, width, height = pcall(gpu.getViewport)
  if ok and type(width) == "number" and type(height) == "number" then
    return width, height
  end
  return gpu.getResolution()
end

-- A super tank holds four million litres and its diesel only ever moves between
-- 5,000 and 10,000, so a bar against the real maximum is empty forever. A local
-- maximum rescales the bar to the part actually in use.
--
-- Once set it is the scale, whatever the value does. Handing the real maximum
-- back as soon as the value went over meant a tank sitting just above the
-- interesting range drew an empty bar again, which is the one moment the bar
-- had to be readable. Above the local maximum the bar simply reads full, and
-- the real capacity is shown beside it so nothing is hidden.
--
-- Returns the maximum to draw against, and whether that is the local one.
function core.scale(gauge, limit)
  if not limit or limit <= 0 then
    return gauge.max, false
  end
  return limit, true
end

-- A painter that only touches the rows whose contents changed.
--
-- Clearing the whole screen and drawing it again every refresh is what makes a
-- dashboard flicker, and on a real machine it spends the GPU call budget on
-- rows that already say the right thing. Draws are collected first, because a
-- row is only worth touching once its whole contents are known.
function core.painter(gpu)
  local drawn, plan = {}, {}
  local painter = {}

  function painter.write(x, row, text, foreground, background)
    local ops = plan[row]
    if not ops then
      ops = { key = "" }
      plan[row] = ops
    end
    ops[#ops + 1] = { x = x, text = text, fg = foreground, bg = background }
    ops.key = ops.key .. x .. "\1" .. text .. "\1"
      .. tostring(foreground) .. "\1" .. tostring(background) .. "\2"
  end

  function painter.flush(width, height, background, foreground)
    for row = 1, height do
      local ops = plan[row]
      local key = ops and ops.key or ""
      if key ~= drawn[row] then
        gpu.setBackground(background)
        gpu.fill(1, row, width, 1, " ")
        for _, op in ipairs(ops or {}) do
          gpu.setForeground(op.fg or foreground)
          gpu.setBackground(op.bg or background)
          gpu.set(op.x, row, op.text)
        end
        drawn[row] = key
      end
    end
    plan = {}
  end

  -- whatever emptied the screen also emptied what this believes is on it
  function painter.forget()
    drawn = {}
  end

  return painter
end

function core.comma(number)
  local text = string.format("%d", number)
  local sign, digits = text:match("^(%-?)(%d+)$")
  if not digits then
    return text
  end
  local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return sign .. grouped
end

-------------------------------------------------------------------------------
-- describing values
--
-- serialization.serialize raises on a table holding a function or userdata, and
-- a Logistics Pipes proxy holds both. These walk anything without failing, and
-- bound themselves so an unexpectedly large table cannot exhaust memory.

local MAX_KEYS = 48
local MAX_DEPTH = 4

local function keyText(key)
  if type(key) == "string" and key:match("^[%a_][%w_]*$") then
    return key
  end
  if type(key) == "string" then
    return "[" .. string.format("%q", key) .. "]"
  end
  return "[" .. tostring(key) .. "]"
end

-- Userdata protects its metatable by setting __metatable, so getmetatable hands
-- back a string rather than the table. The methods are still there and still
-- callable; they just cannot be inspected.
local function metaOf(value)
  local ok, meta = pcall(getmetatable, value)
  if not ok then
    return nil, false
  end
  if type(meta) ~= "table" then
    return nil, meta ~= nil
  end
  return meta, false
end

-- A proxy looks like a plain table of {name=, proxy=} entries, but whether
-- those entries can be called lives in the metatable, not in the fields, so a
-- walk over pairs() alone cannot tell you how to use the thing.
function core.tableKind(value)
  local meta, protected = metaOf(value)
  if protected then
    return "table <protected metatable>"
  end
  if not meta then
    return "table"
  end
  local marks = {}
  if rawget(meta, "__call") then
    marks[#marks + 1] = "callable"
  end
  if rawget(meta, "__index") then
    marks[#marks + 1] = "__index"
  end
  if rawget(meta, "__tostring") then
    marks[#marks + 1] = "__tostring"
  end
  if #marks == 0 then
    return "table"
  end
  return "table <" .. table.concat(marks, ", ") .. ">"
end

local function sortedPairs(value)
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then
      return a < b
    end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function inline(value, depth, seen)
  local kind = type(value)
  if kind == "string" then
    return string.format("%q", core.oneLine(value))
  elseif kind == "number" or kind == "boolean" or kind == "nil" then
    return tostring(value)
  elseif kind ~= "table" then
    return "<" .. kind .. ">"
  end
  if seen[value] then
    return "<cycle>"
  end
  if depth <= 0 then
    return "{...}"
  end

  seen[value] = true
  local parts = {}
  local keys = sortedPairs(value)
  for index, key in ipairs(keys) do
    if index > MAX_KEYS then
      parts[#parts + 1] = "... " .. (#keys - MAX_KEYS) .. " more"
      break
    end
    parts[#parts + 1] = keyText(key) .. "=" .. inline(value[key], depth - 1, seen)
  end
  seen[value] = nil
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- one line, for a value preview next to a method name
function core.formatValue(value)
  if type(value) == "string" then
    return core.oneLine(value)
  end
  return inline(value, 2, {})
end

-- a proxy entry carries its own signature under __tostring, the same way the
-- OpenOS internet library documents its wrapped close
local function callDoc(value)
  local meta = metaOf(value)
  if not meta or not rawget(meta, "__tostring") then
    return nil
  end
  local ok, text = pcall(tostring, value)
  if not ok or type(text) ~= "string" then
    return nil
  end
  text = core.oneLine(text)
  if #text > 140 then
    text = text:sub(1, 140) .. "..."
  end
  return "  -- " .. text
end

-- A proxy method is only called when its own name says it reads. sendMessage
-- and setTurtleConnect sit in the same proxy and would change the world.
local function probe(key, item)
  if type(key) ~= "string" or not core.isReadable(key) then
    return nil
  end
  -- The call is simply attempted rather than gated on a visible __call: a
  -- protected metatable hides that field, and requiring it meant every glasses
  -- widget method was skipped and reported no value at all.
  local results = table.pack(pcall(item))
  if not results[1] then
    return nil, "error: " .. core.oneLine(tostring(results[2]))
  end
  if results.n < 2 then
    return nil, "(no return value)"
  end
  return results
end

-- an indented block, for a dump that someone will read to learn an API
function core.describeLines(value, prefix)
  local lines = {}
  local seen = {}

  local function walk(current, indent, depth)
    local keys = sortedPairs(current)
    seen[current] = true
    for index, key in ipairs(keys) do
      if index > MAX_KEYS then
        lines[#lines + 1] = indent .. "... " .. (#keys - MAX_KEYS) .. " more keys"
        break
      end
      local item = current[key]
      if type(item) == "table" and not seen[item] and depth < MAX_DEPTH then
        lines[#lines + 1] = indent .. keyText(key) .. " = " .. core.tableKind(item)
          .. (callDoc(item) or "")

        local results, note = probe(key, item)
        if note then
          lines[#lines + 1] = indent .. "  -> " .. note
        elseif results then
          for position = 2, results.n do
            local result = results[position]
            -- a proxy method often returns another proxy, so the returned
            -- object is walked rather than flattened onto one line
            if type(result) == "table" and not seen[result] and depth < MAX_DEPTH then
              lines[#lines + 1] = indent .. "  -> " .. core.tableKind(result)
              walk(result, indent .. "    ", depth + 1)
            else
              lines[#lines + 1] = indent .. "  -> " .. inline(result, 2, seen)
            end
          end
        end

        walk(item, indent .. "  ", depth + 1)
      else
        lines[#lines + 1] = indent .. keyText(key) .. " = " .. inline(item, 1, seen)
      end
    end
    seen[current] = nil
  end

  if type(value) ~= "table" then
    return { prefix .. core.formatValue(value) }
  end
  lines[#lines + 1] = prefix .. core.tableKind(value)
  walk(value, prefix:match("^%s*") .. "  ", 1)
  return lines
end

-- reads one method and renders its result; returns nil plus a reason on failure
function core.readValue(address, name)
  local results = table.pack(pcall(component.invoke, address, name))
  if not results[1] then
    return nil, core.oneLine(tostring(results[2]))
  end
  if results.n < 2 then
    return "(no return value)"
  end
  local parts = {}
  for index = 2, results.n do
    parts[#parts + 1] = core.formatValue(results[index])
  end
  return table.concat(parts, ", ")
end

-- the raw values, so a dump can show a table's shape rather than one line
function core.readRaw(address, name)
  local results = table.pack(pcall(component.invoke, address, name))
  if not results[1] then
    return nil, core.oneLine(tostring(results[2]))
  end
  return results
end

-------------------------------------------------------------------------------
-- configuration, shared so a nickname set in ocwatch also shows in ocdebug

local function defaults()
  return { nicknames = {}, watch = {}, alerts = {} }
end

function core.loadConfig()
  local file = io.open(core.CONFIG_PATH, "r")
  if not file then
    return defaults()
  end
  local text = file:read("*a")
  file:close()

  local ok, value = pcall(serialization.unserialize, text)
  if not ok or type(value) ~= "table" then
    return defaults()
  end
  value.nicknames = value.nicknames or {}
  value.watch = value.watch or {}
  value.alerts = value.alerts or {}
  return value
end

function core.saveConfig(config)
  local file, reason = io.open(core.CONFIG_PATH, "w")
  if not file then
    return nil, tostring(reason)
  end
  file:write(serialization.serialize(config))
  file:close()
  return true
end

-- a name the user set always wins over anything a machine says about itself
function core.nickname(config, address)
  local name = config and config.nicknames and config.nicknames[address]
  if name and name ~= "" then
    return name
  end
  return nil
end

return core

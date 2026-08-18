-- A fake OpenComputers machine, enough of it to run the programs in
-- programs/ outside Minecraft: components, a screen buffer, an event queue,
-- a virtual filesystem and a scriptable internet card.
--
-- Configure the state, call install(), then loadfile a program and run it.

local oc = {}

oc.width = 80
oc.height = 20

local screen = {}
local frame = {}

function oc.reset()
  oc.files = {}
  oc.events = {}
  oc.requests = {}
  oc.components = {}
  oc.invoked = {}
  oc.frames = {}
  oc.directories = {}
  oc.deviceInfo = {}
  oc.output = {""}
  oc.osversion = "OpenOS 1.8.9"
  -- tests override this to script the internet card
  oc.respond = function()
    return 404, "Not Found", "missing"
  end
  screen = {}
  frame = {}
  for y = 1, oc.height do
    screen[y] = {}
    for x = 1, oc.width do
      screen[y][x] = " "
    end
  end
end

function oc.push(...)
  oc.events[#oc.events + 1] = table.pack(...)
end

-- the frame captured when the program last blocked on an event, so the exit
-- term.clear() does not wipe what we want to look at
function oc.frame()
  local rows = {}
  for y = 1, oc.height do
    rows[y] = frame[y] or string.rep(" ", oc.width)
  end
  return table.concat(rows, "\n")
end

function oc.printed()
  return table.concat(oc.output, "\n")
end

local function emit(text)
  local start = 1
  while true do
    local newline = text:find("\n", start, true)
    if not newline then
      oc.output[#oc.output] = oc.output[#oc.output] .. text:sub(start)
      return
    end
    oc.output[#oc.output] = oc.output[#oc.output] .. text:sub(start, newline - 1)
    oc.output[#oc.output + 1] = ""
    start = newline + 1
  end
end

local function byAddress(address)
  for _, entry in ipairs(oc.components) do
    if entry.address == address then
      return entry
    end
  end
  error("unknown component: " .. tostring(address), 0)
end

-------------------------------------------------------------------------------
-- component

local gpu = {}
function gpu.getResolution()
  return oc.width, oc.height
end
function gpu.setForeground() end
function gpu.setBackground() end
-- one screen cell holds one character, not one byte: the programs draw with
-- box-drawing and block characters and do their column maths in characters
function gpu.set(x, y, text)
  assert(type(x) == "number" and type(y) == "number", "gpu.set: non-numeric position")
  assert(y >= 1 and y <= oc.height, "gpu.set: row out of bounds: " .. tostring(y))
  assert(x >= 1, "gpu.set: column out of bounds: " .. tostring(x))
  local column = x
  if utf8.len(text) then
    for _, code in utf8.codes(text) do
      if column >= 1 and column <= oc.width then
        screen[y][column] = utf8.char(code)
      end
      column = column + 1
    end
  else
    for i = 1, #text do
      if x + i - 1 <= oc.width then
        screen[y][x + i - 1] = text:sub(i, i)
      end
    end
  end
end
function gpu.fill(x, y, w, h, char)
  for row = y, y + h - 1 do
    for column = x, x + w - 1 do
      if screen[row] and column >= 1 and column <= oc.width then
        screen[row][column] = char
      end
    end
  end
end

local component = { gpu = gpu }

function component.isAvailable(kind)
  if kind == "gpu" then
    return true
  end
  for _, entry in ipairs(oc.components) do
    if entry.kind == kind then
      return true
    end
  end
  return false
end

function component.list()
  local index = 0
  return setmetatable({}, {
    __call = function()
      index = index + 1
      local entry = oc.components[index]
      if entry then
        return entry.address, entry.kind
      end
    end,
  })
end

function component.methods(address)
  local entry = byAddress(address)
  local out = {}
  for name in pairs(entry.methods or {}) do
    out[name] = (entry.direct or {})[name] or false
  end
  return out
end

function component.doc(address, method)
  return (byAddress(address).methods or {})[method]
end

function component.slot(address)
  return byAddress(address).slot or -1
end

function component.invoke(address, method, ...)
  oc.invoked[#oc.invoked + 1] = method
  local entry = byAddress(address)
  local fn = (entry.values or {})[method]
  if not fn then
    error("no such method: " .. method, 0)
  end
  return fn(...)
end

component.internet = {}
function component.internet.request(url, body, headers)
  oc.requests[#oc.requests + 1] = { url = url, body = body, headers = headers }
  local code, message, text = oc.respond(url, body, headers)
  local sent = false
  return {
    finishConnect = function()
      return true
    end,
    response = function()
      return code, message, {}
    end,
    read = function()
      if sent then
        return nil
      end
      sent = true
      return text
    end,
    close = function() end,
  }
end

-------------------------------------------------------------------------------
-- remaining libraries

local computer = {}
function computer.uptime()
  return 2363.7
end
function computer.address()
  return "755c25ca-ccec-4262-bd4a-038440718514"
end
function computer.freeMemory()
  return 1106167
end
function computer.totalMemory()
  return 1572864
end
function computer.energy()
  return 3098
end
function computer.maxEnergy()
  return 3100
end
function computer.getDeviceInfo()
  return oc.deviceInfo or {}
end

local event = {}
function event.pull()
  for y = 1, oc.height do
    frame[y] = table.concat(screen[y])
  end
  -- every frame is kept, so a test can assert that a redraw changed something
  oc.frames[#oc.frames + 1] = table.concat(frame, "\n")
  local queued = table.remove(oc.events, 1)
  if not queued then
    return "key_down", "keyboard", 113, 0x10 -- q, so no test can hang
  end
  return table.unpack(queued, 1, queued.n)
end

local keyboard = {
  keys = { q = 0x10, up = 0xC8, down = 0xD0, pageUp = 0xC9, pageDown = 0xD1 },
}

local term = {}
function term.clear()
  for y = 1, oc.height do
    for x = 1, oc.width do
      screen[y][x] = " "
    end
  end
end
function term.setCursorBlink() end
function term.clearLine()
  oc.output[#oc.output] = ""
end
function term.write(text)
  emit(text)
end

local filesystem = {}

function filesystem.concat(a, b)
  return (a:gsub("/$", "")) .. "/" .. b
end

function filesystem.path(full)
  return full:match("^(.*)/[^/]*$") or "/"
end

function filesystem.exists(path)
  if oc.directories[path] or oc.files[path] then
    return true
  end
  for name in pairs(oc.files) do
    if name:sub(1, #path + 1) == path .. "/" then
      return true
    end
  end
  return false
end

function filesystem.makeDirectory(path)
  oc.directories[path] = true
  return true
end

-- OpenOS counts characters here, not bytes; stubbing these with the string
-- library would let multi-byte drawing characters break every width calculation
local unicode = {}

function unicode.len(text)
  return utf8.len(text) or #text
end

function unicode.sub(text, from, to)
  local length = utf8.len(text)
  if not length then
    return text:sub(from, to)
  end
  if from < 0 then
    from = length + from + 1
  end
  if to == nil then
    to = length
  elseif to < 0 then
    to = length + to + 1
  end
  if from < 1 then
    from = 1
  end
  if to > length then
    to = length
  end
  if from > to then
    return ""
  end
  local first = utf8.offset(text, from)
  local past = utf8.offset(text, to + 1)
  return text:sub(first, past and past - 1 or #text)
end

-- must round-trip: ocgt saves its configuration through these, and the keys
-- include component addresses, which are not valid Lua identifiers
local serialization = {}

local function serializeValue(value)
  local kind = type(value)
  if kind == "string" then
    return string.format("%q", value)
  elseif kind == "table" then
    return serialization.serialize(value)
  end
  return tostring(value)
end

function serialization.serialize(value)
  if type(value) ~= "table" then
    return serializeValue(value)
  end
  local parts = {}
  local count = #value
  for index = 1, count do
    parts[#parts + 1] = serializeValue(value[index])
  end
  local keys = {}
  for key in pairs(value) do
    if not (type(key) == "number" and key >= 1 and key <= count) then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    local name = (type(key) == "string" and key:match("^[%a_][%w_]*$"))
      and key or ("[" .. serializeValue(key) .. "]")
    parts[#parts + 1] = name .. "=" .. serializeValue(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function serialization.unserialize(text)
  local chunk = load("return " .. text, "=config", "t", {})
  if not chunk then
    return nil
  end
  local ok, value = pcall(chunk)
  return ok and value or nil
end

-------------------------------------------------------------------------------

function oc.install()
  package.preload["ocgt"] = function()
    return dofile("lib/ocgt.lua")
  end
  package.preload["oclogistics"] = function()
    return dofile("lib/oclogistics.lua")
  end
  package.preload["component"] = function()
    return component
  end
  package.preload["computer"] = function()
    return computer
  end
  package.preload["event"] = function()
    return event
  end
  package.preload["keyboard"] = function()
    return keyboard
  end
  package.preload["term"] = function()
    return term
  end
  package.preload["filesystem"] = function()
    return filesystem
  end
  package.preload["unicode"] = function()
    return unicode
  end
  package.preload["serialization"] = function()
    return serialization
  end

  _G._OSVERSION = oc.osversion
  os.sleep = function() end

  print = function(...)
    local parts = table.pack(...)
    for index = 1, parts.n do
      parts[index] = tostring(parts[index])
    end
    emit(table.concat(parts, "\t", 1, parts.n) .. "\n")
  end

  io.write = function(...)
    for _, value in ipairs({ ... }) do
      emit(tostring(value))
    end
  end

  io.stderr = {
    write = function(_, ...)
      for _, value in ipairs({ ... }) do
        emit(tostring(value))
      end
    end,
  }

  io.read = function()
    return nil
  end

  io.open = function(path, mode)
    if (mode or "r"):find("w") then
      oc.files[path] = "" -- "w" truncates, matching io.open
      return {
        write = function(_, text)
          oc.files[path] = (oc.files[path] or "") .. text
        end,
        close = function() end,
      }, nil
    end
    local contents = oc.files[path]
    if not contents then
      return nil, "no such file or directory"
    end
    return {
      read = function()
        return contents
      end,
      close = function() end,
    }, nil
  end
end

-- run a program against the current state; returns ok, error
function oc.run(name)
  local chunk, reason = loadfile("programs/" .. name .. ".lua")
  if not chunk then
    return false, reason
  end
  return pcall(chunk)
end

oc.reset()

return oc

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

-- how many filtered waits in a row have found nothing, which is what a hang
-- looks like from in here
local emptyPulls = 0

function oc.reset()
  oc.files = {}
  oc.events = {}
  oc.requests = {}
  oc.components = {}
  oc.invoked = {}
  oc.frames = {}
  oc.fills = {}
  oc.executed = {}
  oc.colors = {}
  oc.reads = {}
  oc.elapsed = 0
  -- how many times a program waiting on a clock is allowed to hear nothing;
  -- tests that watch something happen on a timer raise it
  oc.idle = 0
  -- a program that refuses to do something expensive when the memory is not
  -- there needs both answers, so tests set this
  oc.freeMemory = 1106167
  oc.directories = {}
  oc.deviceInfo = {}
  oc.listeners = {}
  oc.env = {}
  emptyPulls = 0
  oc.timers = {}
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

-- change the screen size mid-run and raise the signal a real screen would
function oc.resize(width, height)
  oc.width, oc.height = width, height
  screen = {}
  for y = 1, oc.height do
    screen[y] = {}
    for x = 1, oc.width do
      screen[y][x] = " "
    end
  end
  oc.push("screen_resized", "screen", width, height)
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

-- the live buffer, not the snapshot taken at the last event.pull: a program that
-- draws and then returns has nothing captured yet
function oc.screen()
  local rows = {}
  for y = 1, oc.height do
    rows[y] = table.concat(screen[y])
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

-- the drawable area; tests resize through oc.resize so both agree
function gpu.getViewport()
  return oc.width, oc.height
end
-- Colour is recorded per cell, not discarded. Without it a closed cell and an
-- opened empty one are both two spaces, so a test cannot tell them apart.
local foreground, background = 0xFFFFFF, 0x000000

function gpu.setForeground(color)
  foreground = color or 0xFFFFFF
end

function gpu.setBackground(color)
  background = color or 0x000000
end

local function paintCell(x, y)
  if not oc.colors[y] then
    oc.colors[y] = {}
  end
  oc.colors[y][x] = { fg = foreground, bg = background }
end
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
        paintCell(column, y)
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
  -- recorded so a test can tell a targeted repaint from clearing the screen
  oc.fills[#oc.fills + 1] = { x = x, y = y, w = w, h = h, char = char }
  for row = y, y + h - 1 do
    for column = x, x + w - 1 do
      if screen[row] and column >= 1 and column <= oc.width then
        screen[row][column] = char
        paintCell(column, row)
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

function component.proxy(address)
  for _, entry in ipairs(oc.components) do
    if entry.address == address then
      local proxy = { address = entry.address, type = entry.kind }
      for name in pairs(entry.methods or {}) do
        proxy[name] = function(...)
          return component.invoke(entry.address, name, ...)
        end
      end
      return proxy
    end
  end
  return nil
end

function component.getPrimary(kind)
  for _, entry in ipairs(oc.components) do
    if entry.kind == kind then
      local proxy = { address = entry.address, type = entry.kind }
      for name in pairs(entry.methods or {}) do
        proxy[name] = function(...)
          return component.invoke(entry.address, name, ...)
        end
      end
      return proxy
    end
  end
  error("no primary " .. tostring(kind), 0)
end

-- the real one takes a filter, and matches a type that contains it
function component.list(filter)
  local index = 0
  return setmetatable({}, {
    __call = function()
      while true do
        index = index + 1
        local entry = oc.components[index]
        if not entry then
          return nil
        end
        if not filter or entry.kind:find(filter, 1, true) then
          return entry.address, entry.kind
        end
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

function component.type(address)
  return byAddress(address).kind
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

-- Time advances, as it must: a program waiting on a real-time deadline would
-- otherwise spin forever against a frozen clock. It only moves inside
-- event.pull, so seeding at startup stays reproducible.
function computer.uptime()
  return 2363.7 + oc.elapsed
end
function computer.address()
  return "755c25ca-ccec-4262-bd4a-038440718514"
end
function computer.tmpAddress()
  return "ab644ac9-35ab-4eb4-91fe-4b45750f14b0"
end
function computer.freeMemory()
  return oc.freeMemory
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
function computer.pushSignal(...)
  oc.push(...)
end

local event = {}

-- Every signal reaches every listener before anybody waiting on event.pull sees
-- it, which is how a daemon like Minitel does its work while a program is
-- blocked on the keyboard.
local function dispatch(signal)
  local handlers = oc.listeners[signal[1]]
  for index = 1, #(handlers or {}) do
    handlers[index](table.unpack(signal, 1, signal.n))
  end
end

local function fireTimers()
  local now = computer.uptime()
  for id, timer in pairs(oc.timers) do
    if timer.at <= now then
      timer.times = timer.times - 1
      timer.at = now + math.max(timer.interval, 0.05)
      if timer.times <= 0 then
        oc.timers[id] = nil
      end
      timer.fn()
    end
  end
end

function event.listen(name, handler)
  oc.listeners[name] = oc.listeners[name] or {}
  local handlers = oc.listeners[name]
  for _, each in ipairs(handlers) do
    if each == handler then
      return false
    end
  end
  handlers[#handlers + 1] = handler
  return true
end

function event.ignore(name, handler)
  for index, each in ipairs(oc.listeners[name] or {}) do
    if each == handler then
      table.remove(oc.listeners[name], index)
      return true
    end
  end
  return false
end

local nextTimer = 0

function event.timer(interval, handler, times)
  nextTimer = nextTimer + 1
  oc.timers[nextTimer] = {
    at = computer.uptime() + (tonumber(interval) or 0),
    interval = tonumber(interval) or 0,
    times = tonumber(times) or 1,
    fn = handler,
  }
  return nextTimer
end

function event.cancel(id)
  if oc.timers[id] then
    oc.timers[id] = nil
    return true
  end
  return false
end

-- The event system running with no program in it: signals reach their
-- listeners and timers fire. That is what a daemon does between one program
-- exiting and the next one starting, and a packet queued by Minitel is only
-- put on the wire by its timer.
function oc.pump(rounds)
  for _ = 1, rounds or 4 do
    fireTimers()
    while oc.events[1] do
      local queued = table.remove(oc.events, 1)
      oc.elapsed = oc.elapsed + 0.05
      dispatch(queued)
    end
  end
end

-- A filtered wait that never finds anything is how a program hangs. The real
-- machine would sit there; here it has to stop, and say which event was waited
-- for rather than run out the clock.
local PATIENCE = 500

function event.pull(timeout, filter)
  -- the real event.pull takes the name in the first argument too, and Minitel
  -- calls it that way
  if type(timeout) == "string" then
    timeout, filter = nil, timeout
  end

  for y = 1, oc.height do
    frame[y] = table.concat(screen[y])
  end
  -- every frame is kept, so a test can assert that a redraw changed something
  oc.frames[#oc.frames + 1] = table.concat(frame, "\n")

  fireTimers()

  -- A signal that does not match the filter is dispatched and then dropped,
  -- as the real event.pull does. It is not kept for the next caller, which is
  -- why a blocking library call loses the keypresses that arrive during it.
  while oc.events[1] do
    local queued = table.remove(oc.events, 1)
    -- a queued event arrives promptly, but not instantly
    oc.elapsed = oc.elapsed + 0.05
    dispatch(queued)
    if not filter or queued[1] == filter then
      emptyPulls = 0
      return table.unpack(queued, 1, queued.n)
    end
  end

  -- nothing matching, so the caller's timeout elapses in full
  oc.elapsed = oc.elapsed + (tonumber(timeout) or 1)
  fireTimers()
  if filter then
    emptyPulls = emptyPulls + 1
    if emptyPulls > PATIENCE then
      emptyPulls = 0
      error("waited " .. PATIENCE .. " times for a " .. filter
        .. " that never came", 0)
    end
    return nil
  end
  emptyPulls = 0
  -- A program that works on a clock only does so between events, so a test that
  -- wants to watch it tick asks for a number of quiet waits first. Without them
  -- nothing on a timer is ever seen to happen; without a limit a test hangs.
  if timeout and oc.idle > 0 then
    oc.idle = oc.idle - 1
    return nil
  end
  return "key_down", "keyboard", 113, 0x10 -- q, so no test can hang
end

local keyboard = {
  keys = {
    q = 0x10, e = 0x12, r = 0x13,
    up = 0xC8, down = 0xD0, pageUp = 0xC9, pageDown = 0xD1,
    space = 0x39, enter = 0x1C,
    d = 0x20, m = 0x32, n = 0x31, v = 0x2F, t = 0x14, w = 0x11, back = 0x0E,
  },
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

-- The real terminal overwrites the row the cursor sits on. Modelling that would
-- need a grid; instead every repaint becomes its own output line, so a test sees
-- the whole sequence of states a row passed through rather than only the last.
function term.getCursor()
  return 1, #oc.output
end

function term.setCursor()
  oc.output[#oc.output + 1] = ""
end

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

function filesystem.list(folder)
  local names, seen = {}, {}
  for path in pairs(oc.files) do
    local name = path:match("^" .. folder .. "/([^/]+)$")
    if name and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  table.sort(names)
  local index = 0
  return function()
    index = index + 1
    return names[index]
  end
end

function filesystem.makeDirectory(path)
  oc.directories[path] = true
  return true
end

function filesystem.remove(path)
  if oc.files[path] == nil then
    return nil, "no such file or directory"
  end
  oc.files[path] = nil
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
  package.preload["sh"] = function()
    return {
      execute = function(_, command)
        oc.executed[#oc.executed + 1] = command
        -- the shell writes the command's output to the redirect target, which
        -- occonnect then reads back
        local target = command:match(">%s*(%S+)%s*$")
        if target then
          oc.files[target] = "output of " .. (command:match("^(.-)%s*>") or command)
        end
        return true
      end,
    }
  end
  package.preload["oclib"] = function()
    return dofile("lib/oclib.lua")
  end
  package.preload["ocgt"] = function()
    return dofile("lib/ocgt.lua")
  end
  package.preload["oclogistics"] = function()
    return dofile("lib/oclogistics.lua")
  end
  package.preload["ocrailcraft"] = function()
    return dofile("lib/ocrailcraft.lua")
  end
  package.preload["octank"] = function()
    return dofile("lib/octank.lua")
  end
  package.preload["occomputronics"] = function()
    return dofile("lib/occomputronics.lua")
  end
  package.preload["ocsecurity"] = function()
    return dofile("lib/ocsecurity.lua")
  end
  package.preload["ocnotify"] = function()
    return dofile("lib/ocnotify.lua")
  end
  package.preload["ocgtp"] = function()
    return dofile("lib/ocgtp.lua")
  end
  package.preload["ocnet"] = function()
    return dofile("lib/ocnet.lua")
  end
  package.preload["minitel"] = function()
    return dofile("lib/minitel.lua")
  end
  package.preload["syslog"] = function()
    return dofile("lib/syslog.lua")
  end
  -- syslog names the program that logged when it is not told one; nothing here
  -- leaves it out, so this only has to exist
  package.preload["process"] = function()
    return { info = function()
      return { path = "?" }
    end }
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
  -- OpenOS keeps the shell environment here, and HOSTNAME in it, which is a
  -- copy of /etc/hostname taken whenever `hostname --update` last ran and can
  -- say something the file no longer does
  os.getenv = function(name)
    return oc.env[name]
  end
  os.sleep = function() end
  -- held still alongside computer.uptime, so anything seeding a generator from
  -- the clock lays out the same board on every run and a test can rely on it
  os.time = function()
    return 1700000000
  end

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

  -- tests queue answers in oc.reads to drive a prompt
  io.read = function()
    return table.remove(oc.reads, 1)
  end

  io.open = function(path, mode)
    mode = mode or "r"
    if mode:find("w") or mode:find("a") then
      if mode:find("w") then
        oc.files[path] = "" -- "w" truncates where "a" keeps, matching io.open
      end
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
    -- Reading from somewhere other than the start is how a program looks at the
    -- end of a file it cannot afford to read whole.
    local at = 0
    return {
      read = function()
        local rest = contents:sub(at + 1)
        at = #contents
        return rest
      end,
      seek = function(_, whence, offset)
        offset = offset or 0
        if whence == "end" then
          at = #contents + offset
        elseif whence == "set" then
          at = offset
        else
          at = at + offset
        end
        at = math.max(0, math.min(#contents, at))
        return at
      end,
      close = function() end,
    }, nil
  end
end

-- Loads an rc service the way OpenOS does, into an environment of its own, and
-- hands back that environment so a test can call start and stop on it. Running
-- the real Minitel daemon is what makes a network test test the protocol rather
-- than our idea of it.
function oc.service(path)
  local env = setmetatable({}, { __index = _G })
  local chunk, reason = loadfile(path, "t", env)
  if not chunk then
    return nil, reason
  end
  local ok, failure = pcall(chunk)
  if not ok then
    return nil, failure
  end
  return env
end

-- run a program against the current state; returns ok, error
-- anything after the name reaches the program as its command line arguments
function oc.run(name, ...)
  local chunk, reason = loadfile("programs/" .. name .. ".lua")
  if not chunk then
    return false, reason
  end
  return pcall(chunk, ...)
end

oc.reset()

return oc

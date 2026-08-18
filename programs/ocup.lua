-- ocup: installs the latest programs from https://github.com/lucemans/oc-gtnh
--
-- Bootstrap on a fresh computer:
--   wget https://raw.githubusercontent.com/lucemans/oc-gtnh/refs/heads/master/programs/ocup.lua /bin/ocup.lua

local component = require("component")
local filesystem = require("filesystem")
local term = require("term")

local VERSION = "0.4.0"

local BASE_URL = "https://raw.githubusercontent.com/lucemans/oc-gtnh/refs/heads/master/programs/"
-- the library is fetched first: the programs that require it are useless without it
local FILES = {
  { source = "lib/ocgt.lua", target = "/lib/ocgt.lua" },
  { source = "ocup.lua", target = "/bin/ocup.lua" },
  { source = "ocdebug.lua", target = "/bin/ocdebug.lua" },
  { source = "ocdump.lua", target = "/bin/ocdump.lua" },
}

local WHITE = 0xFFFFFF
local DIM = 0x999999
local GREEN = 0x66CC66
local CYAN = 0x66CCFF
local RED = 0xCC6666

local gpu = component.isAvailable("gpu") and component.gpu or nil

local function paint(color)
  if gpu then
    gpu.setForeground(color)
  end
end

local function write(text, color)
  paint(color)
  io.write(text)
end

-- written as bytes rather than \u{} so the file still loads on a Lua 5.2 CPU
local FULL_BLOCK = "\226\150\136"
local LIGHT_BLOCK = "\226\150\145"

local function bar(done, total, width)
  local filled = math.floor(width * done / total + 0.5)
  return "[" .. string.rep(FULL_BLOCK, filled) .. string.rep(LIGHT_BLOCK, width - filled) .. "]"
end

local function waitForConnect(handle)
  while true do
    local ok, connected, reason = pcall(handle.finishConnect)
    if not ok then
      return nil, connected
    end
    if connected then
      return true
    end
    if connected == nil then
      return nil, reason
    end
    os.sleep(0)
  end
end

-- the component handle is used directly: the "internet" library wraps it in a
-- table whose close field shadows the real method and is not callable
local function download(url)
  local handle, reason = component.internet.request(url)
  if not handle then
    return nil, tostring(reason)
  end

  local connected, connectReason = waitForConnect(handle)
  if not connected then
    handle.close()
    return nil, tostring(connectReason)
  end

  local code, message = handle.response()
  if code ~= 200 then
    handle.close()
    return nil, "HTTP " .. tostring(code) .. " " .. tostring(message)
  end

  local chunks = {}
  while true do
    local chunk, readReason = handle.read()
    if chunk == nil then
      handle.close()
      if readReason then
        return nil, tostring(readReason)
      end
      return table.concat(chunks)
    end
    -- an empty chunk means the socket has no data yet, not end of stream
    if #chunk > 0 then
      chunks[#chunks + 1] = chunk
    else
      os.sleep(0)
    end
  end
end

local function readFile(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local contents = file:read("*a")
  file:close()
  return contents
end

local function writeFile(path, contents)
  local file, reason = io.open(path, "w")
  if not file then
    return nil, tostring(reason)
  end
  file:write(contents)
  file:close()
  return true
end

local function versionOf(text)
  return text and text:match('VERSION%s*=%s*"([^"]+)"') or nil
end

local function describe(existing, contents)
  local version = versionOf(contents)
  if not existing then
    return "installed   v" .. (version or "?"), GREEN
  end
  if existing == contents then
    return "up to date  v" .. (version or "?"), DIM
  end
  local was = versionOf(existing)
  if was and version and was ~= version then
    return "updated     v" .. was .. " -> v" .. version, GREEN
  end
  return "changed     v" .. (version or "?"), CYAN
end

if not component.isAvailable("internet") then
  io.stderr:write("ocup: no internet card installed\n")
  return 1
end

local nameWidth = 0
for _, file in ipairs(FILES) do
  nameWidth = math.max(nameWidth, #file.source)
end

write("ocup v" .. VERSION .. "\n\n", WHITE)

local failed = 0
for index, file in ipairs(FILES) do
  local name = file.source
  term.clearLine()
  write("  " .. bar(index - 1, #FILES, 12) .. " ", CYAN)
  write(name, DIM)

  local path = file.target
  local directory = filesystem.path(path)
  if not filesystem.exists(directory) then
    filesystem.makeDirectory(directory)
  end
  local existing = readFile(path)
  local contents, reason = download(BASE_URL .. name)

  local status, color
  if not contents then
    status, color = "failed      " .. reason, RED
    failed = failed + 1
  else
    -- overwriting ocup.lua while it runs is safe: OpenOS loads the whole file first
    local ok, writeReason = writeFile(path, contents)
    if ok then
      status, color = describe(existing, contents)
    else
      status, color = "failed      " .. writeReason, RED
      failed = failed + 1
    end
  end

  term.clearLine()
  write("  " .. name .. string.rep(" ", nameWidth - #name) .. "  ", WHITE)
  write(status .. "\n", color)
end

term.clearLine()
write("  " .. bar(#FILES, #FILES, 12) .. " ", CYAN)
if failed > 0 then
  write(failed .. " of " .. #FILES .. " failed\n", RED)
  paint(WHITE)
  return 1
end
write(#FILES .. " files ready\n", GREEN)
paint(WHITE)

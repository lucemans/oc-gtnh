-- ocup: installs the latest programs from https://github.com/lucemans/oc-gtnh
--
-- Bootstrap on a fresh computer:
--   wget https://raw.githubusercontent.com/lucemans/oc-gtnh/refs/heads/master/programs/ocup.lua /bin/ocup.lua

local component = require("component")
local filesystem = require("filesystem")
local term = require("term")

local VERSION = "0.6.0"

local BASE_URL = "https://raw.githubusercontent.com/lucemans/oc-gtnh/refs/heads/master/"
local MANIFEST = "manifest.txt"
local SELF = "programs/ocup.lua"

-- the folder a file lives in decides where it installs
local DESTINATIONS = { programs = "/bin/", lib = "/lib/" }

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
  local directory = filesystem.path(path)
  if not filesystem.exists(directory) then
    filesystem.makeDirectory(directory)
  end
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

local function parseManifest(text)
  local files = {}
  for entry in text:gmatch("[^\n]+") do
    local source = entry:match("^%s*(%S+)%s*$")
    if source then
      -- both captures are bound here: "a and a:match()" would keep only the first
      local folder, name = source:match("^(%w+)/(.+)$")
      local destination = folder and DESTINATIONS[folder]
      if destination then
        files[#files + 1] = { source = source, target = destination .. name }
      end
    end
  end
  return files
end

-------------------------------------------------------------------------------

local arguments = { ... }
local reloaded = arguments[1] == "--reloaded"

if not component.isAvailable("internet") then
  io.stderr:write("ocup: no internet card installed\n")
  return 1
end

write("ocup v" .. VERSION .. (reloaded and "  (reloaded)" or "") .. "\n\n", WHITE)

term.clearLine()
write("  fetching manifest", DIM)
local manifestText, manifestReason = download(BASE_URL .. MANIFEST)
if not manifestText then
  term.clearLine()
  write("  manifest failed: " .. manifestReason .. "\n", RED)
  paint(WHITE)
  return 1
end

local FILES = parseManifest(manifestText)
if #FILES == 0 then
  term.clearLine()
  write("  manifest is empty\n", RED)
  paint(WHITE)
  return 1
end

-- ocup updates itself first and hands over to the new copy, so the rest of the
-- run already uses the behaviour that was just downloaded
if not reloaded then
  for _, file in ipairs(FILES) do
    if file.source == SELF then
      local current = readFile(file.target)
      local latest = download(BASE_URL .. file.source)
      if latest and latest ~= current then
        term.clearLine()
        write("  " .. file.source .. "  ", WHITE)
        local status, color = describe(current, latest)
        write(status .. "\n", color)
        if writeFile(file.target, latest) then
          write("  reloading into the new ocup\n\n", CYAN)
          paint(WHITE)
          local chunk = loadfile(file.target)
          if chunk then
            return chunk("--reloaded")
          end
        end
      end
      break
    end
  end
end

local nameWidth = 0
for _, file in ipairs(FILES) do
  nameWidth = math.max(nameWidth, #file.source)
end

local function label(name)
  return "  " .. name .. string.rep(" ", nameWidth - #name) .. "  "
end

-- Everything is fetched before anything is written. Writing as it goes would
-- let one failed download leave the programs newer than the library they
-- require, which breaks every one of them until the next run.
local failure = nil
for index, file in ipairs(FILES) do
  term.clearLine()
  write("  " .. bar(index - 1, #FILES, 12) .. " ", CYAN)
  write(file.source, DIM)

  local contents, reason = download(BASE_URL .. file.source)
  if not contents then
    failure = { source = file.source, reason = reason }
    break
  end
  file.contents = contents
end

if failure then
  term.clearLine()
  write(label(failure.source), WHITE)
  write("failed      " .. failure.reason .. "\n", RED)
  write("  nothing was installed, the machine is unchanged\n", RED)
  paint(WHITE)
  return 1
end

local failed = 0
for _, file in ipairs(FILES) do
  local existing = readFile(file.target)
  -- overwriting a running program is safe: OpenOS loads the whole file first
  local ok, writeReason = writeFile(file.target, file.contents)

  local status, color
  if ok then
    status, color = describe(existing, file.contents)
  else
    status, color = "failed      " .. writeReason, RED
    failed = failed + 1
  end

  term.clearLine()
  write(label(file.source), WHITE)
  write(status .. "\n", color)
end

term.clearLine()
write("  " .. bar(#FILES, #FILES, 12) .. " ", CYAN)
if failed > 0 then
  write(failed .. " of " .. #FILES .. " could not be written\n", RED)
  paint(WHITE)
  return 1
end
write(#FILES .. " files ready\n", GREEN)
paint(WHITE)

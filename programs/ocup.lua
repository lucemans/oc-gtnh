-- ocup: installs the latest programs from https://github.com/lucemans/oc-gtnh
--
-- Bootstrap on a fresh computer:
--   wget https://raw.githubusercontent.com/lucemans/oc-gtnh/refs/heads/master/programs/ocup.lua /bin/ocup.lua

local component = require("component")
local filesystem = require("filesystem")

local BASE_URL = "https://raw.githubusercontent.com/lucemans/oc-gtnh/refs/heads/master/programs/"
local INSTALL_DIR = "/bin"
local PROGRAMS = {
  "ocup.lua",
  "ocdebug.lua",
  "ocdump.lua",
}

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

local function install(path, contents)
  local file, reason = io.open(path, "w")
  if not file then
    return nil, tostring(reason)
  end
  file:write(contents)
  file:close()
  return true
end

if not component.isAvailable("internet") then
  io.stderr:write("ocup: no internet card installed\n")
  return 1
end

local failed = 0
for _, name in ipairs(PROGRAMS) do
  local path = filesystem.concat(INSTALL_DIR, name)
  local contents, reason = download(BASE_URL .. name)
  if not contents then
    io.stderr:write("ocup: " .. name .. ": " .. reason .. "\n")
    failed = failed + 1
  else
    -- overwriting ocup.lua while it runs is safe: OpenOS loads the whole file first
    local ok, writeReason = install(path, contents)
    if ok then
      print(path .. " (" .. #contents .. " bytes)")
    else
      io.stderr:write("ocup: " .. path .. ": " .. writeReason .. "\n")
      failed = failed + 1
    end
  end
end

if failed > 0 then
  io.stderr:write("ocup: " .. failed .. " of " .. #PROGRAMS .. " failed\n")
  return 1
end

print("ocup: " .. #PROGRAMS .. " programs up to date")

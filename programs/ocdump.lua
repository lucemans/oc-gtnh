-- writes a system dump with information about peripherals (components)
-- uploads as private unlisted pastebin
-- includes values for `get` functions on components

local component = require("component")
local computer = require("computer")
local serialization = require("serialization")

local VERSION = "0.2.0"
local PASTE_URL = "https://dpaste.com/api/v2/"
local EXPIRY_DAYS = "1"
-- multipart avoids percent-encoding the dump, which would cost a whole extra
-- copy of it on a computer that only has a few hundred KB of memory
local BOUNDARY = "ocdump7f3ab21cBOUNDARY"

local out = {}
local function line(text)
  out[#out + 1] = text or ""
end

local function try(fn, ...)
  local ok, value = pcall(fn, ...)
  if ok then
    return value
  end
  return nil
end

local function sortedKeys(source)
  local keys = {}
  for key in pairs(source) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
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

local READABLE = { "get", "is", "has" }

local function isReadable(name)
  for _, prefix in ipairs(READABLE) do
    if name:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

-- only readable methods are invoked: a setter or an action would change the world
local function invoke(address, name)
  local results = table.pack(pcall(component.invoke, address, name))
  if not results[1] then
    return nil, oneLine(tostring(results[2]))
  end
  if results.n < 2 then
    return "(no return value)"
  end
  local parts = {}
  for i = 2, results.n do
    parts[#parts + 1] = formatValue(results[i])
  end
  return table.concat(parts, ", ")
end

local function call(address, method)
  local results = table.pack(pcall(component.invoke, address, method))
  if not results[1] then
    return nil
  end
  return table.unpack(results, 2, results.n)
end

-- GregTech puts the machine's display name in the first sensor line, which is
-- far more useful than either the component type or the internal getName value
local function friendlyName(address)
  local methods = try(component.methods, address)
  if not methods then
    return nil
  end
  -- an indirect method is present with the value false, so only nil means absent
  if methods.getSensorInformation ~= nil then
    local sensor = call(address, "getSensorInformation")
    if type(sensor) == "table" and type(sensor[1]) == "string" then
      return (sensor[1]:gsub("\194\167%w", ""))
    end
  end
  if methods.getName ~= nil then
    local name = call(address, "getName")
    if type(name) == "string" and name ~= "" then
      return name
    end
  end
  return nil
end

local function dumpSystem()
  line("ocdump v" .. VERSION)
  line("uptime      " .. string.format("%.1f", computer.uptime()) .. "s")
  line("os          " .. tostring(_OSVERSION) .. "  " .. tostring(_VERSION))
  line("computer    " .. computer.address())
  line("memory      " .. computer.freeMemory() .. " free of " .. computer.totalMemory())
  line("energy      " .. math.floor(computer.energy()) .. " of " .. math.floor(computer.maxEnergy()))

  local devices = try(computer.getDeviceInfo)
  if devices then
    line("")
    line("== devices ==")
    for _, address in ipairs(sortedKeys(devices)) do
      local ok, text = pcall(serialization.serialize, devices[address])
      line(address .. "  " .. (ok and text or "?"))
    end
  end
end

local function dumpComponent(address, kind)
  line("")
  line("-- " .. kind .. "  " .. address .. "  slot " .. tostring(try(component.slot, address)))

  local methods = try(component.methods, address)
  if not methods then
    line("  (methods unavailable)")
    return
  end

  local names = sortedKeys(methods)
  if #names == 0 then
    line("  (no callable methods)")
  end

  for _, name in ipairs(names) do
    line("  " .. name .. (methods[name] and "" or "  [indirect]"))
    local doc = try(component.doc, address, name)
    if doc then
      line("    doc: " .. oneLine(doc))
    end
    if isReadable(name) then
      local value, reason = invoke(address, name)
      if value then
        line("    value: " .. value)
      else
        line("    error: " .. reason)
      end
    end
  end
end

local function upload(body)
  local parts = {}
  local function field(name, value)
    parts[#parts + 1] = "--" .. BOUNDARY .. "\r\n"
      .. 'Content-Disposition: form-data; name="' .. name .. '"\r\n\r\n'
      .. value .. "\r\n"
  end
  field("content", body)
  field("syntax", "text")
  field("expiry_days", EXPIRY_DAYS)
  parts[#parts + 1] = "--" .. BOUNDARY .. "--\r\n"

  local payload = table.concat(parts)
  local handle, reason = component.internet.request(PASTE_URL, payload,
    { ["Content-Type"] = "multipart/form-data; boundary=" .. BOUNDARY })
  if not handle then
    return nil, tostring(reason)
  end

  while true do
    local ok, connected, connectReason = pcall(handle.finishConnect)
    if not ok then
      handle.close()
      return nil, tostring(connected)
    end
    if connected == nil then
      handle.close()
      return nil, tostring(connectReason)
    end
    if connected then
      break
    end
    os.sleep(0)
  end

  local code, message = handle.response()
  if code ~= 200 and code ~= 201 then
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
      return (table.concat(chunks):gsub("%s+$", ""))
    end
    if #chunk > 0 then
      chunks[#chunks + 1] = chunk
    else
      os.sleep(0)
    end
  end
end

if not component.isAvailable("internet") then
  io.stderr:write("ocdump: no internet card installed\n")
  return 1
end

dumpSystem()

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

print("ocdump v" .. VERSION .. ": reading " .. #entries .. " components...")

line("")
line("== index ==")
for _, entry in ipairs(entries) do
  local friendly = friendlyName(entry.address)
  line(string.format("%-18s %s  %s", entry.kind, entry.address:sub(1, 8), friendly or ""))
end

line("")
line("== components (" .. #entries .. ") ==")
for _, entry in ipairs(entries) do
  dumpComponent(entry.address, entry.kind)
end

local body = table.concat(out, "\n")
out = nil -- the dump is held twice while the request body is built

print("uploading " .. #body .. " bytes...")
local url, reason = upload(body)
if not url then
  io.stderr:write("ocdump: upload failed: " .. reason .. "\n")
  return 1
end

print("")
print("  " .. url .. ".txt")
print("")
print("  expires in " .. EXPIRY_DAYS .. " day, anyone with the link can read it")

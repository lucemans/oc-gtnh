-- ocdump: writes a full system dump and uploads it as an unlisted paste, so it
-- can be handed to someone who needs to understand this machine's setup

local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local core = require("oclib")
local gt = require("ocgt")
local lp = require("oclogistics")
local serialization = require("serialization")

local VERSION = "0.7.0"

local ARCHIVE_DIR = "/home/dumps"
local PASTE_URL = "https://dpaste.com/api/v2/"
local EXPIRY_DAYS = "1"
-- multipart avoids percent-encoding the dump, which would cost a whole extra
-- copy of it on a computer that only has a few hundred KB of memory
local BOUNDARY = "ocdump7f3ab21cBOUNDARY"

-- nicknames set in ocwatch, so a dump names machines the way you do
local config = core.loadConfig()

local out = {}
local function line(text)
  out[#out + 1] = text or ""
end

local function sortedKeys(source)
  local keys = {}
  for key in pairs(source) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local function dumpSystem()
  line("ocdump v" .. VERSION)
  line("uptime      " .. string.format("%.1f", computer.uptime()) .. "s")
  line("os          " .. tostring(_OSVERSION) .. "  " .. tostring(_VERSION))
  line("computer    " .. computer.address())
  line("memory      " .. computer.freeMemory() .. " free of " .. computer.totalMemory())
  line("energy      " .. math.floor(computer.energy()) .. " of " .. math.floor(computer.maxEnergy()))

  local ok, devices = pcall(computer.getDeviceInfo)
  if ok and devices then
    line("")
    line("== devices ==")
    for _, address in ipairs(sortedKeys(devices)) do
      local serialized, text = pcall(serialization.serialize, devices[address])
      line(address .. "  " .. (serialized and text or "?"))
    end
  end
end

local function dumpComponent(address, kind)
  line("")
  local ok, slot = pcall(component.slot, address)
  line("-- " .. kind .. "  " .. address .. "  slot " .. tostring(ok and slot or "?"))

  local methods = core.methodsOf(address)
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
    local documented, doc = pcall(component.doc, address, name)
    if documented and doc then
      line("    doc: " .. core.oneLine(doc))
    end
    if core.isReadable(name) then
      local results, reason = core.readRaw(address, name)
      if not results then
        line("    error: " .. reason)
      elseif results.n < 2 then
        line("    value: (no return value)")
      else
        local nested = false
        for index = 2, results.n do
          nested = nested or type(results[index]) == "table"
        end
        if not nested then
          local parts = {}
          for index = 2, results.n do
            parts[#parts + 1] = core.formatValue(results[index])
          end
          line("    value: " .. table.concat(parts, ", "))
        else
          -- a table is written out in full: this is how an unknown component
          -- such as a Logistics Pipes block reveals what it actually offers
          for index = 2, results.n do
            for _, text in ipairs(core.describeLines(results[index], "    value: ")) do
              line(text)
            end
          end
        end
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
  line(string.format("%-18s %s  %s", entry.kind, entry.address:sub(1, 8),
    gt.displayName(entry.address, config) or lp.displayName(entry.address) or ""))
end

line("")
line("== components (" .. #entries .. ") ==")
for _, entry in ipairs(entries) do
  dumpComponent(entry.address, entry.kind)
end

local body = table.concat(out, "\n")
out = nil -- the dump is held twice while the request body is built

-- kept on disk as well, because the upload expires in a day and a failed
-- upload should not lose the dump
local function archive(text)
  if not filesystem.exists(ARCHIVE_DIR) then
    filesystem.makeDirectory(ARCHIVE_DIR)
  end
  local number = 1
  while filesystem.exists(string.format("%s/%03d.txt", ARCHIVE_DIR, number)) do
    number = number + 1
  end
  local path = string.format("%s/%03d.txt", ARCHIVE_DIR, number)
  local file = io.open(path, "w")
  if not file then
    return nil
  end
  file:write(text)
  file:close()
  return path
end

local saved = archive(body)
if saved then
  print("saved " .. saved)
end

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

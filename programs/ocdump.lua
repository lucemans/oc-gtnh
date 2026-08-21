-- ocdump: writes a full system dump and uploads it as an unlisted paste, so it
-- can be handed to someone who needs to understand this machine's setup
--
--   ocdump         this computer: its components, their methods and values
--   ocdump --net   and the network as well, as this computer sees it
--
-- The network half is one round of questions and one window to answer in,
-- rather than a machine at a time. A satellite that says nothing in that window
-- is in the dump as silence, which is the fault worth reading about.

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local core = require("oclib")
local gt = require("ocgt")
local lp = require("oclogistics")
local net = require("ocnet")
local serialization = require("serialization")

local VERSION = "0.8.0"

local ARCHIVE_DIR = "/home/dumps"
local PASTE_URL = "https://dpaste.com/api/v2/"
local EXPIRY_DAYS = "1"
-- how long the answers have to arrive. Every satellite is asked at once, so
-- this is the whole cost of --net rather than the cost of each one.
local ANSWER_WAIT = 5
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

-- The daemon prints its route cache and keeps it in an upvalue, and it is
-- vendored, so the only way to it is to send the print somewhere else for the
-- length of the call.
local function routeLines()
  local ok, rc = pcall(require, "rc")
  local route = ok and rc.loaded and rc.loaded.minitel and rc.loaded.minitel.route
  if type(route) ~= "function" then
    return nil
  end

  local captured = {}
  local was = print
  _G.print = function(...)
    local parts = table.pack(...)
    for index = 1, parts.n do
      parts[index] = tostring(parts[index])
    end
    captured[#captured + 1] = table.concat(parts, "  ", 1, parts.n)
  end
  pcall(route)
  _G.print = was
  return captured
end

local function dumpCards()
  line("")
  line("-- cards --")
  local found = 0
  for address in component.list("modem") do
    found = found + 1
    local card = component.proxy(address)
    local how = card.isWireless and card.isWireless() and
      ("wireless, strength " .. tostring(card.getStrength())) or "wired"
    line("  " .. address:sub(1, 8) .. "  " .. how
      .. "  packet " .. tostring(card.maxPacketSize and card.maxPacketSize() or "?"))
  end
  for address in component.list("tunnel") do
    found = found + 1
    line("  " .. address:sub(1, 8) .. "  linked card")
  end
  if found == 0 then
    line("  (none, so this machine is only ever a relay)")
  end
end

local function dumpSatellite(answer)
  line("")
  line("-- " .. answer.host .. "  " .. tostring(answer.address) .. " --")

  for _, card in ipairs(answer.cards) do
    line("  machine  " .. tostring(card.name)
      .. (card.status and ("  " .. card.status) or "")
      .. (card.alarm and "  ALARM" or ""))
    for _, gauge in ipairs(card.gauges or {}) do
      line("    " .. tostring(gauge.label) .. "  "
        .. tostring(gauge.current) .. " of " .. tostring(gauge.maximum)
        .. " " .. tostring(gauge.unit or "")
        .. string.format("  %.1f%%", gauge.percent or 0)
        .. (gauge.rate and ("  rate " .. tostring(gauge.rate)) or ""))
    end
  end

  for _, alert in ipairs(answer.alerts) do
    line("  alert  " .. tostring(alert.name)
      .. (alert.tripped and "  tripped" or "  quiet"))
  end

  if answer.items[1] then
    line("  items moving over " .. tostring(answer.over) .. "s")
    for _, item in ipairs(answer.items) do
      line("    " .. tostring(item.name) .. "  " .. tostring(item.rate))
    end
  end

  for _, fluid in ipairs(answer.fluids) do
    line("  fluid  " .. tostring(fluid.name) .. "  " .. tostring(fluid.amount)
      .. (fluid.rate and ("  " .. tostring(fluid.rate)) or ""))
  end
end

-- Everything this machine can see of the network. Listening starts before the
-- daemon is proved alive, because proving it consumes a packet and a satellite
-- that answered first would otherwise be taken for the proof and then be gone.
local function dumpNetwork()
  line("")
  line("== network ==")
  line("hostname    " .. net.hostname(config))

  local answers, gateways = {}, {}
  local token = net.listen(function(from, port, data)
    if port == core.PORT and data == net.GATEWAY_REPLY then
      gateways[#gateways + 1] = from
      return
    end
    local answer = net.decode(port, from, data)
    if answer then
      answers[from] = answer
    end
  end)

  local minitel, reason = net.up()
  if not minitel then
    net.deafen(token)
    line("minitel     " .. reason)
    dumpCards()
    return
  end

  line("minitel     running")
  line("mtu         " .. tostring(minitel.mtu))
  dumpCards()

  local routes = routeLines()
  line("")
  line("-- routes the daemon has learned --")
  if not routes or #routes == 0 then
    line("  (none yet, so nothing has been heard from since it started)")
  else
    for _, text in ipairs(routes) do
      line("  " .. text)
    end
  end

  local peers = net.peers(config)
  line("")
  line("-- satellites written down --")
  line("  " .. (peers[1] and table.concat(peers, ", ") or "(none)"))

  net.ask(minitel, config)
  net.askGateway(minitel)

  local until_ = computer.uptime() + ANSWER_WAIT
  repeat
    event.pull(until_ - computer.uptime())
  until computer.uptime() >= until_
  net.deafen(token)

  local hosts = {}
  for host in pairs(answers) do
    hosts[#hosts + 1] = host
  end
  table.sort(hosts)

  line("")
  line("-- who answered --")
  if #hosts == 0 then
    line("  (nobody in " .. ANSWER_WAIT .. "s)")
  end
  for _, host in ipairs(hosts) do
    local answer = answers[host]
    line(string.format("  %-24s %d machines  %d alerts  %d fluids  %d items",
      host, #answer.cards, #answer.alerts, #answer.fluids, #answer.items))
  end
  for _, host in ipairs(peers) do
    if not answers[host] then
      line(string.format("  %-24s no answer", host))
    end
  end

  line("")
  line("-- who can reach the internet --")
  line("  " .. (gateways[1] and table.concat(gateways, ", ") or "(nobody said so)"))

  line("")
  line("== satellites (" .. #hosts .. ") ==")
  for _, host in ipairs(hosts) do
    dumpSatellite(answers[host])
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

local wantsNetwork = false
for _, argument in ipairs({ ... }) do
  if argument == "--net" then
    wantsNetwork = true
  else
    io.stderr:write("ocdump: unknown argument " .. tostring(argument) .. "\n")
    return 1
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

if wantsNetwork then
  print("asking the network, " .. ANSWER_WAIT .. "s for answers...")
  dumpNetwork()
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

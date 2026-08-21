-- ocup: installs the latest programs from https://github.com/lucemans/oc-gtnh
--
--   ocup          install and update what this computer is set to have
--   ocup install  choose which programs this computer installs, then install them
--
-- Bootstrap on a fresh computer:
--   wget https://raw.githubusercontent.com/lucemans/oc-gtnh/refs/heads/master/programs/ocup.lua /bin/ocup.lua

local component = require("component")
local computer = require("computer")
local event = require("event")
local filesystem = require("filesystem")
local keyboard = require("keyboard")
local serialization = require("serialization")
local sh = require("sh")
local term = require("term")

local VERSION = "0.20.0"

-- read here rather than through oclib: on a fresh computer ocup arrives alone
-- and there is no /lib yet for it to require
local CONFIG_PATH = "/etc/ocgt.cfg"

local REPO = "lucemans/oc-gtnh"
local COMMIT_URL = "https://api.github.com/repos/" .. REPO .. "/commits/master"
local RAW_URL = "https://raw.githubusercontent.com/" .. REPO .. "/"
local BRANCH = "refs/heads/master"
local MANIFEST = "manifest.txt"
local VERSIONS = "versions.txt"
local SELF = "programs/ocup.lua"

-- the folder a file lives in decides where it installs
local DESTINATIONS = { programs = "/bin/", lib = "/lib/", etc = "/etc/rc.d/" }

-- the services a machine with the daemons installed should be running
local SERVICES = { "minitel", "syslogd" }
-- and the one only a machine that can reach the internet is any use running
local GATEWAY_SERVICE = "fserv"

-- FRequest, which is how a machine with no internet card fetches: it asks a
-- machine that has one to make the request and hand back what came out.
local FREQUEST_PORT = 70
local FREQUEST_WAIT = 20

-- What the vendored daemons do when nobody has said otherwise. Both ship with a
-- default that is no use here: syslogd writes its records to /dev/null and
-- prints the loud ones over whatever is on the screen, and fserv will not
-- proxy at all, which is the one thing a gateway exists to do.
local DAEMON_CONFIG = {
  ["/etc/syslogd.cfg"] =
    '{destination="/home/ocgt.log",write=true,minlevel=6,displevel=-1,'
    .. 'beeplevel=-1,relay=false,relayhost="",receive=false}',
  ["/etc/fserv.cfg"] = '{path="/srv",port=70,looptimer=0.5,iproxy=true}',
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

-- A branch path on raw.githubusercontent.com can serve a stale file for minutes
-- after a push. It ignores Cache-Control: no-cache, and a unique query string
-- only misses the edge cache, not the layer behind it. A commit path cannot go
-- stale, so ocup resolves the commit first and fetches everything from that.
-- The query string is still used where a URL is not immutable.
local requests = 0

local function fresh(url)
  requests = requests + 1
  return url .. "?ocup=" .. math.floor(computer.uptime() * 1000) .. "-" .. requests
end

-- the component handle is used directly: the "internet" library wraps it in a
-- table whose close field shadows the real method and is not callable
local function overInternet(url, headers)
  local handle, reason = component.internet.request(url, nil, headers)
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

-- Fetches through another machine on the Minitel network, which is the only way
-- a computer with no internet card gets anything. The far end is fserv,
-- whose proxy takes a path of scheme then host then the rest and makes the
-- request itself. The first character that comes back is the status.
local function overGateway(minitel, host, url)
  local scheme, rest = url:match("^(https?)://(.+)$")
  if not scheme then
    return nil, "not a URL this can proxy: " .. tostring(url)
  end

  local socket, why = minitel.open(host, FREQUEST_PORT)
  if not socket then
    return nil, tostring(why or "no answer from " .. host)
  end
  socket:write("t/" .. scheme .. "/" .. rest .. "\n")

  local chunks = {}
  local quiet = computer.uptime() + FREQUEST_WAIT
  while socket.state ~= "closed" and computer.uptime() < quiet do
    local chunk = socket:read("*a")
    if chunk and #chunk > 0 then
      chunks[#chunks + 1] = chunk
      quiet = computer.uptime() + FREQUEST_WAIT
    else
      -- event.pull rather than os.sleep, because the socket is filled by a
      -- listener and only an event.pull runs one
      event.pull(0.05)
    end
  end
  local last = socket:read("*a")
  if last and #last > 0 then
    chunks[#chunks + 1] = last
  end
  socket:close()

  local body = table.concat(chunks)
  if #body == 0 then
    return nil, "nothing came back from " .. host
  end
  local status, contents = body:sub(1, 1), body:sub(2)
  if status ~= "y" then
    return nil, host .. " said " .. status .. " " .. contents:sub(1, 40)
  end
  return contents
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

local function loadConfig()
  local ok, config = pcall(serialization.unserialize, readFile(CONFIG_PATH) or "")
  if not ok or type(config) ~= "table" then
    return {}
  end
  return config
end

-- OpenOS keeps required modules in package.loaded for the whole shell session,
-- so a library replaced on disk stays stale in memory until a reboot. Dropping
-- it here means the next program run picks up what was just installed.
local function forget(target)
  local name = target:match("^/lib/(.+)%.lua$")
  if name then
    package.loaded[name] = nil
  end
end

local function versionOf(text)
  return text and text:match('VERSION%s*=%s*"([^"]+)"') or nil
end

local function shown(version)
  return version and ("v" .. version) or "-"
end

-- the version column and the status are separate so the column can be filled in
-- from disk before anything is fetched, and only the status changes as work runs
local function describe(existing, contents)
  local version = versionOf(contents)
  local was = versionOf(existing)

  if not existing then
    return shown(version), "installed", GREEN
  end
  if existing == contents then
    return shown(version), "up to date", DIM
  end
  if was and version and was ~= version then
    return shown(was) .. " -> " .. shown(version), "updated", GREEN
  end
  return shown(version), "changed", CYAN
end

-- A line is a path and, on versions.txt, one word of "version:size" beside it.
-- Both have to match for a file to go unfetched: a version alone is only as good
-- as the discipline behind it, and a library once got rewritten without its
-- number moving, so every computer went on running the old one.
--
-- Anything further along the line is ignored rather than refused. A stricter
-- parser than this is what made a new column look like an empty manifest, and a
-- computer that cannot read the manifest cannot update itself out of it.
local function parseManifest(text)
  local files = {}
  for entry in text:gmatch("[^\n]+") do
    local source, stamp = entry:match("^%s*(%S+)%s*(%S*)")
    local version, size = tostring(stamp):match("^([^:]*):?(%d*)$")
    if source then
      -- both captures are bound here: "a and a:match()" would keep only the first
      local folder, name = source:match("^(%w+)/(.+)$")
      local destination = folder and DESTINATIONS[folder]
      if destination then
        files[#files + 1] = {
          source = source,
          target = destination .. name,
          -- a manifest written before versions were in it says nothing here,
          -- and then every file is fetched, which is what used to happen
          latest = version ~= "" and version or nil,
          bytes = tonumber(size),
        }
      end
    end
  end
  return files
end

-------------------------------------------------------------------------------

local arguments = { ... }
local reloaded = arguments[1] == "--reloaded"
local choosing = arguments[1] == "install"

write("ocup v" .. VERSION .. (reloaded and "  (reloaded)" or "") .. "\n\n", WHITE)

local config = loadConfig()

-- Where the files come from. An internet card fetches for itself; a machine
-- without one asks another on the Minitel network to fetch on its behalf, which
-- is what makes one card enough for a whole base.
local gateway, minitel = nil, nil

if not component.isAvailable("internet") then
  local hasNet, ocnet = pcall(require, "ocnet")
  local up = hasNet and ocnet.up()
  if not up then
    io.stderr:write("ocup: no internet card, and no minitel to fetch through\n")
    return 1
  end
  minitel = up
  -- ocnet loaded, so its own dependencies are on the disk too
  local core = require("oclib")

  gateway = config.gateway
  if not gateway or gateway == "" then
    term.clearLine()
    write("  looking for a machine that can reach the internet", DIM)
    ocnet.askGateway(minitel)
    local until_ = computer.uptime() + 5
    while computer.uptime() < until_ do
      local name, from, port, data = event.pull(until_ - computer.uptime(), "net_msg")
      if name == nil then
        break
      end
      if port == core.PORT and data == ocnet.GATEWAY_REPLY then
        gateway = from
        break
      end
    end
  end

  term.clearLine()
  if not gateway or gateway == "" then
    write("  nobody answered as a gateway\n", RED)
    write("  run ocwatch or ocserve on the machine with the internet card,\n", DIM)
    write("  and rc fserv start there\n", DIM)
    paint(WHITE)
    return 1
  end
  write("  fetching through " .. gateway .. "\n", DIM)
end

local function download(url, headers)
  if gateway then
    return overGateway(minitel, gateway, url)
  end
  return overInternet(url, headers)
end

-- the API rejects a request without a User-Agent
term.clearLine()
write("  resolving commit", DIM)
local commitText = download(fresh(COMMIT_URL), { ["User-Agent"] = "ocup" })
local commit = commitText and commitText:match('"sha"%s*:%s*"(%x+)"')

local BASE_URL, immutable
if commit then
  BASE_URL, immutable = RAW_URL .. commit .. "/", true
else
  BASE_URL, immutable = RAW_URL .. BRANCH .. "/", false
end

local function urlFor(path)
  if immutable then
    return BASE_URL .. path
  end
  return fresh(BASE_URL .. path)
end

term.clearLine()
if commit then
  write("  commit " .. commit:sub(1, 7) .. "\n", DIM)
else
  write("  could not resolve the commit, files may be up to five minutes old\n", RED)
end

term.clearLine()
write("  fetching manifest", DIM)

-- versions.txt lists the same paths with the version each file declares, which
-- is what lets a file that has not changed go unfetched. manifest.txt is the
-- same list without the versions, kept because an older ocup skips any line
-- with more than a path on it and would read a versioned one as empty.
local manifestText = download(urlFor(VERSIONS))
local manifestReason
if not manifestText then
  manifestText, manifestReason = download(urlFor(MANIFEST))
end
if not manifestText then
  term.clearLine()
  write("  manifest failed: " .. tostring(manifestReason) .. "\n", RED)
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

-- What a computer gets before anybody has chosen: enough to look at the
-- machines in front of it and to ask for help with them. Everything else is
-- opted into, since no computer wants the lot.
--
-- Once a choice is recorded it is the whole truth: a program missing from it is
-- not installed, and is taken off the disk if it is already there. Libraries
-- are not part of the choice, since the programs that are kept need whichever
-- of them they require.
-- ocinstall is here because a floppy carries whatever the machine that flashed
-- it had, and a machine that never installed it cannot put it on one.
local DEFAULT = { ocdebug = true, ocdump = true, ocinstall = true }

local chosen = nil
if type(config.programs) == "table" then
  chosen = {}
  for _, name in ipairs(config.programs) do
    chosen[name] = true
  end
end

local function programName(source)
  return source:match("^programs/(.+)%.lua$")
end

local function isWanted(source)
  -- ocup cannot opt out of itself: nothing would be left to opt back in with
  if source == SELF or not programName(source) then
    return true
  end
  local name = programName(source)
  if chosen == nil then
    return DEFAULT[name] == true
  end
  return chosen[name] == true
end

if choosing then
  local names = {}
  for _, file in ipairs(FILES) do
    local name = programName(file.source)
    if name and file.source ~= SELF then
      names[#names + 1] = name
    end
  end

  -- the first toggle turns the defaults into an explicit list, so what was
  -- already installed is not silently dropped by editing something else
  local function toggle(name)
    if chosen == nil then
      chosen = {}
      for _, each in ipairs(names) do
        chosen[each] = DEFAULT[each]
      end
    end
    if chosen[name] then
      chosen[name] = nil
    else
      chosen[name] = true
    end
  end

  local cursor = 1
  while true do
    term.clear()
    write("ocup v" .. VERSION .. "   what this computer installs\n\n", WHITE)
    for index, name in ipairs(names) do
      local on = isWanted("programs/" .. name .. ".lua")
      local here = index == cursor
      write((here and "  > " or "    ") .. (on and "[x] " or "[ ] ") .. name .. "\n",
        on and WHITE or DIM)
    end
    local keeping = 0
    for _, name in ipairs(names) do
      if isWanted("programs/" .. name .. ".lua") then
        keeping = keeping + 1
      end
    end

    write("\n  ocup and the libraries are always installed\n", DIM)
    write("  up and down to move, space to toggle\n", DIM)
    write("  enter to install these " .. keeping .. ", q to leave it as it is\n", DIM)

    local name, _, _, code = event.pull(nil, "key_down")
    if name == nil or code == keyboard.keys.q then
      term.clear()
      write("  nothing changed\n", DIM)
      paint(WHITE)
      return 0
    elseif code == keyboard.keys.enter then
      break
    elseif code == keyboard.keys.up then
      if cursor > 1 then
        cursor = cursor - 1
      else
        cursor = #names
      end
    elseif code == keyboard.keys.down then
      if cursor < #names then
        cursor = cursor + 1
      else
        cursor = 1
      end
    elseif code == keyboard.keys.space and names[cursor] then
      toggle(names[cursor])
    end
  end

  local keep = {}
  for _, name in ipairs(names) do
    if isWanted("programs/" .. name .. ".lua") then
      keep[#keep + 1] = name
    end
  end
  config.programs = keep
  local saved, saveReason = writeFile(CONFIG_PATH, serialization.serialize(config))

  term.clear()
  if not saved then
    write("  could not save: " .. tostring(saveReason) .. "\n", RED)
    paint(WHITE)
    return 1
  end
  write("  " .. #keep .. " of " .. #names .. " programs chosen\n", GREEN)
  write("\n", DIM)
  -- and straight on into installing it, because choosing and then being told to
  -- run the same program again is one step too many
end

-- ocup updates itself first and hands over to the new copy, so the rest of the
-- run already uses the behaviour that was just downloaded
if not reloaded then
  local self = nil
  for _, file in ipairs(FILES) do
    if file.source == SELF then
      self = file
    end
  end

  -- the manifest says what version is out there, so a copy that already says
  -- the same is not downloaded to find out it was the same
  if self and self.latest ~= VERSION then
    local current = readFile(self.target)
    local latest = download(urlFor(self.source))
    if latest and latest ~= current then
      term.clearLine()
      write("  " .. self.source .. "  ", WHITE)
      local version, status, color = describe(current, latest)
      write(version .. "  " .. status .. "\n", color)
      if writeFile(self.target, latest) then
        write("  reloading into the new ocup\n\n", CYAN)
        paint(WHITE)
        local chunk = loadfile(self.target)
        if chunk then
          return chunk("--reloaded")
        end
      end
    end
  end
end

-- The manifest already says what the run will touch, so the whole list is drawn
-- before any of it is fetched. Rows are then repainted in place, which reserves
-- the right amount of space up front instead of growing as results arrive.
local TEE = "\226\148\156\226\148\128 "
local ELBOW = "\226\148\148\226\148\128 "

-- What is already installed is on disk, so the version column is filled in
-- before a single request goes out. Only the status changes as work proceeds.
local nameWidth, versionWidth, total = 0, 0, 0
for _, file in ipairs(FILES) do
  local name = file.source:match("/(.+)$") or file.source
  file.name = name
  file.wanted = isWanted(file.source)
  file.existing = readFile(file.target)
  file.version = shown(versionOf(file.existing))
  if file.wanted then
    total = total + 1
  end
  nameWidth = math.max(nameWidth, #name)
  versionWidth = math.max(versionWidth, #file.version)
end
-- room for the widest transition this run can produce, so nothing shifts later
versionWidth = math.max(versionWidth * 2 + 4, versionWidth)

-- What this run is doing comes first, and what it is leaving alone sinks to the
-- bottom of its folder, so the interesting rows are together. Folders stay in
-- manifest order because the tree draws them as one group each.
local ordered = {}
local folders = {}
for _, file in ipairs(FILES) do
  local here = file.source:match("^(.-)/") or ""
  if not ordered[here] then
    ordered[here] = { wanted = {}, rest = {} }
    folders[#folders + 1] = here
  end
  local group = ordered[here]
  if file.wanted then
    group.wanted[#group.wanted + 1] = file
  else
    group.rest[#group.rest + 1] = file
  end
end

FILES = {}
for _, here in ipairs(folders) do
  for _, file in ipairs(ordered[here].wanted) do
    FILES[#FILES + 1] = file
  end
  for _, file in ipairs(ordered[here].rest) do
    FILES[#FILES + 1] = file
  end
end

local lines = {}

local function addLine(text)
  lines[#lines + 1] = text
  return #lines
end

local function rowText(file, status, version)
  version = version or file.version
  return "  " .. file.branch .. file.name
    .. string.rep(" ", nameWidth - #file.name) .. "   "
    .. version .. string.rep(" ", math.max(1, versionWidth - #version)) .. "  "
    .. status
end

local folder = nil
for index, file in ipairs(FILES) do
  local here = file.source:match("^(.-)/") or ""
  if here ~= folder then
    addLine("  " .. here .. "/")
    folder = here
  end
  local next = FILES[index + 1]
  local lastOfGroup = not next or (next.source:match("^(.-)/") or "") ~= here
  file.branch = lastOfGroup and ELBOW or TEE
  local waiting = "pending"
  if not file.wanted then
    waiting = file.existing and "to remove" or "not chosen"
  end
  file.line = addLine(rowText(file, waiting))
end

addLine("")
local barLine = addLine("")

for _, text in ipairs(lines) do
  write(text .. "\n", DIM)
end

-- anchored to where the cursor ended up, so a screen that scrolled while the
-- block was printed still resolves to the right rows
local _, below = term.getCursor()
local firstRow = below - #lines

-- What each row already says, so a row that has not changed is left alone. The
-- second pass repainting every line is what made the whole table appear to
-- rewrite itself at the end of a run.
local drawn = {}

local function repaint(line, text, color)
  local key = text .. "\1" .. tostring(color)
  if drawn[line] == key then
    return
  end
  drawn[line] = key
  term.setCursor(1, firstRow + line - 1)
  term.clearLine()
  write(text, color)
  term.setCursor(1, below)
end

-- how many of the chosen files this run has dealt with so far
local done = 0

local function showBar(note, color)
  repaint(barLine, "  " .. bar(done, total, 12) .. " " .. note, color or CYAN)
end

showBar("fetching")

-- Everything is fetched before anything is written. Writing as it goes would
-- let one failed download leave the programs newer than the library they
-- require, which breaks every one of them until the next run.
local failure = nil
for _, file in ipairs(FILES) do
  if file.wanted then
    -- The manifest already said which version is out there. A file whose
    -- installed copy declares the same one is not fetched at all, which is what
    -- makes a run with nothing to do cost two requests rather than one a file.
    local same = file.latest and file.existing
      and versionOf(file.existing) == file.latest
      and (file.bytes == nil or #file.existing == file.bytes)
    if same then
      repaint(file.line, rowText(file, "up to date"), DIM)
      done = done + 1
      showBar("checking")
    else
      repaint(file.line, rowText(file, "fetching"), CYAN)
      local contents, reason = download(urlFor(file.source))
      if not contents then
        repaint(file.line, rowText(file, "failed  " .. reason), RED)
        failure = file
        break
      end
      file.contents = contents

      -- What this file is going to do is known the moment it arrives, so the
      -- row says it now rather than at the end. Writing still waits until every
      -- file is here, since a download that fails halfway would otherwise leave
      -- programs newer than the library they require.
      local version, status, color = describe(file.existing, contents)
      file.version, file.status, file.color = version, status, color
      if status == "up to date" then
        repaint(file.line, rowText(file, status, version), color)
      else
        repaint(file.line, rowText(file, "ready", version), CYAN)
      end

      done = done + 1
      showBar("fetching")
    end
  end
end

if failure then
  -- the row shows the reason, but a failure is worth naming in full: the tree
  -- splits the path across a group header and a leaf
  repaint(barLine, "  " .. failure.source .. " failed, nothing was installed", RED)
  paint(WHITE)
  return 1
end

local failed, removed = 0, 0
done = 0
showBar("installing")
for _, file in ipairs(FILES) do
  local version, status, color

  if not file.wanted then
    -- opting out means the program leaves the disk, so what is in /bin is
    -- always what was chosen
    if file.existing then
      local ok, removeReason = filesystem.remove(file.target)
      if ok then
        removed = removed + 1
        version, status, color = file.version, "removed", CYAN
      else
        version, status, color = file.version,
          "could not remove  " .. tostring(removeReason), RED
        failed = failed + 1
      end
    end
  elseif not file.contents then
    -- never fetched, because the version on disk already matched
    version, status, color = file.version, "up to date", DIM
    done = done + 1
    showBar("installing")
  else
    -- overwriting a running program is safe: OpenOS loads the whole file first
    local ok, writeReason = writeFile(file.target, file.contents)
    if ok then
      forget(file.target)
      -- the row already says what this is; only the word changes
      version, status, color = file.version, file.status, file.color
    else
      version, status, color = file.version, "failed  " .. writeReason, RED
      failed = failed + 1
    end
    done = done + 1
    showBar("installing")
  end

  if status then
    repaint(file.line, rowText(file, status, version), color)
  end
end

done = total
if failed > 0 then
  showBar(failed .. " of " .. total .. " could not be written", RED)
  paint(WHITE)
  return 1
end
showBar(total .. " files in place"
  .. (removed > 0 and ", " .. removed .. " removed" or ""), GREEN)

-------------------------------------------------------------------------------
-- Installing a daemon does not run it. Minitel names this machine after
-- /etc/hostname and rc starts a service because it is listed in /etc/rc.cfg,
-- and neither file is one the file list above would ever touch.

-- read and written the way rc itself does: a Lua chunk of key and value lines,
-- evaluated into an environment of its own
local function rcConfig()
  local env = {}
  local chunk = load(readFile("/etc/rc.cfg") or "", "=rc.cfg", "t", env)
  if chunk then
    pcall(chunk)
  end
  return env
end

local function saveRc(conf)
  local settings = {}
  for key, value in pairs(conf) do
    settings[#settings + 1] = tostring(key) .. " = " .. serialization.serialize(value)
  end
  return writeFile("/etc/rc.cfg", table.concat(settings, "\n") .. "\n")
end

local named = nil
if not (readFile("/etc/hostname") or ""):match("%S") then
  named = config.hostname
  if not named or named == "" then
    named = computer.address():sub(1, 8)
  end
  writeFile("/etc/hostname", named)
  -- OpenOS keeps its own copy of the name per shell, read out of that file
  -- whenever this last ran, so without it everything else on the machine goes
  -- on calling it nothing at all
  pcall(sh.execute, _ENV, "hostname --update")
end

local wanted = { table.unpack(SERVICES) }
-- only a machine that can reach the internet is any use as a gateway, and one
-- serving files it cannot fetch is a machine answering questions with nothing
if component.isAvailable("internet") then
  wanted[#wanted + 1] = GATEWAY_SERVICE
end

local conf = rcConfig()
conf.enabled = conf.enabled or {}
local already = {}
for _, name in ipairs(conf.enabled) do
  already[name] = true
end

local enabled = {}
for _, name in ipairs(wanted) do
  if not already[name] and filesystem.exists("/etc/rc.d/" .. name .. ".lua") then
    conf.enabled[#conf.enabled + 1] = name
    enabled[#enabled + 1] = name
  end
end
if #enabled > 0 then
  saveRc(conf)
end

-- Written once and then left alone: a settings file somebody has edited is
-- theirs, and a daemon that is not installed here needs none.
for path, defaults in pairs(DAEMON_CONFIG) do
  local daemon = path:match("^/etc/(.+)%.cfg$")
  if filesystem.exists("/etc/rc.d/" .. daemon .. ".lua") and not readFile(path) then
    writeFile(path, defaults)
  end
end

if named then
  write("\n  named this machine " .. named .. "\n", CYAN)
end

-- A daemon that is installed and enabled and not running is the state every
-- program below has to detect and explain, so it is worth not creating. rc
-- starting one that is already going does nothing.
if #enabled > 0 then
  write((named and "" or "\n") .. "  enabled " .. table.concat(enabled, ", ")
    .. "\n", CYAN)
  for _, name in ipairs(enabled) do
    pcall(sh.execute, _ENV, "rc " .. name .. " start")
  end
  write("  started them\n", CYAN)
end
paint(WHITE)

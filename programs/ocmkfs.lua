-- ocmkfs: flash a floppy so a brand new computer can install ocup from it.
--
--   ocmkfs                 pick a disk, pick what to copy, write it
--   ocmkfs --disk 3de61ebf name the disk and copy everything, without asking
--
-- Both prompts read the keyboard, so anything driving this from off the machine
-- has to use --disk, which skips them and takes the lot. Naming the disk is also
-- the safer way to script it: a position in a list can move, an address cannot.
--
-- OpenOS's own `install` looks for a .prop file at the root of a candidate
-- filesystem, reads it as a Lua table, and then copies the disk's contents onto
-- the target. So the floppy needs that file plus the tree it should copy, and
-- nothing else: `install` does the rest.
--
-- Everything gets copied, not just ocup: the programs, the libraries, the
-- Minitel daemons and the file saying to run them. A machine with no internet
-- card fetches through another machine on the network, so a floppy carrying
-- only the updater would install a program with no way to reach anything.
--
-- The floppy also carries the choice itself, as `programs` in the configuration.
-- ocup treats a recorded choice as the whole truth and removes anything missing
-- from it, so a floppy that copied programs and said nothing about them left a
-- computer that threw them away on its first update. `ocinstall` on the target
-- is how that choice is narrowed to the one machine.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local filesystem = require("filesystem")
local keyboard = require("keyboard")
local serialization = require("serialization")
local term = require("term")

local VERSION = "0.7.0"

local LABEL = "oc-gtnh"
-- Where the installed set lives, and what belongs to this project. Our own
-- files are named for it. The vendored Minitel ones are not, so they are named
-- here: a floppy without them installs a machine that cannot reach anything,
-- which is the one machine a floppy is for.
local FOLDERS = { "/lib", "/bin", "/etc/rc.d" }
-- where a file installed here came from in the repository, which is how ocup
-- names it and therefore how a dashboard comparing two machines names it
local SOURCES = { ["/lib"] = "lib", ["/bin"] = "programs", ["/etc/rc.d"] = "etc" }
local BELONGS = "^oc.*%.lua$"
local VENDORED = {
  ["minitel.lua"] = true,
  ["syslog.lua"] = true,
  ["syslogd.lua"] = true,
  ["fserv.lua"] = true,
}
-- the two the floppy exists for, so neither is ever left off one and neither is
-- offered as a choice: ocup is what updates the machine afterwards, ocinstall is
-- what narrows the floppy to the machine
local ALWAYS = { ["/bin/ocup.lua"] = true, ["/bin/ocinstall.lua"] = true }
-- A brand new computer has nothing enabled, so the floppy says which services
-- to run. Written rather than merged, which is safe on the empty machine this
-- exists for and would not be on one that had been set up already.
local RC_CONFIG = 'enabled = {"minitel","syslogd"}\n'

local WHITE = 0xFFFFFF
local DIM = 0x999999
local GREEN = 0x66CC66
local CYAN = 0x66CCFF
local RED = 0xCC6666

local gpu = component.isAvailable("gpu") and component.gpu or nil

local function say(text, color)
  if gpu then
    gpu.setForeground(color or WHITE)
  end
  print(text)
end

-- Device info describes every filesystem as "Filesystem" whatever it is, so it
-- cannot tell a floppy from a hard drive. A disk drive names the medium inside
-- it, which can.
local function removableAddresses()
  local removable = {}
  for address, kind in component.list() do
    if kind == "disk_drive" then
      local empty = core.call(address, "isEmpty")
      if empty == false then
        local media = core.call(address, "media")
        if type(media) == "string" then
          removable[media] = address
        end
      end
    end
  end
  return removable
end

local function disks()
  local removable = removableAddresses()
  local temporary = computer.tmpAddress()
  local found = {}

  for address, kind in component.list() do
    if kind == "filesystem" and address ~= temporary then
      local readOnly = core.call(address, "isReadOnly")
      found[#found + 1] = {
        address = address,
        label = core.call(address, "getLabel"),
        total = core.call(address, "spaceTotal"),
        used = core.call(address, "spaceUsed"),
        readOnly = readOnly == true,
        drive = removable[address],
      }
    end
  end

  -- removable media first: that is what somebody carries to another computer
  table.sort(found, function(a, b)
    if (a.drive ~= nil) ~= (b.drive ~= nil) then
      return a.drive ~= nil
    end
    return a.address < b.address
  end)
  return found
end

-- everything this project installed, read off the machine doing the flashing
local function payload()
  local files = {}
  for _, folder in ipairs(FOLDERS) do
    if filesystem.exists(folder) then
      for name in filesystem.list(folder) do
        if name:match(BELONGS) or VENDORED[name] then
          local path = folder .. "/" .. name
          local file = io.open(path, "r")
          if file then
            local contents = file:read("*a") or ""
            file:close()
            files[#files + 1] = { path = path, contents = contents }
          end
        end
      end
    end
  end
  return files
end

local function bytesOf(files)
  local bytes = 0
  for _, file in ipairs(files) do
    bytes = bytes + #file.contents
  end
  return bytes
end

local function writeTo(address, path, contents)
  local disk = component.proxy(address)
  if not disk then
    return nil, "no such filesystem"
  end

  local folder = path:match("^(.*)/[^/]*$")
  if folder and folder ~= "" then
    pcall(disk.makeDirectory, folder)
  end

  local handle, reason = disk.open(path, "w")
  if not handle then
    return nil, tostring(reason)
  end
  disk.write(handle, contents)
  disk.close(handle)
  return true
end

-- Only the programs are offered. Libraries go on regardless, since whichever
-- programs are kept need whichever of them they require, and ocup goes on
-- regardless because it is the reason the floppy exists.
local function choose(files)
  local programs = {}
  for _, file in ipairs(files) do
    if file.path:match("^/bin/") and not ALWAYS[file.path] then
      programs[#programs + 1] = file
    end
  end
  if #programs == 0 then
    return files
  end

  local taking = {}
  for _, file in ipairs(programs) do
    taking[file.path] = true
  end

  local cursor = 1
  while true do
    term.clear()
    say("ocmkfs v" .. VERSION .. "   what goes on the floppy", WHITE)
    say("")
    for index, file in ipairs(programs) do
      local on = taking[file.path]
      say((index == cursor and "  > " or "    ") .. (on and "[x] " or "[ ] ")
        .. file.path:match("/([^/]+)$"), on and WHITE or DIM)
    end
    say("")
    say("  ocup, ocinstall and the libraries are always copied", DIM)
    say("  up and down to move, space to toggle, enter to flash", DIM)

    local name, _, _, code = event.pull(nil, "key_down")
    if name == nil or code == keyboard.keys.enter then
      break
    elseif code == keyboard.keys.up then
      if cursor > 1 then
        cursor = cursor - 1
      else
        cursor = #programs
      end
    elseif code == keyboard.keys.down then
      if cursor < #programs then
        cursor = cursor + 1
      else
        cursor = 1
      end
    elseif code == keyboard.keys.space and programs[cursor] then
      taking[programs[cursor].path] = not taking[programs[cursor].path]
    end
  end

  local kept = {}
  for _, file in ipairs(files) do
    if not file.path:match("^/bin/") or ALWAYS[file.path] or taking[file.path] then
      kept[#kept + 1] = file
    end
  end
  return kept
end

local function size(bytes)
  if type(bytes) ~= "number" then
    return "?"
  end
  if bytes >= 1048576 then
    return string.format("%.1f MB", bytes / 1048576)
  end
  return string.format("%d KB", math.floor(bytes / 1024))
end

-------------------------------------------------------------------------------

local found = disks()
local writable = {}
for _, disk in ipairs(found) do
  if not disk.readOnly then
    writable[#writable + 1] = disk
  end
end

say("ocmkfs v" .. VERSION, WHITE)
say("")

if #found == 0 then
  io.stderr:write("ocmkfs: no filesystem components found\n")
  return 1
end

for index, disk in ipairs(found) do
  local kind = disk.drive and "floppy" or "fixed"
  local note = disk.readOnly and "   read only, cannot be written" or ""
  local number = disk.readOnly and "  -" or string.format("%3d", index)
  say(string.format("%s  %-7s %-10s %-9s %s%s", number, kind,
    disk.label or "(no label)", size(disk.total), disk.address:sub(1, 8), note),
    disk.readOnly and DIM or WHITE)
end

if #writable == 0 then
  say("")
  io.stderr:write("ocmkfs: every disk is read only, nothing can be flashed\n")
  return 1
end

local files = payload()
if #files == 0 then
  say("")
  io.stderr:write("ocmkfs: nothing to copy from /bin or /lib, run ocup first\n")
  return 1
end

local arguments = { ... }
local wanted = nil
for index = 1, #arguments do
  if arguments[index] == "--disk" and arguments[index + 1] then
    wanted = arguments[index + 1]
  end
end

local chosen = nil
if wanted then
  for _, disk in ipairs(found) do
    if disk.address:sub(1, #wanted) == wanted then
      chosen = disk
    end
  end
  if not chosen then
    say("")
    io.stderr:write("ocmkfs: no disk matches " .. wanted .. "\n")
    return 1
  end
else
  say("")
  io.write("  number to flash (blank to cancel) > ")
  local answer = tonumber(io.read())
  chosen = answer and found[answer]
end

if not chosen then
  say("  cancelled", DIM)
  return 0
end
if chosen.readOnly then
  say("  that disk is read only", RED)
  return 1
end

-- naming the disk is how this gets driven from off the machine, and nothing
-- there can work a menu
if not wanted then
  files = choose(files)
end

local bytes = bytesOf(files)
local free = (chosen.total or 0) - (chosen.used or 0)
if bytes > free then
  say("")
  io.stderr:write("ocmkfs: " .. size(bytes) .. " will not fit in "
    .. size(free) .. " free on that disk\n")
  return 1
end

say("")
say("  flashing " .. chosen.address:sub(1, 8) .. " with " .. #files
  .. " files, " .. size(bytes), DIM)

for _, file in ipairs(files) do
  local written, reason = writeTo(chosen.address, file.path, file.contents)
  if not written then
    io.stderr:write("ocmkfs: could not write " .. file.path .. ": "
      .. tostring(reason) .. "\n")
    return 1
  end
  say("    " .. file.path, DIM)
end

-- install reads this as a Lua table and skips copying the file itself. setboot
-- and reboot are left out on purpose: this drops a program onto a working
-- machine, it does not install an operating system.
local prop = "{label=" .. string.format("%q", LABEL) .. "}"
local ok, reason = writeTo(chosen.address, "/.prop", prop)
if not ok then
  io.stderr:write("ocmkfs: could not write .prop: " .. tostring(reason) .. "\n")
  return 1
end

-- Installing the daemon does not run it, and a machine off the network cannot
-- fetch the thing that would have enabled it.
local enabled, why = writeTo(chosen.address, "/etc/rc.cfg", RC_CONFIG)
if not enabled then
  io.stderr:write("ocmkfs: could not write /etc/rc.cfg: " .. tostring(why) .. "\n")
  return 1
end
say("    /etc/rc.cfg", DIM)

-- What ocup will read as the choice already made. Without it ocup falls back to
-- its own default and takes everything else off the disk, which is a computer
-- throwing away what it was just given. ocup never lists itself, so neither
-- does this.
local carried = {}
for _, file in ipairs(files) do
  local name = file.path:match("^/bin/(.+)%.lua$")
  if name and name ~= "ocup" then
    carried[#carried + 1] = name
  end
end
table.sort(carried)

-- What the floppy is carrying, written down the way ocup writes it, so a
-- machine installed off a floppy can say what it is running before it has ever
-- reached the internet. The commit is this machine's, which is the right answer:
-- the floppy is a copy of what is on this disk.
local here = core.loadConfig()
local installed = { commit = here.installed and here.installed.commit, files = {} }
for _, file in ipairs(files) do
  local folder, name = file.path:match("^(.*)/([^/]+)$")
  local source = SOURCES[folder]
  local version = file.contents:match('VERSION%s*=%s*"([^"]+)"')
  if source and version then
    installed.files[source .. "/" .. name] = version
  end
end

local recorded, badly = writeTo(chosen.address, core.CONFIG_PATH,
  serialization.serialize({ programs = carried, installed = installed }))
if not recorded then
  io.stderr:write("ocmkfs: could not write " .. core.CONFIG_PATH .. ": "
    .. tostring(badly) .. "\n")
  return 1
end
say("    " .. core.CONFIG_PATH .. "  " .. #carried .. " programs", DIM)

core.setValue(chosen.address, "setLabel", LABEL)

say("")
say("  done, labelled " .. LABEL, GREEN)
say("")
say("  put the floppy in another computer and run:", DIM)
say("    install", CYAN)
say("    ocinstall", CYAN)
say("")
say("  install copies the lot and the machine is usable straight away.", DIM)
say("  ocinstall is where that machine drops what it does not want,", DIM)
say("  and it is the only thing that has to be run on the machine itself.", DIM)
say("  run ocup afterwards only to pick up anything newer.", DIM)

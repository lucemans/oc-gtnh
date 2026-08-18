-- ocmkfs: flash a floppy so a brand new computer can install ocup from it.
--
--   ocmkfs                 pick a disk and write the installer onto it
--   ocmkfs --disk 3de61ebf name the disk instead of being asked
--
-- The prompt reads the keyboard, so anything driving this from off the machine
-- has to use --disk. Naming the disk is also the safer way to script it: a
-- position in a list can move, an address cannot.
--
-- OpenOS's own `install` looks for a .prop file at the root of a candidate
-- filesystem, reads it as a Lua table, and then copies the disk's contents onto
-- the target. So the floppy needs that file plus the tree it should copy, and
-- nothing else: `install` does the rest.
--
-- Everything gets copied, not just ocup. A tablet has no internet card, so a
-- floppy carrying only the updater would install a program that cannot reach
-- GitHub to fetch the rest.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local filesystem = require("filesystem")

local VERSION = "0.3.0"

local LABEL = "oc-gtnh"
-- where the installed set lives, and what belongs to this project
local FOLDERS = { "/lib", "/bin" }
local BELONGS = "^oc.*%.lua$"

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
  local files, bytes = {}, 0
  for _, folder in ipairs(FOLDERS) do
    if filesystem.exists(folder) then
      for name in filesystem.list(folder) do
        if name:match(BELONGS) then
          local path = folder .. "/" .. name
          local file = io.open(path, "r")
          if file then
            local contents = file:read("*a") or ""
            file:close()
            files[#files + 1] = { path = path, contents = contents }
            bytes = bytes + #contents
          end
        end
      end
    end
  end
  return files, bytes
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

local files, bytes = payload()
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

core.setValue(chosen.address, "setLabel", LABEL)

say("")
say("  done, labelled " .. LABEL, GREEN)
say("")
say("  put the floppy in another computer and run:", DIM)
say("    install", CYAN)
say("")
say("  that is all a machine without an internet card needs.", DIM)
say("  run ocup afterwards only to pick up anything newer.", DIM)

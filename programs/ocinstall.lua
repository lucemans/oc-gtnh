-- ocinstall: choose what this computer keeps of what a floppy just gave it.
--
--   ocinstall     pick the programs, remove the rest, write the choice down
--
-- A floppy carries every program, because it is made before anybody knows which
-- computer it is for. `install` copies the lot. This is where the computer says
-- which of them it actually wanted.
--
-- Writing the choice down is the point. ocup treats a recorded choice as the
-- whole truth and takes anything missing from it off the disk, so a computer set
-- up from a floppy and never asked would lose its programs on the first update.
-- The rest of the configuration is read and put back untouched: the machines
-- being watched, the alerts, the satellites and the telemetry service all belong
-- to whoever set them, not to this.

local component = require("component")
local core = require("oclib")
local event = require("event")
local filesystem = require("filesystem")
local keyboard = require("keyboard")
local term = require("term")

local VERSION = "0.1.0"

local BIN = "/bin"
-- Neither can be opted out of here. Removing ocup leaves nothing to update with,
-- and removing this leaves nothing to choose with.
local KEEP = { ocup = true, ocinstall = true }

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

local function recorded(config)
  return type(config.programs) == "table" and config.programs or {}
end

local function choices(config)
  local seen = {}
  if filesystem.exists(BIN) then
    for entry in filesystem.list(BIN) do
      local name = entry:match("^(oc.+)%.lua$")
      if name and not KEEP[name] then
        seen[name] = true
      end
    end
  end
  -- A name that is recorded but not on the disk is one ocup has yet to install.
  -- Leaving it out of the menu would take it off the list without ever showing
  -- it, which cancels an install nobody cancelled.
  for _, name in ipairs(recorded(config)) do
    if not KEEP[name] then
      seen[name] = true
    end
  end

  local names = {}
  for name in pairs(seen) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

-- What is ticked when the menu opens. A computer that has been asked before is
-- shown its own answer; one that has not is shown everything the floppy gave it,
-- since somebody chose that much already when they made the floppy.
local function opening(config, names)
  local taking = {}
  if config.programs then
    for _, name in ipairs(recorded(config)) do
      taking[name] = true
    end
    return taking
  end
  for _, name in ipairs(names) do
    taking[name] = true
  end
  return taking
end

local function menu(names, taking)
  local cursor = 1
  while true do
    term.clear()
    say("ocinstall v" .. VERSION .. "   what this computer keeps", WHITE)
    say("")
    for index, name in ipairs(names) do
      local on = taking[name]
      say((index == cursor and "  > " or "    ") .. (on and "[x] " or "[ ] ") .. name,
        on and WHITE or DIM)
    end
    say("")
    say("  ocup, ocinstall and the libraries are always kept", DIM)
    say("  up and down to move, space to toggle", DIM)
    say("  enter to keep these, q to change nothing", DIM)

    local name, _, _, code = event.pull(nil, "key_down")
    if name == nil or code == keyboard.keys.q then
      return false
    elseif code == keyboard.keys.enter then
      return true
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
      taking[names[cursor]] = not taking[names[cursor]]
    end
  end
end

-------------------------------------------------------------------------------

local config = core.loadConfig()
local names = choices(config)
if #names == 0 then
  io.stderr:write("ocinstall: nothing in " .. BIN .. " to choose from,"
    .. " run install from the floppy first\n")
  return 1
end

local taking = opening(config, names)

if not menu(names, taking) then
  term.clear()
  say("  nothing changed", DIM)
  return 0
end

local kept, dropped = {}, {}
for _, name in ipairs(names) do
  if taking[name] then
    kept[#kept + 1] = name
  else
    dropped[#dropped + 1] = name
  end
end

term.clear()
say("ocinstall v" .. VERSION, WHITE)
say("")

for _, name in ipairs(dropped) do
  local path = BIN .. "/" .. name .. ".lua"
  if filesystem.exists(path) then
    local ok, reason = filesystem.remove(path)
    if not ok then
      io.stderr:write("ocinstall: could not remove " .. path .. ": "
        .. tostring(reason) .. "\n")
      return 1
    end
    say("    removed  " .. name, CYAN)
  end
end

config.programs = kept
local saved, reason = core.saveConfig(config)
if not saved then
  io.stderr:write("ocinstall: could not write the choice: " .. tostring(reason) .. "\n")
  return 1
end

say("")
say("  keeping " .. #kept .. " of " .. #names .. ": " .. table.concat(kept, ", "), GREEN)
say("  written to " .. core.CONFIG_PATH .. ", so ocup will leave them alone", DIM)
if #kept == 0 then
  say("  every program was dropped, which is allowed but unusual", RED)
end
say("")
say("  ocup picks up anything newer once this machine is on the network", DIM)

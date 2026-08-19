-- ocsecurity: the OpenSecurity blocks worth driving from a program.
--
-- The alarm is the one thing here that makes a noise and needs nothing
-- installed on the server to do it. Computronics' speech box needs
-- text-to-speech that a pack does not ship; its speakers only ever carry a tape
-- drive or that speech box. This block is its own loudspeaker.
--
-- Signatures from the mod's own @Callback annotations, 1.7.10 branch:
--
--   os_alarm   activate():string      deactivate():string
--              setAlarm(name:string):string
--              setRange(blocks:number):string   0 to 15
--              listSounds():table
--              playSoundAt(x, y, z, sound:string, range:number):string
--
-- Two sounds ship with the mod, klaxon1 and klaxon2, and a pack may configure
-- more. Every call is direct, so none of them costs a server tick.

local component = require("component")
local core = require("oclib")

local sec = {}

sec.VERSION = "0.1.0"

sec.KINDS = {
  os_alarm = "a siren, loud enough to hear from outside",
  os_keypad = "a PIN pad on a door",
}

function sec.alarms()
  local found = {}
  for address in component.list("os_alarm") do
    found[#found + 1] = address
  end
  table.sort(found)
  return found
end

-- Sounds an alarm, or silences one. Returns how many answered, so a caller can
-- tell "there are none" from "they are all going off".
--
-- An alarm keeps sounding until it is told to stop, which is what makes it an
-- alarm rather than an announcement: it is set while something is wrong and
-- cleared when it is not.
function sec.alarm(on, sound)
  local answered = 0
  for _, address in ipairs(sec.alarms()) do
    if sound then
      core.setValue(address, "setAlarm", sound)
    end
    local ok
    if on then
      ok = core.setValue(address, "activate")
    else
      ok = core.setValue(address, "deactivate")
    end
    if ok then
      answered = answered + 1
    end
  end
  return answered
end

function sec.sounds()
  local address = sec.alarms()[1]
  if not address then
    return {}
  end
  local list = core.call(address, "listSounds")
  if type(list) ~= "table" then
    return {}
  end
  return list
end

return sec

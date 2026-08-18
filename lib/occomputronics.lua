-- occomputronics: the Computronics blocks that can tell somebody something.
--
-- Signatures below are taken from the mod's own source, from the @Callback
-- annotations on each tile, because the wiki says of itself that its pages are
-- usually outdated.
--
--   iron_noteblock   playNote([instrument:number or string,] note:number [, volume:number])
--   chat_box         say(text:string [, distance:number]):boolean
--                    getDistance():number  setDistance(n):number
--                    getName():string      setName(s):string
--   speech_box       say(text:string):boolean[, error:string]
--                    stop():boolean  isProcessing():boolean  setVolume(0..1)
--   colorful_lamp    getLampColor():number  setLampColor(0..0x7FFF):boolean
--   tape_drive       play() stop() isReady() isEnd() getState() getPosition()
--                    getSize() seek(n) read([n]) write(data) getLabel()
--                    setLabel(s) setSpeed(0.25..2) setVolume(0..1)
--   ticket_machine   printTicket([amount [, slot]])  setDestination([slot,] s)
--                    getDestination([slot])  getSelectedTicket()
--                    setSelectedTicket(slot) and the manual-use permissions
--
-- The Speaker is deliberately absent. It registers no OpenComputers component
-- at all: it is the loudspeaker a tape drive feeds over audio cable, and
-- nothing a program can call. Sound that a program chooses comes from the note
-- block, speech from the speech box, and words in chat from the chat box.

local component = require("component")
local core = require("oclib")

local ct = {}

ct.VERSION = "0.1.0"

-- what each component is, for a program that lists what it can see
ct.KINDS = {
  iron_noteblock = "plays one note at a time",
  chat_box = "writes into Minecraft chat",
  speech_box = "speaks text aloud, if the server has MaryTTS",
  colorful_lamp = "one lamp, 32768 colours",
  tape_drive = "plays a recorded tape through a speaker",
  ticket_machine = "prints Railcraft tickets",
}

-- the seven the mod accepts by name; anything else is refused outright
ct.INSTRUMENTS = { "harp", "bd", "snare", "hat", "bassattack", "pling", "bass" }

function ct.addresses(kind)
  local found = {}
  for address, present in component.list(kind) do
    if present then
      found[#found + 1] = address
    end
  end
  table.sort(found)
  return found
end

function ct.first(kind)
  return ct.addresses(kind)[1]
end

-- The lamp takes five bits a channel, not eight, so a colour has to be packed
-- rather than passed through. Zero is off rather than black, which is why a
-- dark colour still lights the block a little.
function ct.rgb(red, green, blue)
  local function channel(value)
    local scaled = math.floor((value or 0) / 8)
    if scaled < 0 then
      return 0
    end
    if scaled > 31 then
      return 31
    end
    return scaled
  end
  return channel(red) * 1024 + channel(green) * 32 + channel(blue)
end

function ct.lamps(color)
  local lit = 0
  for _, address in ipairs(ct.addresses("colorful_lamp")) do
    if core.setValue(address, "setLampColor", color) then
      lit = lit + 1
    end
  end
  return lit
end

-- Says something out loud, by whatever this computer has to say it with. A
-- speech box speaks; a chat box writes; a note block can only make a noise, so
-- it plays a short rising or falling figure instead of the words.
--
-- Returns what it used, or nil when the computer has none of them and the
-- caller should fall back to its own beep.
function ct.announce(text, urgent)
  local speech = ct.first("speech_box")
  if speech and core.setValue(speech, "say", text) then
    return "speech_box"
  end

  local chat = ct.first("chat_box")
  if chat and core.setValue(chat, "say", text) then
    return "chat_box"
  end

  local note = ct.first("iron_noteblock")
  if note then
    -- falling for trouble, rising for it being over: the only two things a
    -- single note block can say apart
    local figure = { 12, 7, 3 }
    if not urgent then
      figure = { 3, 7, 12 }
    end
    local played = false
    for _, pitch in ipairs(figure) do
      if core.setValue(note, "playNote", "harp", pitch, 1) then
        played = true
      end
    end
    if played then
      return "iron_noteblock"
    end
  end

  return nil
end

return ct

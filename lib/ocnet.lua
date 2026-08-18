-- ocnet: how machines here ask each other for status.
--
-- One satellite watches the machines around it and answers questions about
-- them; a main computer asks every satellite in range and shows the lot. Both
-- halves live here so the question and the answer cannot drift apart.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local gt = require("ocgt")
local lp = require("oclogistics")
local serialization = require("serialization")

local net = {}

net.VERSION = "0.1.0"

net.ASK = "ocstatus?"
net.REPLY = "ocstatus!"

-- An access point relays other people's packets; it is not a network card and
-- offers no open, send or broadcast. Asking for a modem specifically avoids
-- mistaking one for the other.
function net.modem()
  if not component.isAvailable("modem") then
    return nil, "no network card, only a relay or nothing at all"
  end
  local modem = component.getPrimary("modem")
  modem.open(core.PORT)
  -- a wireless card sits at zero range until told otherwise, which looks
  -- exactly like a card that does not work
  if modem.isWireless() then
    pcall(modem.setStrength, 400)
  end
  return modem
end

-- what to call this machine when its readings appear on somebody else's screen
function net.hostname(config)
  local name = config and config.hostname
  if name and name ~= "" then
    return name
  end
  return computer.address():sub(1, 8)
end

-- the machines this computer is responsible for: whatever ocwatch was told to
-- watch, and failing that everything GregTech it can see
local function targets(config)
  if config and config.watch and #config.watch > 0 then
    return config.watch
  end
  local found = {}
  for address, kind in component.list() do
    if kind:sub(1, 3) == "gt_" then
      found[#found + 1] = { address = address }
    end
  end
  return found
end

function net.snapshot(config)
  local cards = {}
  for _, entry in ipairs(targets(config)) do
    local card = {
      name = gt.displayName(entry.address, config)
        or lp.displayName(entry.address)
        or entry.address:sub(1, 8),
      status = gt.statusOf(entry.address),
      gauges = {},
    }
    for _, reading in ipairs(gt.readings(entry.address)) do
      if reading.kind == "gauge" then
        card.gauges[#card.gauges + 1] = {
          label = reading.label,
          current = reading.current,
          maximum = reading.maximum,
          unit = reading.unit,
          -- computed here so the asking machine never has to turn "42,000"
          -- back into a number
          percent = reading.max > 0 and (reading.value / reading.max * 100) or 0,
        }
      end
    end
    cards[#cards + 1] = card
  end
  return cards
end

-- Answers one request. Returns a description of what was sent, or nil when the
-- message was not a question this understands.
function net.answer(modem, port, remote, request, config)
  if port ~= core.PORT or request ~= net.ASK then
    return nil
  end

  local payload = serialization.serialize(net.snapshot(config))
  local limit = modem.maxPacketSize and modem.maxPacketSize() or 8192
  if #payload > limit then
    -- better a short answer than a packet the card silently refuses
    payload = serialization.serialize({ { name = "too many machines to send" } })
  end

  modem.send(remote, core.PORT, net.REPLY, net.hostname(config), payload)
  return tostring(remote):sub(1, 8) .. "  " .. #payload .. " bytes"
end

-- Asks everyone in range and collects every answer within the window, rather
-- than taking the first: a base has more than one satellite.
function net.ask(modem, event, seconds)
  modem.broadcast(core.PORT, net.ASK)

  local answers = {}
  local deadline = seconds or 3
  while deadline > 0 do
    local name, _, remote, port, _, kind, host, payload =
      event.pull(deadline, "modem_message")
    if name == nil then
      break
    end
    if port == core.PORT and kind == net.REPLY then
      local ok, cards = pcall(serialization.unserialize, payload)
      if ok and type(cards) == "table" then
        answers[#answers + 1] = {
          host = host or tostring(remote):sub(1, 8),
          address = remote,
          cards = cards,
        }
      end
    end
    -- keep listening: a second satellite may still be about to answer
    deadline = deadline - 1
  end
  return answers
end

return net

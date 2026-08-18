-- ocview: the base at a glance, on a tablet.
--
--   ocview        ask the network and keep the answer fresh
--   ocview --once ask once and stop, for checking it works
--
-- A tablet cannot see another computer's components, so it asks: ocserve on the
-- base answers with everything ocwatch is configured to watch.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local net = require("ocnet")
local keyboard = require("keyboard")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.6.0"

-- How long to give up on before saying so on screen. Answers are absorbed as
-- they arrive rather than waited for, so this is only how long a blank screen
-- may stay blank before it explains itself.
local ANSWER_TIMEOUT = 8
local REFRESH_SECONDS = 2
-- a satellite unheard for this long is shown as stale rather than as current
local QUIET_SECONDS = 12

local BG = 0x000000
local FG = 0xFFFFFF
local DIM = 0x999999
local BAR = 0x333333
local OK_COLOR = 0x66CC66
local ALARM = 0xCC6666

local FULL_BLOCK = "\226\150\136"
local LIGHT_BLOCK = "\226\150\145"

local gpu = component.gpu

local W, H, GAUGE_W

local paint = core.painter(gpu)

-- recomputed on a resize: a tablet docked to a screen changes size under us
local function layout()
  W, H = core.viewport(gpu)
  GAUGE_W = math.max(8, math.min(20, math.floor(W / 3)))
  paint.forget()
end

layout()

local function fit(text, width)
  local length = unicode.len(text)
  if length > width then
    return unicode.sub(text, 1, width)
  end
  return text .. string.rep(" ", width - length)
end

local write = paint.write

-- What each satellite last said, kept between rounds rather than gathered
-- inside one blocking call. A relay repeats what it forwards, so the same
-- answer arrives several times over different paths: keying on the answering
-- card means one satellite stays one entry however many copies land.
local satellites = {}
local order = {}
local seen = { heard = 0, unreadable = 0 }
local started = computer.uptime()

local function absorb(packed)
  seen.heard = seen.heard + 1
  local answer, why = net.decode(packed[4], packed[3], packed[6], packed[7], packed[8])
  if not answer then
    if why then
      seen.unreadable = seen.unreadable + 1
    end
    return false
  end

  answer.at = computer.uptime()
  if not satellites[answer.address] then
    order[#order + 1] = answer.address
  end
  satellites[answer.address] = answer
  return true
end

-- Saying only "no answer" hides which half is broken. Whether anything at all
-- arrived separates a satellite that never heard the question from one that
-- answered with something unreadable.
local function problem()
  if #order > 0 then
    return nil
  end
  if seen.unreadable > 0 then
    return "heard " .. seen.unreadable .. " unreadable answers: version mismatch?"
  end
  if seen.heard > 0 then
    return "heard " .. seen.heard .. " messages, none of them answers"
  end
  return "no answer yet: is ocwatch running there, and in range?"
end

-- green only for a machine that is actually doing something, red for one an
-- alert has stopped, and grey for one that is simply waiting
local function statusColor(status, alarm)
  if status == "stopped" or alarm then
    return ALARM
  end
  if status == "working" then
    return OK_COLOR
  end
  return DIM
end

local function drawGauge(x, y, gauge, width)
  local ratio = (gauge.percent or 0) / 100
  if ratio < 0 then
    ratio = 0
  elseif ratio > 1 then
    ratio = 1
  end
  local filled = math.floor(width * ratio + 0.5)

  write(x, y, "[", DIM, BG)
  local cursor = x + 1
  if filled > 0 then
    write(cursor, y, string.rep(FULL_BLOCK, filled), OK_COLOR, BG)
    cursor = cursor + filled
  end
  if width - filled > 0 then
    write(cursor, y, string.rep(LIGHT_BLOCK, width - filled), DIM, BG)
    cursor = cursor + width - filled
  end
  write(cursor, y, "]", DIM, BG)

  local unit = (gauge.unit and gauge.unit ~= "") and (" " .. gauge.unit) or ""
  local text = string.format("  %s / %s%s", tostring(gauge.current), tostring(gauge.maximum), unit)
  -- the satellite sends this only when its bar is drawn against a local
  -- maximum, so the real capacity is never lost
  if gauge.capacity then
    text = text .. "  of " .. tostring(gauge.capacity)
  end
  write(cursor + 1, y, fit(text, math.max(0, W - cursor - 1)), FG, BG)
end

local function render()
  local trouble = problem()
  local machines = 0
  for _, address in ipairs(order) do
    machines = machines + #satellites[address].cards
  end
  write(1, 1, fit("  ocview v" .. VERSION .. "    "
    .. (#order > 0 and (#order .. " satellites, " .. machines .. " machines")
      or "no data"), W), FG, BAR)

  if trouble then
    write(3, 3, fit(trouble, W - 4), ALARM, BG)
  end

  local y = 3
  for _, address in ipairs(order) do
    local answer = satellites[address]
    if y > H - 2 then
      break
    end
    -- naming the satellite matters once there is more than one: otherwise two
    -- machines called EBF1 on different computers are indistinguishable
    local quiet = computer.uptime() - answer.at > QUIET_SECONDS
    write(1, y, fit(" " .. answer.host
      .. (quiet and "   not answering" or ""), W), FG, BAR)
    y = y + 1

    -- An alert that has tripped is the reason to be looking at this screen at
    -- all, so it goes above the machines rather than being deduced from them.
    for _, alert in ipairs(answer.alerts or {}) do
      if y > H - 2 then
        break
      end
      local mark = alert.tripped and "!" or "ok"
      write(3, y, fit(mark .. "  " .. tostring(alert.name), W - 4),
        alert.tripped and ALARM or DIM, BG)
      y = y + 1
    end

    for _, card in ipairs(answer.cards) do
      if y > H - 2 then
        break
      end
      write(3, y, fit(card.name or "?", W - 14), FG, BG)
      if card.status then
        write(math.max(1, W - 12), y, fit(card.status, 11),
          statusColor(card.status, card.alarm), BG)
      end
      y = y + 1

      for _, gauge in ipairs(card.gauges or {}) do
        if y > H - 2 then
          break
        end
        local label = (gauge.label and gauge.label ~= "") and gauge.label or "value"
        write(5, y, fit(label, 10), DIM, BG)
        drawGauge(16, y, gauge, GAUGE_W)
        y = y + 1
      end
    end
    y = y + 1
  end

  write(1, H, fit("  [r] refresh   [q] quit      every " .. REFRESH_SECONDS .. "s", W), FG, BAR)
  paint.flush(W, H, BG, FG)
end

-------------------------------------------------------------------------------

local arguments = { ... }
local once = arguments[1] == "--once"

local modem, reason = net.modem()
if not modem then
  io.stderr:write("ocview: " .. reason .. "\n")
  return 1
end

term.clear()
term.setCursorBlink(false)
paint.forget()

-- One loop, so a keypress is read the moment it arrives. Waiting for a whole
-- round of answers inside the ask is what made this ignore the keyboard for
-- seconds at a time, and what kept the screen a round behind the machines.
--
-- Backdated so the first turn of the loop asks rather than waiting a round.
local asked = computer.uptime() - REFRESH_SECONDS

while true do
  local now = computer.uptime()
  if now - asked >= REFRESH_SECONDS then
    net.ask(modem)
    asked = now
  end
  render()

  -- one screen, but not before every satellite in range has had its say
  if once and now - started >= ANSWER_TIMEOUT then
    break
  end

  local wait = math.max(0.1, asked + REFRESH_SECONDS - computer.uptime())
  local packed = table.pack(event.pull(wait))
  local name = packed[1]

  if name == "interrupted" then
    break
  elseif name == "modem_message" then
    absorb(packed)
  elseif name == "screen_resized" then
    layout()
  elseif name == "key_down" then
    local code = packed[4]
    if code == keyboard.keys.q then
      break
    elseif code == keyboard.keys.r then
      asked = 0
    end
  end
end

gpu.setForeground(FG)
-- --once exists to be looked at, so it leaves its one screen up
if not once then
  gpu.setBackground(BG)
  term.clear()
end

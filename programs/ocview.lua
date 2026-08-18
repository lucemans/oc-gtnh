-- ocview: the base at a glance, on a tablet.
--
--   ocview        ask the network and keep the answer fresh
--   ocview --once ask once and stop, for checking it works
--
-- A tablet cannot see another computer's components, so it asks: ocserve on the
-- base answers with everything ocwatch is configured to watch.

local component = require("component")
local core = require("oclib")
local event = require("event")
local net = require("ocnet")
local keyboard = require("keyboard")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.4.0"

-- a satellite answers between refreshes, and reading six GregTech machines
-- costs a second or more of server ticks; three seconds was too impatient
local ANSWER_TIMEOUT = 8
local REFRESH_SECONDS = 5

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

-- recomputed on a resize: a tablet docked to a screen changes size under us
local function layout()
  W, H = core.viewport(gpu)
  GAUGE_W = math.max(8, math.min(20, math.floor(W / 3)))
end

layout()

local function fit(text, width)
  local length = unicode.len(text)
  if length > width then
    return unicode.sub(text, 1, width)
  end
  return text .. string.rep(" ", width - length)
end

local function write(x, y, text, foreground, background)
  gpu.setForeground(foreground or FG)
  gpu.setBackground(background or BG)
  gpu.set(x, y, text)
end

-- Every satellite in range is collected, not just the quickest: a base has more
-- than one, and taking the first answer would hide the rest.
local function ask(modem)
  local answers, seen = net.ask(modem, event, ANSWER_TIMEOUT)
  if #answers > 0 then
    return answers
  end

  -- Saying only "no answer" hides which half is broken. Whether anything at all
  -- arrived separates a satellite that never heard the question from one that
  -- answered with something unreadable.
  if seen.unreadable > 0 then
    return nil, "heard " .. seen.unreadable .. " unreadable answers: version mismatch?"
  end
  if seen.heard > 0 then
    return nil, "heard " .. seen.heard .. " messages, none of them answers"
  end
  return nil, "no answer in " .. ANSWER_TIMEOUT .. "s: is ocwatch running there, and in range?"
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
  write(cursor + 1, y, fit(text, math.max(0, W - cursor - 1)), FG, BG)
end

local function render(answers, problem)
  gpu.setBackground(BG)
  gpu.fill(1, 1, W, H, " ")

  local machines = 0
  for _, answer in ipairs(answers or {}) do
    machines = machines + #answer.cards
  end
  write(1, 1, fit("  ocview v" .. VERSION .. "    "
    .. (answers and (#answers .. " satellites, " .. machines .. " machines")
      or "no data"), W), FG, BAR)

  if problem then
    write(3, 3, fit(problem, W - 4), ALARM, BG)
  end

  local y = 3
  for _, answer in ipairs(answers or {}) do
    if y > H - 2 then
      break
    end
    -- naming the satellite matters once there is more than one: otherwise two
    -- machines called EBF1 on different computers are indistinguishable
    write(1, y, fit(" " .. answer.host, W), FG, BAR)
    y = y + 1

    for _, card in ipairs(answer.cards) do
      if y > H - 2 then
        break
      end
      write(3, y, fit(card.name or "?", W - 14), FG, BG)
      if card.status then
        write(math.max(1, W - 12), y, fit(card.status, 11), OK_COLOR, BG)
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

local cards, problem = ask(modem)
render(cards, problem)

if once then
  gpu.setForeground(FG)
  return 0
end

while true do
  local name, _, _, code = event.pull(REFRESH_SECONDS)

  if name == "interrupted" then
    break
  elseif name == "screen_resized" then
    layout()
    render(cards, problem)
  elseif name == "key_down" and code == keyboard.keys.q then
    break
  elseif name == "key_down" and code == keyboard.keys.r then
    local fresh, trouble = ask(modem)
    -- a missed round keeps the last good picture rather than blanking it
    cards, problem = fresh or cards, trouble
    render(cards, problem)
  elseif name == nil then
    local fresh, trouble = ask(modem)
    cards, problem = fresh or cards, trouble
    render(cards, problem)
  end
end

gpu.setForeground(FG)
gpu.setBackground(BG)
term.clear()

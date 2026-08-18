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
local keyboard = require("keyboard")
local serialization = require("serialization")
local term = require("term")
local unicode = require("unicode")

local VERSION = "0.1.0"

local ASK = "ocstatus?"
local REPLY = "ocstatus!"
-- long enough for a busy base to answer, short enough not to feel stuck
local ANSWER_TIMEOUT = 3
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
local W, H = gpu.getResolution()
local GAUGE_W = math.max(8, math.min(20, math.floor(W / 3)))

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

local function ask(modem)
  modem.broadcast(core.PORT, ASK)

  local deadline = ANSWER_TIMEOUT
  while deadline > 0 do
    local name, _, _, port, _, kind, payload = event.pull(deadline, "modem_message")
    if name == nil then
      return nil, "no answer"
    end
    if port == core.PORT and kind == REPLY then
      local ok, cards = pcall(serialization.unserialize, payload)
      if ok and type(cards) == "table" then
        return cards
      end
      return nil, "unreadable answer"
    end
    deadline = deadline - 1
  end
  return nil, "no answer"
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

local function render(cards, problem)
  gpu.setBackground(BG)
  gpu.fill(1, 1, W, H, " ")
  write(1, 1, fit("  ocview v" .. VERSION .. "    "
    .. (cards and (#cards .. " machines") or "no data"), W), FG, BAR)

  if problem then
    write(3, 3, fit(problem, W - 4), ALARM, BG)
  end

  local y = 3
  for _, card in ipairs(cards or {}) do
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
    y = y + 1
  end

  write(1, H, fit("  [r] refresh   [q] quit      every " .. REFRESH_SECONDS .. "s", W), FG, BAR)
end

-------------------------------------------------------------------------------

local arguments = { ... }
local once = arguments[1] == "--once"

if not component.isAvailable("modem") then
  io.stderr:write("ocview: no network card installed\n")
  return 1
end

local modem = component.getPrimary("modem")
modem.open(core.PORT)
if modem.isWireless() then
  pcall(modem.setStrength, 400)
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
  elseif name == "key_down" and code == keyboard.keys.q then
    break
  elseif name == "key_down" and code == keyboard.keys.r then
    cards, problem = ask(modem)
    render(cards, problem)
  elseif name == nil then
    cards, problem = ask(modem)
    render(cards, problem)
  end
end

gpu.setForeground(FG)
gpu.setBackground(BG)
term.clear()

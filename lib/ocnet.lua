-- ocnet: how machines here ask each other for status.
--
-- One satellite watches the machines around it and answers questions about
-- them; a main computer asks every satellite it knows of and shows the lot.
-- Both halves live here so the question and the answer cannot drift apart.
--
-- It rides on Minitel, which is a daemon owning the modems and a library
-- turning calls into signals for it. What that buys is a hostname instead of
-- half a card address, and a satellite reachable through whatever computers
-- sit between here and there rather than only one that is in range.
--
-- Nothing here waits for a packet to be acknowledged. A report is replaced by
-- the next one within seconds, and the blocking form of a Minitel send sits in
-- a filtered event.pull, which drops every keypress that arrives while it
-- waits. Programs with a screen receive through net.listen for the same
-- reason.

local component = require("component")
local computer = require("computer")
local core = require("oclib")
local event = require("event")
local gt = require("ocgt")
local lp = require("oclogistics")
local rc = require("ocrailcraft")
local serialization = require("serialization")
local tank = require("octank")

local net = {}

net.VERSION = "0.14.0"

net.ASK = "ocstatus?"
net.REPLY = "ocstatus!"

-- Whoever can reach the internet, asked for by anyone who cannot. The answer
-- is a hostname, which ocup then fetches through.
net.GATEWAY_ASK = "ocgateway?"
net.GATEWAY_REPLY = "ocgateway!"

-- What the base has written down, asked of whichever machine collects it. The
-- answer carries the collector's own clock as well as the records, because a
-- record is stamped with the uptime of the machine that wrote it and that
-- number means nothing on the machine reading it.
net.LOG_ASK = "oclog?"
net.LOG_REPLY = "oclog!"

-- how many records travel. Beyond a screenful nobody is reading them here.
local RECORDS = 40

-- Minitel's own broadcast address. It is delivered to every node on this
-- segment and deliberately never forwarded, so it finds what is in range and
-- the peer list finds the rest.
net.EVERYONE = "~"

-- The word net.up sends to itself, and how long it waits for the daemon to hand
-- it back. Deliberately not a question, so answering the loopback is not work
-- every program does once at startup.
local PROBE = "ocalive?"
local ALIVE = 1

-- Whether Minitel is installed and its daemon is actually running, and where
-- packets go once it is. A packet addressed to this machine is handed straight
-- back by the daemon, and by nothing else, so a loopback that returns is the
-- whole proof.
--
-- The loopback consumes a packet, so a program that wants to hear the network
-- calls net.listen before this rather than after: a question that arrived first
-- would otherwise be taken as the proof and then be gone.
function net.up()
  local ok, minitel = pcall(require, "minitel")
  if not ok or type(minitel) ~= "table" then
    return nil, "minitel is not installed, run ocup"
  end

  -- a wireless card sits at zero range until told otherwise, which looks
  -- exactly like a card that does not work. The daemon opens the ports but
  -- leaves the strength alone.
  local cards = 0
  for address in component.list("modem") do
    cards = cards + 1
    local card = component.proxy(address)
    if card.isWireless and card.isWireless() then
      pcall(card.setStrength, 400)
    end
  end
  if cards == 0 then
    return nil, "no network card, only a relay or nothing at all"
  end

  minitel.usend(net.hostname(), core.PORT, PROBE)
  if not event.pull(ALIVE, "net_msg") then
    return nil, "the minitel daemon is not running, try: rc minitel start"
  end

  return minitel
end

-- Read once. The name is asked far more often than it can change: every packet
-- sent and every question answered asks, so a satellite answering a dashboard
-- was opening the file every couple of seconds and the disks were audible
-- across the base. net.setHostname is the only rename here and keeps this
-- current.
local named, readNamed

local function fromFile()
  if not readNamed then
    readNamed = true
    local file = io.open("/etc/hostname", "r")
    if file then
      named = file:read()
      file:close()
    end
  end
  return named
end

-- What to call this machine. The Minitel daemon reads /etc/hostname when it
-- starts and names every packet with it, so that file is asked first and
-- everything else is a fallback for a machine that has none.
--
-- The HOSTNAME variable is deliberately second. OpenOS sets it per shell, from
-- that same file, at whatever moment `hostname --update` last ran, so it can
-- say something the daemon has never heard of. Believing it over the file is
-- how a machine addresses its own loopback to a name that is not its own.
function net.hostname(config)
  local name = fromFile()
  if not name or name == "" then
    name = os.getenv("HOSTNAME")
  end
  if not name or name == "" then
    name = config and config.hostname
  end
  if not name or name == "" then
    return computer.address():sub(1, 8)
  end
  return name
end

-- Renames this machine. The Minitel daemon reads /etc/hostname when it starts
-- and names every packet with what it found there, so writing the file is the
-- rename and the daemon has to be restarted for it to take.
function net.setHostname(name)
  local file, reason = io.open("/etc/hostname", "w")
  if not file then
    return nil, tostring(reason)
  end
  file:write(name)
  file:close()
  named, readNamed = name, true
  return true
end

-- What a Minitel packet can carry as an address. The protocol allows rather
-- more than this, but a tilde is the broadcast marker and a space makes the
-- name awkward everywhere else it is typed.
function net.validHostname(name)
  if type(name) ~= "string" or name == "" then
    return nil, "a machine needs a name"
  end
  if #name > 63 then
    return nil, "too long, 63 characters at most"
  end
  if name:find("^[%w][%w%-_%.]*$") == nil then
    return nil, "letters, digits, dot, dash and underscore only, starting with a letter or digit"
  end
  return true
end

-- Every satellite this machine should hear from: the ones it has heard from
-- before, which is how a peer list fills itself in, and any added by hand for
-- a satellite that was never in range to be heard.
function net.peers(config)
  local out, seen = {}, {}
  for _, host in ipairs(config and config.peers or {}) do
    if host ~= "" and not seen[host] then
      seen[host] = true
      out[#out + 1] = host
    end
  end
  return out
end

-- Records a satellite that answered, so the next question reaches it by name
-- through the mesh rather than only when it happens to be in range. Returns
-- true when the list changed and is worth saving.
function net.remember(config, host)
  if not config or host == "" or host == net.hostname(config) then
    return false
  end
  config.peers = config.peers or {}
  for _, each in ipairs(config.peers) do
    if each == host then
      return false
    end
  end
  config.peers[#config.peers + 1] = host
  return true
end

function net.forget(config, host)
  for index, each in ipairs(config and config.peers or {}) do
    if each == host then
      table.remove(config.peers, index)
      return true
    end
  end
  return false
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

-- Reads every machine this computer is responsible for. ocwatch calls this once
-- per refresh for its own dashboard and hands the result straight to net.report,
-- so a question costs no machine reads at all: on a busy satellite each one is a
-- server tick, and doing them again per request was most of the delay a tablet
-- saw.
function net.machines(config)
  local cards = {}
  for _, entry in ipairs(targets(config)) do
    -- a side means a tank read through a transposer, which is how a block with
    -- no driver of its own gets onto the dashboard
    local look
    if entry.side then
      look = tank.inspect(entry.address, entry.side, config)
    else
      look = rc.inspect(entry.address, config) or gt.inspect(entry.address, config)
    end
    cards[#cards + 1] = {
      entry = entry,
      name = look.name or lp.displayName(entry.address) or entry.address:sub(1, 8),
      status = look.status,
      readings = look.readings,
    }
  end
  return cards
end

-- Where the alerts watching a reading sit along its bar, as shares of the
-- maximum. A bar says how full something is; these say how full it has to get
-- before anything happens, which is the other half of the same question.
function net.marksOn(config, reading, max)
  if not max or max <= 0 then
    return nil
  end
  local marks = nil
  for _, alert in ipairs(config and config.alerts or {}) do
    if alert.label == reading.label
      or (alert.unit or "") == (reading.unit or "") then
      for _, at in ipairs({ alert.below, alert.above, alert.over, alert.under }) do
        local share = at / max
        if share > 0 and share <= 1 then
          marks = marks or {}
          marks[#marks + 1] = share
        end
      end
    end
  end
  return marks
end

-- the local maximum chosen for the nth gauge of a machine, kept by position
-- rather than by label because a tank drops its fluid name when it runs dry
function net.limitOf(entry, ordinal)
  return entry and entry.limits and entry.limits[ordinal] or nil
end

-- How many fluids travel. A base stocks tens of them where it stocks thousands
-- of items, so the list is short enough to send nearly whole; the bound is here
-- because a packet is 8 KB and a machine is worth more of it than a fluid.
local FLUIDS = 12

-- What travels over the wire. Gauges arrive already rescaled and already
-- formatted, so the asking machine never turns "42,000" back into a number.
function net.report(config, cards, movers, fluids)
  local report = {
    -- the card address is the only thing that tells two satellites sharing a
    -- hostname apart, and a hostname is what everything else keys on
    address = computer.address(),
    cards = {},
    alerts = {},
    items = {},
    fluids = {},
  }

  -- What the item network is doing, if this computer is watching one. Only the
  -- few that are moving travel; the list itself is thousands long. The window
  -- travels with them, because the machine that measured it is the one that
  -- knows what it measured over.
  for _, item in ipairs(movers or {}) do
    report.items[#report.items + 1] = { name = item.name, rate = item.rate }
  end
  if report.items[1] then
    report.over = lp.OVER
  end

  -- What the fluid network holds, if this computer is watching one. The amount
  -- itself travels as well as what it is doing: a fluid network is short enough
  -- for the whole stock to be news, where an item network is not.
  for rank, fluid in ipairs(fluids or {}) do
    if rank > FLUIDS then
      break
    end
    report.fluids[rank] =
      { name = fluid.name, amount = fluid.amount, rate = fluid.rate }
  end

  for _, card in ipairs(cards) do
    local out = {
      name = card.name,
      status = card.status,
      alarm = card.alarm,
      -- how it is drawn belongs to the machine, not to whoever is looking
      compact = card.entry and card.entry.compact or nil,
      gauges = {},
    }
    local ordinal = 0
    for _, reading in ipairs(card.readings) do
      if reading.kind == "gauge" then
        ordinal = ordinal + 1
        local max, isLocal = core.scale(reading, net.limitOf(card.entry, ordinal))
        out.gauges[#out.gauges + 1] = {
          label = reading.label,
          current = reading.current,
          maximum = core.comma(max),
          -- only sent when the bar is drawn against a local maximum, so the
          -- real capacity is still visible somewhere
          capacity = isLocal and reading.maximum or nil,
          unit = reading.unit,
          -- the colour travels too, or a bar means one thing on the dashboard
          -- and another on the tablet watching it
          colorCode = reading.colorCode,
          -- which way the reading is going, and how fast
          rate = reading.rate,
          -- where along the bar an alert on this reading sits, as a share of
          -- the maximum it is drawn against
          marks = net.marksOn(config, reading, max),
          percent = max > 0 and (reading.value / max * 100) or 0,
        }
      end
    end
    report.cards[#report.cards + 1] = out
  end

  for _, alert in ipairs(config and config.alerts or {}) do
    report.alerts[#report.alerts + 1] = {
      name = alert.name,
      tripped = alert.tripped or false,
      trouble = alert.trouble ~= false,
    }
  end

  return report
end

-- What one packet holds. Minitel fragments anything longer across several
-- packets and only reassembles them inside a stream, so a report that does not
-- fit here arrives as pieces nobody puts back together.
local function room(minitel, to)
  local mtu = minitel and minitel.mtu or 8192
  return mtu - (44 + #net.hostname() + #tostring(to))
end

-- Answers one request with a report somebody else has already prepared. Returns
-- a description of what was sent, or nil when the message was not a question
-- this understands.
function net.answer(minitel, port, from, request, report)
  if port ~= core.PORT then
    return nil
  end

  if request == net.GATEWAY_ASK then
    if not component.isAvailable("internet") then
      return nil
    end
    minitel.usend(from, core.PORT, net.GATEWAY_REPLY)
    return from .. "  gateway"
  end

  if request == net.LOG_ASK then
    -- Required here rather than at the top of the file: ocitems decides how
    -- often it can read its network out of the memory it has left, and a
    -- library it will almost never be asked for is memory taken off that.
    local ok, notify = pcall(require, "ocnotify")
    if not ok then
      return nil
    end
    -- A machine that has never written anything answers with nothing rather
    -- than staying silent. Silence and an empty history look the same on the
    -- asking screen, and only one of them is worth investigating.
    local records = notify.records(RECORDS) or {}

    local payload = serialization.serialize({
      now = computer.uptime(),
      records = records,
    })
    -- newest first, so the oldest is what goes when it will not all fit
    while #payload > room(minitel, from) and #records > 1 do
      table.remove(records)
      payload = serialization.serialize({
        now = computer.uptime(),
        records = records,
      })
    end

    minitel.usend(from, core.PORT, net.LOG_REPLY .. "\n" .. payload)
    return from .. "  " .. #records .. " records"
  end

  if request ~= net.ASK then
    return nil
  end

  local payload = serialization.serialize(report)
  if #payload > room(minitel, from) then
    -- better a short answer than one that arrives in pieces
    payload = serialization.serialize({
      address = computer.address(),
      cards = { { name = "too many machines to send", gauges = {} } },
      alerts = {},
    })
  end

  minitel.usend(from, core.PORT, net.REPLY .. "\n" .. payload)
  return from .. "  " .. #payload .. " bytes"
end

-- Puts the question to everyone in range, and by name to every satellite this
-- machine has heard from before. A broadcast is never forwarded, so the peer
-- list is the only thing that crosses the mesh.
function net.ask(minitel, config)
  minitel.usend(net.EVERYONE, core.PORT, net.ASK)
  local here = net.hostname(config)
  for _, host in ipairs(net.peers(config)) do
    if host ~= here then
      minitel.usend(host, core.PORT, net.ASK)
    end
  end
end

-- Asks whoever can reach the internet to say so. Answered by any machine
-- running ocwatch or ocserve that has an internet card.
function net.askGateway(minitel)
  minitel.usend(net.EVERYONE, core.PORT, net.GATEWAY_ASK)
end

-- Asks for what has been written down.
--
-- With a collector named, only it is asked, because it already holds a copy of
-- everybody's records and asking the satellites as well would hear each one
-- twice. With none named, every machine keeps its own and nobody holds the lot,
-- so everybody is asked and the answers are one base's history between them.
function net.askLog(minitel, config, host)
  if host and host ~= "" then
    minitel.usend(host, core.PORT, net.LOG_ASK)
    return
  end
  minitel.usend(net.EVERYONE, core.PORT, net.LOG_ASK)
  local here = net.hostname(config)
  for _, peer in ipairs(net.peers(config)) do
    if peer ~= here then
      minitel.usend(peer, core.PORT, net.LOG_ASK)
    end
  end
end

-- Reads one message off the network. Returns the answer it carries, or nil, and
-- with nil a reason when the message was an answer that could not be
-- understood. A satellite still on the old raw broadcast is not heard at all,
-- which is what a version this far apart looks like.
function net.decode(port, from, data)
  if port ~= core.PORT or type(data) ~= "string" then
    return nil
  end
  local body = data:match("^" .. net.REPLY .. "\n(.*)$")
  if not body then
    return nil
  end

  local ok, report = pcall(serialization.unserialize, body)
  if not ok or type(report) ~= "table" or type(report.cards) ~= "table" then
    return nil, "unreadable"
  end

  return {
    host = from,
    address = report.address,
    cards = report.cards,
    alerts = report.alerts or {},
    items = report.items or {},
    fluids = report.fluids or {},
    over = report.over,
  }
end

-- Reads an answer to net.askLog. The records come back newest first, each with
-- the level it was raised at, and `now` is the collector's clock at the moment
-- it answered, which is the only thing that makes the stamps mean anything
-- here.
function net.decodeLog(port, from, data)
  if port ~= core.PORT or type(data) ~= "string" then
    return nil
  end
  local body = data:match("^" .. net.LOG_REPLY .. "\n(.*)$")
  if not body then
    return nil
  end

  local ok, answer = pcall(serialization.unserialize, body)
  if not ok or type(answer) ~= "table" or type(answer.records) ~= "table" then
    return nil, "unreadable"
  end

  return { host = from, now = answer.now or 0, records = answer.records }
end

-- Hands every packet that arrives to one function, which is how a program with
-- a screen hears the network without ever blocking on it. The handler is called
-- from inside whatever event.pull the program happens to be in, so it should
-- put the packet somewhere and return rather than draw anything.
function net.listen(handler)
  local function heard(_, from, port, data)
    -- the loopback net.up sends itself is this library proving the daemon is
    -- alive, and is nobody else's packet to see
    if port == core.PORT and data == PROBE then
      return
    end
    handler(from, port, data)
  end
  event.listen("net_msg", heard)
  event.listen("net_broadcast", heard)
  return heard
end

function net.deafen(token)
  event.ignore("net_msg", token)
  event.ignore("net_broadcast", token)
end

return net

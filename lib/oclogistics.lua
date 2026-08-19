-- oclogistics: what we know about Logistics Pipes.
-- machine/NOTES.md records where each of these rules came from.
--
-- A logisticspipe component offers one method, getPipe, which returns a proxy
-- rather than data. Each field of that proxy is one method, shaped
-- {name = "...", proxy = <the proxy>}, callable through a __call metamethod.

local component = require("component")
local computer = require("computer")
local core = require("oclib")

local lp = {}

lp.VERSION = "0.7.0"

function lp.isPipe(address)
  return core.has(core.methodsOf(address), "getPipe")
end

-- the proxy itself, or nil when this component is not a pipe
function lp.pipe(address)
  if not lp.isPipe(address) then
    return nil
  end
  local proxy = core.call(address, "getPipe")
  if type(proxy) ~= "table" then
    return nil
  end
  return proxy
end

-- calls one method on a proxy; the entry is a table, callable through __call
function lp.invoke(proxy, name, ...)
  local entry = proxy and proxy[name]
  if type(entry) ~= "table" then
    return nil, "no such method: " .. tostring(name)
  end
  local results = table.pack(pcall(entry, ...))
  if not results[1] then
    return nil, core.oneLine(tostring(results[2]))
  end
  return table.unpack(results, 2, results.n)
end

-- short and unique on the network, but only for as long as the server runs
function lp.routerId(address)
  local id = lp.invoke(lp.pipe(address), "getRouterId")
  return type(id) == "number" and id or nil
end

-- survives a restart, so this is the one to store in configuration
function lp.routerUUID(address)
  local uuid = lp.invoke(lp.pipe(address), "getRouterUUID")
  return type(uuid) == "string" and uuid or nil
end

function lp.hasModule(address)
  return lp.invoke(lp.pipe(address), "hasLogisticsModule") == true
end

-- a pipe answers no getName, so its router id is the only label it offers
function lp.displayName(address)
  local id = lp.routerId(address)
  return id and ("Logistics Pipe #" .. id) or nil
end

function lp.pipes()
  local found = {}
  for address in component.list("logisticspipe") do
    found[#found + 1] = address
  end
  table.sort(found)
  return found
end

-- A request pipe is the one that can see the whole network; a basic pipe knows
-- only its own filters and answers no getAvailableItems.
function lp.requestPipe()
  for _, address in ipairs(lp.pipes()) do
    local proxy = lp.pipe(address)
    if type(proxy) == "table" and type(proxy.getAvailableItems) == "table" then
      return proxy, address
    end
  end
  return nil
end

-- What a name costs while a scan is running: about 1.4 KB, of which 600 bytes
-- is the identifier that is kept and the rest is the pairs the collector has
-- not got to yet.
local NAME = 1400
-- what is left alone for the program to draw with afterwards
local SPARE = 150 * 1024

-- How many items can be named, asked after the list has arrived so the answer
-- is what is left rather than what there was. A computer with 1.4 MB names
-- about 220 of them; a server with 3.8 MB names the whole network. Nothing is
-- tuned per machine, because the machine already knows.
local function most()
  return math.max(50, math.floor((computer.freeMemory() - SPARE) / NAME))
end

-- Everything the network holds, the most plentiful first.
--
-- getAvailableItems answers with one Pair an item: getValue2 is how many there
-- are, getValue1 the ItemIdentifier the name comes from. The counts are cheap
-- and the names are not, so every count is read, the order is settled from
-- them, and only the items that will be shown are ever named.
--
-- The pairs nobody will name are dropped before the first name is read, because
-- what they free is the room the names go into. There is no collectgarbage on
-- this machine, so memory comes back only under the pressure of asking for
-- more, and asking for the whole list twice in one run ends the computer.
function lp.available(proxy, howMany)
  local list = lp.invoke(proxy, "getAvailableItems")
  if type(list) ~= "table" then
    return nil, "getAvailableItems answered nothing"
  end

  local total = #list
  local wanted = math.min(howMany or most(), total)
  local items = {}

  -- one pcall around the whole scan rather than one a call: three thousand of
  -- them would cost more memory than the names they were guarding
  local ok, reason = pcall(function()
    local amounts, order = {}, {}
    for index = 1, total do
      amounts[index] = list[index].getValue2()
      order[index] = index
    end

    table.sort(order, function(a, b) return amounts[a] > amounts[b] end)

    local named = {}
    for rank = 1, wanted do
      named[order[rank]] = true
    end
    for index = 1, total do
      if not named[index] then
        list[index] = false
      end
    end

    for rank = 1, wanted do
      local index = order[rank]
      local id = list[index].getValue1()
      items[rank] = {
        name = id.getName(),
        amount = amounts[index],
        itemId = id.getId(),
        itemData = id.getData(),
        tagged = id.hasTagCompound() == true,
      }
      list[index] = false
    end
  end)

  if not ok then
    return nil, core.oneLine(tostring(reason))
  end
  return items, total
end

-- The builder that names an item to the network. It is made once and set again
-- for each item, since asking for a new one hands back another object the
-- computer then has to hold.
function lp.builder(proxy)
  local object = lp.invoke(proxy, "getLP")
  if type(object) ~= "table" then
    return nil
  end
  local builder = lp.invoke(object, "getItemIdentifierBuilder")
  return type(builder) == "table" and builder or nil
end

-- How many of one item the network has, asked for by the two numbers that name
-- it. Building the identifier costs nothing and waits for nothing; the question
-- itself takes a server tick, which is why a program asks it about a few items
-- between draws rather than about all of them at once.
--
-- An item carrying an NBT tag cannot be asked for this way. Two numbers do not
-- say which variant is meant and the network answers 0, so a tagged item is
-- only ever counted by a full read.
function lp.count(proxy, builder, itemId, itemData)
  lp.invoke(builder, "setItemID", itemId)
  lp.invoke(builder, "setItemData", itemData)
  local id = lp.invoke(builder, "build")
  if type(id) ~= "table" then
    return nil
  end
  local amount = lp.invoke(proxy, "getItemAmount", id)
  return type(amount) == "number" and amount or nil
end

-- what a rate is measured over
local MINUTE = 60

-- Takes one reading of an item and works out which way it is going.
--
-- The reading is compared with the one that opened the window rather than with
-- the reading before it: a pass round the list takes about a quarter of a
-- minute, and a difference over a quarter of a minute is mostly noise. The rate
-- only changes when a window closes, so a figure on screen is what happened
-- over the last minute rather than what happened in the last moment.
function lp.mark(item, amount, now)
  item.amount = amount
  if not item.when then
    item.was, item.when = amount, now
    return
  end
  local since = now - item.when
  if since >= MINUTE then
    item.rate = math.floor((amount - item.was) / since * MINUTE + 0.5)
    item.was, item.when = amount, now
  end
end

-- Counts a few items, carrying on from wherever the last call stopped, and says
-- where it stopped this time and whether that was the end of a pass. One count
-- is a server tick, so a program does a few of these between draws instead of
-- the whole list at once.
function lp.sweep(proxy, builder, items, from, many)
  local now = computer.uptime()
  local cursor = from
  for _ = 1, many do
    local item = items[cursor]
    if not item then
      return 1, true
    end
    -- a tagged item cannot be counted this way; only a full read counts it
    if not item.tagged then
      local amount = lp.count(proxy, builder, item.itemId, item.itemData)
      if amount then
        lp.mark(item, amount, now)
      end
    end
    cursor = cursor + 1
    if cursor > #items then
      return 1, true
    end
  end
  return cursor, false
end

-- The few items whose count is moving, the ones going up first and the ones
-- going down last. Everything standing still says nothing and is left out, so a
-- short list is the whole of what is happening rather than the top of it.
function lp.movers(items, ends)
  local moving = {}
  for _, item in ipairs(items) do
    if item.rate and item.rate ~= 0 then
      moving[#moving + 1] = item
    end
  end
  table.sort(moving, function(a, b) return a.rate > b.rate end)

  if #moving <= ends * 2 then
    return moving
  end
  local few = {}
  for rank = 1, ends do
    few[#few + 1] = moving[rank]
  end
  for rank = #moving - ends + 1, #moving do
    few[#few + 1] = moving[rank]
  end
  return few
end

return lp

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

lp.VERSION = "0.11.0"

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

-- What a name costs while a scan is running. There is no one answer: 1.4 KB on
-- a machine where the collector cannot keep up, and 370 bytes on one where it
-- can, because most of the cost is pairs waiting to be collected rather than
-- anything kept. A sum against the dearer figure stopped a server naming a
-- third of its network for no reason, so this errs low and the naming stops
-- when the memory actually runs out instead.
local NAME = 600
-- what is left alone for the program to draw with afterwards
local SPARE = 250 * 1024
-- how often the naming looks at what is left rather than trusting the sum
local WATCH = 32

-- Roughly how many can be named, asked after the list has arrived so it answers
-- from what is left rather than from what there was. It only decides how much
-- of the list is worth holding on to; how many are really named is decided by
-- the memory as it goes.
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

    local kept = 0
    for rank = 1, wanted do
      -- the sum above only chose what to hold on to; what can really be named
      -- is whatever the memory turns out to allow, asked as it goes
      if rank % WATCH == 0 and computer.freeMemory() < SPARE then
        break
      end

      local index = order[rank]
      local id = list[index].getValue1()
      -- A tool wears out and an enchantment is a tag, so one pair of golden
      -- boots arrives as a dozen entries and an enchanted book as dozens more.
      -- None of them is a stock: they are single things somebody is carrying.
      -- A meta variant that is a real item -- wool by colour, a dust by grade --
      -- is neither damageable nor tagged, and stays.
      if id.hasTagCompound() ~= true and id.isDamageable() ~= true then
        kept = kept + 1
        items[kept] = {
          name = id.getName(),
          amount = amounts[index],
          itemId = id.getId(),
          itemData = id.getData(),
          -- where in the answer it came, which is what lets a later read be
          -- taken as counts alone
          slot = index,
        }
      end
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

-- What a rate is measured over, and how to say so on a screen. The two belong
-- together: a figure whose window is not named beside it is a figure nobody can
-- read.
--
-- A minute was too short. A pass round the list is a quarter of a minute on a
-- computer and a minute on a server, so a stock that moves in bursts sits still
-- through whole windows and reports nothing, and the one window it does move in
-- is gone from the screen before anybody sees it. Three minutes is long enough
-- to hold a burst and still short enough to be news.
local WINDOW = 180
lp.OVER = "3 minutes"

-- Takes one reading of an item and adds up what has moved lately.
--
-- What it reports is the plain difference: take 20 ingots out and it says 20.
-- It used to be scaled to the window, which is right for a flow and a lie about
-- an event. A window closes on the first reading past its end, so a withdrawal
-- of 20 inside a 200-second window came out as 18 — and the one figure anybody
-- could check against by hand was the one that was wrong.
--
-- Movement is added up rather than measured end to end, so it shows on the
-- first reading that sees it instead of when a window runs out. The window only
-- bounds how far back it reaches: movement collects for three minutes from the
-- first of it, and three quiet minutes clear it, so what is on screen is what
-- moved lately rather than everything that has moved since the program started.
function lp.mark(item, amount, now)
  local before = item.amount
  item.amount = amount
  if before == nil then
    return
  end

  local change = amount - before
  if change ~= 0 then
    if not item.opened or now - item.opened >= WINDOW then
      item.opened, item.rate = now, change
    else
      item.rate = item.rate + change
    end
    item.stirred = now
  elseif item.stirred and now - item.stirred >= WINDOW then
    item.rate, item.stirred = 0, nil
  end
end

-- How many positions are checked before a counted read is believed. Eight names
-- cost about 20 ms; being wrong costs every count in the list.
local CHECKED = 8

-- A read taken as counts alone.
--
-- The call costs the same whether the names are read out of it or not, and the
-- names are nearly all of the time it takes: 1,592 counts arrive in a twentieth
-- of a second, the names behind them take three. The network answers in the
-- same order from one call to the next — checked, thirty positions out of
-- thirty — so the counts can be matched to the names an earlier read
-- established, by the position each item came back in.
--
-- That stops being true the moment one item stops being stocked and another
-- starts, which can leave the total unchanged and every count attached to the
-- wrong name. So the total has to match and a few positions spread through the
-- list are named and compared. It answers whether it was believed; a caller
-- that is told no reads the list properly instead.
function lp.recount(proxy, items, total, now)
  local list = lp.invoke(proxy, "getAvailableItems")
  if type(list) ~= "table" or #list ~= total or not items[1] then
    return false
  end

  return (pcall(function()
    local step = math.max(1, math.floor(#items / CHECKED))
    for rank = 1, #items, step do
      local item = items[rank]
      local id = list[item.slot].getValue1()
      if id.getId() ~= item.itemId or id.getData() ~= item.itemData then
        error("the network answered in a different order")
      end
    end

    for _, item in ipairs(items) do
      lp.mark(item, list[item.slot].getValue2(), now)
    end
  end))
end

-- Folds a fresh read of the network into what is already known.
--
-- A read hands back new tables, and the window a rate is measured over lives on
-- the old ones, so replacing the list outright throws away every rate the
-- program has spent minutes collecting. What is already known keeps its window
-- and takes the new count as an ordinary reading; what is new starts a window
-- of its own; what the network no longer has is gone.
function lp.merge(items, fresh, now)
  local known = {}
  for _, item in ipairs(items) do
    known[item.itemId .. ":" .. item.itemData] = item
  end

  local out = {}
  for _, entry in ipairs(fresh) do
    local already = known[entry.itemId .. ":" .. entry.itemData]
    if already then
      -- the position is the new one: a read is what settles where things are
      already.slot = entry.slot
      lp.mark(already, entry.amount, now)
      out[#out + 1] = already
    else
      out[#out + 1] = entry
    end
  end
  return out
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
    local amount = lp.count(proxy, builder, item.itemId, item.itemData)
    if amount then
      lp.mark(item, amount, now)
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

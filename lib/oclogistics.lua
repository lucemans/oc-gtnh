-- oclogistics: what we know about Logistics Pipes.
-- machine/NOTES.md records where each of these rules came from.
--
-- A logisticspipe component offers one method, getPipe, which returns a proxy
-- rather than data. Each field of that proxy is one method, shaped
-- {name = "...", proxy = <the proxy>}, callable through a __call metamethod.

local component = require("component")
local core = require("oclib")

local lp = {}

lp.VERSION = "0.5.0"

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

-- How many items are named. Measured rather than chosen: a network of 1,592
-- items costs about 950 KB to ask for, on a computer that has 1.4 MB, and every
-- name read costs a further 600 bytes that does not come back while the program
-- runs. 250 names leave the screen enough to draw with.
local MOST = 250

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
function lp.available(proxy, most)
  local list = lp.invoke(proxy, "getAvailableItems")
  if type(list) ~= "table" then
    return nil, "getAvailableItems answered nothing"
  end

  local total = #list
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

    local wanted = math.min(most or MOST, total)
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
      items[rank] = { name = list[index].getValue1().getName(),
        amount = amounts[index] }
      list[index] = false
    end
  end)

  if not ok then
    return nil, core.oneLine(tostring(reason))
  end
  return items, total
end

return lp

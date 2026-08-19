-- oclogistics: what we know about Logistics Pipes.
-- machine/NOTES.md records where each of these rules came from.
--
-- A logisticspipe component offers one method, getPipe, which returns a proxy
-- rather than data. Each field of that proxy is one method, shaped
-- {name = "...", proxy = <the proxy>}, callable through a __call metamethod.

local component = require("component")
local core = require("oclib")

local lp = {}

lp.VERSION = "0.4.0"

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

-- Only the named fields. A proxy's methods have names; what a request pipe
-- answers with is a list, and its keys are numbers. Taking those for methods is
-- what made a number arrive where a method name was expected.
function lp.methods(proxy)
  local names = {}
  if type(proxy) ~= "table" then
    return names
  end
  for name, entry in pairs(proxy) do
    if type(name) == "string" and type(entry) == "table" and name ~= "proxy" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

-- What one proxy offers, without calling anything.
--
-- Calling every readable method and walking into whatever came back is what a
-- basic pipe survived and a request pipe did not: it reaches the whole item
-- network, and building that in a computer with a few hundred kilobytes of
-- memory runs the machine out of it. Nothing here calls into the world; the
-- program asks for one method at a time and the answer is bounded when it
-- arrives.
function lp.offers(proxy)
  local out = {}
  for _, name in ipairs(lp.methods(proxy)) do
    out[#out + 1] = { name = name, readable = core.isReadable(name) }
  end
  return out
end

-- how many entries of a long answer are kept, so a list of everything a base
-- owns cannot be larger than the computer asking about it
local MOST = 250

-- Calls one readable method and says what came back. Three things can come
-- back, and they are not the same kind of thing at all:
--
--   value   something to read, described in one line
--   proxy   more methods, which the caller may go into
--   list    rows of data, which is what "everything we have" looks like
--
-- Whatever the call built is described and then let go, because what a request
-- pipe answers with can be larger than the computer running the question.
function lp.read(proxy, name)
  if not core.isReadable(name) then
    return { kind = "value", text = "changes something, so it is not called" }
  end

  local value, reason = lp.invoke(proxy, name)
  if value == nil then
    return { kind = "value", failed = true,
      text = tostring(reason or "no answer") }
  end

  if type(value) == "table" and lp.methods(value)[1] then
    return { kind = "proxy", proxy = value,
      text = #lp.methods(value) .. " methods" }
  end

  if type(value) == "table" and #value > 0 then
    local rows = {}
    for index = 1, math.min(#value, MOST) do
      rows[index] = core.formatValue(value[index])
    end
    return { kind = "list", rows = rows, total = #value,
      text = #value .. " entries" }
  end

  return { kind = "value", text = core.formatValue(value) }
end

return lp

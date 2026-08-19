-- oclogistics: what we know about Logistics Pipes.
-- machine/NOTES.md records where each of these rules came from.
--
-- A logisticspipe component offers one method, getPipe, which returns a proxy
-- rather than data. Each field of that proxy is one method, shaped
-- {name = "...", proxy = <the proxy>}, callable through a __call metamethod.

local component = require("component")
local core = require("oclib")

local lp = {}

lp.VERSION = "0.2.0"

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

-- The names a proxy offers, sorted. Every field of a proxy is one method, so
-- this is its whole vocabulary.
function lp.methods(proxy)
  local names = {}
  if type(proxy) ~= "table" then
    return names
  end
  for name, entry in pairs(proxy) do
    if type(entry) == "table" and name ~= "proxy" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

-- Logistics Pipes is a moving target: a pack forks it, and which methods a pipe
-- offers depends on which pipe it is. So rather than name them in advance, every
-- method that only reads is called and shown, and anything that answers with
-- another proxy is walked into.
--
-- Returns a flat list of { depth, name, text, proxy }, deep first, bounded so a
-- proxy that refers back to itself cannot run away with the program.
function lp.walk(proxy, depth, seen, out)
  depth = depth or 0
  seen = seen or {}
  out = out or {}

  if depth > 3 or seen[proxy] then
    return out
  end
  seen[proxy] = true

  for _, name in ipairs(lp.methods(proxy)) do
    if core.isReadable(name) then
      local value, reason = lp.invoke(proxy, name)
      if type(value) == "table" and lp.methods(value)[1] then
        out[#out + 1] = { depth = depth, name = name, text = "", proxy = value }
        lp.walk(value, depth + 1, seen, out)
      else
        out[#out + 1] = {
          depth = depth,
          name = name,
          text = value == nil and ("- " .. tostring(reason or "no answer"))
            or core.formatValue(value),
        }
      end
    else
      out[#out + 1] = { depth = depth, name = name, text = "", callable = true }
    end
  end

  return out
end

return lp

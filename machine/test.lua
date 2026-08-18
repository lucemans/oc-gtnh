-- Checks for the programs in programs/, run against the fake machine.
--
--   nix develop -c lua machine/test.lua          run every check
--   nix develop -c lua machine/test.lua --show   also print screens and output

local oc = dofile("machine/oc.lua")

-- install() redirects the global print into the fake screen, so the harness
-- keeps its own handle on the real one to report with
local say = print
oc.install()

local show = (arg and arg[1] == "--show") or false

local failures = 0
local current = "?"

local function check(condition, description)
  if condition then
    return
  end
  failures = failures + 1
  say("  FAIL  " .. current .. ": " .. description)
end

local function contains(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

local function test(name, fn)
  current = name
  oc.reset()
  local before = failures
  local ok, reason = pcall(fn)
  if not ok then
    failures = failures + 1
    say("  FAIL  " .. name .. ": crashed: " .. tostring(reason))
  elseif failures == before then
    say("  ok    " .. name)
  end
end

-------------------------------------------------------------------------------
-- fixtures

local GT_MACHINE = {
  address = "ce0ace5a-e712-4134-bce1-b194453d6217",
  kind = "gt_machine",
  slot = -1,
  methods = {
    getName = "function():string; Returns the machine's name",
    getEUStored = "function():number; Returns the EU stored in this block",
    getCoordinates = "function():table; Returns machine coordinates",
    isMachineActive = "function():boolean; Returns whether the machine is active",
    setWorkAllowed = "function(work:boolean); Sets whether this block may work",
  },
  direct = { getName = true, getCoordinates = true },
  values = {
    getName = function()
      return "basicgenerator.diesel.tier.02"
    end,
    getEUStored = function()
      return 10658
    end,
    getCoordinates = function()
      return -395, 63, -1088
    end,
    isMachineActive = function()
      return true
    end,
    setWorkAllowed = function()
      error("setWorkAllowed must never be invoked", 0)
    end,
  },
}

-- taken verbatim from a real dump: dumps/002.txt
local SUPER_TANK = {
  address = "aa11bb22-e712-4134-bce1-b194453d6217",
  kind = "gt_machine",
  slot = -1,
  methods = {
    getName = "function():string; Returns the machine's name",
    getSensorInformation = "function():table -- Returns the sensor information.",
    getEUStored = "function():number; Returns the EU stored in this block",
    getEUMaxStored = "function():number; Returns the max EU that can be stored",
    getWorkProgress = "function():number; Returns the current progress",
    getWorkMaxProgress = "function():number; Returns the max progress",
    isMachineActive = "function():boolean; Returns whether the machine is active",
    setWorkAllowed = "function(work:boolean); Sets whether this block may work",
  },
  values = {
    getName = function()
      return "super.tank.tier.01"
    end,
    getSensorInformation = function()
      return {
        "\194\1679Super Tank\194\167r",
        "Stored Fluid:",
        "\194\1676Bio Diesel\194\167r",
        "\194\167a42,000 L\194\167r \194\167e4,000,000 L\194\167r",
      }
    end,
    getEUStored = function()
      return 0
    end,
    getEUMaxStored = function()
      return 0
    end,
    getWorkProgress = function()
      return 0
    end,
    getWorkMaxProgress = function()
      return 0
    end,
    isMachineActive = function()
      return false
    end,
    setWorkAllowed = function()
      error("setWorkAllowed must never be invoked", 0)
    end,
  },
}

local REDSTONE = {
  address = "b2c3d4e5-0000-0000-0000-000000000002",
  kind = "redstone",
  methods = { getInput = "function(side:number):number -- Gets the redstone input." },
  values = {
    getInput = function()
      error("bad arguments #1 (number expected, got no value)", 0)
    end,
  },
}

local INTERNET = { address = "01258489-8c4f-4be7-96d2-3f0fc17814ee", kind = "internet", methods = {} }

local MANIFEST = table.concat({
  "lib/ocgt.lua",
  "programs/ocup.lua",
  "programs/ocdebug.lua",
  "programs/ocdump.lua",
}, "\n")

local COMMIT = "e62b7b01adbf2372c7ed15f4600e018ad04ca562"

-- longest match wins, so "programs/ocup.lua" is not served by an "ocup.lua" key
local function serveProgram(bodies)
  return function(url)
    if url:find("api.github.com", 1, true) then
      return 200, "OK", '{\n  "sha": "' .. COMMIT .. '",\n  "node_id": "x"\n}'
    end
    local best, bestLength = nil, -1
    for name, body in pairs(bodies) do
      if url:find(name, 1, true) and #name > bestLength then
        best, bestLength = body, #name
      end
    end
    if best then
      return 200, "OK", best
    end
    return 404, "Not Found", "404: Not Found"
  end
end

local function program(version)
  return '-- fake program\nlocal VERSION = "' .. version .. '"\n'
end

-------------------------------------------------------------------------------
-- ocup

test("ocup installs missing programs", function()
  oc.components = { INTERNET }
  oc.respond = serveProgram({
    ["manifest.txt"] = MANIFEST,
    ["programs/ocup.lua"] = program("0.3.0"),
    ["programs/ocdebug.lua"] = program("0.2.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
  })

  local ok, reason = oc.run("ocup")
  check(ok, "ocup crashed: " .. tostring(reason))

  local out = oc.printed()
  check(contains(out, "ocup v"), "no version banner")
  check(contains(out, "installed"), "did not report a fresh install")
  check(contains(out, "4 files ready"), "no success summary")
  check(oc.files["/bin/ocdump.lua"] == program("0.1.0"), "ocdump.lua not written to /bin")
  check(oc.files["/lib/ocgt.lua"] ~= nil, "library not written to /lib")
  if show then
    say(out)
  end
end)

test("ocup reports a version bump", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocdebug.lua"] = program("0.2.0")
  oc.respond = serveProgram({
    ["manifest.txt"] = MANIFEST,
    ["programs/ocup.lua"] = program("0.3.0"),
    ["programs/ocdebug.lua"] = program("0.3.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
  })

  oc.run("ocup")
  local out = oc.printed()
  check(contains(out, "v0.2.0 -> v0.3.0"), "did not show the version transition")
  if show then
    say(out)
  end
end)

test("ocup reports unchanged programs", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocdebug.lua"] = program("0.2.0")
  oc.respond = serveProgram({
    ["manifest.txt"] = "programs/ocdebug.lua\n",
    ["programs/ocdebug.lua"] = program("0.2.0"),
  })

  oc.run("ocup")
  check(contains(oc.printed(), "up to date"), "did not report an unchanged program")
end)

test("ocup installs nothing when one file fails", function()
  oc.components = { INTERNET }
  -- the library is missing, exactly the state that broke the machine once:
  -- programs newer than the library they require
  oc.respond = serveProgram({
    ["manifest.txt"] = MANIFEST,
    ["programs/ocup.lua"] = program("0.3.0"),
    ["programs/ocdebug.lua"] = program("0.2.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
  })

  oc.run("ocup")
  local out = oc.printed()
  check(contains(out, "lib/ocgt.lua"), "did not name the file that failed")
  check(contains(out, "nothing was installed"), "did not say the machine is unchanged")
  check(oc.files["/bin/ocdebug.lua"] == nil, "installed a program despite the missing library")
  check(oc.files["/bin/ocdump.lua"] == nil, "installed a program despite the missing library")
end)

test("ocup drops a replaced library from the module cache", function()
  oc.components = { INTERNET }
  oc.respond = serveProgram({
    ["manifest.txt"] = MANIFEST,
    ["programs/ocup.lua"] = program("0.3.0"),
    ["programs/ocdebug.lua"] = program("0.2.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
  })

  -- OpenOS would otherwise hand this stale table to every later program in the
  -- session, however new the file on disk is
  package.loaded["ocgt"] = { stale = true }
  oc.run("ocup")
  check(package.loaded["ocgt"] == nil, "left the old library in package.loaded")
end)

test("ocup asks for a fresh copy every time", function()
  oc.components = { INTERNET }
  oc.respond = serveProgram({
    ["manifest.txt"] = MANIFEST,
    ["programs/ocup.lua"] = program("0.3.0"),
    ["programs/ocdebug.lua"] = program("0.2.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
  })

  oc.run("ocup")
  check(#oc.requests > 1, "no requests were made")

  local resolved = 0
  for _, request in ipairs(oc.requests) do
    if request.url:find("api.github.com", 1, true) then
      resolved = resolved + 1
      -- the commit lookup is the one URL that is not immutable
      check(request.url:find("?ocup=", 1, true) ~= nil, "commit lookup was not cache busted")
    else
      -- a branch path can serve a file that is minutes out of date; a commit
      -- path is immutable, so it cannot
      check(request.url:find(COMMIT, 1, true) ~= nil,
        "file was not fetched from a commit path: " .. request.url)
      check(request.url:find("refs/heads/master", 1, true) == nil,
        "file was fetched from the branch: " .. request.url)
    end
  end
  check(resolved == 1, "expected exactly one commit lookup, got " .. resolved)
end)

test("ocup falls back to the branch when the commit cannot be resolved", function()
  oc.components = { INTERNET }
  oc.respond = function(url)
    if url:find("api.github.com", 1, true) then
      return 403, "Forbidden", "rate limited"
    end
    if url:find("manifest.txt", 1, true) then
      return 200, "OK", "programs/ocdebug.lua"
    end
    return 200, "OK", program("0.2.0")
  end

  oc.run("ocup")
  local out = oc.printed()
  check(contains(out, "could not resolve the commit"), "did not warn that files may be stale")
  check(oc.files["/bin/ocdebug.lua"] ~= nil, "gave up instead of falling back to the branch")
end)

test("ocup reports a failed download", function()
  oc.components = { INTERNET }
  oc.respond = function()
    return 404, "Not Found", "404: Not Found"
  end

  oc.run("ocup")
  local out = oc.printed()
  check(contains(out, "failed"), "did not report failure")
  check(contains(out, "HTTP 404"), "did not report the status code")
  check(oc.files["/bin/ocup.lua"] == nil, "wrote a file despite the 404")
end)

-------------------------------------------------------------------------------
-- ocdebug

test("ocdebug renders and selects on click", function()
  oc.components = { GT_MACHINE, REDSTONE }
  oc.push("touch", "screen", 5, 3, 0) -- first row of the list

  local ok, reason = oc.run("ocdebug")
  check(ok, "ocdebug crashed: " .. tostring(reason))

  local frame = oc.frame()
  check(contains(frame, "ocdebug v"), "no version in the header")
  check(contains(frame, "gt_machine"), "component list missing")
  check(contains(frame, "basicgenerator.diesel"), "getName value not previewed")
  check(contains(frame, "10658"), "getEUStored value not previewed")
  if show then
    say(frame)
  end
end)

test("ocdebug summarises a tank from its sensor lines", function()
  oc.components = { SUPER_TANK }

  local ok, reason = oc.run("ocdebug")
  check(ok, "ocdebug crashed: " .. tostring(reason))

  local frame = oc.frame()
  local divider = frame:find("methods", 1, true)
  check(divider ~= nil, "no methods divider drawn")
  local summary = frame:sub(1, divider or #frame)

  check(contains(summary, "Super Tank"), "did not use the sensor name as the title")
  check(not contains(summary, "super.tank.tier.01"), "titled with the internal name")
  check(contains(summary, "Bio Diesel"), "did not show the fluid")
  check(contains(summary, "42,000 / 4,000,000 L"), "did not build a gauge from the sensor line")
  check(contains(summary, "1.1%"), "did not compute the fill percentage")
  check(contains(summary, "\226\150\145"), "gauge drew no empty portion")
  -- the tank reports EU and steam it has no use for; those stay in the method
  -- list below, but must not reach the summary
  check(not contains(summary, "EU"), "irrelevant EU reading leaked into the summary")
  -- getName is still listed as a method further down
  check(contains(frame, "super.tank.tier.01"), "getName value missing from the method list")
  if show then
    say(frame)
  end
end)

test("ocdebug labels a gauge that carries one", function()
  -- verbatim from a real dump: the buffer prefixes its reading, the tank does not
  oc.components = { {
    address = "cc33dd44-0000-0000-0000-000000000004",
    kind = "gt_batterybuffer",
    methods = { getSensorInformation = "function():table -- sensor info" },
    values = {
      getSensorInformation = function()
        return {
          "\194\1679Medium Voltage Battery Buffer\194\167r",
          "Stored Items: \194\167a832,768\194\167r EU / \194\167e832,768\194\167r EU",
          "Average input: 0 EU/t",
        }
      end,
    },
  } }

  local ok = oc.run("ocdebug")
  check(ok, "ocdebug crashed")
  local frame = oc.frame()
  check(contains(frame, "Medium Voltage Battery Buffer"), "no title from sensor line")
  check(contains(frame, "Stored Items:"), "dropped the gauge label")
  check(contains(frame, "832,768 / 832,768 EU"), "no gauge built")
  check(contains(frame, "100.0%"), "wrong fill percentage")
  check(contains(frame, "Average input: 0 EU/t"), "dropped a plain sensor line")
  if show then
    say(frame)
  end
end)

test("ocdebug gauges carry no stray label", function()
  oc.components = { SUPER_TANK }
  oc.run("ocdebug")
  -- the tank's reading opens with the number, so nothing should precede the bar
  check(not contains(oc.frame(), "42,000 L\n"), "left a stray label line above the gauge")
end)

-- verbatim from a real dump: dumps/003.txt
local BLAST_FURNACE = {
  address = "1c646dd8-0000-0000-0000-000000000005",
  kind = "gt_machine",
  methods = {
    getName = "function():string; Returns the machine's name",
    getSensorInformation = "function():table -- sensor info",
    getWorkProgress = "function():number; Returns the current progress",
    getWorkMaxProgress = "function():number; Returns the max progress",
    isMachineActive = "function():boolean; whether the machine is active",
  },
  values = {
    getName = function()
      return "multimachine.blastfurnace"
    end,
    getSensorInformation = function()
      return {
        "Progress: \194\167a31\194\167r s / \194\167e37\194\167r s",
        "Stored Energy: \194\167a1,789\194\167r EU / \194\167e3,072\194\167r EU",
        "Currently uses: \194\167c480\194\167r EU/t",
        "Problems: \194\167c0\194\167r Efficiency: \194\167e100.0\194\167r %",
        "Heat capacity: \194\167a1,901\194\167r K",
      }
    end,
    getWorkProgress = function()
      return 644
    end,
    getWorkMaxProgress = function()
      return 750
    end,
    isMachineActive = function()
      return true
    end,
  },
}

test("ocdebug handles a multiblock with no name line", function()
  oc.components = { BLAST_FURNACE }

  local ok, reason = oc.run("ocdebug")
  check(ok, "ocdebug crashed: " .. tostring(reason))

  local frame = oc.frame()
  local summary = frame:sub(1, frame:find("methods", 1, true) or #frame)
  -- its first sensor line is a reading, so it must not become the title
  check(not contains(summary, "Progress: 31 s / 37 s\n"), "used a reading as the title")
  check(contains(summary, "Electric Blast Furnace"), "profile name not used for the furnace")
  -- and that first line must still appear as a gauge rather than being skipped
  check(contains(summary, "31 / 37 s"), "dropped the first sensor line")
  check(contains(summary, "1,789 / 3,072 EU"), "dropped the second gauge")
  check(contains(summary, "Currently uses: 480 EU/t"), "dropped a plain reading")
  check(contains(summary, "Heat capacity: 1,901 K"), "dropped a single-value reading")
  -- getWorkProgress duplicates the sensor's own progress, in worse units
  check(not contains(summary, "644"), "raw work counter duplicated the sensor progress")
  if show then
    say(frame)
  end
end)

test("ocdebug still lists the raw counters below the summary", function()
  oc.components = { BLAST_FURNACE }
  oc.push("key_down", "keyboard", 0, 0xD1) -- pageDown, past the summary

  oc.run("ocdebug")
  local seen = table.concat(oc.frames, "\n")
  check(contains(seen, "getWorkProgress"), "getWorkProgress missing from the method list")
  check(contains(seen, "644"), "raw work counter value not shown anywhere")
end)

test("ocdebug re-reads values on a refresh tick", function()
  local reads = 0
  oc.components = { {
    address = "dd44ee55-0000-0000-0000-000000000006",
    kind = "gt_machine",
    methods = { getEUStored = "function():number", getEUMaxStored = "function():number" },
    values = {
      getEUStored = function()
        reads = reads + 1
        return reads * 100
      end,
      getEUMaxStored = function()
        return 1000
      end,
    },
  } }
  oc.push() -- an empty event is what event.pull returns on timeout

  local ok = oc.run("ocdebug")
  check(ok, "ocdebug crashed")
  check(reads >= 2, "value was read only once, so nothing refreshes")
  check(#oc.frames >= 2, "only one frame was drawn")
  check(oc.frames[1] ~= oc.frames[2], "screen did not change after the refresh tick")
end)

test("ocdebug notices a component attached while running", function()
  local attached = false
  oc.components = { {
    address = "11112222-0000-0000-0000-000000000008",
    kind = "redstone",
    methods = { getInput = "function():number" },
    values = {
      getInput = function()
        -- fires during the first draw, standing in for plugging a machine in
        if not attached then
          attached = true
          oc.components[#oc.components + 1] = {
            address = "ff66aa77-0000-0000-0000-000000000007",
            kind = "gt_machine",
            methods = { getName = "function():string" },
            values = {
              getName = function()
                return "late.arrival"
              end,
            },
          }
        end
        return 0
      end,
    },
  } }
  oc.push() -- refresh tick: the rescan should pick the new component up

  local ok = oc.run("ocdebug")
  check(ok, "ocdebug crashed")
  check(attached, "fixture never fired")
  check(contains(oc.frame(), "Late Arrival"), "did not list the newly attached component")
end)

test("ocdebug reads is/has methods", function()
  oc.components = { GT_MACHINE }

  local ok = oc.run("ocdebug")
  check(ok, "ocdebug crashed")
  local invoked = table.concat(oc.invoked, " ")
  check(contains(invoked, "isMachineActive"), "did not invoke an is method")
end)

test("ocdebug never invokes a setter", function()
  oc.components = { GT_MACHINE, REDSTONE }
  oc.push("key_down", "keyboard", 0, 0xD0) -- down, selects redstone

  local ok = oc.run("ocdebug")
  check(ok, "ocdebug crashed")
  for _, method in ipairs(oc.invoked) do
    local readable = method:sub(1, 3) == "get" or method:sub(1, 2) == "is" or method:sub(1, 3) == "has"
    check(readable, "invoked a method that is not a read: " .. method)
  end
end)

test("ocdebug survives a getter that needs arguments", function()
  oc.components = { REDSTONE }

  local ok = oc.run("ocdebug")
  check(ok, "ocdebug crashed on a failing getter")
  check(contains(oc.frame(), "bad arguments"), "did not surface the getter error")
end)

-------------------------------------------------------------------------------
-- values that serialization.serialize cannot handle

-- a Logistics Pipes block: one method returning a table holding functions,
-- which is exactly what serialize raises on
local LOGISTICS = {
  address = "e1f2a3b4-0000-0000-0000-000000000009",
  kind = "logisticspipe",
  methods = { getPipe = "function():table -- Returns the pipe." },
  values = {
    getPipe = function()
      return {
        name = "Basic Logistics Pipe",
        isRouted = true,
        getRouterId = function() end,
        inventory = { slots = 27, contents = { "minecraft:iron_ingot" } },
      }
    end,
  },
}

test("ocdebug describes a table it cannot serialize", function()
  oc.components = { LOGISTICS }

  local ok, reason = oc.run("ocdebug")
  check(ok, "ocdebug crashed: " .. tostring(reason))

  local frame = oc.frame()
  -- the old behaviour printed the bare word "table" and lost everything
  check(contains(frame, "getRouterId"), "table contents not described at all")
  check(contains(frame, "<function>"), "function field not reported by type")
  check(not contains(frame, "getPipe    table"), "still collapsing to the bare word table")
end)

test("ocdump writes a nested table out in full", function()
  oc.components = { INTERNET, LOGISTICS }
  oc.respond = function()
    return 201, "Created", "https://dpaste.com/TESTTESTT\n"
  end

  local ok, reason = oc.run("ocdump")
  check(ok, "ocdump crashed: " .. tostring(reason))

  local body = oc.requests[1] and oc.requests[1].body or ""
  check(contains(body, "getPipe"), "method missing")
  check(contains(body, 'name = "Basic Logistics Pipe"'), "table field not expanded")
  check(contains(body, "inventory = table"), "nested table not walked")
  check(contains(body, "slots = 27"), "nested field missing")
  check(contains(body, "getRouterId = <function>"), "function not reported by type")
  if show then
    say(body)
  end
end)

-- shaped like the real Logistics Pipes proxy in dumps/005.txt: every entry is
-- callable and documents itself through __tostring
local function proxyMethod(name, result)
  return setmetatable({ name = name }, {
    __call = function()
      if result == nil then
        return
      end
      return result
    end,
    __tostring = function()
      return "function():" .. name
    end,
  })
end

local function logisticsPipe(written)
  return {
    address = "96cdfbc3-11fa-462f-adf2-2599720fbb32",
    kind = "logisticspipe",
    methods = { getPipe = "function():table -- Returns the pipe." },
    values = {
      getPipe = function()
        return {
          type = "userdata",
          getRouterId = proxyMethod("getRouterId", 42),
          hasLogisticsModule = proxyMethod("hasLogisticsModule", true),
          sendMessage = setmetatable({ name = "sendMessage" }, {
            __call = function()
              written.value = true
            end,
            __tostring = function()
              return "function(target, message)"
            end,
          }),
        }
      end,
    },
  }
end

test("ocdump reads a proxy method and reports its signature", function()
  local written = { value = false }
  oc.components = { INTERNET, logisticsPipe(written) }
  oc.respond = function()
    return 201, "Created", "https://dpaste.com/TESTTESTT\n"
  end

  oc.run("ocdump")
  local body = oc.requests[1] and oc.requests[1].body or ""
  check(contains(body, "table <callable, __tostring>"), "did not report the entry as callable")
  check(contains(body, "-- function():getRouterId"), "did not extract the signature")
  check(contains(body, "-> 42"), "did not call the readable proxy method")
  check(contains(body, "-> true"), "did not call the has method")
  check(written.value == false, "called a proxy method that writes")
  if show then
    say(body)
  end
end)

test("ocdump keeps scalar returns on one line", function()
  oc.components = { INTERNET, GT_MACHINE }
  oc.respond = function()
    return 201, "Created", "https://dpaste.com/TESTTESTT\n"
  end

  oc.run("ocdump")
  local body = oc.requests[1] and oc.requests[1].body or ""
  check(contains(body, "-395, 63, -1088"), "multiple scalar returns not joined")
end)

-------------------------------------------------------------------------------
-- ocwatch

local function tankAt(amount)
  return {
    address = "aa11bb22-e712-4134-bce1-b194453d6217",
    kind = "gt_machine",
    methods = { getSensorInformation = "function():table" },
    values = {
      getSensorInformation = function()
        return {
          "\194\1679Super Tank\194\167r",
          "\194\1676Bio Diesel\194\167r",
          "\194\167a" .. amount .. "\194\167r L \194\167e4,000,000\194\167r L",
        }
      end,
    },
  }
end

local function furnace(stopped)
  return {
    address = "1c646dd8-0000-0000-0000-000000000005",
    kind = "gt_machine",
    methods = {
      getName = "function():string",
      setWorkAllowed = "function(work:boolean)",
      isWorkAllowed = "function():boolean",
    },
    values = {
      getName = function()
        return "multimachine.blastfurnace"
      end,
      isWorkAllowed = function()
        return not stopped.value
      end,
      setWorkAllowed = function(allowed)
        stopped.value = (allowed == false)
        return true
      end,
    },
  }
end

test("ocwatch stops a machine when a tank runs low", function()
  local stopped = { value = false }
  local tank = tankAt("100")
  oc.components = { tank, furnace(stopped) }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = { [tank.address] = "EBF Fluid Tank" },
    watch = { { address = tank.address, hidden = {} } },
    alerts = { {
      name = "diesel low",
      address = tank.address,
      index = 2,
      below = 50000,
      above = 200000,
      beep = false,
      act = {
        address = "1c646dd8-0000-0000-0000-000000000005",
        method = "setWorkAllowed",
        onTrip = false,
        onClear = true,
      },
    } },
  })

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))
  check(stopped.value == true, "the furnace was not stopped by the low tank")
  check(contains(oc.frame(), "EBF Fluid Tank"), "nickname not used on the dashboard")
  check(contains(oc.frame(), "diesel low"), "no notice that the alert tripped")
  if show then
    say(oc.frame())
  end
end)

test("ocwatch leaves a machine alone above the threshold", function()
  local stopped = { value = false }
  local tank = tankAt("3,000,000")
  oc.components = { tank, furnace(stopped) }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = {},
    watch = { { address = tank.address, hidden = {} } },
    alerts = { {
      name = "diesel low",
      address = tank.address,
      index = 2,
      below = 50000,
      above = 200000,
      beep = false,
      act = {
        address = "1c646dd8-0000-0000-0000-000000000005",
        method = "setWorkAllowed",
        onTrip = false,
        onClear = true,
      },
    } },
  })

  oc.run("ocwatch")
  check(stopped.value == false, "stopped a machine while the tank was full")
end)

-------------------------------------------------------------------------------
-- ocdump

test("ocdump builds a valid multipart upload", function()
  oc.components = { INTERNET, GT_MACHINE, REDSTONE }
  oc.deviceInfo = { [GT_MACHINE.address] = { class = "generic", description = "Machine" } }
  oc.respond = function()
    return 201, "Created", "https://dpaste.com/TESTTESTT\n"
  end

  local ok, reason = oc.run("ocdump")
  check(ok, "ocdump crashed: " .. tostring(reason))
  check(#oc.requests == 1, "expected exactly one upload")

  local request = oc.requests[1]
  local boundary = request.headers["Content-Type"]:match("boundary=(.+)")
  check(boundary ~= nil, "no boundary in Content-Type")
  check(contains(request.body, "--" .. boundary .. "--"), "multipart body not terminated")
  check(contains(request.body, 'name="content"'), "no content field")
  check(contains(request.body, 'name="expiry_days"'), "no expiry field")
  check(not contains(request.body:gsub("--" .. boundary, ""), boundary), "boundary appears inside the payload")
  check(contains(request.body, "basicgenerator.diesel"), "getName value missing from dump")
  check(contains(request.body, "-395, 63, -1088"), "multiple return values not joined")
  check(contains(oc.printed(), "dpaste.com/TESTTESTT"), "did not print the paste URL")

  for _, method in ipairs(oc.invoked) do
    local readable = method:sub(1, 3) == "get" or method:sub(1, 2) == "is" or method:sub(1, 3) == "has"
    check(readable, "invoked a method that is not a read: " .. method)
  end
  if show then
    say(request.body)
  end
end)

test("ocdump reports an upload failure", function()
  oc.components = { INTERNET, REDSTONE }
  oc.respond = function()
    return 413, "Payload Too Large", ""
  end

  oc.run("ocdump")
  check(contains(oc.printed(), "upload failed"), "did not report the failure")
  check(contains(oc.printed(), "HTTP 413"), "did not report the status code")
end)

-------------------------------------------------------------------------------

say("")
if failures > 0 then
  say(failures .. " check(s) failed")
  os.exit(1)
end
say("all checks passed")

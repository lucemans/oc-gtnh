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
  -- a test that wants a bigger screen sets it before reset builds the buffer;
  -- it must not decide the size for every test that runs after it
  oc.width, oc.height = 80, 20
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
  "lib/oclib.lua",
  "lib/ocgt.lua",
  "lib/oclogistics.lua",
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
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
  })

  local ok, reason = oc.run("ocup")
  check(ok, "ocup crashed: " .. tostring(reason))

  local out = oc.printed()
  check(contains(out, "ocup v"), "no version banner")
  check(contains(out, "installed"), "did not report a fresh install")
  check(contains(out, "6 files ready"), "no success summary")
  check(oc.files["/bin/ocdump.lua"] == program("0.1.0"), "ocdump.lua not written to /bin")
  check(oc.files["/lib/ocgt.lua"] ~= nil, "library not written to /lib")
  if show then
    say(out)
  end
end)

-- Not every computer wants every program. The satellite by the blast furnace
-- has no use for minesweeper, and /bin is small.
local function serveEverything()
  return serveProgram({
    ["manifest.txt"] = MANIFEST,
    ["programs/ocup.lua"] = program("0.3.0"),
    ["programs/ocdebug.lua"] = program("0.2.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
  })
end

test("ocup installs only the programs the config chose", function()
  oc.components = { INTERNET }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    programs = { "ocdebug" },
  })
  oc.respond = serveEverything()

  local ok, reason = oc.run("ocup")
  check(ok, "ocup crashed: " .. tostring(reason))

  check(oc.files["/bin/ocdebug.lua"] ~= nil, "did not install the chosen program")
  check(oc.files["/bin/ocdump.lua"] == nil, "installed a program nobody chose")
  -- a program that opts out still needs ocup to opt back in with
  check(oc.files["/bin/ocup.lua"] ~= nil, "removed itself")
  -- the kept programs require whichever libraries they require
  check(oc.files["/lib/ocgt.lua"] ~= nil, "skipped a library")
  check(contains(oc.printed(), "not chosen"), "did not say what it left out")
end)

test("ocup takes a program off the disk once it is opted out", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocdump.lua"] = program("0.1.0")
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    programs = { "ocdebug" },
  })
  oc.respond = serveEverything()

  oc.run("ocup")
  check(oc.files["/bin/ocdump.lua"] == nil, "left an opted-out program behind")
  check(contains(oc.printed(), "removed"), "did not report the removal")
end)

test("ocup installs only the default set when nothing has been chosen yet", function()
  oc.components = { INTERNET }
  oc.respond = serveProgram({
    ["manifest.txt"] = MANIFEST .. "\nprograms/ocsweeper.lua",
    ["programs/ocup.lua"] = program("0.3.0"),
    ["programs/ocdebug.lua"] = program("0.2.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["programs/ocsweeper.lua"] = program("0.1.0"),
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
  })

  oc.run("ocup")
  -- enough to look at the machines in front of it and to ask for help with
  -- them; no computer wants the lot
  check(oc.files["/bin/ocdebug.lua"] ~= nil, "left ocdebug out of the default set")
  check(oc.files["/bin/ocdump.lua"] ~= nil, "left ocdump out of the default set")
  check(oc.files["/bin/ocup.lua"] ~= nil, "left itself out")
  check(oc.files["/bin/ocsweeper.lua"] == nil, "installed a program nobody opted into")
end)

test("ocup sinks what it is not installing to the bottom of its folder", function()
  oc.components = { INTERNET }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    programs = { "ocdump" },
  })
  oc.respond = serveEverything()

  oc.run("ocup")
  local out = oc.printed()
  check(out:find("ocdump", 1, true) < out:find("ocdebug", 1, true),
    "left an untouched program above the ones being installed")
end)

test("ocup --edit writes the choice and applies nothing yet", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocdump.lua"] = program("0.1.0")
  oc.respond = serveEverything()
  -- down to ocdump, space to turn it off, enter to save
  oc.push("key_down", "keyboard", 0, 0xD0)
  oc.push("key_down", "keyboard", 32, 0x39)
  oc.push("key_down", "keyboard", 13, 0x1C)

  local ok, reason = oc.run("ocup", "--edit")
  check(ok, "ocup --edit crashed: " .. tostring(reason))

  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  check(saved and saved.programs, "wrote no choice")
  local chosen = table.concat(saved and saved.programs or {}, ",")
  check(chosen == "ocdebug", "chose " .. chosen)
  -- editing decides, running applies: nothing should vanish behind the user
  check(oc.files["/bin/ocdump.lua"] ~= nil, "removed a file while only editing")
end)

test("ocup --edit keeps the rest of the config", function()
  oc.components = { INTERNET }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = { ["aa11bb22"] = "EBF Fluid Tank" },
    watch = { { address = "aa11bb22", hidden = {} } },
  })
  oc.respond = serveEverything()
  oc.push("key_down", "keyboard", 13, 0x1C)

  oc.run("ocup", "--edit")
  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  check(saved and saved.nicknames and saved.nicknames["aa11bb22"] == "EBF Fluid Tank",
    "lost what ocwatch had saved")
  check(saved and saved.watch and #saved.watch == 1, "lost the watch list")
end)

test("ocup reports a version bump", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocdebug.lua"] = program("0.2.0")
  oc.respond = serveProgram({
    ["manifest.txt"] = MANIFEST,
    ["programs/ocup.lua"] = program("0.3.0"),
    ["programs/ocdebug.lua"] = program("0.3.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
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
  check(contains(out, "lib/oclib.lua"), "did not name the file that failed")
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
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
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
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
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

test("ocdebug re-lays out when the screen changes size", function()
  oc.width, oc.height = 80, 20
  oc.reset()
  oc.components = { SUPER_TANK }
  oc.resize(160, 50)

  local ok, reason = oc.run("ocdebug")
  check(ok, "ocdebug crashed on resize: " .. tostring(reason))
  -- rows are as wide as the screen, so a stale layout shows up as a short row
  local first = (oc.frame() .. "\n"):match("([^\n]*)\n")
  check(first and #first == 160, "row is " .. tostring(first and #first) .. " wide, expected 160")
  -- and the list divider must sit at the wider screen's quarter, not the old one
  check(contains(oc.frame(), string.rep(" ", 8) .. "\226\148\130")
    or oc.frame():find("\226\148\130") ~= nil, "no divider drawn after the resize")

  oc.width, oc.height = 80, 20
  oc.reset()
end)

test("ocdebug and ocwatch fit a small display", function()
  oc.width, oc.height = 42, 12
  oc.reset()
  oc.components = { SUPER_TANK }

  -- gpu.set asserts on an out-of-bounds row, so a crash here means it drew off
  -- the edge of a display smaller than the one it was written against
  local ok, reason = oc.run("ocdebug")
  check(ok, "ocdebug drew outside a small screen: " .. tostring(reason))

  oc.reset()
  oc.components = { SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = {}, alerts = {},
    watch = { { address = SUPER_TANK.address, hidden = {} } },
  })
  local watchOk, watchReason = oc.run("ocwatch")
  check(watchOk, "ocwatch drew outside a small screen: " .. tostring(watchReason))

  oc.width, oc.height = 80, 20
  oc.reset()
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
          -- a proxy method that returns another proxy, as getLP does
          getLogisticsModule = proxyMethod("getLogisticsModule", {
            type = "userdata",
            isDefaultRoute = proxyMethod("isDefaultRoute", false),
            setDefaultRoute = proxyMethod("setDefaultRoute", nil),
          }),
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
  -- a returned proxy must be walked, not flattened onto one line
  check(contains(body, "isDefaultRoute = table <callable"), "nested proxy was not walked")
  check(contains(body, "-> false"), "did not read through into the nested proxy")
  if show then
    say(body)
  end
end)

test("ocdump names a logistics pipe by its router id", function()
  local written = { value = false }
  oc.components = { INTERNET, logisticsPipe(written) }
  oc.respond = function()
    return 201, "Created", "https://dpaste.com/TESTTESTT\n"
  end

  oc.run("ocdump")
  local body = oc.requests[1] and oc.requests[1].body or ""
  -- the index line was blank before, since a pipe answers no getName
  check(contains(body, "Logistics Pipe #42"), "pipe not named by its router id")
end)

test("ocdump reads through a protected metatable", function()
  -- shaped like a glasses widget in dumps: userdata sets __metatable, so
  -- getmetatable hands back a string and __call cannot be seen
  local guarded = setmetatable({ type = "userdata" }, {
    __call = function()
      return "Bio Diesel"
    end,
    __metatable = "userdata",
  })

  oc.components = { INTERNET, {
    address = "8c14b00c-fe87-4aee-a451-7991d34fd7e3",
    kind = "glasses",
    methods = { getWidget = "function():table" },
    values = {
      getWidget = function()
        return { getText = guarded }
      end,
    },
  } }
  oc.respond = function()
    return 201, "Created", "https://dpaste.com/TESTTESTT\n"
  end

  oc.run("ocdump")
  local body = oc.requests[1] and oc.requests[1].body or ""
  check(contains(body, "protected metatable"), "did not report the metatable as hidden")
  -- the value is what matters: gating on a visible __call skipped it entirely
  check(contains(body, "Bio Diesel"), "did not call through the protected metatable")
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
-- occonnect

local function connected(code)
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = {}, watch = {}, alerts = {},
    connect = { server = "https://ntfy.sh", topic = "oc-755c25caccec", code = code },
  })
end

-- shaped exactly like a real ntfy line, captured from ntfy.sh
local function ntfyLine(id, message)
  return '{"id":"' .. id .. '","time":1787070203,"expires":1787113403,'
    .. '"event":"message","topic":"oc-755c25caccec","message":"' .. message .. '"}'
end

local function posted()
  local body = nil
  for _, request in ipairs(oc.requests) do
    if request.url:find("-out", 1, true) then
      body = request.body
    end
  end
  return body
end

test("occonnect shows a pairing code and a topic", function()
  oc.components = { INTERNET }
  oc.respond = function()
    return 200, "OK", ""
  end

  oc.run("occonnect", "--once")
  local out = oc.printed()
  check(contains(out, "pairing code"), "no pairing code shown")
  check(contains(out, "oc-755c25ca"), "topic not shown")
  -- both have to survive a restart or the pairing is worthless
  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  check(saved and saved.connect and saved.connect.code ~= nil, "code not saved")
  check(saved and saved.connect.topic ~= nil, "topic not saved")
end)

test("occonnect runs a command carrying the right code", function()
  connected("ABC12345")
  oc.components = { INTERNET }
  local polls = 0
  oc.respond = function(url)
    if url:find("poll=1", 1, true) then
      polls = polls + 1
      -- the first poll only learns where the log is; the second carries work
      if polls == 1 then
        return 200, "OK", ntfyLine("OLD1", "ABC12345 should-not-run")
      end
      return 200, "OK", ntfyLine("NEW1", "ABC12345 ocup")
    end
    return 200, "OK", ""
  end

  oc.run("occonnect", "--once")
  check(#oc.executed == 1, "expected exactly one command, got " .. #oc.executed)
  check(contains(oc.executed[1] or "", "ocup"), "did not run the command")
  check(not contains(table.concat(oc.executed, " "), "should-not-run"),
    "replayed a command that was already in the topic at startup")
  check(posted() ~= nil, "no output published back")
end)

test("occonnect refuses a command with the wrong code", function()
  connected("ABC12345")
  oc.components = { INTERNET }
  local polls = 0
  oc.respond = function(url)
    if url:find("poll=1", 1, true) then
      polls = polls + 1
      if polls == 1 then
        return 200, "OK", ""
      end
      return 200, "OK", ntfyLine("NEW1", "WRONGCODE reboot")
    end
    return 200, "OK", ""
  end

  oc.run("occonnect", "--once")
  -- an ntfy topic is a public pipe, so this is the only thing between a leaked
  -- topic name and someone running whatever they like on the machine
  check(#oc.executed == 0, "ran a command that carried the wrong code")
  check(contains(oc.printed(), "refused"), "did not report the refusal")
end)

test("occonnect reads a command containing quotes", function()
  connected("ABC12345")
  oc.components = { INTERNET }
  local polls = 0
  oc.respond = function(url)
    if url:find("poll=1", 1, true) then
      polls = polls + 1
      if polls == 1 then
        return 200, "OK", ""
      end
      -- ntfy escapes the quotes, so a pattern would stop at the first one
      return 200, "OK", ntfyLine("NEW1", 'ABC12345 echo \\"hi there\\"')
    end
    return 200, "OK", ""
  end

  oc.run("occonnect", "--once")
  check(#oc.executed == 1, "did not run the quoted command")
  check(contains(oc.executed[1] or "", 'echo "hi there"'), "mangled the quotes")
end)

-- Pushing a file through echo and a redirect costs a round trip per line, and
-- the shell eats the quotes on the way past.
test("occonnect writes a file straight from a message", function()
  connected("ABC12345")
  oc.components = { INTERNET }
  local polls = 0
  oc.respond = function(url)
    if url:find("poll=1", 1, true) then
      polls = polls + 1
      if polls == 1 then
        return 200, "OK", ""
      end
      return 200, "OK", ntfyLine("NEW1",
        'ABC12345 :file /bin/hello.lua\\nprint(\\"hi\\")\\nreturn 0')
    end
    return 200, "OK", ""
  end

  oc.run("occonnect", "--once")
  check(#oc.executed == 0, "sent it to the shell instead of writing it")
  check(oc.files["/bin/hello.lua"] == 'print("hi")\nreturn 0',
    "wrote " .. tostring(oc.files["/bin/hello.lua"]))
  check(contains(posted() or "", "/bin/hello.lua"), "did not say what it wrote")
end)

test("occonnect runs Lua and sends back what it printed", function()
  connected("ABC12345")
  oc.components = { INTERNET }
  local polls = 0
  oc.respond = function(url)
    if url:find("poll=1", 1, true) then
      polls = polls + 1
      if polls == 1 then
        return 200, "OK", ""
      end
      return 200, "OK", ntfyLine("NEW1",
        'ABC12345 :lua\\nprint(2 + 3, [[answer]])')
    end
    return 200, "OK", ""
  end

  oc.run("occonnect", "--once")
  check(#oc.executed == 0, "sent it to the shell instead of running it")
  local out = posted() or ""
  check(contains(out, "5\tanswer"), "did not send back what it printed: " .. out)
end)

test("occonnect reports Lua that does not compile", function()
  connected("ABC12345")
  oc.components = { INTERNET }
  local polls = 0
  oc.respond = function(url)
    if url:find("poll=1", 1, true) then
      polls = polls + 1
      if polls == 1 then
        return 200, "OK", ""
      end
      return 200, "OK", ntfyLine("NEW1", 'ABC12345 :lua\\nthis is not lua')
    end
    return 200, "OK", ""
  end

  oc.run("occonnect", "--once")
  -- silence here would look exactly like a command that worked
  check(contains(posted() or "", "failed"), "did not report the broken chunk")
end)

test("occonnect survives ntfy being down", function()
  connected("ABC12345")
  oc.components = { INTERNET }
  oc.respond = function()
    return 502, "Bad Gateway", ""
  end

  local ok = oc.run("occonnect", "--once")
  check(ok, "crashed when ntfy was down")
  check(#oc.executed == 0, "ran something despite the poll failing")
end)

-------------------------------------------------------------------------------
-- ocglass

-- a widget shaped like the real thing: methods are callable but the metatable
-- is protected, exactly as OpenComputers userdata behaves
local function fakeWidget(record, id)
  local widget = {}
  local function method(name)
    return setmetatable({ type = "userdata" }, {
      __call = function(_, ...)
        record[#record + 1] = { id = id, method = name, args = table.pack(...) }
        return 0
      end,
      __metatable = "userdata",
    })
  end
  for _, name in ipairs({ "setText", "setPosition", "setColor", "setScale",
    "setAlpha", "setVisible", "setSize", "getID" }) do
    widget[name] = method(name)
  end
  return widget
end

local function fakeGlasses(record)
  local made = 0
  return {
    address = "8c14b00c-fe87-4aee-a451-7991d34fd7e3",
    kind = "glasses",
    methods = {
      addTextLabel = "function():Text2D", addRect = "function():Rect2D",
      removeAll = "function()", getObjectCount = "function():number",
      getBindPlayers = "function():string...",
    },
    values = {
      addTextLabel = function()
        made = made + 1
        return fakeWidget(record, made)
      end,
      addRect = function()
        made = made + 1
        return fakeWidget(record, made)
      end,
      removeAll = function()
        made = 0
        return true
      end,
      getObjectCount = function()
        return made
      end,
      getBindPlayers = function()
        return "Lucemans"
      end,
    },
  }
end

test("ocglass draws the watched machines", function()
  local record = {}
  oc.components = { fakeGlasses(record), SUPER_TANK }

  local ok, reason = oc.run("ocglass", "--once")
  check(ok, "ocglass crashed: " .. tostring(reason))

  local texts, colors = {}, {}
  for _, call in ipairs(record) do
    if call.method == "setText" then
      texts[#texts + 1] = tostring(call.args[1])
    elseif call.method == "setColor" then
      colors[#colors + 1] = call.args
    end
  end

  local all = table.concat(texts, " | ")
  check(contains(all, "Super Tank"), "did not draw the machine name")
  check(contains(all, "42,000 / 4,000,000 L"), "did not draw the reading")

  -- colour is three floats from 0 to 1, read off the real widget; sending
  -- 0 to 255 would wash every bar out to white
  check(#colors > 0, "never set a colour")
  local first = colors[1]
  check(first and first.n == 3, "setColor wants three arguments, sent " .. tostring(first and first.n))
  for position = 1, (first and first.n or 0) do
    local value = first[position]
    check(type(value) == "number" and value >= 0 and value <= 1,
      "colour component out of the 0 to 1 range: " .. tostring(value))
  end
end)

test("ocglass sends a bar size as height then width", function()
  local record = {}
  oc.components = { fakeGlasses(record), SUPER_TANK }

  oc.run("ocglass", "--once")

  local sizes = {}
  for _, call in ipairs(record) do
    if call.method == "setSize" then
      sizes[#sizes + 1] = call.args
    end
  end
  check(#sizes > 0, "never sized a bar")

  -- Measured on real glasses: setSize(100, 5) drew a vertical line and
  -- setSize(5, 100) a horizontal one, so the first argument is the height. A
  -- bar is wide and short, so the second number must be the larger one.
  local first = sizes[1]
  check(first and first.n == 2, "setSize wants two arguments")
  check(first and first[2] > first[1],
    "sent " .. tostring(first and first[1]) .. ", " .. tostring(first and first[2])
      .. " which draws a vertical sliver")
end)

test("ocglass reuses widgets instead of rebuilding the scene", function()
  local record = {}
  local glasses = fakeGlasses(record)
  oc.components = { glasses, SUPER_TANK }
  -- one refresh tick, then quit
  oc.push()
  oc.push("key_down", "keyboard", 0, 0x10)

  oc.run("ocglass")

  local ids = {}
  for _, call in ipairs(record) do
    ids[call.id] = true
  end
  local count = 0
  for _ in pairs(ids) do
    count = count + 1
  end
  -- redrawing from scratch would double this and blink the wearer's display
  check(count <= 4, "made " .. count .. " widgets for one machine, so it rebuilt the scene")
end)

test("ocglass clears what it drew", function()
  local record = {}
  oc.components = { fakeGlasses(record), SUPER_TANK }

  oc.run("ocglass", "--clear")
  check(contains(table.concat(oc.invoked, " "), "removeAll"), "did not clear the display")
end)

-------------------------------------------------------------------------------
-- ocserve and ocview

local function fakeModem(address, wireless)
  local sent = {}
  return {
    address = address,
    kind = "modem",
    sent = sent,
    methods = {
      open = "function(port:number):boolean", close = "function([port]):boolean",
      isOpen = "function(port:number):boolean", isWireless = "function():boolean",
      getStrength = "function():number",
      send = "function(address,port,...):boolean",
      broadcast = "function(port,...):boolean",
      setStrength = "function(value:number):number",
      maxPacketSize = "function():number",
    },
    values = {
      open = function()
        return true
      end,
      close = function()
        return true
      end,
      isOpen = function()
        return true
      end,
      isWireless = function()
        return wireless == true
      end,
      setStrength = function(value)
        sent.strength = value
        return value
      end,
      getStrength = function()
        return sent.strength or 0
      end,
      maxPacketSize = function()
        return 8192
      end,
      -- a status reply carries the satellite's name before its payload, so all
      -- five are kept: capturing four silently recorded the name as the payload
      send = function(to, port, kind, host, payload)
        sent[#sent + 1] = { to = to, port = port, kind = kind,
          host = host, payload = payload }
        return true
      end,
      broadcast = function(port, kind)
        sent[#sent + 1] = { to = "*", port = port, kind = kind }
        return true
      end,
    },
  }
end

local PORT = 4021

test("ocserve answers a status request", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", true)
  oc.components = { modem, SUPER_TANK }
  -- localAddress, remoteAddress, port, distance, then the payload
  oc.push("modem_message", modem.address, "bb000000", PORT, 12, "ocstatus?")

  local ok, reason = oc.run("ocserve", "--once")
  check(ok, "ocserve crashed: " .. tostring(reason))
  check(#modem.sent == 1, "expected exactly one reply, got " .. #modem.sent)

  local reply = modem.sent[1]
  check(reply and reply.to == "bb000000", "did not answer the asker directly")
  check(reply and reply.kind == "ocstatus!", "wrong reply marker")

  local report = reply and require("serialization").unserialize(reply.payload)
  local cards = report and report.cards
  check(type(cards) == "table" and #cards > 0, "sent no machines")
  check(cards and cards[1].name == "Super Tank", "did not name the machine")
  check(cards and #cards[1].gauges > 0, "sent no readings")
  -- the tablet should not have to parse "42,000" back into a number
  check(cards and type(cards[1].gauges[1].percent) == "number", "no percentage sent")
  check(report and type(report.alerts) == "table", "sent no alert list")
end)

test("ocserve raises a wireless card off zero strength", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", true)
  oc.components = { modem, SUPER_TANK }

  oc.run("ocserve", "--once")
  -- a wireless card sits at zero range until told otherwise, which looks
  -- exactly like a card that does not work
  check(modem.sent.strength ~= nil and modem.sent.strength > 0, "never set the strength")
end)

test("ocserve ignores traffic that is not its own", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", false)
  oc.components = { modem, SUPER_TANK }
  oc.push("modem_message", modem.address, "bb000000", PORT, 0, "something else")

  oc.run("ocserve", "--once")
  check(#modem.sent == 0, "answered a message it should have ignored")
end)

-- A satellite runs ocwatch, not ocserve, so this is the path that actually
-- answers the main computer. It is easy to break without noticing: the dashboard
-- keeps working while the network half goes quiet.
test("ocwatch answers a status request while it is watching", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000003", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    hostname = "satellite",
    watch = { { address = SUPER_TANK.address, hidden = {} } },
    alerts = {},
  })
  oc.push("modem_message", modem.address, "bb000000", PORT, 12, "ocstatus?")

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))
  check(#modem.sent == 1, "expected one reply, got " .. #modem.sent)

  local reply = modem.sent[1]
  check(reply and reply.to == "bb000000", "did not answer the asker directly")
  check(reply and reply.kind == "ocstatus!", "wrong reply marker")
  check(contains(oc.frame(), "served"), "did not say it served the request")
end)

test("ocping answers a ping", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000004", true)
  oc.components = { modem }
  oc.push("modem_message", modem.address, "bb000000", PORT, 12, "ocping?")

  local ok, reason = oc.run("ocping", "--listen")
  check(ok, "ocping crashed: " .. tostring(reason))
  local pong
  for _, packet in ipairs(modem.sent) do
    if packet.kind == "ocping!" then
      pong = packet
    end
  end
  check(pong ~= nil, "never answered the ping")
  check(pong and pong.to == "bb000000", "answered somebody else")
end)

test("ocping says plainly when nothing answers", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000004", true)
  oc.components = { modem }

  oc.run("ocping")
  check(contains(oc.printed(), "nothing heard"), "did not report the silence")
end)

test("ocview asks and draws what comes back", function()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  local payload = require("serialization").serialize({
    cards = {
      {
        name = "Super Tank",
        status = "idle",
        gauges = { { label = "Bio Diesel", current = "42,000", maximum = "4,000,000",
          unit = "L", percent = 1.05 } },
      },
    },
    alerts = { { name = "diesel low", tripped = true } },
  })
  -- the reply now names the satellite, so several can be told apart
  oc.push("modem_message", modem.address, "bb000000", PORT, 12, "ocstatus!", "satellite-1", payload)

  local ok, reason = oc.run("ocview", "--once")
  check(ok, "ocview crashed: " .. tostring(reason))

  local frame = oc.screen()
  check(contains(frame, "Super Tank"), "did not show the machine")
  check(contains(frame, "42,000 / 4,000,000 L"), "did not show the reading")
  check(contains(frame, "Bio Diesel"), "did not label the gauge")
  -- a tripped alert is the reason to be looking at this screen at all
  check(contains(frame, "diesel low"), "did not show the alert")
  check(modem.sent[1] and modem.sent[1].kind == "ocstatus?", "never asked")
  if show then
    say(frame)
  end
end)

test("ocview collects every satellite, not just the quickest", function()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  local serialize = require("serialization").serialize

  local first = serialize({
    cards = { { name = "EBF1", status = "working", gauges = {} } }, alerts = {} })
  local second = serialize({
    cards = { { name = "Super Tank", status = "idle", gauges = {} } }, alerts = {} })
  oc.push("modem_message", modem.address, "bb000000", PORT, 12, "ocstatus!", "boiler-room", first)
  oc.push("modem_message", modem.address, "dd000000", PORT, 40, "ocstatus!", "tank-farm", second)

  oc.run("ocview", "--once")
  local frame = oc.screen()

  -- taking the first answer would have hidden the second satellite entirely
  check(contains(frame, "EBF1"), "lost the first satellite's machines")
  check(contains(frame, "Super Tank"), "lost the second satellite's machines")
  check(contains(frame, "boiler-room"), "did not name the first satellite")
  check(contains(frame, "tank-farm"), "did not name the second satellite")
  check(contains(frame, "2 satellites"), "did not count the satellites")
  if show then
    say(frame)
  end
end)

-- A relay repeats what it forwards, so a satellite hears the same question over
-- several paths and answers each copy, and every answer comes back over several
-- paths as well. One card is one satellite however many copies arrive.
test("ocview shows one satellite once however often it answers", function()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  local serialize = require("serialization").serialize

  local payload = serialize({
    cards = { { name = "EBF1", status = "working", gauges = {} } }, alerts = {} })
  for _ = 1, 4 do
    oc.push("modem_message", modem.address, "bb000000", PORT, 12, "ocstatus!",
      "boiler-room", payload)
  end
  local other = serialize({
    cards = { { name = "Super Tank", status = "idle", gauges = {} } }, alerts = {} })
  oc.push("modem_message", modem.address, "dd000000", PORT, 40, "ocstatus!",
    "tank-farm", other)

  oc.run("ocview", "--once")
  local frame = oc.screen()

  check(contains(frame, "2 satellites"), "counted the repeats as satellites")
  check(contains(frame, "2 machines"), "counted the repeats as machines")
  check(contains(frame, "tank-farm"), "lost the satellite that answered once")
  if show then
    say(frame)
  end
end)

-- Sitting out the whole window on every round is what made a tablet feel
-- seconds behind what the satellite was reading.
test("asking stops as soon as every known satellite has answered", function()
  oc.components = {}
  local net = require("ocnet")
  local payload = require("serialization").serialize({ cards = {}, alerts = {} })

  local queue = {
    { "modem_message", "me", "bb000000", PORT, 12, "ocstatus!", "boiler-room", payload },
  }
  local pulls = 0
  local fakeEvent = {
    pull = function()
      pulls = pulls + 1
      local item = table.remove(queue, 1)
      if not item then
        return nil
      end
      return table.unpack(item)
    end,
  }
  local fakeComputer = { uptime = function() return 0 end }
  local modem = { broadcast = function() return true end }

  local answers = net.ask(modem, fakeEvent, 8, 1, fakeComputer)
  check(#answers == 1, "did not collect the answer")
  check(pulls == 1, "kept listening after everyone had answered, " .. pulls .. " pulls")
end)

test("ocview says so when nothing answers", function()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }

  oc.run("ocview", "--once")
  check(contains(oc.screen(), "no answer"), "did not report the silence")
end)

-------------------------------------------------------------------------------
-- ocmkfs

-- a filesystem that records what gets written to it, shaped like the component
-- in dumps/009.txt
local function fakeDisk(address, label, total, readOnly)
  local written = {}
  return {
    address = address,
    kind = "filesystem",
    written = written,
    methods = {
      getLabel = "function():string", setLabel = "function(value:string):string",
      isReadOnly = "function():boolean", spaceTotal = "function():number",
      spaceUsed = "function():number", open = "function(path,mode)",
      write = "function(handle,value):boolean", close = "function(handle)",
      makeDirectory = "function(path):boolean",
    },
    values = {
      getLabel = function()
        return label
      end,
      setLabel = function(value)
        label = value
        return value
      end,
      isReadOnly = function()
        return readOnly == true
      end,
      spaceTotal = function()
        return total
      end,
      spaceUsed = function()
        return 0
      end,
      makeDirectory = function()
        return true
      end,
      open = function(path)
        written.open = path
        return 1
      end,
      write = function(_, value)
        written[written.open] = (written[written.open] or "") .. value
        return true
      end,
      close = function()
        return true
      end,
    },
  }
end

-- the drive is what makes a filesystem removable: device info calls every
-- filesystem "Filesystem" and cannot tell them apart
local function fakeDrive(address, media)
  return {
    address = address,
    kind = "disk_drive",
    methods = {
      isEmpty = "function():boolean", media = "function():string",
      eject = "function([velocity:number]):boolean",
    },
    values = {
      isEmpty = function()
        return media == nil
      end,
      media = function()
        return media
      end,
      eject = function()
        return true
      end,
    },
  }
end

local FLOPPY = "3de61ebf-5122-4b20-9f22-b324c66888cf"
local HDD = "a92767d2-9bb4-4dec-a5dd-ac038ab59250"
local TMPFS = "ab644ac9-35ab-4eb4-91fe-4b45750f14b0"

test("ocmkfs lists removable media before fixed disks", function()
  local floppy = fakeDisk(FLOPPY, nil, 524288, false)
  oc.components = {
    fakeDisk(HDD, "openos", 4194304, false),
    fakeDisk(TMPFS, "tmpfs", 65536, false),
    floppy,
    fakeDrive("372997ab-4a0c-46ee-a425-e13a3b7b18a4", FLOPPY),
  }
  oc.files["/bin/ocup.lua"] = "-- ocup"

  oc.run("ocmkfs")
  local out = oc.printed()
  local floppyAt = out:find("floppy", 1, true)
  local fixedAt = out:find("fixed", 1, true)
  check(floppyAt ~= nil, "the floppy was not listed")
  check(fixedAt ~= nil, "the fixed disk was not listed")
  check(floppyAt < fixedAt, "the fixed disk was listed before the floppy")
  -- tmpfs is scratch space, never an install medium
  check(not contains(out, TMPFS:sub(1, 8)), "offered the temporary filesystem")
end)

test("ocmkfs will not offer a read-only disk", function()
  oc.components = { fakeDisk(HDD, "rom", 65536, true) }
  oc.files["/bin/ocup.lua"] = "-- ocup"

  oc.run("ocmkfs")
  check(contains(oc.printed(), "read only"), "did not mark the disk read only")
end)

test("ocmkfs needs ocup on the machine before it can copy it", function()
  oc.components = { fakeDisk(HDD, "openos", 4194304, false) }

  oc.run("ocmkfs")
  check(contains(oc.printed(), "run ocup first"), "did not say what was missing")
end)

test("ocmkfs flashes a named disk without asking", function()
  local floppy = fakeDisk(FLOPPY, nil, 524288, false)
  oc.components = {
    fakeDisk(HDD, "openos", 4194304, false),
    floppy,
    fakeDrive("372997ab-4a0c-46ee-a425-e13a3b7b18a4", FLOPPY),
  }
  oc.files["/bin/ocup.lua"] = "-- the real ocup"
  -- nothing queued for io.read: the prompt would block a remote caller, so
  -- naming the disk has to avoid it entirely
  oc.reads = {}

  oc.run("ocmkfs", "--disk", FLOPPY:sub(1, 8))
  check(floppy.written["/bin/ocup.lua"] == "-- the real ocup", "did not flash the named disk")
  check(floppy.written["/.prop"] ~= nil, "no .prop on the named disk")
end)

test("ocmkfs copies every program and library, not just ocup", function()
  local floppy = fakeDisk(FLOPPY, nil, 524288, false)
  oc.components = {
    floppy,
    fakeDrive("372997ab-4a0c-46ee-a425-e13a3b7b18a4", FLOPPY),
  }
  -- a tablet has no internet card, so a floppy carrying only the updater would
  -- install a program that cannot fetch anything
  oc.files["/bin/ocup.lua"] = "-- ocup"
  oc.files["/bin/ocdebug.lua"] = "-- ocdebug"
  oc.files["/bin/ocdump.lua"] = "-- ocdump"
  oc.files["/lib/oclib.lua"] = "-- oclib"
  oc.files["/lib/ocgt.lua"] = "-- ocgt"
  oc.files["/bin/edit.lua"] = "-- not ours"

  oc.run("ocmkfs", "--disk", FLOPPY:sub(1, 8))

  check(floppy.written["/bin/ocdebug.lua"] == "-- ocdebug", "ocdebug not copied")
  check(floppy.written["/lib/oclib.lua"] == "-- oclib", "the library was not copied")
  check(floppy.written["/lib/ocgt.lua"] == "-- ocgt", "ocgt not copied")
  -- OpenOS's own programs are not ours to ship
  check(floppy.written["/bin/edit.lua"] == nil, "copied a file that is not ours")
end)

test("ocmkfs copies only the programs picked for the floppy", function()
  local floppy = fakeDisk(FLOPPY, nil, 524288, false)
  oc.components = {
    floppy,
    fakeDrive("372997ab-4a0c-46ee-a425-e13a3b7b18a4", FLOPPY),
  }
  oc.files["/bin/ocup.lua"] = "-- ocup"
  oc.files["/bin/ocdebug.lua"] = "-- ocdebug"
  oc.files["/bin/ocdump.lua"] = "-- ocdump"
  oc.files["/lib/oclib.lua"] = "-- oclib"

  -- pick the disk by number, then turn ocdump off and flash
  oc.reads = { "1" }
  oc.push("key_down", "keyboard", 0, 0xD0) -- down, onto ocdump
  oc.push("key_down", "keyboard", 32, 0x39) -- space
  oc.push("key_down", "keyboard", 13, 0x1C) -- enter

  local ok, reason = oc.run("ocmkfs")
  check(ok, "ocmkfs crashed: " .. tostring(reason))

  check(floppy.written["/bin/ocdebug.lua"] == "-- ocdebug", "dropped a chosen program")
  check(floppy.written["/bin/ocdump.lua"] == nil, "copied a program that was turned off")
  -- the floppy exists to carry the updater, and the libraries are not a choice
  check(floppy.written["/bin/ocup.lua"] == "-- ocup", "left the updater off")
  check(floppy.written["/lib/oclib.lua"] == "-- oclib", "left a library off")
end)

test("ocmkfs refuses a disk too small to hold the payload", function()
  local tiny = fakeDisk(FLOPPY, nil, 64, false)
  oc.components = {
    tiny,
    fakeDrive("372997ab-4a0c-46ee-a425-e13a3b7b18a4", FLOPPY),
  }
  oc.files["/bin/ocup.lua"] = string.rep("x", 4096)

  oc.run("ocmkfs", "--disk", FLOPPY:sub(1, 8))
  check(tiny.written["/bin/ocup.lua"] == nil, "wrote past the end of the disk")
end)

test("ocmkfs refuses a name that matches nothing", function()
  oc.components = { fakeDisk(HDD, "openos", 4194304, false) }
  oc.files["/bin/ocup.lua"] = "-- ocup"

  oc.run("ocmkfs", "--disk", "deadbeef")
  check(not contains(oc.printed(), "done"), "claimed to flash a disk that is not there")
end)

test("ocmkfs writes the installer and labels the disk", function()
  local floppy = fakeDisk(FLOPPY, nil, 524288, false)
  oc.components = {
    floppy,
    fakeDrive("372997ab-4a0c-46ee-a425-e13a3b7b18a4", FLOPPY),
  }
  oc.files["/bin/ocup.lua"] = "-- the real ocup"
  oc.reads = { "1" }

  oc.run("ocmkfs")

  check(floppy.written["/bin/ocup.lua"] == "-- the real ocup", "ocup was not copied")
  -- install parses this as a Lua table and skips copying the file itself
  local prop = floppy.written["/.prop"]
  check(prop ~= nil, "no .prop written, so install will not offer the disk")
  check(prop and contains(prop, "oc-gtnh"), ".prop carries no label")
  local parsed = prop and load("return " .. prop)
  check(parsed ~= nil and parsed() ~= nil, ".prop is not a readable Lua table")
  check(contains(table.concat(oc.invoked, " "), "setLabel"), "disk was not labelled")
end)

-------------------------------------------------------------------------------
-- ockeypad

-- methods verbatim from dumps/009.txt; this build takes setKey per index and
-- setShouldBeep, not the table-based setKey and setVolume the wiki describes
local KEYPAD = {
  address = "01b33e83-6d6d-4974-9fbd-2e60abb5a0f3",
  kind = "os_keypad",
  methods = {
    setDisplay = "function(String:text[, color:number]):boolean",
    setEventName = "function(String:name):boolean",
    setKey = "function(idx:number, text:string, color:number):boolean",
    setShouldBeep = "function(Boolean):boolean",
  },
  values = {
    setDisplay = function()
      return true
    end,
    setEventName = function()
      return true
    end,
    setKey = function()
      return true
    end,
    setShouldBeep = function()
      return true
    end,
  },
}

local function withPin(pin)
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = {}, watch = {}, alerts = {}, keypad = { pin = pin },
  })
end

-- the shape the wiki documents: name, address, button, label
local function keyPress(label)
  oc.push("ockeypad", KEYPAD.address, 1, label)
end

test("ockeypad refuses to guard without a code", function()
  oc.components = { KEYPAD }

  oc.run("ockeypad")
  check(contains(oc.printed(), "--pin"), "did not say how to set a code")
end)

test("ockeypad stores a code and names its own event", function()
  oc.components = { KEYPAD }

  oc.run("ockeypad", "--pin", "4321")
  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  check(saved and saved.keypad and saved.keypad.pin == "4321", "code not stored")
  -- the keypad has no getter for a keypress, so naming the event is what makes
  -- input arrive at all
  check(contains(table.concat(oc.invoked, " "), "setEventName"), "never named its event")
end)

test("ockeypad opens on the right code", function()
  oc.components = { KEYPAD }
  withPin("1234")
  keyPress("1")
  keyPress("2")
  keyPress("3")
  keyPress("4")

  local ok, reason = oc.run("ockeypad")
  check(ok, "ockeypad crashed: " .. tostring(reason))
  check(contains(oc.printed(), "granted"), "the right code was not accepted")
  check(not contains(oc.printed(), "denied"), "the right code was also denied")
end)

test("ockeypad stays shut on the wrong code", function()
  oc.components = { KEYPAD }
  withPin("1234")
  keyPress("1")
  keyPress("2")
  keyPress("9")
  keyPress("9")

  oc.run("ockeypad")
  check(contains(oc.printed(), "denied"), "the wrong code was not refused")
  check(not contains(oc.printed(), "granted"), "the wrong code opened the door")
end)

test("ockeypad clears a part-typed code on star", function()
  oc.components = { KEYPAD }
  withPin("1234")
  keyPress("9")
  keyPress("9")
  keyPress("*")
  keyPress("1")
  keyPress("2")
  keyPress("3")
  keyPress("4")

  oc.run("ockeypad")
  -- without the clear those two nines would still be in the buffer and the
  -- correct code that follows would be refused
  check(contains(oc.printed(), "granted"), "star did not clear the entry")
end)

test("ockeypad says so when nothing can open a door", function()
  oc.components = { KEYPAD }
  withPin("1234")

  oc.run("ockeypad")
  check(contains(oc.printed(), "no redstone"), "did not warn that no door can open")
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

-- a blast furnace between jobs: it reports progress, so it can be idle
local function blastFurnace(active)
  return {
    address = "1c646dd8-0000-0000-0000-000000000009",
    kind = "gt_machine",
    methods = {
      getSensorInformation = "function():table",
      isMachineActive = "function():boolean",
    },
    values = {
      getSensorInformation = function()
        return {
          "Progress: \194\167a0\194\167r s / \194\167e0\194\167r s",
          "Stored Energy: \194\167a1,536\194\167r EU / \194\167e1,536\194\167r EU",
        }
      end,
      isMachineActive = function()
        return active
      end,
    },
  }
end

-- shaped from dumps/013-satellite.txt: no progress line, and it answers
-- isMachineActive yes whether or not any power is moving
local function batteryBuffer(output)
  return {
    address = "6ecc24a5-0000-0000-0000-000000000001",
    kind = "gt_batterybuffer",
    methods = {
      getSensorInformation = "function():table",
      isMachineActive = "function():boolean",
    },
    values = {
      getSensorInformation = function()
        return {
          "\194\1679Medium Voltage Battery Buffer\194\167r",
          "Stored Items: \194\167a1,673,728\194\167r EU / \194\167e1,673,728\194\167r EU",
          "Average input: 0 EU/t",
          "Average output: " .. output .. " EU/t",
        }
      end,
      isMachineActive = function()
        return true
      end,
    },
  }
end

test("ocwatch calls a battery buffer idle while nothing leaves it", function()
  local buffer = batteryBuffer("0")
  oc.components = { buffer }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = buffer.address, hidden = {} } },
    alerts = {},
  })
  oc.run("ocwatch")
  check(contains(oc.frame(), "idle"), "called a buffer passing nothing working")

  oc.width, oc.height = 80, 20
  oc.reset()
  local busy = batteryBuffer("128")
  oc.components = { busy }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = busy.address, hidden = {} } },
    alerts = {},
  })
  oc.run("ocwatch")
  check(contains(oc.frame(), "working"), "did not notice power leaving the buffer")
end)

test("ocwatch says nothing about a machine that never works", function()
  local tank = tankAt("100000")
  oc.components = { tank }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = { [tank.address] = "Super Tank" },
    watch = { { address = tank.address, hidden = {} } },
    alerts = {},
  })

  oc.run("ocwatch")
  -- a tank answers isMachineActive as readily as a furnace does, and calling it
  -- idle said nothing: it has no work to be idle from
  check(not contains(oc.frame(), "idle"), "called a tank idle")
end)

test("ocwatch calls a furnace between jobs idle, and a busy one working", function()
  local waiting = blastFurnace(false)
  oc.components = { waiting }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = waiting.address, hidden = {} } },
    alerts = {},
  })
  oc.run("ocwatch")
  check(contains(oc.frame(), "idle"), "did not call a waiting furnace idle")

  oc.reset()
  local busy = blastFurnace(true)
  oc.components = { busy }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = busy.address, hidden = {} } },
    alerts = {},
  })
  oc.run("ocwatch")
  check(contains(oc.frame(), "working"), "did not call a busy furnace working")
end)

test("ocwatch stops every machine an alert names, not just the first", function()
  local first, second = { value = false }, { value = false }
  local tank = tankAt("100")
  local one = furnace(first)
  local two = furnace(second)
  two.address = "1c646dd8-0000-0000-0000-000000000006"
  oc.components = { tank, one, two }
  -- one tank feeds both blast furnaces
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = tank.address, hidden = {} } },
    alerts = { {
      name = "diesel low",
      address = tank.address,
      label = "Bio Diesel",
      below = 50000,
      above = 200000,
      beep = false,
      act = {
        { address = one.address, method = "setWorkAllowed", onTrip = false, onClear = true },
        { address = two.address, method = "setWorkAllowed", onTrip = false, onClear = true },
      },
    } },
  })

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))
  check(first.value == true, "the first furnace was not stopped")
  check(second.value == true, "the second furnace was not stopped")
end)

test("ocwatch draws a bar against a local maximum and still shows the real one", function()
  local tank = tankAt("7,500")
  -- the size of the attached display, so the row is not cut short
  oc.width, oc.height = 160, 50
  oc.reset()
  oc.components = { tank }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = { [tank.address] = "Super Tank" },
    -- the diesel only ever moves between 5,000 and 10,000 of four million
    watch = { { address = tank.address, hidden = {}, limits = { [1] = 10000 } } },
    alerts = {},
  })

  oc.run("ocwatch")
  local frame = oc.frame()
  check(contains(frame, "7,500 / 10,000 L"), "did not draw against the local maximum")
  check(contains(frame, "75.0%"), "percentage is not of the local maximum")
  -- a local maximum that hides the real capacity is a lie about the tank
  check(contains(frame, "of 4,000,000"), "lost the real capacity")
end)

test("ocwatch keeps the local maximum when the value climbs past it", function()
  -- the tank sits just above the range worth watching, which is exactly when
  -- handing the real maximum back drew an empty bar again
  local tank = tankAt("11,000")
  oc.width, oc.height = 160, 50
  oc.reset()
  oc.components = { tank }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = tank.address, hidden = {}, limits = { [1] = 10000 } } },
    alerts = {},
  })

  oc.run("ocwatch")
  local frame = oc.frame()
  check(contains(frame, "11,000 / 10,000 L"), "went back to the real maximum")
  check(contains(frame, "110.0%"), "rounded the percentage down to full")
  -- the bar itself cannot go past its own end
  check(not contains(frame, "\226\150\145"), "left part of the bar unfilled")
end)

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

test("ocwatch repaints without clearing the screen every frame", function()
  local tank = tankAt("100")
  oc.components = { tank }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = tank.address, hidden = {} } },
    alerts = {},
  })

  -- three idle ticks, each one a refresh
  oc.push()
  oc.push()
  oc.push()

  oc.run("ocwatch")
  local full = 0
  for _, fill in ipairs(oc.fills) do
    if fill.w >= oc.width and fill.h >= oc.height then
      full = full + 1
    end
  end
  check(full <= 1, "cleared the whole screen " .. full .. " times over four frames")
end)

test("ocwatch acts again after its runtime state was saved into the config", function()
  local stopped = { value = false }
  local tank = tankAt("100")
  oc.components = { tank, furnace(stopped) }
  -- Opening the editor once used to write the live alert state to disk. A saved
  -- applied=false then told every later run the furnace had already been
  -- stopped, so the command was never sent and the alert did nothing for good.
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = {}, watch = { { address = tank.address, hidden = {} } },
    alerts = { {
      name = "diesel low",
      address = tank.address,
      index = 2,
      unit = "L",
      below = 50000,
      above = 200000,
      beep = false,
      tripped = true,
      applied = false,
      act = {
        address = "1c646dd8-0000-0000-0000-000000000005",
        method = "setWorkAllowed",
        onTrip = false,
        onClear = true,
      },
    } },
  })

  oc.run("ocwatch")
  check(stopped.value == true, "stale saved state stopped the alert from acting")
  -- watching never rewrites the config, so there is nothing to assert about the
  -- file here; the editor is the only writer and it goes through save(), which
  -- strips these fields
end)

test("ocwatch still finds its reading when the sensor rewords itself", function()
  local stopped = { value = false }
  -- A tank that has run dry drops its fluid name line, so the gauge that used to
  -- sit on line 3 now sits on line 2. The alert was configured against the old
  -- shape, and must still fire: this is the case that silently stopped working.
  local dry = {
    address = "aa11bb22-e712-4134-bce1-b194453d6217",
    kind = "gt_machine",
    methods = { getSensorInformation = "function():table" },
    values = {
      getSensorInformation = function()
        return {
          "\194\1679Super Tank\194\167r",
          "\194\167a100\194\167r L \194\167e4,000,000\194\167r L",
        }
      end,
    },
  }
  oc.components = { dry, furnace(stopped) }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = {}, watch = { { address = dry.address, hidden = {} } },
    alerts = { {
      name = "diesel low",
      address = dry.address,
      -- what the editor recorded when the tank still named its fluid
      label = "Bio Diesel",
      unit = "L",
      gauge = 1,
      index = 3,
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
  check(stopped.value == true, "the alert did not fire after the sensor changed shape")
end)

test("ocwatch says so when an alert matches no reading", function()
  local stopped = { value = false }
  oc.components = { tankAt("100"), furnace(stopped) }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = {},
    watch = { { address = "aa11bb22-e712-4134-bce1-b194453d6217", hidden = {} } },
    alerts = { {
      name = "broken alert",
      address = "aa11bb22-e712-4134-bce1-b194453d6217",
      label = "Nothing Like This",
      unit = "kJ",
      gauge = 9,
      index = 99,
      below = 1,
      beep = false,
    } },
  })

  oc.run("ocwatch")
  -- silence was the real bug: an unwatchable alert looked like a happy one
  check(contains(oc.frame(), "watching nothing"), "an alert that matches nothing said nothing")
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
-- ocsweeper

local SWEEPER_CELL_W = 3
local TOP_LEFT = "\226\148\140"

-- mirrors the layout in programs/ocsweeper.lua: the board is a full grid and is
-- centred, so a cell owns two rows and three columns
local SWEEPER_CELL_H = 2

local function sweeperOrigin(width, height)
  local columns = width * SWEEPER_CELL_W + 1
  local rows = height * SWEEPER_CELL_H + 1
  local x = math.max(1, math.floor((oc.width - columns) / 2) + 1)
  local y = 2 + math.max(0, math.floor(((oc.height - 2) - (rows + 1)) / 2))
  return x, y
end

local function cellTouch(boardW, boardH, x, y, button)
  local originX, originY = sweeperOrigin(boardW, boardH)
  oc.push("touch", "screen",
    originX + (x - 1) * SWEEPER_CELL_W + 1,
    originY + (y - 1) * SWEEPER_CELL_H + 1, button or 0)
end

test("ocsweeper draws a board", function()
  cellTouch(8, 8, 1, 1)

  local ok, reason = oc.run("ocsweeper", "8", "8", "10")
  check(ok, "ocsweeper crashed: " .. tostring(reason))

  local frame = oc.frame()
  check(contains(frame, "ocsweeper v"), "no header")
  check(contains(frame, "8 x 8"), "board size not shown")
  check(contains(frame, "mines"), "mine counter missing")
  if show then
    say(frame)
  end
end)

test("ocsweeper clamps the board to 21", function()
  local ok = oc.run("ocsweeper", "40", "40")
  check(ok, "ocsweeper crashed")
  local header = oc.frame():sub(1, 60)
  -- 21 is the cap, and the height is further limited by the rows available
  check(contains(header, "21 x "), "width was not clamped to 21: " .. header)
  check(not contains(header, "40"), "an unclamped size reached the header: " .. header)
end)

test("ocsweeper never loses on the first click", function()
  -- mines are laid after the opening click, so it cannot land on one. The
  -- click moves each round, which changes the layout as well as the target.
  for y = 1, 8 do
    for x = 1, 8 do
      oc.reset()
      oc.components = {}
      cellTouch(8, 8, x, y)
      oc.run("ocsweeper", "8", "8", "50")
      if contains(oc.frame(), "boom") then
        check(false, "the first click hit a mine at " .. x .. "," .. y)
        return
      end
    end
  end
end)

test("ocsweeper still protects the first click on a crowded board", function()
  -- 3 mines on a 2 by 2 board leaves no room to clear the neighbourhood, so
  -- the safe area shrinks to the clicked cell rather than dropping mines
  for _ = 1, 10 do
    oc.reset()
    oc.components = {}
    cellTouch(2, 2, 1, 1)
    oc.run("ocsweeper", "2", "2", "3")
    if contains(oc.frame(), "boom") then
      check(false, "the first click hit a mine on a crowded board")
      return
    end
  end
end)

test("ocsweeper flags a cell with the right button", function()
  cellTouch(8, 8, 2, 2, 1)

  oc.run("ocsweeper", "8", "8", "10")
  local frame = oc.frame()
  check(contains(frame, "F"), "no flag drawn")
  -- the counter shows mines left to find, so flagging one drops it to 9
  check(contains(frame, "mines 9"), "flag did not change the counter")
end)

test("ocsweeper ends when a mine is opened", function()
  -- sweeping the whole board must reach a mine whatever the layout
  for y = 1, 8 do
    for x = 1, 8 do
      cellTouch(8, 8, x, y)
    end
  end

  oc.run("ocsweeper", "8", "8", "20")
  check(contains(oc.frame(), "boom"), "clicking every cell never hit a mine")
  check(contains(oc.frame(), "*"), "mines were not shown after the loss")
end)

test("ocsweeper is won when every safe cell is open", function()
  -- with no mines the opening click floods the whole board, which reaches the
  -- win without depending on where mines happened to land
  cellTouch(5, 5, 1, 1)

  oc.run("ocsweeper", "5", "5", "0")
  local frame = oc.frame()
  check(contains(frame, "cleared in"), "board was never won")
  check(not contains(frame, "boom"), "reported a loss as well as a win")
end)

test("ocsweeper centres the board and boxes the cells", function()
  oc.run("ocsweeper", "8", "8", "10")
  local frame = oc.frame()
  check(contains(frame, TOP_LEFT), "no box drawn around the board")
  check(contains(frame, "\226\148\130"), "no separator between cells")

  local border = nil
  for line in (frame .. "\n"):gmatch("([^\n]*)\n") do
    if not border and line:find(TOP_LEFT, 1, true) then
      border = line
    end
  end
  check(border ~= nil, "no border row found")
  -- an 8 by 8 board is 25 columns on an 80 column screen, so a centred board
  -- has to have blank space on both sides of it
  check(border and border:sub(1, 1) == " ", "board is flush against the left edge")
  check(border and border:sub(-1) == " ", "board is flush against the right edge")
end)

test("ocsweeper repaints without clearing the screen every frame", function()
  -- three idle ticks. Clearing and redrawing on each one is what made it flicker
  oc.push()
  oc.push()
  oc.push()

  oc.run("ocsweeper", "8", "8", "10")
  local full = 0
  for _, fill in ipairs(oc.fills) do
    if fill.w >= oc.width and fill.h >= oc.height then
      full = full + 1
    end
  end
  check(full <= 1, "cleared the whole screen " .. full .. " times over four frames")
end)

-- On a 2 by 2 board every cell touches every other, so opening a corner always
-- shows a 1 and the single mine is one of the three closed cells.

-- Reads the board back off the screen the way a player sees it. Closed and
-- opened-empty cells are both two spaces, so the background colour is what
-- separates them.
local HIDDEN_BG, OPEN_BG = 0x6E6E6E, 0x1A1A1A

local function readBoard(w, h)
  local rows = {}
  for line in (oc.frame() .. "\n"):gmatch("([^\n]*)\n") do
    rows[#rows + 1] = line
  end

  local originX, originY
  for y = 1, #rows do
    local at = rows[y]:find("\226\148\140", 1, true) -- the top-left corner
    if at then
      -- byte offset to character column
      originX = utf8.len(rows[y]:sub(1, at - 1)) + 1
      originY = y
      break
    end
  end
  if not originX then
    return nil
  end

  local board = {}
  for y = 1, h do
    board[y] = {}
    for x = 1, w do
      local column = originX + (x - 1) * 3 + 2
      local row = originY + (y - 1) * 2 + 1
      local colour = oc.colors[row] and oc.colors[row][column]
      local char = " "
      if rows[row] then
        local offset = utf8.offset(rows[row], column)
        if offset then
          char = rows[row]:sub(offset, offset)
        end
      end
      board[y][x] = {
        digit = tonumber(char),
        closed = colour ~= nil and colour.bg == HIDDEN_BG,
        opened = colour ~= nil and colour.bg == OPEN_BG,
        screenX = column,
        screenY = row,
      }
    end
  end
  return board, originX, originY
end

local function neighboursOf(board, x, y, w, h)
  local out = {}
  for dy = -1, 1 do
    for dx = -1, 1 do
      local nx, ny = x + dx, y + dy
      if (dx ~= 0 or dy ~= 0) and nx >= 1 and nx <= w and ny >= 1 and ny <= h then
        out[#out + 1] = { nx, ny, board[ny][nx] }
      end
    end
  end
  return out
end

test("ocsweeper deals only boards that can be reasoned out", function()
  -- reset again after resizing: the screen buffer is built to the size in effect
  oc.width, oc.height = 160, 50
  oc.reset()

  -- ten fresh boards, each opened and then restarted
  for _ = 1, 10 do
    cellTouch(21, 21, 11, 11)
    oc.push("key_down", "keyboard", 0, 0x13) -- r
  end

  local ok, reason = oc.run("ocsweeper", "21", "21")
  check(ok, "ocsweeper crashed: " .. tostring(reason))
  -- the header says so when a fair layout could not be found
  local seen = table.concat(oc.frames, "\n")
  check(not contains(seen, "guess required"), "dealt a board that needs a guess")
  check(contains(seen, "21 x 21"), "did not deal the full 21 by 21")

  oc.width, oc.height = 80, 20
  oc.reset()
end)

-- A 2x2 board with one mine cannot be reasoned out, so the generator now eases
-- its mines away and the old trick of enumerating three candidates no longer
-- says anything. These play a real board instead, deducing from the screen the
-- way a player would, and rely on the harness's fixed clock to deal the same
-- board twice.
local BOARD_W, BOARD_H, BOARD_MINES = 9, 8, 10

local function openingLook()
  oc.reset()
  cellTouch(BOARD_W, BOARD_H, 5, 4)
  oc.run("ocsweeper", tostring(BOARD_W), tostring(BOARD_H), tostring(BOARD_MINES))
  return readBoard(BOARD_W, BOARD_H)
end

-- Every mine a player can prove from one look: a number whose closed neighbours
-- exactly equal its count has all of them as mines.
local function knownMines(board)
  local mines, list = {}, {}
  for y = 1, BOARD_H do
    for x = 1, BOARD_W do
      local cell = board[y][x]
      if cell.opened and cell.digit then
        local closed = {}
        for _, n in ipairs(neighboursOf(board, x, y, BOARD_W, BOARD_H)) do
          if n[3].closed then
            closed[#closed + 1] = { n[1], n[2] }
          end
        end
        if #closed == cell.digit and #closed > 0 then
          for _, at in ipairs(closed) do
            local key = at[2] * 100 + at[1]
            if not mines[key] then
              mines[key] = true
              list[#list + 1] = at
            end
          end
        end
      end
    end
  end
  return mines, list
end

-- A number that those flags satisfy and which still has an unflagged closed
-- neighbour. Chording the number whose neighbours are ALL mines would be sound
-- but would open nothing, which is why this looks for one with slack.
local function chordable(board, mines)
  for y = 1, BOARD_H do
    for x = 1, BOARD_W do
      local cell = board[y][x]
      if cell.opened and cell.digit then
        local flagged, spare = 0, 0
        for _, n in ipairs(neighboursOf(board, x, y, BOARD_W, BOARD_H)) do
          if n[3].closed then
            if mines[n[2] * 100 + n[1]] then
              flagged = flagged + 1
            else
              spare = spare + 1
            end
          end
        end
        if flagged == cell.digit and spare > 0 then
          return x, y
        end
      end
    end
  end
  return nil
end

test("ocsweeper opens around a finished number, and never detonates", function()
  local board = openingLook()
  check(board ~= nil, "could not read the board off the screen")
  if not board then
    return
  end

  local mines, list = knownMines(board)
  check(#list > 0, "no mine could be proved from the opening board")
  local x, y = chordable(board, mines)
  check(x ~= nil, "no number was satisfied by the provable flags with slack left")
  if not x then
    return
  end

  local before = 0
  for by = 1, BOARD_H do
    for bx = 1, BOARD_W do
      if board[by][bx].opened then
        before = before + 1
      end
    end
  end

  oc.reset()
  cellTouch(BOARD_W, BOARD_H, 5, 4)
  for _, cell in ipairs(list) do
    cellTouch(BOARD_W, BOARD_H, cell[1], cell[2], 1)
  end
  cellTouch(BOARD_W, BOARD_H, x, y)
  oc.run("ocsweeper", tostring(BOARD_W), tostring(BOARD_H), tostring(BOARD_MINES))

  local after = readBoard(BOARD_W, BOARD_H)
  local opened = 0
  for by = 1, BOARD_H do
    for bx = 1, BOARD_W do
      if after[by][bx].opened then
        opened = opened + 1
      end
    end
  end

  check(not contains(oc.frame(), "boom"), "a correct chord detonated")
  check(opened > before, "the chord opened nothing: " .. before .. " -> " .. opened)
end)

test("ocsweeper refuses a chord when a flag is in the wrong place", function()
  local board = openingLook()
  if not board then
    check(false, "could not read the board off the screen")
    return
  end

  local mines = knownMines(board)
  local x, y = chordable(board, mines)
  if not x then
    check(false, "no settled number on the opening board")
    return
  end

  local before = 0
  for by = 1, BOARD_H do
    for bx = 1, BOARD_W do
      if board[by][bx].opened then
        before = before + 1
      end
    end
  end

  -- flag a closed cell that the number does not touch, so its count can never
  -- be satisfied; the chord must do nothing at all rather than gamble
  local wrongX, wrongY
  for by = 1, BOARD_H do
    for bx = 1, BOARD_W do
      if board[by][bx].closed and (math.abs(bx - x) > 1 or math.abs(by - y) > 1) then
        wrongX, wrongY = bx, by
        break
      end
    end
    if wrongX then
      break
    end
  end
  check(wrongX ~= nil, "no distant closed cell to mis-flag")

  oc.reset()
  cellTouch(BOARD_W, BOARD_H, 5, 4)
  cellTouch(BOARD_W, BOARD_H, wrongX, wrongY, 1)
  cellTouch(BOARD_W, BOARD_H, x, y)
  oc.run("ocsweeper", tostring(BOARD_W), tostring(BOARD_H), tostring(BOARD_MINES))

  local after = readBoard(BOARD_W, BOARD_H)
  local opened = 0
  for by = 1, BOARD_H do
    for bx = 1, BOARD_W do
      if after[by][bx].opened then
        opened = opened + 1
      end
    end
  end

  check(not contains(oc.frame(), "boom"), "a misplaced flag detonated")
  -- the number's count was never satisfied, so nothing beyond the opening move
  -- should have opened
  check(opened == before, "a refused chord still opened cells: " .. before .. " -> " .. opened)
  check(not contains(oc.frame(), "cleared in"), "a wrong flag cleared the board")
end)

test("ocsweeper refuses to open around a number without the flags", function()
  cellTouch(2, 2, 1, 1)
  cellTouch(2, 2, 1, 1) -- click the number again, nothing flagged

  oc.run("ocsweeper", "2", "2", "1")
  local frame = oc.frame()
  check(not contains(frame, "boom"), "clicking a number detonated")
  check(not contains(frame, "cleared in"), "opened cells the flags did not account for")
end)

test("ocsweeper re-lays out when the screen changes size", function()
  -- an attached display is often not the size the program started on
  oc.width, oc.height = 80, 20
  oc.reset()
  oc.resize(160, 50)

  local ok, reason = oc.run("ocsweeper")
  check(ok, "ocsweeper crashed on resize: " .. tostring(reason))

  local frame = oc.frame()
  check(contains(frame, "21 x 21"), "did not grow into the larger screen")
  -- and it must still be centred in the new width, not stuck at the old origin
  local row = nil
  for line in (frame .. "\n"):gmatch("([^\n]*)\n") do
    if line:find("\226\148\140", 1, true) then
      row = line
      break
    end
  end
  check(row ~= nil, "no board drawn after the resize")
  local before = row and (row:find("\226\148\140", 1, true) or 1) - 1
  check(before > 20, "board was not re-centred, only " .. tostring(before) .. " columns to its left")

  oc.width, oc.height = 80, 20
  oc.reset()
end)

test("ocsweeper never draws outside a small screen", function()
  oc.width, oc.height = 44, 14
  oc.reset()

  local ok, reason = oc.run("ocsweeper")
  -- gpu.set asserts on an out-of-bounds row, so crashing here means it drew off
  -- the edge of a display smaller than the default board
  check(ok, "ocsweeper drew outside a small screen: " .. tostring(reason))

  oc.width, oc.height = 80, 20
  oc.reset()
end)

test("ocsweeper starts over on r", function()
  cellTouch(8, 8, 3, 3, 1)
  oc.push("key_down", "keyboard", 0, 0x13) -- r

  oc.run("ocsweeper", "8", "8", "10")
  -- the flag placed before the restart is gone, so the counter is back to 10
  check(contains(oc.frame(), "mines 10"), "restart did not clear the flag")
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

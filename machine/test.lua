-- Checks for the programs in programs/, run against the fake machine.
--
--   nix develop -c lua machine/test.lua          run every check
--   nix develop -c lua machine/test.lua --show   also print screens and output

local oc = dofile("machine/oc.lua")

-- install() redirects the global print into the fake screen, and io.open into the
-- fake filesystem, so the harness keeps its own handles on the real ones: one to
-- report with, one to read the repository with
local say = print
local openReal = io.open
oc.install()

local function contentsOf(path)
  local file = openReal(path, "r")
  if not file then
    return nil
  end
  local text = file:read("*a") or ""
  file:close()
  return text
end

local function declaredVersion(path)
  local text = contentsOf(path)
  return text and text:match('VERSION%s*=%s*"([^"]+)"')
end

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
    ["programs/ocup.lua"] = program(declaredVersion("programs/ocup.lua")),
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
  check(contains(out, "6 files in place"), "no success summary")
  check(oc.files["/bin/ocdump.lua"] == program("0.1.0"), "ocdump.lua not written to /bin")
  check(oc.files["/lib/ocgt.lua"] ~= nil, "library not written to /lib")
  if show then
    say(out)
  end
end)

-- What a machine is running has to be answerable without going to the disk for
-- it, or a dashboard asking a dozen satellites sets a dozen disks going. ocup
-- is the only thing that changes those files, so ocup is what writes them down.
test("ocup writes down the commit and the versions it installed", function()
  oc.components = { INTERNET }
  oc.respond = serveProgram({
    ["manifest.txt"] = MANIFEST,
    ["programs/ocup.lua"] = program(declaredVersion("programs/ocup.lua")),
    ["programs/ocdebug.lua"] = program("0.2.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.4.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
  })

  local ok, reason = oc.run("ocup")
  check(ok, "ocup crashed: " .. tostring(reason))

  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  check(type(saved) == "table" and type(saved.installed) == "table",
    "wrote nothing down about what it installed")
  check(saved and saved.installed and saved.installed.commit == COMMIT,
    "did not record the commit it fetched from")
  check(saved and saved.installed and saved.installed.files
    and saved.installed.files["lib/ocgt.lua"] == "0.4.0",
    "did not record the version of a file it installed")
end)

-- A machine told to update reboots into what it fetched, and OpenOS boots to a
-- shell. Without this it boots to a prompt and is never heard from again.
test("ocup starts the chosen program at boot", function()
  oc.components = { INTERNET }
  oc.respond = serveProgram({
    ["manifest.txt"] = MANIFEST,
    ["programs/ocup.lua"] = program(declaredVersion("programs/ocup.lua")),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
  })
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    programs = { "ocdump" },
    boot = "ocdump",
  })

  oc.run("ocup")
  check(oc.files["/home/.shrc"] == "ocdump\n",
    "did not write the autostart: " .. tostring(oc.files["/home/.shrc"]))
end)

test("ocup leaves the autostart alone when no program was chosen for it", function()
  oc.components = { INTERNET }
  oc.respond = serveProgram({
    ["manifest.txt"] = MANIFEST,
    ["programs/ocup.lua"] = program(declaredVersion("programs/ocup.lua")),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
  })
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    programs = { "ocdump" },
  })

  oc.run("ocup")
  check(oc.files["/home/.shrc"] == nil, "wrote an autostart nobody asked for")
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

test("ocup install chooses and then installs, without a second run", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocdump.lua"] = program("0.1.0")
  oc.respond = serveEverything()
  -- down to ocdump, space to turn it off, enter to install what is left
  oc.push("key_down", "keyboard", 0, 0xD0)
  oc.push("key_down", "keyboard", 32, 0x39)
  oc.push("key_down", "keyboard", 13, 0x1C)

  local ok, reason = oc.run("ocup", "install")
  check(ok, "ocup install crashed: " .. tostring(reason))

  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  local chosen = table.concat(saved and saved.programs or {}, ",")
  check(chosen == "ocdebug", "chose " .. chosen)
  -- being told to run the same program again was one step too many
  check(oc.files["/bin/ocdebug.lua"] ~= nil, "did not install what was chosen")
  check(oc.files["/bin/ocdump.lua"] == nil, "left behind what was turned off")
end)

test("ocup install leaves everything alone when it is cancelled", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocdump.lua"] = program("0.1.0")
  oc.respond = serveEverything()
  oc.push("key_down", "keyboard", 0, 0xD0)
  oc.push("key_down", "keyboard", 32, 0x39)
  oc.push("key_down", "keyboard", 0, 0x10)

  oc.run("ocup", "install")
  check(oc.files["/etc/ocgt.cfg"] == nil, "saved a choice that was cancelled")
  check(oc.files["/bin/ocdump.lua"] ~= nil, "removed a program on the way out")
end)

test("ocup install keeps the rest of the config", function()
  oc.components = { INTERNET }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = { ["aa11bb22"] = "EBF Fluid Tank" },
    watch = { { address = "aa11bb22", hidden = {} } },
  })
  oc.respond = serveEverything()
  oc.push("key_down", "keyboard", 13, 0x1C)

  oc.run("ocup", "install")
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
    -- and an older repository has no versions.txt, so the plain manifest is
    -- what it falls back to
    if url:find("versions.txt", 1, true) then
      return 404, "Not Found", "404: Not Found"
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

-- Installing a daemon does not run it, and neither the hostname nor the list of
-- services is a file the manifest would ever name.

local DAEMON_MANIFEST = table.concat({
  "lib/oclib.lua",
  "lib/minitel.lua",
  "etc/minitel.lua",
  "programs/ocup.lua",
}, "\n")

local function serveDaemons()
  return serveProgram({
    ["manifest.txt"] = DAEMON_MANIFEST,
    ["programs/ocup.lua"] = program(declaredVersion("programs/ocup.lua")),
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/minitel.lua"] = program("minitel-c679ae36"),
    ["etc/minitel.lua"] = program("minitel-c679ae36"),
  })
end

test("ocup installs a daemon into /etc/rc.d", function()
  oc.components = { INTERNET }
  oc.respond = serveDaemons()

  local ok, reason = oc.run("ocup")
  check(ok, "ocup crashed: " .. tostring(reason))
  check(oc.files["/etc/rc.d/minitel.lua"] ~= nil,
    "the daemon did not reach /etc/rc.d")
  check(oc.files["/lib/minitel.lua"] ~= nil, "the library did not reach /lib")
end)

test("ocup enables the daemons it installed", function()
  oc.components = { INTERNET }
  oc.respond = serveDaemons()

  oc.run("ocup")

  local cfg = oc.files["/etc/rc.cfg"] or ""
  check(contains(cfg, "minitel"), "installed a daemon and never enabled it")
  check(contains(oc.printed(), "enabled minitel"), "did not say what it enabled")

  -- installed, enabled and not running is the state every program below has to
  -- detect and explain, so it is worth not creating
  check(contains(table.concat(oc.executed, " "), "rc minitel start"),
    "enabled a daemon and left it stopped")
  check(contains(oc.printed(), "started them"), "did not say it started them")
end)

test("ocup tells OpenOS the name it just gave the machine", function()
  oc.components = { INTERNET }
  oc.respond = serveDaemons()

  oc.run("ocup")
  -- OpenOS keeps its own copy per shell, so a name written and not announced is
  -- a machine that goes on calling itself nothing
  check(contains(table.concat(oc.executed, " "), "hostname --update"),
    "named the machine and told nothing else about it")
end)

test("ocup leaves a service somebody else enabled alone", function()
  oc.components = { INTERNET }
  oc.respond = serveDaemons()
  oc.files["/etc/rc.cfg"] = 'enabled = {"minitel","ocsomething"}\n'

  oc.run("ocup")

  local cfg = oc.files["/etc/rc.cfg"] or ""
  check(contains(cfg, "ocsomething"), "threw away a service it did not install")
  local _, twice = cfg:gsub("minitel", "")
  check(twice == 1, "enabled minitel a second time, " .. twice .. " mentions")
end)

test("ocup names a machine that has no name yet", function()
  oc.components = { INTERNET }
  oc.respond = serveDaemons()

  oc.run("ocup")
  check((oc.files["/etc/hostname"] or "") ~= "", "left the machine unnamed")
  check(contains(oc.printed(), "named this machine"), "did not say it named it")
end)

test("ocup keeps a name the machine already has", function()
  oc.components = { INTERNET }
  oc.respond = serveDaemons()
  oc.files["/etc/hostname"] = "boiler-room"

  oc.run("ocup")
  check(oc.files["/etc/hostname"] == "boiler-room", "renamed a machine that had a name")
end)

test("ocup will not enable a daemon that was not installed", function()
  oc.components = { INTERNET }
  oc.respond = serveProgram({
    ["manifest.txt"] = "programs/ocup.lua",
    ["programs/ocup.lua"] = program(declaredVersion("programs/ocup.lua")),
  })

  oc.run("ocup")
  check(not contains(oc.files["/etc/rc.cfg"] or "", "minitel"),
    "enabled a daemon that is not on the disk")
end)

test("ocup with no internet card and no network says both", function()
  oc.components = {}

  oc.run("ocup")
  check(contains(oc.printed(), "no internet card"), "did not say the card is missing")
  check(contains(oc.printed(), "minitel"), "did not say what it tried instead")
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
-- ocserve, ocwatch and ocview over Minitel
--
-- These run the real Minitel daemon out of etc/minitel.lua, so what is asserted
-- on is a packet that went through real routing rather than one this file made
-- up. The other machine is a modem_message pushed in by hand, which is exactly
-- what a card hearing one off the wire raises.

-- A packet is six modem parts, so every argument is kept rather than the first
-- few named ones.
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
      send = function(to, port, ...)
        sent[#sent + 1] = { to = to, port = port, parts = table.pack(...) }
        return true
      end,
      broadcast = function(port, ...)
        sent[#sent + 1] = { to = "*", port = port, parts = table.pack(...) }
        return true
      end,
    },
  }
end

-- the virtual port ocnet talks on, and the physical one Minitel itself uses
local PORT = 4021
local WIRE = 4096

-- Starts the real daemon, named. It reads /etc/hostname once, here.
local function startMinitel(hostname)
  oc.files["/etc/hostname"] = hostname
  local daemon, why = oc.service("etc/minitel.lua")
  check(daemon ~= nil, "the minitel daemon would not load: " .. tostring(why))
  if daemon then
    daemon.start()
  end
  return daemon
end

-- The daemon installed and not started, which is what a machine looks like when
-- rc has not run it. Nothing here starts it; the program under test has to.
local function installMinitel(hostname)
  oc.files["/etc/hostname"] = hostname
  oc.services.minitel = function()
    local daemon = oc.service("etc/minitel.lua")
    if daemon then
      daemon.start()
    end
  end
end

-- One packet arriving off the wire, from a machine that is not this one. Packet
-- ids are counted rather than random, so a rerun sends the same thing twice and
-- the daemon's duplicate cache can be tested on purpose.
local delivered = 0
local function deliver(modem, card, dest, sender, data, id)
  delivered = delivered + 1
  oc.push("modem_message", modem.address, card, WIRE, 12,
    id or ("packet-" .. delivered), 0, dest, sender, PORT, data)
end

-- The same, once the program has been running a while. Nothing hears a packet
-- that arrives before the daemon does.
local function deliverAfter(round, modem, card, dest, sender, data, id)
  delivered = delivered + 1
  oc.pushAfter(round, "modem_message", modem.address, card, WIRE, 12,
    id or ("packet-" .. delivered), 0, dest, sender, PORT, data)
end

-- What this machine put on the wire, read back as Minitel packets rather than
-- as modem arguments.
local function outbound(modem)
  local out = {}
  for _, packet in ipairs(modem.sent) do
    local parts = packet.parts
    if parts and parts.n >= 6 then
      out[#out + 1] = { to = packet.to, dest = parts[3], sender = parts[4],
        port = parts[5], data = parts[6] }
    end
  end
  return out
end

local function firstReply(modem)
  for _, packet in ipairs(outbound(modem)) do
    if type(packet.data) == "string" and packet.data:sub(1, 10) == "ocstatus!\n" then
      return packet
    end
  end
  return nil
end

local function satellite(address, wireless)
  local modem = fakeModem(address, wireless ~= false)
  oc.components = { modem, SUPER_TANK }
  return modem
end

test("ocserve answers a status request", function()
  local modem = satellite("aa000000-0000-0000-0000-000000000001")
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "boiler-room", "tablet", "ocstatus?")

  local ok, reason = oc.run("ocserve", "--once")
  check(ok, "ocserve crashed: " .. tostring(reason))
  -- the answer is queued by the daemon and only put on the wire by its timer
  oc.pump()

  local reply = firstReply(modem)
  check(reply ~= nil, "no answer went out")
  check(reply and reply.dest == "tablet", "did not answer the asker")
  check(reply and reply.sender == "boiler-room", "did not sign the answer")
  check(reply and reply.port == PORT, "answered on the wrong port")

  local report = reply and require("serialization").unserialize(reply.data:sub(11))
  check(report ~= nil, "the answer did not unserialize")
  check(report and #report.cards == 1, "sent no machines")
  check(report and report.cards[1].name == "Super Tank", "did not name the machine")
  check(report and #report.cards[1].gauges == 1, "sent no readings")
  check(report and report.cards[1].gauges[1].percent ~= nil, "no percentage sent")
  check(report and report.address ~= nil, "sent no address to tell a name clash by")
end)

test("ocserve raises a wireless card off zero strength", function()
  local modem = satellite("aa000000-0000-0000-0000-000000000001")
  startMinitel("boiler-room")

  oc.run("ocserve", "--once")
  check(modem.sent.strength ~= nil and modem.sent.strength > 0, "never set the strength")
end)

test("ocserve ignores traffic that is not its own", function()
  local modem = satellite("aa000000-0000-0000-0000-000000000001", false)
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "boiler-room", "tablet", "something else")

  oc.run("ocserve", "--once")
  oc.pump()
  check(firstReply(modem) == nil, "answered a message it should have ignored")
end)

test("a packet for somebody else is passed on rather than answered", function()
  local modem = satellite("aa000000-0000-0000-0000-000000000001")
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "tank-farm", "tablet", "ocstatus?")

  oc.run("ocserve", "--once")
  oc.pump()

  check(firstReply(modem) == nil, "answered a question addressed to another machine")
  local forwarded = nil
  for _, packet in ipairs(outbound(modem)) do
    if packet.dest == "tank-farm" then
      forwarded = packet
    end
  end
  check(forwarded ~= nil, "did not pass the packet on: the mesh does not route")
  check(forwarded and forwarded.sender == "tablet", "rewrote the sender while routing")
end)

test("the same packet arriving twice is answered once", function()
  local modem = satellite("aa000000-0000-0000-0000-000000000001")
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "boiler-room", "tablet", "ocstatus?", "one-packet")
  deliver(modem, "cc000000", "boiler-room", "tablet", "ocstatus?", "one-packet")

  oc.run("ocserve", "--once")
  oc.pump()

  local replies = 0
  for _, packet in ipairs(outbound(modem)) do
    if type(packet.data) == "string" and packet.data:sub(1, 10) == "ocstatus!\n" then
      replies = replies + 1
    end
  end
  check(replies == 1, "answered a repeat of the same packet, got " .. replies)
end)

test("a broadcast question is answered as well as a directed one", function()
  local modem = satellite("aa000000-0000-0000-0000-000000000001")
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "~", "tablet", "ocstatus?")

  oc.run("ocserve", "--once")
  oc.pump()
  check(firstReply(modem) ~= nil, "a broadcast question went unanswered")
end)

test("ocwatch answers a status request while it is watching", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000003", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = {},
  })
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "boiler-room", "tablet", "ocstatus?")

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))
  oc.pump()

  local reply = firstReply(modem)
  check(reply ~= nil, "no answer went out")
  check(reply and reply.dest == "tablet", "did not answer the asker")
  check(contains(oc.frame(), "served"), "did not say it served the request")
end)

-- A disk in this game is heard from across the room. ocwatch answers a
-- dashboard every couple of seconds for as long as it runs, and reading the
-- machine's name off the disk to sign each answer had every satellite in the
-- base clicking on a clock.
test("the machine's own name is read off the disk once, not per question", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000003", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = {},
  })
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "boiler-room", "tablet", "ocstatus?", "one")
  deliver(modem, "cc000000", "boiler-room", "wall-screen", "ocstatus?", "two")
  -- the daemon read the file when it started, which is its one read and not
  -- ocwatch's
  oc.opened = {}

  oc.run("ocwatch")
  oc.pump()

  local answered, reads = 0, 0
  for _, packet in ipairs(outbound(modem)) do
    if type(packet.data) == "string" and packet.data:sub(1, 10) == "ocstatus!\n" then
      answered = answered + 1
    end
  end
  for _, path in ipairs(oc.opened) do
    if path == "/etc/hostname" then
      reads = reads + 1
    end
  end
  check(answered == 2, "answered " .. answered .. " of two questions")
  check(reads == 1, "opened /etc/hostname " .. reads .. " times, not once")
end)

-- The answer comes out of the configuration ocup wrote, which the program is
-- already holding, so a dashboard can ask every machine in the base what it is
-- running and not one of them opens a file to reply.
test("a satellite says what it is running, without touching the disk", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000003", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = {},
    installed = { commit = "abc1234", files = { ["programs/ocwatch.lua"] = "0.22.0" } },
  })
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "boiler-room", "tablet", "ocver?")
  oc.opened = {}

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))
  oc.pump()

  local reply
  for _, packet in ipairs(outbound(modem)) do
    if type(packet.data) == "string" and packet.data:sub(1, 7) == "ocver!\n" then
      reply = packet
    end
  end
  check(reply ~= nil, "no answer to ocver? went out")

  local answer = reply and require("ocnet").decodeVersions(PORT, "boiler-room", reply.data)
  check(answer ~= nil, "the answer could not be read back")
  check(answer and answer.program and answer.program.name == "ocwatch",
    "did not say which program is running")
  check(answer and answer.installed
    and answer.installed.files["programs/ocwatch.lua"] == "0.22.0",
    "did not send the versions it has")
  check(answer and answer.uptime > 0, "sent no uptime to tell a reboot by")

  -- The two a program opens once when it starts, and never again. Anything else
  -- in this list is a disk going round because somebody looked at a screen.
  local STARTUP = { ["/etc/ocgt.cfg"] = true, ["/etc/hostname"] = true }
  local extra = {}
  for _, opened in ipairs(oc.opened) do
    if not STARTUP[opened] then
      extra[#extra + 1] = opened
    end
  end
  check(#extra == 0, "went to the disk to answer: " .. table.concat(extra, ", "))
end)

-- The reboot is the point of it. Overwriting a file changes nothing that is
-- already running, and a daemon reads its own file once when rc starts it.
test("a satellite told to update runs ocup and reboots", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000003", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = {},
  })
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "boiler-room", "tablet", "ocupdate?")

  oc.run("ocwatch")
  oc.pump()

  local said
  for _, packet in ipairs(outbound(modem)) do
    if type(packet.data) == "string" and packet.data:sub(1, 10) == "ocupdate!\n" then
      said = packet
    end
  end
  check(said ~= nil, "never said it had heard the order")
  check(said and said.dest == "tablet", "did not answer the machine that asked")
  check(contains(table.concat(oc.executed, " "), "ocup"), "never ran ocup")
  check(oc.shutdowns[1] == "reboot",
    "did not reboot: " .. tostring(oc.shutdowns[1]))
end)

-- Said before ocup runs rather than after. What happens next is a machine that
-- answers nothing for half a minute, and a dashboard with no word from it
-- cannot tell that from one that has died.
test("the machine says it heard the order before it starts fetching", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000003", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = {},
  })
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "boiler-room", "tablet", "ocupdate?")

  oc.run("ocwatch")
  oc.pump()

  local answer = nil
  for _, packet in ipairs(outbound(modem)) do
    if type(packet.data) == "string" and packet.data:sub(1, 10) == "ocupdate!\n" then
      answer = require("ocnet").decodeUpdate(PORT, "boiler-room", packet.data)
    end
  end
  check(answer ~= nil and answer.word == "starting",
    "did not say what it was about to do")
end)

-- A machine set to come up into a dashboard has nobody at a prompt to type the
-- command at, and the dashboard clears the screen over whatever rc said went
-- wrong at boot. So it starts the daemon itself rather than describing it.
test("a dashboard starts the minitel daemon when rc has not", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000003", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = {},
  })
  installMinitel("boiler-room")
  -- asked once the daemon is up: a packet arriving before there is anything
  -- listening for it is a packet nobody ever sees
  deliverAfter(3, modem, "bb000000", "boiler-room", "tablet", "ocstatus?")

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))
  oc.pump()

  local ran = table.concat(oc.executed, " ")
  check(contains(ran, "rc minitel start"), "never started the daemon: " .. ran)
  -- starting fixes this boot; enabling is what stops the next one going the
  -- same way, and rc refuses a name it already has
  check(contains(ran, "rc minitel enable"), "started it for this boot only")
  check(firstReply(modem) ~= nil,
    "started the daemon and still did not get on the network")
  check(contains(oc.frame(), "was not running"),
    "did not say the daemon had to be started")
end)

test("a dashboard that has a daemon already does not go near rc", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000003", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = {},
  })
  startMinitel("boiler-room")

  oc.run("ocwatch")
  check(not contains(table.concat(oc.executed, " "), "rc minitel"),
    "restarted a daemon that was already answering")
end)

test("ocwatch says so when the daemon is not running", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000003", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = {},
  })

  oc.run("ocwatch")
  check(contains(oc.frame(), "minitel will not answer"),
    "a dashboard off the network never said so")
end)

test("ocping times a packet to a named machine", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000004", true)
  oc.components = { modem }
  startMinitel("tablet")

  -- the far end acknowledges: type 2, carrying the id of what it answers
  oc.push("net_ack", "whatever-id")

  oc.run("ocping", "boiler-room")
  check(contains(oc.printed(), "boiler-room"), "never named what it was pinging")
  check(contains(oc.printed(), "minitel   running"), "did not report the daemon")
end)

test("ocping says plainly when nothing answers on the bare modem", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000004", true)
  oc.components = { modem }

  oc.run("ocping", "--l2")
  check(contains(oc.printed(), "nothing heard"), "did not report the silence")
end)

test("ocping answers a ping on the bare modem", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000004", true)
  oc.components = { modem }
  oc.push("modem_message", modem.address, "bb000000", PORT, 12, "ocping?")

  local ok, reason = oc.run("ocping", "--listen")
  check(ok, "ocping crashed: " .. tostring(reason))
  local pong
  for _, packet in ipairs(modem.sent) do
    if packet.parts and packet.parts[1] == "ocping!" then
      pong = packet
    end
  end
  check(pong ~= nil, "never answered the ping")
  check(pong and pong.to == "bb000000", "answered somebody else")
end)

-- What a satellite says, as ocview would hear it.
local function answerOf(report)
  return "ocstatus!\n" .. require("serialization").serialize(report)
end

test("ocview asks and draws what comes back", function()
  -- wide enough for the name of the reading as well as its numbers
  oc.width, oc.height = 120, 30
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  startMinitel("tablet")

  deliver(modem, "bb000000", "tablet", "satellite-1", answerOf({
    address = "aa000000-0000-0000-0000-000000000001",
    cards = {
      {
        name = "Super Tank",
        status = "idle",
        gauges = { { label = "Bio Diesel", current = "42,000", maximum = "4,000,000",
          unit = "L", percent = 1.05 } },
      },
    },
    alerts = { { name = "diesel low", tripped = true } },
  }))

  local ok, reason = oc.run("ocview", "--once")
  check(ok, "ocview crashed: " .. tostring(reason))

  local shown = oc.screen()
  check(contains(shown, "Super Tank"), "did not show the machine")
  check(contains(shown, "42,000"), "did not show the reading")
  check(contains(shown, "Bio Diesel"), "did not label the gauge")
  check(contains(shown, "diesel low"), "did not show the alert")
  check(contains(shown, "satellite-1"), "did not name the satellite")

  local asked = false
  for _, packet in ipairs(outbound(modem)) do
    if packet.data == "ocstatus?" and packet.dest == "~" then
      asked = true
    end
  end
  check(asked, "never broadcast the question")
end)

test("ocview remembers a satellite so the next question is routed to it", function()
  oc.width, oc.height = 120, 30
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  startMinitel("tablet")

  deliver(modem, "bb000000", "tablet", "satellite-1", answerOf({
    address = "aa000000-0000-0000-0000-000000000001",
    cards = { { name = "EBF1", gauges = {} } },
    alerts = {},
  }))

  oc.run("ocview", "--once")

  local kept = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "{}")
  check(kept and kept.peers ~= nil, "wrote down no satellites at all")
  check(kept and kept.peers and kept.peers[1] == "satellite-1",
    "did not remember the satellite that answered")
end)

test("ocview asks a remembered satellite by name, which a broadcast cannot reach", function()
  oc.width, oc.height = 120, 30
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    peers = { "tank-farm" },
  })
  startMinitel("tablet")

  oc.run("ocview", "--once")

  local byName = false
  for _, packet in ipairs(outbound(modem)) do
    if packet.data == "ocstatus?" and packet.dest == "tank-farm" then
      byName = true
    end
  end
  check(byName, "never asked the remembered satellite by name")
end)

test("ocview says which remembered satellite has gone quiet", function()
  oc.width, oc.height = 120, 30
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    peers = { "satellite-1", "tank-farm" },
  })
  startMinitel("tablet")

  deliver(modem, "bb000000", "tablet", "satellite-1", answerOf({
    cards = { { name = "EBF1", gauges = {} } },
    alerts = {},
  }))

  oc.run("ocview", "--once")
  check(contains(oc.screen(), "tank-farm"), "never named the satellite that said nothing")
end)

test("ocview says so when two machines answer to one name", function()
  oc.width, oc.height = 120, 30
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  startMinitel("tablet")

  for _, address in ipairs({ "aa000000", "dd000000" }) do
    deliver(modem, "bb000000", "tablet", "boiler-room", answerOf({
      address = address,
      cards = { { name = "EBF1", gauges = {} } },
      alerts = {},
    }))
  end

  oc.run("ocview", "--once")
  check(contains(oc.screen(), "both called boiler-room"),
    "two machines under one name looked like one machine")
end)

test("ocview keeps a non-problem alert out of the alarm count", function()
  oc.width, oc.height = 120, 30
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  startMinitel("tablet")

  deliver(modem, "bb000000", "tablet", "satellite-1", answerOf({
    cards = { { name = "Super Tank", gauges = {} } },
    alerts = { { name = "steamfull", tripped = true, trouble = false } },
  }))

  oc.run("ocview", "--once")
  check(not contains(oc.screen(), "1 alarm"), "treated a non-problem alert as trouble")
end)

test("ocview collects every satellite, not just the quickest", function()
  oc.width, oc.height = 160, 40
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  startMinitel("tablet")

  deliver(modem, "bb000000", "tablet", "boiler-room", answerOf({
    cards = { { name = "Boiler One", gauges = {} } },
    alerts = {},
  }))
  deliver(modem, "dd000000", "tablet", "tank-farm", answerOf({
    cards = { { name = "Creosote Tank", gauges = {} } },
    alerts = {},
  }))

  oc.run("ocview", "--once")

  local shown = oc.screen()
  check(contains(shown, "Boiler One"), "lost the first satellite's machines")
  check(contains(shown, "Creosote Tank"), "lost the second satellite's machines")
  check(contains(shown, "boiler-room"), "did not name the first satellite")
  check(contains(shown, "tank-farm"), "did not name the second satellite")
  check(contains(shown, "2 satellites"), "did not count the satellites")
end)

test("ocview shows one satellite once however often it answers", function()
  oc.width, oc.height = 160, 40
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  startMinitel("tablet")

  -- a relay repeats what it forwards, so the same answer arrives more than once
  for _ = 1, 3 do
    deliver(modem, "bb000000", "tablet", "boiler-room", answerOf({
      cards = { { name = "Boiler One", gauges = {} } },
      alerts = {},
    }))
  end
  deliver(modem, "dd000000", "tablet", "tank-farm", answerOf({
    cards = { { name = "Creosote Tank", gauges = {} } },
    alerts = {},
  }))

  oc.run("ocview", "--once")

  local shown = oc.screen()
  check(contains(shown, "2 satellites"), "counted the repeats as satellites")
  check(contains(shown, "2 machines"), "counted the repeats as machines")
  check(contains(shown, "Creosote Tank"), "lost the satellite that answered once")
end)

test("an answer is read from one packet", function()
  oc.components = {}
  local net = require("ocnet")
  local payload = answerOf({
    cards = { { name = "EBF1", gauges = {} } },
    alerts = { { name = "diesel low", tripped = true } },
  })

  local answer = net.decode(PORT, "boiler-room", payload)
  check(answer ~= nil, "did not read the answer")
  check(answer and answer.host == "boiler-room", "lost the satellite name")
  check(answer and #answer.cards == 1, "lost the machines")
  check(answer and answer.alerts[1].tripped == true, "lost the alerts")

  check(net.decode(PORT, "boiler-room", "ocstatus?") == nil, "read a question as an answer")
  check(net.decode(9999, "boiler-room", payload) == nil, "read the wrong port")

  -- a satellite on an older ocwatch sends a bare list, which is a version
  -- mismatch rather than an answer with no machines in it
  local old = "ocstatus!\n" .. require("serialization").serialize({
    { name = "EBF1", gauges = {} },
  })
  local none, why = net.decode(PORT, "boiler-room", old)
  check(none == nil and why == "unreadable", "took an old payload as current")
end)

test("the network report preserves whether a tripped alert is trouble", function()
  oc.components = {}
  local net = require("ocnet")
  local report = net.report({ alerts = {
    { name = "steamfull", tripped = true, trouble = false },
  } }, {})
  check(report.alerts[1].tripped == true, "lost the tripped state")
  check(report.alerts[1].trouble == false, "lost the non-problem mode")
end)

test("a satellite is not remembered under its own name", function()
  oc.components = {}
  local net = require("ocnet")
  oc.files["/etc/hostname"] = "tablet"
  local config = {}
  check(net.remember(config, "tablet") == false, "remembered itself as a satellite")
  check(net.remember(config, "boiler-room") == true, "did not remember a satellite")
  check(net.remember(config, "boiler-room") == false, "remembered the same one twice")
  check(net.forget(config, "boiler-room") == true, "could not forget a satellite")
  check(#net.peers(config) == 0, "forgetting left it in the list")
end)

test("ocview says so when nothing answers", function()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  startMinitel("tablet")

  oc.run("ocview", "--once")
  check(contains(oc.screen(), "no answer"), "did not report the silence")
end)

test("ocview says so when the daemon is not running", function()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }

  oc.run("ocview", "--once")
  check(contains(oc.printed(), "minitel will not answer"),
    "did not say why it could not ask")
end)

-- What the base wrote down, on somebody else's screen. The records travel with
-- the collector's own clock, because a record is stamped with the uptime of the
-- machine that wrote it and that number means nothing anywhere else.

local function logLine(at, host, service, level, message)
  return string.format("%.2f\t%s\t%s\t%d\t%s\n", at, host, service, level, message)
end

test("the log is read newest first, with what raised each record", function()
  oc.components = {}
  local notify = require("ocnotify")
  oc.files[notify.LOG] =
    logLine(100, "boiler-room", "ocwatch", 6, "steamfull cleared at 12,000 L")
    .. logLine(140, "tank-farm", "ocwatch", 3, "diesel low tripped at 41,000 L")

  local records = notify.records(20)
  check(records ~= nil, "found no log at all")
  check(records and #records == 2, "read " .. #(records or {}) .. " records, not two")
  check(records and records[1].message:find("diesel low", 1, true) ~= nil,
    "did not put the newest first")
  check(records and records[1].level == 3, "lost the severity")
  check(records and records[1].host == "tank-farm", "lost which machine it came from")
  check(records and records[2].service == "ocwatch", "lost what raised it")
end)

test("a machine with no log says so, rather than saying it is empty", function()
  oc.components = {}
  local notify = require("ocnotify")
  check(notify.records(20) == nil, "an absent log read as an empty one")
  oc.files[notify.LOG] = ""
  check(#notify.records(20) == 0, "an empty log did not read as empty")
end)

test("only the end of a long log is read", function()
  oc.components = {}
  local notify = require("ocnotify")
  local lines = {}
  for index = 1, 400 do
    lines[#lines + 1] = logLine(index, "boiler-room", "ocwatch", 6,
      "record number " .. index)
  end
  oc.files[notify.LOG] = table.concat(lines)

  local records = notify.records(5)
  check(#records == 5, "read " .. #records .. " records, not five")
  check(records[1].message == "record number 400", "did not read the end")
  -- the read lands in the middle of a line, and half a line is not a record
  for _, record in ipairs(records) do
    check(record.message:find("^record number %d+$") ~= nil,
      "kept a half line: " .. record.message)
  end
end)

test("ocview shows what the collector has written down", function()
  oc.width, oc.height = 120, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({ view = "log" })
  startMinitel("tablet")

  deliver(modem, "bb000000", "tablet", "main", "oclog!\n"
    .. require("serialization").serialize({
      now = 500,
      records = {
        { at = 440, host = "tank-farm", service = "ocwatch", level = 3,
          message = "diesel low tripped at 41,000 L" },
        { at = 200, host = "boiler-room", service = "ocwatch", level = 6,
          message = "steamfull cleared at 12,000 L" },
      },
    }))

  local ok, reason = oc.run("ocview", "--once")
  check(ok, "ocview crashed: " .. tostring(reason))

  local shown = oc.screen()
  check(contains(shown, "diesel low tripped"), "did not show the record")
  check(contains(shown, "tank-farm"), "did not say which machine raised it")
  check(contains(shown, "ocwatch"), "did not say what raised it")
  check(contains(shown, "60s"), "did not say how long ago: " .. tostring(shown:match("[^\n]*diesel[^\n]*")))
  check(contains(shown, "2 records"), "did not head the view")
  check(contains(shown, "1 machine"), "did not say how many machines answered")
  check(contains(shown, "1 error"), "did not count the errors")
end)

test("ocview asks the collector for the log, and only in the log view", function()
  oc.width, oc.height = 120, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    view = "log",
    notify = { syslog = { collector = "main" } },
  })
  startMinitel("tablet")

  oc.run("ocview", "--once")
  local askedLog = false
  for _, packet in ipairs(outbound(modem)) do
    if packet.data == "oclog?" and packet.dest == "main" then
      askedLog = true
    end
  end
  check(askedLog, "never asked the collector for the log")
end)

test("ocview in the machine views asks for no log at all", function()
  oc.width, oc.height = 120, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({ view = "columns" })
  startMinitel("tablet")

  oc.run("ocview", "--once")
  for _, packet in ipairs(outbound(modem)) do
    check(packet.data ~= "oclog?",
      "fetched a screenful of history nobody was looking at")
  end
end)

-------------------------------------------------------------------------------
-- the maintenance screen

local function versionsOf(answer)
  return "ocver!\n" .. require("serialization").serialize(answer)
end

test("ocview asks what every machine is running, and only on the update view",
  function()
    oc.width, oc.height = 120, 20
    oc.reset()
    local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
    oc.components = { modem }
    oc.files["/etc/ocgt.cfg"] =
      require("serialization").serialize({ view = "update" })
    startMinitel("tablet")

    oc.run("ocview", "--once")
    local asked = false
    for _, packet in ipairs(outbound(modem)) do
      if packet.data == "ocver?" then
        asked = true
      end
    end
    check(asked, "never asked what anything is running")
  end)

test("ocview on the machine views asks for no versions at all", function()
  oc.width, oc.height = 120, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] =
    require("serialization").serialize({ view = "columns" })
  startMinitel("tablet")

  oc.run("ocview", "--once")
  for _, packet in ipairs(outbound(modem)) do
    check(packet.data ~= "ocver?",
      "asked for versions on a screen that does not show them")
  end
end)

test("the update view names each machine, what it runs and its commit", function()
  oc.width, oc.height = 120, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] =
    require("serialization").serialize({ view = "update" })
  startMinitel("tablet")

  deliver(modem, "bb000000", "tablet", "boiler-room", answerOf({
    address = "aa000000-0000-0000-0000-000000000001",
    program = { name = "ocwatch", version = "0.22.0" },
    commit = "a1b2c3d4e5f6",
    cards = {},
    alerts = {},
  }), "one")
  deliver(modem, "bb000000", "tablet", "boiler-room", versionsOf({
    uptime = 4200,
    program = { name = "ocwatch", version = "0.22.0" },
    installed = { commit = "a1b2c3d4e5f6",
      files = { ["programs/ocwatch.lua"] = "0.22.0" } },
  }), "two")

  oc.run("ocview", "--once")

  local shown = oc.screen()
  check(contains(shown, "boiler-room"), "did not name the machine")
  check(contains(shown, "ocwatch v0.22.0"), "did not say what it is running")
  check(contains(shown, "a1b2c3d"), "did not show the commit")
  check(contains(shown, "up 70m"), "did not show how long it has been up")
end)

-- A base spread across two commits is the thing this screen exists to show. One
-- machine left behind after an update looks exactly like a machine that is fine
-- until somebody puts the versions side by side.
test("the update view says when the base does not agree with itself", function()
  oc.width, oc.height = 120, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] =
    require("serialization").serialize({ view = "update" })
  startMinitel("tablet")

  deliver(modem, "bb000000", "tablet", "boiler-room", answerOf({
    address = "aa000000-0000-0000-0000-000000000001",
    program = { name = "ocwatch", version = "0.22.0" },
    commit = "a1b2c3d4", cards = {}, alerts = {},
  }), "one")
  deliver(modem, "bb000000", "tablet", "tank-farm", answerOf({
    address = "aa000000-0000-0000-0000-000000000002",
    program = { name = "ocwatch", version = "0.21.0" },
    commit = "9f8e7d6c", cards = {}, alerts = {},
  }), "two")
  deliver(modem, "bb000000", "tablet", "boiler-room", versionsOf({
    uptime = 100, installed = { files = { ["lib/ocnet.lua"] = "0.14.0" } },
  }), "three")
  deliver(modem, "bb000000", "tablet", "tank-farm", versionsOf({
    uptime = 100, installed = { files = { ["lib/ocnet.lua"] = "0.15.0" } },
  }), "four")

  oc.run("ocview", "--once")

  local shown = oc.screen()
  check(contains(shown, "2 different commits"), "did not say the base disagrees")
  check(contains(shown, "behind on 1 file"),
    "did not say which machine is behind, on the one it has selected")
  check(contains(shown, "lib/ocnet.lua"), "did not name the file that differs")
end)

-- 0.9.0 sorts after 0.10.0 in every comparison of strings, and that is exactly
-- the pair a base gets to eventually.
test("a version further on is told from one that only looks it", function()
  oc.width, oc.height = 120, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] =
    require("serialization").serialize({ view = "update" })
  startMinitel("tablet")

  deliver(modem, "bb000000", "tablet", "boiler-room", answerOf({
    address = "aa000000-0000-0000-0000-000000000001",
    commit = "aaaa1111", cards = {}, alerts = {},
  }), "one")
  deliver(modem, "bb000000", "tablet", "boiler-room", versionsOf({
    uptime = 100, installed = { files = { ["lib/ocnet.lua"] = "0.9.0" } },
  }), "two")
  deliver(modem, "bb000000", "tablet", "tank-farm", answerOf({
    address = "aa000000-0000-0000-0000-000000000002",
    commit = "aaaa1111", cards = {}, alerts = {},
  }), "three")
  deliver(modem, "bb000000", "tablet", "tank-farm", versionsOf({
    uptime = 100, installed = { files = { ["lib/ocnet.lua"] = "0.10.0" } },
  }), "four")

  oc.run("ocview", "--once")

  local shown = oc.screen()
  check(contains(shown, "base has 0.10.0"),
    "took 0.9.0 for the newer of the two")
end)

test("pressing u tells the selected machine to update itself", function()
  oc.width, oc.height = 120, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] =
    require("serialization").serialize({ view = "update" })
  startMinitel("tablet")

  deliver(modem, "bb000000", "tablet", "boiler-room", answerOf({
    address = "aa000000-0000-0000-0000-000000000001",
    cards = {}, alerts = {},
  }), "one")
  -- pressed once there is a screen to press it at: anything queued before the
  -- program starts is eaten by the loopback net.up waits on
  oc.pushAfter(2, "key_down", "keyboard", 117, 0x16)
  oc.pushAfter(3, "key_down", "keyboard", 113, 0x10)

  oc.run("ocview")
  oc.pump()

  local told = nil
  for _, packet in ipairs(outbound(modem)) do
    if packet.data == "ocupdate?" then
      told = packet.dest
    end
  end
  check(told == "boiler-room", "told " .. tostring(told) .. " rather than the machine on the cursor")
end)

-- Twelve satellites fetching at once go through one gateway and one internet
-- card, and a base with every computer rebooting together is watching nothing
-- at all for as long as it takes.
test("update all goes one machine at a time, with the gateway last", function()
  oc.width, oc.height = 120, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    view = "update",
    gateway = "main-hall",
    peers = { "boiler-room", "main-hall", "tank-farm" },
  })
  startMinitel("tablet")

  oc.pushAfter(2, "key_down", "keyboard", 97, 0x1E)
  oc.pushAfter(3, "key_down", "keyboard", 113, 0x10)

  oc.run("ocview")
  oc.pump()

  local told = {}
  for _, packet in ipairs(outbound(modem)) do
    if packet.data == "ocupdate?" then
      told[#told + 1] = packet.dest
    end
  end
  check(#told == 1, "told " .. #told .. " machines at once rather than one")
  check(told[1] ~= "main-hall", "started with the gateway everybody fetches through")
end)

test("a satellite answers for the log it keeps", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", true)
  oc.components = { modem, SUPER_TANK }
  local notify = require("ocnotify")
  oc.files[notify.LOG] =
    logLine(90, "boiler-room", "ocwatch", 3, "diesel low tripped at 41,000 L")
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "boiler-room", "tablet", "oclog?")

  oc.run("ocserve", "--once")
  oc.pump()

  local reply
  for _, packet in ipairs(outbound(modem)) do
    if type(packet.data) == "string" and packet.data:sub(1, 7) == "oclog!\n" then
      reply = packet
    end
  end
  check(reply ~= nil, "no log answer went out")

  local answer = require("ocnet").decodeLog(PORT, "boiler-room", reply.data)
  check(answer ~= nil, "the answer could not be read back")
  check(answer and #answer.records == 1, "sent no records")
  check(answer and answer.now > 0, "sent no clock to read the stamps against")
end)

test("a machine with no log answers, with nothing in it", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", true)
  oc.components = { modem, SUPER_TANK }
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "boiler-room", "tablet", "oclog?")

  oc.run("ocserve", "--once")
  oc.pump()

  local reply
  for _, packet in ipairs(outbound(modem)) do
    if type(packet.data) == "string" and packet.data:sub(1, 7) == "oclog!\n" then
      reply = packet
    end
  end
  -- silence and an empty history look the same on the asking screen, and only
  -- one of them is worth walking over to the machine about
  check(reply ~= nil, "said nothing at all, which reads as unreachable")
  local answer = require("ocnet").decodeLog(PORT, "boiler-room",
    reply and reply.data or "")
  check(answer and #answer.records == 0, "answered with records it does not have")
end)

test("the log view shows every machine, not just one", function()
  oc.width, oc.height = 120, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({ view = "log" })
  startMinitel("tablet")

  local serialize = require("serialization").serialize
  -- Two machines, two uptimes that have nothing to do with each other. The
  -- newest record is the boiler's, and its raw stamp is the smaller number.
  deliver(modem, "bb000000", "tablet", "boiler-room", "oclog!\n" .. serialize({
    now = 300,
    records = { { at = 290, host = "boiler-room", service = "ocwatch", level = 3,
      message = "steam low tripped" } },
  }))
  deliver(modem, "dd000000", "tablet", "tank-farm", "oclog!\n" .. serialize({
    now = 90000,
    records = { { at = 89000, host = "tank-farm", service = "ocwatch", level = 6,
      message = "creosote switchover" } },
  }))

  oc.run("ocview", "--once")

  local shown = oc.screen()
  check(contains(shown, "steam low tripped"), "lost the first machine's records")
  check(contains(shown, "creosote switchover"), "lost the second machine's records")
  check(contains(shown, "2 records"), "did not count both machines' records")
  check(contains(shown, "2 machines"), "did not say how many answered")

  -- sorted by how long ago, which is comparable across machines even though the
  -- uptimes it was worked out from are not
  local first = shown:match("[^\n]*tripped[^\n]*")
  local second = shown:match("[^\n]*switchover[^\n]*")
  check(shown:find(first, 1, true) < shown:find(second, 1, true),
    "put the older record above the newer one")
end)

test("with no collector named, every machine is asked for its own log", function()
  oc.width, oc.height = 120, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    view = "log",
    peers = { "tank-farm" },
  })
  startMinitel("tablet")

  oc.run("ocview", "--once")

  local broadcast, byName = false, false
  for _, packet in ipairs(outbound(modem)) do
    if packet.data == "oclog?" and packet.dest == "~" then
      broadcast = true
    end
    if packet.data == "oclog?" and packet.dest == "tank-farm" then
      byName = true
    end
  end
  check(broadcast, "did not ask what is in range")
  check(byName, "did not ask the satellite that a broadcast cannot reach")
end)

test("with a collector named, only it is asked", function()
  oc.width, oc.height = 120, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    view = "log",
    peers = { "tank-farm" },
    notify = { syslog = { collector = "main" } },
  })
  startMinitel("tablet")

  oc.run("ocview", "--once")

  -- it holds a copy of everybody's already, so asking the satellites as well
  -- would hear every record twice
  for _, packet in ipairs(outbound(modem)) do
    if packet.data == "oclog?" then
      check(packet.dest == "main",
        "asked " .. tostring(packet.dest) .. " as well as the collector")
    end
  end
end)

test("a machine agrees with its daemon about its own name", function()
  oc.components = {}
  local net = require("ocnet")
  oc.files["/etc/hostname"] = "boiler-room"

  -- OpenOS keeps its own copy per shell, from that file, at whatever moment
  -- hostname --update last ran. Believing it over the file is how a machine
  -- addresses its own loopback to a name that is not its own.
  oc.env.HOSTNAME = "an-older-name"
  local name = net.hostname({ hostname = "a-third-name" })

  check(name == "boiler-room",
    "took the shell's word over the daemon's: " .. tostring(name))
end)

test("a name a packet cannot carry is refused", function()
  oc.components = {}
  local net = require("ocnet")
  check(net.validHostname("boiler-room") == true, "refused a plain name")
  check(net.validHostname("main.2") == true, "refused a name with a dot")
  check(net.validHostname("") == nil, "took an empty name")
  check(net.validHostname("boiler room") == nil, "took a name with a space")
  -- a leading tilde is how Minitel marks a broadcast
  check(net.validHostname("~everyone") == nil, "took the broadcast marker as a name")
  check(net.validHostname(string.rep("a", 64)) == nil, "took a name too long to send")
end)

-- Fetching through another machine, which is the whole point of P10: one
-- internet card serves a base. The far end is scripted into the modem, so what
-- runs here is the real Minitel stream client against a real FRequest exchange.

local function gatewayModem(address, here, there, body)
  local sent = {}
  local streamPort = 40001
  local closer = "end-of-stream"
  local replies = 0

  local function inward(kind, port, data)
    replies = replies + 1
    oc.push("modem_message", address, "ff000000", WIRE, 12,
      "gw-" .. replies, kind, here, there, port, data)
  end

  local function outward(parts)
    local id, kind = parts[1], parts[2]
    local dest, port, data = parts[3], parts[5], parts[6]
    if dest ~= there then
      return
    end
    -- a reliable packet is acknowledged, or the sender gives up on it
    if kind == 1 then
      inward(2, port, id)
    end
    if data == "openstream" then
      inward(0, port, tostring(streamPort))
      inward(0, streamPort, closer)
    elseif port == streamPort and data ~= closer and data:sub(1, 1) == "t" then
      sent.asked = data
      inward(0, streamPort, "y" .. body)
      inward(0, streamPort, closer)
    end
  end

  return {
    address = address,
    kind = "modem",
    sent = sent,
    methods = {
      open = "", close = "", isOpen = "", isWireless = "", getStrength = "",
      send = "", broadcast = "", setStrength = "", maxPacketSize = "",
    },
    values = {
      open = function() return true end,
      close = function() return true end,
      isOpen = function() return true end,
      isWireless = function() return true end,
      setStrength = function(value) sent.strength = value return value end,
      getStrength = function() return sent.strength or 0 end,
      maxPacketSize = function() return 8192 end,
      send = function(to, port, ...)
        local parts = table.pack(...)
        sent[#sent + 1] = { to = to, port = port, parts = parts }
        outward(parts)
        return true
      end,
      broadcast = function(port, ...)
        local parts = table.pack(...)
        sent[#sent + 1] = { to = "*", port = port, parts = parts }
        outward(parts)
        return true
      end,
    },
  }
end

test("ocup fetches through a machine that has the internet card", function()
  local modem = gatewayModem("aa000000-0000-0000-0000-000000000009",
    "satellite", "gateway", program("0.9.0"))
  oc.components = { modem }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    gateway = "gateway",
  })
  startMinitel("satellite")

  local ok, reason = oc.run("ocup")
  check(ok, "ocup crashed: " .. tostring(reason))
  check(contains(oc.printed(), "fetching through gateway"),
    "did not say it was going through the gateway")
  check(modem.sent.asked ~= nil, "asked the gateway for nothing")
  check(modem.sent.asked and modem.sent.asked:find("/https/", 1, true) ~= nil,
    "did not ask for the file as a proxied URL: " .. tostring(modem.sent.asked))
end)

test("ocup asks around for a gateway when none is configured", function()
  local modem = gatewayModem("aa000000-0000-0000-0000-000000000009",
    "satellite", "gateway", program("0.9.0"))
  oc.components = { modem }
  startMinitel("satellite")

  oc.run("ocup")
  local asked = false
  for _, packet in ipairs(modem.sent) do
    if packet.parts and packet.parts[6] == "ocgateway?" then
      asked = true
    end
  end
  check(asked, "never asked who can reach the internet")
  check(contains(oc.printed(), "nobody answered as a gateway"),
    "did not say that nothing answered")
end)

test("a machine with an internet card answers as the gateway", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", true)
  oc.components = { modem, INTERNET, SUPER_TANK }
  startMinitel("main")
  deliver(modem, "bb000000", "~", "satellite", "ocgateway?")

  oc.run("ocserve", "--once")
  oc.pump()

  local answered = false
  for _, packet in ipairs(outbound(modem)) do
    if packet.data == "ocgateway!" and packet.dest == "satellite" then
      answered = true
    end
  end
  check(answered, "a machine with an internet card kept quiet")
end)

test("a machine with no internet card does not answer as the gateway", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", true)
  oc.components = { modem, SUPER_TANK }
  startMinitel("boiler-room")
  deliver(modem, "bb000000", "~", "satellite", "ocgateway?")

  oc.run("ocserve", "--once")
  oc.pump()

  for _, packet in ipairs(outbound(modem)) do
    check(packet.data ~= "ocgateway!", "offered to fetch with no card to fetch by")
  end
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

test("ocmkfs writes down what the floppy carries", function()
  local floppy = fakeDisk(FLOPPY, nil, 524288, false)
  oc.components = {
    floppy,
    fakeDrive("372997ab-4a0c-46ee-a425-e13a3b7b18a4", FLOPPY),
  }
  oc.files["/bin/ocup.lua"] = "-- ocup"
  oc.files["/bin/ocinstall.lua"] = "-- ocinstall"
  oc.files["/bin/ocdebug.lua"] = "-- ocdebug"
  oc.files["/bin/ocwatch.lua"] = "-- ocwatch"
  oc.files["/lib/oclib.lua"] = "-- oclib"

  oc.run("ocmkfs", "--disk", FLOPPY:sub(1, 8))

  -- Without this the first ocup falls back to its own default and takes
  -- everything else off the disk, which is a machine throwing away what the
  -- floppy just gave it.
  local written = floppy.written["/etc/ocgt.cfg"]
  check(written ~= nil, "the floppy carried no choice for ocup to read")
  local saved = written and require("serialization").unserialize(written)
  check(type(saved) == "table" and type(saved.programs) == "table",
    "what was written is not a configuration ocup can read")

  local carrying = {}
  for _, name in ipairs(saved and saved.programs or {}) do
    carrying[name] = true
  end
  check(carrying.ocdebug, "a program on the floppy was left out of the choice")
  check(carrying.ocwatch, "a program on the floppy was left out of the choice")
  check(carrying.ocinstall, "ocinstall was left out, so ocup would remove it")
  check(not carrying.ocup, "ocup listed itself, which it never does")
end)

test("ocmkfs never leaves ocinstall off a floppy", function()
  local floppy = fakeDisk(FLOPPY, nil, 524288, false)
  oc.components = {
    floppy,
    fakeDrive("372997ab-4a0c-46ee-a425-e13a3b7b18a4", FLOPPY),
  }
  oc.files["/bin/ocup.lua"] = "-- ocup"
  oc.files["/bin/ocinstall.lua"] = "-- ocinstall"
  oc.files["/bin/ocdebug.lua"] = "-- ocdebug"

  -- pick the disk, then flash without touching anything. ocinstall is not in
  -- the list to be turned off, so the only entry the cursor can reach is ocdebug
  oc.reads = { "1" }
  oc.push("key_down", "keyboard", 32, 0x39) -- space, on whatever is first
  oc.push("key_down", "keyboard", 13, 0x1C) -- enter

  oc.run("ocmkfs")
  check(floppy.written["/bin/ocinstall.lua"] == "-- ocinstall",
    "the one program that has to be on the floppy was left off it")
  check(floppy.written["/bin/ocdebug.lua"] == nil,
    "the entry the cursor started on was not the one that got toggled")
end)

-------------------------------------------------------------------------------
-- ocinstall

local function installedSet()
  local names = {}
  for path in pairs(oc.files) do
    local name = path:match("^/bin/(oc.+)%.lua$")
    if name then
      names[name] = true
    end
  end
  return names
end

test("ocinstall removes what was not picked and writes down what was", function()
  oc.files["/bin/ocup.lua"] = "-- ocup"
  oc.files["/bin/ocinstall.lua"] = "-- ocinstall"
  oc.files["/bin/ocdebug.lua"] = "-- ocdebug"
  oc.files["/bin/ocdump.lua"] = "-- ocdump"
  oc.files["/bin/ocwatch.lua"] = "-- ocwatch"

  -- everything starts ticked, so one space turns the first entry off
  oc.push("key_down", "keyboard", 32, 0x39) -- space, on ocdebug
  oc.push("key_down", "keyboard", 13, 0x1C) -- enter

  local ok, reason = oc.run("ocinstall")
  check(ok, "ocinstall crashed: " .. tostring(reason))

  local left = installedSet()
  check(not left.ocdebug, "kept a program that was turned off")
  check(left.ocdump and left.ocwatch, "removed a program that was left on")
  check(left.ocup and left.ocinstall, "removed one of the two it must never remove")

  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  local chosen = {}
  for _, name in ipairs(saved and saved.programs or {}) do
    chosen[name] = true
  end
  check(not chosen.ocdebug, "wrote down a program it had just removed")
  check(chosen.ocdump and chosen.ocwatch, "left a kept program out of the choice")
end)

test("ocinstall keeps the rest of the configuration", function()
  oc.files["/bin/ocup.lua"] = "-- ocup"
  oc.files["/bin/ocinstall.lua"] = "-- ocinstall"
  oc.files["/bin/ocdump.lua"] = "-- ocdump"
  -- what somebody set up on this machine, which is none of this program's
  -- business and has to survive it
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    programs = { "ocdump" },
    peers = { "boiler-room" },
    alerts = { { name = "water low", below = 4000 } },
    nicknames = { ["aa000000"] = "Big Tank" },
    telemetry = { host = "ovw-core-obs-01" },
  })

  oc.push("key_down", "keyboard", 13, 0x1C) -- enter, changing nothing

  oc.run("ocinstall")

  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"])
  check(saved.peers and saved.peers[1] == "boiler-room", "lost the satellites")
  check(saved.alerts and saved.alerts[1] and saved.alerts[1].name == "water low",
    "lost the alerts")
  check(saved.nicknames and saved.nicknames["aa000000"] == "Big Tank", "lost the names")
  check(saved.telemetry and saved.telemetry.host == "ovw-core-obs-01",
    "lost where telemetry goes")
end)

test("ocinstall shows the choice already recorded rather than everything", function()
  oc.files["/bin/ocup.lua"] = "-- ocup"
  oc.files["/bin/ocinstall.lua"] = "-- ocinstall"
  oc.files["/bin/ocdebug.lua"] = "-- ocdebug"
  oc.files["/bin/ocdump.lua"] = "-- ocdump"
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({ programs = { "ocdump" } })

  oc.push("key_down", "keyboard", 13, 0x1C) -- enter, changing nothing

  oc.run("ocinstall")
  local left = installedSet()
  check(not left.ocdebug, "a program the machine had already opted out of was kept")
  check(left.ocdump, "removed the one program that was recorded")
end)

test("ocinstall offers a program that is chosen but not installed yet", function()
  oc.files["/bin/ocup.lua"] = "-- ocup"
  oc.files["/bin/ocinstall.lua"] = "-- ocinstall"
  oc.files["/bin/ocdump.lua"] = "-- ocdump"
  -- ocwatch is chosen and has not arrived: ocup installs it on the next run.
  -- Leaving it out of the menu would cancel that without ever showing it.
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    programs = { "ocdump", "ocwatch" },
  })

  oc.push("key_down", "keyboard", 13, 0x1C) -- enter, changing nothing

  oc.run("ocinstall")
  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"])
  local chosen = {}
  for _, name in ipairs(saved.programs or {}) do
    chosen[name] = true
  end
  check(chosen.ocwatch, "dropped a program that was waiting to be installed")
  check(chosen.ocdump, "dropped a program that is installed")
end)

test("ocinstall changes nothing when it is quit", function()
  oc.files["/bin/ocup.lua"] = "-- ocup"
  oc.files["/bin/ocinstall.lua"] = "-- ocinstall"
  oc.files["/bin/ocdebug.lua"] = "-- ocdebug"

  oc.push("key_down", "keyboard", 32, 0x39) -- space, turning ocdebug off
  oc.push("key_down", "keyboard", 113, 0x10) -- q

  oc.run("ocinstall")
  check(installedSet().ocdebug, "removed a program on the way out")
  check(oc.files["/etc/ocgt.cfg"] == nil, "wrote a choice that was cancelled")
end)

test("ocinstall says so when there is nothing to choose from", function()
  oc.files["/bin/ocup.lua"] = "-- ocup"
  oc.files["/bin/ocinstall.lua"] = "-- ocinstall"

  oc.run("ocinstall")
  check(contains(oc.printed(), "run install from the floppy first"),
    "did not say why there was nothing to do")
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

-- Shaped from the boiler dump: three methods and no fluid of its own. The
-- temperature arrives with a fraction on it, which is what a Railcraft firebox
-- really answers.
-- The address is the caller's, because how hot a boiler can get is read once and
-- kept for good, and a cache outlives the test that filled it.
local function firebox(address, temperature, burning)
  return {
    address = address,
    kind = "boiler_firebox",
    methods = {
      getMaxHeat = "function():number",
      getTemperature = "function():number",
      isBurning = "function():boolean",
    },
    values = {
      getMaxHeat = function()
        return 500.0
      end,
      getTemperature = function()
        return temperature
      end,
      isBurning = function()
        return burning
      end,
    },
  }
end

-- The steam side of the boiler house, which is the other way round from the
-- diesel: the tank filling up is the signal to stop, not to worry. Each read
-- takes the next level, so one run can watch it fill and drain.
local function steamTank(levels)
  local reads = 0
  return {
    address = "5cf68471-2c11-4b38-ace3-83ff36864ca4",
    kind = "gt_machine",
    methods = { getSensorInformation = "function():table" },
    values = {
      getSensorInformation = function()
        reads = reads + 1
        return {
          "\194\1679Super Tank\194\167r",
          "\194\167fSteam\194\167r",
          "\194\167a" .. levels[math.min(reads, #levels)]
            .. "\194\167r L \194\167e4,000,000\194\167r L",
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

-- A blast furnace, which reports progress and so can be idle. With a recipe
-- running the progress line carries a maximum; between jobs it reads 0 s / 0 s.
local function blastFurnace(running)
  return {
    address = "1c646dd8-0000-0000-0000-000000000009",
    kind = "gt_machine",
    methods = {
      getSensorInformation = "function():table",
      isMachineActive = "function():boolean",
    },
    values = {
      getSensorInformation = function()
        local progress = "Progress: \194\167a0\194\167r s / \194\167e0\194\167r s"
        if running then
          progress = "Progress: \194\167a12\194\167r s / \194\167e120\194\167r s"
        end
        return {
          progress,
          "Stored Energy: \194\167a1,536\194\167r EU / \194\167e1,536\194\167r EU",
        }
      end,
      isMachineActive = function()
        return running
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

-- Every indirect call blocks until the next server tick. Six machines read
-- three times over came to well over a second of every two, which is what made
-- the dashboard lag and swallow keystrokes.
test("ocwatch reads each machine once per refresh", function()
  local watch = {}
  oc.components = {}
  for index = 1, 6 do
    local machine = tankAt("100,000")
    machine.address = string.format("aa11bb%02d-e712-4134-bce1-b194453d6217", index)
    oc.components[#oc.components + 1] = machine
    watch[#watch + 1] = { address = machine.address, hidden = {} }
  end
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = watch, alerts = {},
  })

  oc.run("ocwatch")

  local reads = 0
  for _, method in ipairs(oc.invoked) do
    if method == "getSensorInformation" then
      reads = reads + 1
    end
  end
  check(reads == 6, "read the sensor " .. reads .. " times for 6 machines")
  -- a tank says in its own text that it has no work, so asking is wasted ticks
  for _, method in ipairs(oc.invoked) do
    check(method ~= "isMachineActive" and method ~= "hasWork",
      "asked " .. method .. " of a machine whose sensor had already answered")
  end
end)

-- Shaped from dumps/014-satellite-transposer.txt. A Railcraft tank has no
-- component of its own, so it is read through the side of a transposer.
local function transposer(side, amount)
  return {
    address = "2e06d349-23e2-4bec-9cd1-cfceb00fe3da",
    kind = "transposer",
    methods = {
      getTankCount = "function(side:number):number",
      getTankLevel = "function(side:number [, tank:number]):number",
      getTankCapacity = "function(side:number [, tank:number]):number",
      getFluidInTank = "function(side:number [, tank:number]):table",
    },
    values = {
      getTankCount = function(asked)
        if asked == side then
          return 1
        end
        return 0
      end,
      getFluidInTank = function(asked)
        if asked ~= side then
          return {}
        end
        return { { name = "creosote", label = "Creosote Oil",
          amount = amount, capacity = 64000 } }
      end,
    },
  }
end

test("ocwatch watches a tank through a side of a transposer", function()
  local reader = transposer(3, 12000)
  oc.components = { reader }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = reader.address, side = 3, hidden = {} } },
    alerts = {},
  })

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))
  local frame = oc.frame()
  check(contains(frame, "tank south"), "did not name the side the tank is on")
  check(contains(frame, "Creosote Oil"), "did not name the fluid")
  check(contains(frame, "12,000 / 64,000 L"), "did not show the level")
end)

-- A transposer reports no colour of its own, unlike GregTech's sensor text, so
-- steam drew in the default green.
test("a fluid read through a transposer is coloured by what it is", function()
  oc.components = {}
  local octank = require("octank")
  check(octank.colorOf("steam") == "f", "steam is not white")
  check(octank.colorOf("water") == "b", "water is not blue")
  check(octank.colorOf("Creosote Oil") == "6", "creosote took no colour")
  -- a pack renames fluids more often than it invents them
  check(octank.colorOf("densesteam") == "f", "a renamed steam lost its colour")
  check(octank.colorOf("nothing in the table") == nil, "invented a colour")
end)

test("a lamp colour is packed into the five bits a channel it takes", function()
  oc.components = {}
  local ct = require("occomputronics")
  check(ct.rgb(255, 0, 0) == 31 * 1024, "red is " .. ct.rgb(255, 0, 0))
  check(ct.rgb(0, 255, 0) == 31 * 32, "green is " .. ct.rgb(0, 255, 0))
  check(ct.rgb(0, 0, 255) == 31, "blue is " .. ct.rgb(0, 0, 255))
  check(ct.rgb(255, 255, 255) == 0x7FFF, "white is not the top of the range")
  check(ct.rgb(0, 0, 0) == 0, "black is not zero")
  -- the mod refuses anything above 0x7FFF, so nothing may overflow into it
  check(ct.rgb(999, 999, 999) == 0x7FFF, "a value over 255 escaped the range")
end)

test("with only a note block, an alert is played rather than spoken", function()
  local notes = {}
  local noteBlock = {
    address = "b0000000-0000-0000-0000-000000000001",
    kind = "iron_noteblock",
    methods = { playNote = "function([instrument,] note:number [, volume:number])" },
    values = {
      playNote = function(instrument, note)
        notes[#notes + 1] = { instrument = instrument, note = note }
        return true
      end,
    },
  }
  local tank = tankAt("100")
  oc.components = { tank, noteBlock }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = tank.address, hidden = {} } },
    alerts = { {
      name = "diesel low",
      address = tank.address,
      label = "Bio Diesel",
      below = 50000,
      above = 200000,
    } },
  })

  oc.run("ocwatch")
  check(#notes == 3, "played " .. #notes .. " notes, expected a figure of three")
  -- falling for trouble, so it cannot be mistaken for the all clear
  check(notes[1] and notes[1].note > notes[3].note, "the figure rose for an alarm")
  check(notes[1] and notes[1].instrument == "harp", "used an instrument the mod refuses")
end)

test("an alert can watch one face of a transposer", function()
  local stopped = { value = false }
  local reader = transposer(3, 500)
  oc.components = { reader, furnace(stopped) }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = reader.address, side = 3, hidden = {} } },
    alerts = { {
      name = "creosote low",
      address = reader.address,
      -- one transposer can hold a different tank on each face, so the side is
      -- part of what the alert is watching
      side = 3,
      label = "Creosote Oil",
      below = 1000,
      above = 5000,
      beep = false,
      act = { { address = "1c646dd8-0000-0000-0000-000000000005",
        method = "setWorkAllowed", onTrip = false, onClear = true } },
    } },
  })

  oc.run("ocwatch")
  check(stopped.value == true, "the alert on the transposer face did not act")
  check(contains(oc.frame(), "creosote low"), "no notice that it tripped")
end)

-- Signatures taken from Computronics' own @Callback annotations
local function speechBox(said)
  return {
    address = "5e100000-0000-0000-0000-000000000001",
    kind = "speech_box",
    methods = {
      say = "function(text:string):boolean",
      stop = "function():boolean",
      isProcessing = "function():boolean",
      setVolume = "function(volume:number)",
    },
    values = {
      say = function(text)
        said[#said + 1] = text
        return true
      end,
    },
  }
end

-- 00ff00 packed down to the five bits a channel the lamp really takes
local GREEN_LAMP = 31 * 32

local function colorfulLamp(colors)
  return {
    address = "1a300000-0000-0000-0000-000000000001",
    kind = "colorful_lamp",
    methods = {
      getLampColor = "function():number",
      setLampColor = "function(color:number):boolean",
    },
    values = {
      setLampColor = function(color)
        colors[#colors + 1] = color
        return true
      end,
      getLampColor = function()
        return colors[#colors] or 0
      end,
    },
  }
end

test("a tripped alert is spoken aloud and turns the lamps red", function()
  local said, colors = {}, {}
  local tank = tankAt("100")
  oc.components = { tank, speechBox(said), colorfulLamp(colors) }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = { [tank.address] = "EBF Fluid Tank" },
    watch = { { address = tank.address, hidden = {} } },
    alerts = { {
      name = "diesel low",
      address = tank.address,
      label = "Bio Diesel",
      below = 50000,
      above = 200000,
    } },
  })

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))
  check(#said == 1, "expected one spoken phrase, got " .. #said)
  check(contains(said[1] or "", "diesel low"), "did not name the alert: " .. tostring(said[1]))

  -- the lamp takes five bits a channel, so full red is 31 shifted up ten places
  check(#colors == 1, "set the lamp " .. #colors .. " times")
  check(colors[1] == 31 * 1024, "lit the lamp " .. tostring(colors[1]) .. ", not red")
end)

-- The speech box needs text-to-speech installed on the server. Without it the
-- call succeeds and returns false, and reading that as success is what kept the
-- chat box silent behind it.
test("a speech box that cannot speak hands over to the chat box", function()
  local chatted = {}
  local mute = {
    address = "5e100000-0000-0000-0000-000000000002",
    kind = "speech_box",
    methods = { say = "function(text:string):boolean" },
    values = {
      say = function()
        return false, "MaryTTS is not installed"
      end,
    },
  }
  local chat = {
    address = "c8a70000-0000-0000-0000-000000000001",
    kind = "chat_box",
    methods = { say = "function(text:string [, distance:number]):boolean" },
    values = {
      say = function(text)
        chatted[#chatted + 1] = text
        return true
      end,
    },
  }
  local tank = tankAt("100")
  oc.components = { tank, mute, chat }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = tank.address, hidden = {} } },
    alerts = { { name = "diesel low", address = tank.address,
      label = "Bio Diesel", below = 50000, above = 200000 } },
  })

  oc.run("ocwatch")
  check(#chatted == 1, "the chat box said " .. #chatted .. " things")
  check(contains(chatted[1] or "", "diesel low"), "did not name the alert")
end)

test("an alarm sounds while an alert is tripped", function()
  local calls = {}
  local alarm = {
    address = "a1a70000-0000-0000-0000-000000000001",
    kind = "os_alarm",
    methods = {
      activate = "function():string",
      deactivate = "function():string",
      setAlarm = "function(name:string):string",
      setRange = "function(blocks:number):string",
      listSounds = "function():table",
    },
    values = {
      activate = function()
        calls[#calls + 1] = "activate"
        return "Ok"
      end,
      deactivate = function()
        calls[#calls + 1] = "deactivate"
        return "Ok"
      end,
    },
  }
  local tank = tankAt("100")
  oc.components = { tank, alarm }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = tank.address, hidden = {} } },
    alerts = { { name = "diesel low", address = tank.address,
      label = "Bio Diesel", below = 50000, above = 200000 } },
  })

  oc.run("ocwatch")
  -- an alarm is set while something is wrong, not sounded once and stopped
  check(#calls == 1 and calls[1] == "activate",
    "the alarm was told " .. table.concat(calls, ", "))
end)

-- An alert that shuts the fuel off because the steam tank is full is doing its
-- job, and it sits at its threshold most of the time. A base that runs with a
-- red lamp all day has no red lamp left to mean anything with.
test("an alert that does not count as trouble reddens nothing", function()
  local said, colors = {}, {}
  local tank = tankAt("100")
  oc.components = { tank, speechBox(said), colorfulLamp(colors) }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = tank.address, hidden = {} } },
    alerts = { {
      name = "diesel low",
      address = tank.address,
      label = "Bio Diesel",
      below = 50000,
      above = 200000,
      trouble = false,
    } },
  })

  oc.run("ocwatch")
  check(#said == 0, "spoke for an alert that is not trouble")
  -- the lamp is still set, to the colour that means all is well
  check(colors[#colors] == GREEN_LAMP, "reddened the lamp for an alert that is not trouble")
end)

-- An alert that is not trouble says nothing and holds nothing, so nothing
-- anywhere shows it happened. That is what the log is for, and it runs the real
-- syslog daemon rather than watching for the event that feeds it.

local function startSyslog(destination)
  oc.files["/etc/syslogd.cfg"] = require("serialization").serialize({
    destination = destination,
    write = true,
    minlevel = 6,
    displevel = -1,
  })
  local logd, why = oc.service("etc/syslogd.lua")
  check(logd ~= nil, "the syslog daemon would not load: " .. tostring(why))
  if logd then
    logd.start()
  end
  return logd
end

local function alertConfig(tank, extra)
  local alert = {
    name = "diesel low",
    address = tank.address,
    label = "Bio Diesel",
    below = 50000,
    above = 200000,
  }
  for key, value in pairs(extra or {}) do
    alert[key] = value
  end
  return require("serialization").serialize({
    watch = { { address = tank.address, hidden = {} } },
    alerts = { alert },
  })
end

test("a tripped alert is written down", function()
  local tank = tankAt("100")
  oc.components = { tank }
  oc.files["/etc/ocgt.cfg"] = alertConfig(tank)
  startSyslog("/home/ocgt.log")

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))

  local log = oc.files["/home/ocgt.log"] or ""
  check(contains(log, "diesel low"), "the alert never reached the log")
  check(contains(log, "ocwatch"), "the log does not say what wrote the line")
  -- tab separated: service, level, message. Trouble is an error.
  check(contains(log, "\t3\t"), "did not log trouble at the error level")
end)

test("an alert that is not trouble is written down anyway", function()
  local said = {}
  local tank = tankAt("100")
  oc.components = { tank, speechBox(said) }
  oc.files["/etc/ocgt.cfg"] = alertConfig(tank, { trouble = false })
  startSyslog("/home/ocgt.log")

  oc.run("ocwatch")

  check(#said == 0, "spoke for an alert that is not trouble")
  local log = oc.files["/home/ocgt.log"] or ""
  check(contains(log, "diesel low"),
    "a switchover said nothing and was written nowhere")
  check(contains(log, "\t6\t"), "did not log a switchover at the info level")
end)

test("the log can be switched off like any other channel", function()
  local tank = tankAt("100")
  oc.components = { tank }
  local config = require("serialization").unserialize(alertConfig(tank))
  config.notify = { syslog = { on = false } }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize(config)
  startSyslog("/home/ocgt.log")

  oc.run("ocwatch")
  check((oc.files["/home/ocgt.log"] or "") == "", "logged with the channel off")
end)

test("a record goes nowhere quietly when no daemon is listening", function()
  oc.components = {}
  local notify = require("ocnotify")
  local ok = notify.record({}, "nobody is listening", notify.NOTICE)
  check(ok == true, "raising a record without a collector was an error")
end)

test("one name settles every machine's part in the log", function()
  oc.components = {}
  local notify = require("ocnotify")
  local serialize = require("serialization")
  local config = {}

  notify.set(config, "syslog", "collector", "main")
  check(notify.collect(config, "boiler-room") == true, "could not write the settings")
  local sending = serialize.unserialize(oc.files["/etc/syslogd.cfg"])
  check(sending.relay == true, "a satellite is not sending its records on")
  check(sending.relayhost == "main", "a satellite is sending them nowhere")
  check(sending.receive == false, "a satellite is collecting other machines' records")
  check(sending.write == true, "a satellite keeps no copy of its own")

  check(notify.collect(config, "main") == true, "could not write the settings")
  local collector = serialize.unserialize(oc.files["/etc/syslogd.cfg"])
  check(collector.receive == true, "the collector will not take anything in")
  check(collector.relay == false, "the collector is relaying to itself")

  -- a record printed over a dashboard is a record that broke the screen
  check(collector.displevel < 0, "would print records over whatever is on screen")
end)

test("with no collector named, records stay on the machine that made them", function()
  oc.components = {}
  local notify = require("ocnotify")
  notify.collect({}, "boiler-room")
  local kept = require("serialization").unserialize(oc.files["/etc/syslogd.cfg"])
  check(kept.relay == false, "sent records to nobody in particular")
  check(kept.receive == false, "took in records nobody sends")
  check(kept.write == true, "kept nothing at all")
end)

-- `trouble` was called `beep` and said only whether the alert made a noise
test("an alert written before trouble had a name is still quiet", function()
  local said, colors = {}, {}
  local tank = tankAt("100")
  oc.components = { tank, speechBox(said), colorfulLamp(colors) }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = tank.address, hidden = {} } },
    alerts = { { name = "diesel low", address = tank.address,
      label = "Bio Diesel", below = 50000, above = 200000, beep = false } },
  })

  oc.run("ocwatch")
  check(#said == 0, "spoke for an alert that was told not to make a noise")
  check(colors[#colors] == GREEN_LAMP, "reddened the lamp for an alert told to stay quiet")
end)

-- Two blast furnaces fed by one tank were two identical alerts before this,
-- which then had to be kept in step by hand.
test("an action can be added to an alert that already exists", function()
  local first, second = { value = false }, { value = false }
  local tank = tankAt("100000")
  local one = furnace(first)
  local two = furnace(second)
  two.address = "1c646dd8-0000-0000-0000-000000000006"
  oc.components = { tank, one, two }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = tank.address, hidden = {} } },
    alerts = { {
      name = "diesel low",
      address = tank.address,
      label = "Bio Diesel",
      below = 50000,
      above = 200000,
      beep = false,
      act = { { address = one.address, method = "setWorkAllowed",
        onTrip = false, onClear = true } },
    } },
  })

  local DOWN, ENTER, Q = 0xD0, 0x1C, 0x10
  local function press(code)
    oc.push("key_down", "keyboard", 0, code)
  end

  press(DOWN)          -- past the machine, onto the alert
  press(ENTER)         -- open it
  for _ = 1, 8 do
    press(DOWN)        -- down to "add a machine to act on"
  end
  press(ENTER)
  press(ENTER)         -- take the first machine offered
  press(Q)             -- back out of the alert
  press(Q)             -- and out of the editor

  local ok, reason = oc.run("ocwatch", "--edit")
  check(ok, "the editor crashed: " .. tostring(reason))

  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  local acts = saved and saved.alerts and saved.alerts[1] and saved.alerts[1].act
  check(acts and #acts == 2, "the alert acts on " .. #(acts or {}) .. " machines")
end)

test("the editor lists what is watched and what will fire", function()
  local tank = tankAt("100000")
  oc.width, oc.height = 160, 50
  oc.reset()
  oc.components = { tank }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = { [tank.address] = "EBF Fluid Tank" },
    watch = { { address = tank.address, hidden = {} } },
    alerts = { {
      name = "diesel low", address = tank.address, label = "Bio Diesel",
      below = 5000, above = 10000,
      act = { { address = "x", method = "setWorkAllowed", onTrip = false } },
    } },
  })
  oc.push("key_down", "keyboard", 0, 0x10)

  oc.run("ocwatch", "--edit")
  -- the editor is drawn on the screen now, not printed
  local out = oc.frame()
  check(contains(out, "MACHINES"), "no machines section")
  check(contains(out, "ALERTS"), "no alerts section")
  check(contains(out, "EBF Fluid Tank"), "did not name the machine")
  check(contains(out, "diesel low"), "did not name the alert")
  check(contains(out, "below 5,000"), "did not show the threshold")
  check(contains(out, "acts on 1"), "did not say how many machines it acts on")
end)

test("an alert screen offers both directions", function()
  oc.width, oc.height = 160, 50
  oc.reset()
  local steam = steamTank({ "3,900,000" })
  oc.components = { steam }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = steam.address, hidden = {} } },
    alerts = { { name = "steam full", address = steam.address, label = "Steam",
      over = 3500000, under = 2000000, trouble = false } },
  })

  local DOWN, ENTER, Q = 0xD0, 0x1C, 0x10
  oc.push("key_down", "keyboard", 0, DOWN)   -- past the machine, onto the alert
  oc.push("key_down", "keyboard", 0, ENTER)  -- open it
  oc.push("key_down", "keyboard", 0, Q)

  local ok, reason = oc.run("ocwatch", "--edit")
  check(ok, "the editor crashed: " .. tostring(reason))
  local out = table.concat(oc.frames, "\n")
  check(contains(out, "above 3,500,000"), "the list did not show the trip point")
  check(contains(out, "trips above       3,500,000"), "no high trip point")
  check(contains(out, "clears below      2,000,000"), "did not say where it clears")
  check(contains(out, "counts as trouble no"), "did not say it is not trouble")
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

-- A super tank has no auto-output switch of its own in the OpenComputers API.
-- What stops it feeding the boilers is setWorkAllowed, the same switch a blast
-- furnace has, so a full steam tank starves them and a falling one feeds them
-- again.
test("a tank that fills up stops a machine, and starts it as the tank drains",
  function()
  local stopped = { value = false }
  local switched = {}
  local fuel = furnace(stopped)
  local setWork = fuel.values.setWorkAllowed
  fuel.values.setWorkAllowed = function(allowed)
    switched[#switched + 1] = allowed
    return setWork(allowed)
  end

  local steam = steamTank({ "3,900,000", "3,000,000", "1,000,000" })
  oc.components = { steam, fuel }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = steam.address, hidden = {} } },
    alerts = { {
      name = "steam full",
      address = steam.address,
      label = "Steam",
      over = 3500000,
      under = 2000000,
      trouble = false,
      act = { { address = fuel.address, method = "setWorkAllowed",
        onTrip = false, onClear = true } },
    } },
  })

  local R = 0x13
  oc.push("key_down", "keyboard", 114, R)
  oc.push("key_down", "keyboard", 114, R)

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))
  -- three quarters full is neither: an alert that cleared there would switch the
  -- boilers on and off against the same steam
  check(#switched == 2, "switched the fuel " .. #switched .. " times, not twice")
  check(switched[1] == false, "the full tank did not stop the fuel")
  check(switched[2] == true, "the drained tank did not start the fuel again")
  check(stopped.value == false, "left the fuel off after the steam ran down")
end)

-------------------------------------------------------------------------------
-- Railcraft boilers

test("ocwatch draws a boiler by how hot it is", function()
  oc.width, oc.height = 160, 30
  oc.reset()
  local boiler = firebox("20bfbc1d-98ef-4903-9fb4-8bf3273932b8", 376.13531494141, true)
  oc.components = { boiler }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = boiler.address, hidden = {} } },
    alerts = {},
  })

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))
  local frame = oc.frame()
  check(contains(frame, "Boiler Firebox"), "did not name the boiler")
  check(contains(frame, "Temperature"), "did not label the reading")
  -- the temperature arrives with a fraction on it, and a degree is plenty
  check(contains(frame, "376 / 500 C"), "did not show the heat: " .. frame)
  check(contains(frame, "75.2%"), "did not show how far up its range it is")
  check(contains(frame, "working"), "a burning boiler is not working")
end)

test("a boiler that is not burning is idle", function()
  local boiler = firebox("b2353c84-3e41-4028-80ef-763f29af083b", 225.80444335938, false)
  oc.components = { boiler }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = boiler.address, hidden = {} } },
    alerts = {},
  })

  oc.run("ocwatch")
  check(contains(oc.frame(), "idle"), "a boiler burning nothing is not idle")
end)

-- Every call into a firebox blocks until the next server tick, and how hot one
-- can get does not change while the world runs.
test("how hot a boiler can get is asked once, not every refresh", function()
  local boiler = firebox("dc09058f-19ce-4c96-ab28-45001cc5bc76", 300.5, true)
  oc.components = { boiler }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = boiler.address, hidden = {} } },
    alerts = {},
  })

  oc.push("key_down", "keyboard", 114, 0x13) -- r, a second read of the machines
  oc.run("ocwatch")

  local heats, temperatures = 0, 0
  for _, method in ipairs(oc.invoked) do
    if method == "getMaxHeat" then
      heats = heats + 1
    elseif method == "getTemperature" then
      temperatures = temperatures + 1
    end
  end
  check(temperatures == 2, "read the temperature " .. temperatures .. " times, not twice")
  check(heats == 1, "asked the maximum " .. heats .. " times across two refreshes")
end)

-- A boiler that has gone cold makes no steam, which is worth being told about.
test("an alert can watch a boiler temperature", function()
  local stopped = { value = false }
  local boiler = firebox("ee94fabd-1ec8-472d-8915-3f1018a22b3d", 42.5, false)
  oc.components = { boiler, furnace(stopped) }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = boiler.address, hidden = {} } },
    alerts = { {
      name = "boiler cold",
      address = boiler.address,
      label = "Temperature",
      unit = "C",
      below = 100,
      above = 150,
      trouble = false,
      act = { { address = "1c646dd8-0000-0000-0000-000000000005",
        method = "setWorkAllowed", onTrip = false, onClear = true } },
    } },
  })

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))
  check(stopped.value == true, "a cold boiler did not act")
  check(contains(oc.frame(), "boiler cold"), "no notice that the alert tripped")
end)

test("a boiler travels to the tablet with its heat", function()
  oc.components = { firebox("20bfbc1d-98ef-4903-9fb4-8bf3273932b8", 376.13531494141, true) }
  local net = require("ocnet")
  local config = { watch = { { address = "20bfbc1d-98ef-4903-9fb4-8bf3273932b8" } },
    alerts = {} }
  local report = net.report(config, net.machines(config))

  local card = report.cards[1]
  check(card and card.name == "Boiler Firebox", "the tablet was sent no boiler")
  check(card.status == "working", "lost whether it is burning")
  local gauge = card.gauges[1]
  check(gauge and gauge.label == "Temperature", "sent no temperature")
  check(gauge.current == "376" and gauge.maximum == "500", "sent "
    .. tostring(gauge.current) .. " / " .. tostring(gauge.maximum))
  check(gauge.unit == "C", "lost the unit")
  -- the colour travels, or a bar means one thing on the dashboard and another
  -- on the tablet watching it
  check(gauge.colorCode == "c", "the heat lost its colour")
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
-- octiles

-- mirrors the layout in programs/octiles.lua: a tile owns two rows and seven
-- columns, and the board is centred in what the header and the bar leave
local TILES_CELL_W = 7
local TILES_CELL_H = 2
local PIPE = "\226\148\130"

local function tilesOrigin(size)
  local columns = size * TILES_CELL_W + 1
  local rows = size * TILES_CELL_H + 1
  local x = math.max(1, math.floor((oc.width - columns) / 2) + 1)
  local y = 2 + math.max(0, math.floor(((oc.height - 2) - (rows + 1)) / 2))
  return x, y, columns, rows
end

-- Split on the separator rather than by column, because the box characters are
-- three bytes each and a byte offset stops being a column at the first one.
local function tilesInRow(line)
  local values, at = {}, 1
  while true do
    local _, ends = line:find(PIPE, at, true)
    if not ends then
      break
    end
    local nextOne = line:find(PIPE, ends + 1, true)
    if not nextOne then
      break
    end
    values[#values + 1] = tonumber((line:sub(ends + 1, nextOne - 1):gsub("%s", ""))) or 0
    at = ends + 1
  end
  return values
end

local function tilesBoard()
  local rows = {}
  for line in (oc.frame() .. "\n"):gmatch("([^\n]*)\n") do
    if line:find(PIPE, 1, true) then
      rows[#rows + 1] = tilesInRow(line)
    end
  end
  return rows
end

test("octiles draws a board", function()
  local ok, reason = oc.run("octiles")
  check(ok, "octiles crashed: " .. tostring(reason))

  local frame = oc.frame()
  check(contains(frame, "octiles v"), "no header")
  check(contains(frame, "4 x 4"), "board size not shown")
  check(contains(frame, "score 0"), "score missing")
  check(contains(frame, TOP_LEFT), "no box drawn around the board")
  if show then
    say(frame)
  end
end)

test("octiles keeps the board between 2 and 8 a side", function()
  oc.run("octiles", "40")
  check(contains(oc.frame(), "8 x 8"), "a board wider than 8 was dealt")

  oc.reset()
  oc.run("octiles", "1")
  check(contains(oc.frame(), "2 x 2"), "a board narrower than 2 was dealt")

  oc.reset()
  oc.run("octiles", "x")
  check(contains(oc.frame(), "4 x 4"), "a size that is not a number was not ignored")
end)

test("octiles joins equal tiles, and stops when nothing can move", function()
  -- a 2 by 2 board played left and up until it jams. Every join is worth what
  -- the two tiles made, so 12 is a four and then an eight, which is the whole
  -- of the rule: two twos become a four rather than the four becoming an eight
  -- in the same move.
  for _ = 1, 40 do
    oc.push("key_down", "keyboard", 0, 0xCB)
    oc.push("key_down", "keyboard", 0, 0xC8)
  end

  local ok, reason = oc.run("octiles", "2")
  check(ok, "octiles crashed: " .. tostring(reason))

  local frame = oc.frame()
  check(contains(frame, "score 12"), "joins did not score what the tiles made")
  check(contains(frame, "no moves left"), "a jammed board was not called finished")
end)

test("octiles slides every tile as far as it goes", function()
  for _ = 1, 12 do
    oc.push("key_down", "keyboard", 0, 0xCB)
  end
  oc.run("octiles")

  -- one new tile arrives after each slide and it can land anywhere, so at most
  -- one row is allowed to hold a tile with a hole to its left
  local loose = 0
  for _, row in ipairs(tilesBoard()) do
    local filled = 0
    for _, value in ipairs(row) do
      if value ~= 0 then
        filled = filled + 1
      end
    end
    for x = 1, filled do
      if row[x] == 0 then
        loose = loose + 1
        break
      end
    end
  end
  check(loose <= 1, loose .. " rows left a hole on the side they were slid to")
end)

test("octiles slides towards the side a click lands on", function()
  -- the board is quartered along its diagonals, so a click in one quarter has
  -- to do what the arrow key for that side does
  local function afterKey(code)
    oc.reset()
    oc.push("key_down", "keyboard", 0, code)
    oc.run("octiles")
    return oc.frame()
  end

  local function afterClick(dx, dy)
    oc.reset()
    local x, y, columns, rows = tilesOrigin(4)
    oc.push("touch", "screen",
      math.floor(x + columns / 2 + dx), math.floor(y + rows / 2 + dy), 0)
    oc.run("octiles")
    return oc.frame()
  end

  local sides = {
    { name = "left", code = 0xCB, dx = -5, dy = 0 },
    { name = "right", code = 0xCD, dx = 5, dy = 0 },
    { name = "up", code = 0xC8, dx = 0, dy = -3 },
    { name = "down", code = 0xD0, dx = 0, dy = 3 },
  }
  for _, side in ipairs(sides) do
    check(afterClick(side.dx, side.dy) == afterKey(side.code),
      "a click on the " .. side.name .. " did not slide " .. side.name)
  end

  -- and the four are not all the same thing quietly passing
  check(afterKey(0xCB) ~= afterKey(0xCD), "left and right left the same board")
end)

test("octiles starts over on r", function()
  for _ = 1, 12 do
    oc.push("key_down", "keyboard", 0, 0xCB)
  end
  oc.push("key_down", "keyboard", 0, 0x13) -- r

  oc.run("octiles", "2")
  check(contains(oc.frame(), "score 0"), "restart kept the score")
  check(not contains(oc.frame(), "no moves left"), "restart kept the finished board")
end)

test("octiles grows into a screen that changed size", function()
  oc.width, oc.height = 44, 14
  oc.reset()
  oc.run("octiles", "8")
  check(contains(oc.frame(), "5 x 5"), "did not shrink to what the small screen fits")

  oc.reset()
  oc.resize(160, 50)
  local ok, reason = oc.run("octiles", "8")
  check(ok, "octiles crashed on resize: " .. tostring(reason))
  check(contains(oc.frame(), "8 x 8"), "did not grow into the larger screen")

  oc.width, oc.height = 80, 20
  oc.reset()
end)

test("octiles never draws outside a small screen", function()
  oc.width, oc.height = 44, 14
  oc.reset()

  -- gpu.set asserts on an out-of-bounds row, so crashing here means it drew off
  -- the edge of a display smaller than the default board
  local ok, reason = oc.run("octiles")
  check(ok, "octiles drew outside a small screen: " .. tostring(reason))

  oc.width, oc.height = 80, 20
  oc.reset()
end)

test("octiles repaints without clearing the screen every frame", function()
  oc.push()
  oc.push()
  oc.push()

  oc.run("octiles")
  local full = 0
  for _, fill in ipairs(oc.fills) do
    if fill.w >= oc.width and fill.h >= oc.height then
      full = full + 1
    end
  end
  check(full <= 1, "cleared the whole screen " .. full .. " times over four frames")
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

test("ocdump --net writes down what the network answered", function()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { INTERNET, modem }
  startMinitel("tablet")
  oc.respond = function()
    return 201, "Created", "https://dpaste.com/TESTTESTT\n"
  end

  deliver(modem, "bb000000", "tablet", "boiler-room", answerOf({
    address = "aa000000-0000-0000-0000-000000000001",
    cards = {
      {
        name = "Super Tank",
        status = "idle",
        gauges = { { label = "Bio Diesel", current = "42,000", maximum = "4,000,000",
          unit = "L", percent = 1.05 } },
      },
    },
    alerts = { { name = "diesel low", tripped = true } },
    fluids = { { name = "Creosote", amount = "12,000" } },
  }))
  deliver(modem, "bb000000", "tablet", "boiler-room", "ocgateway!")

  local ok, reason = oc.run("ocdump", "--net")
  check(ok, "ocdump crashed: " .. tostring(reason))
  check(#oc.requests == 1, "expected exactly one upload")

  local body = oc.requests[1].body
  check(contains(body, "== network =="), "no network section")
  check(contains(body, "hostname    tablet"), "did not name this machine")
  check(contains(body, "minitel     running"), "did not report the daemon")
  check(contains(body, modem.address:sub(1, 8)), "did not list the card")
  check(contains(body, "boiler-room"), "did not name the satellite that answered")
  check(contains(body, "Super Tank"), "did not write down the machine it reported")
  check(contains(body, "Bio Diesel"), "did not write down the gauge")
  check(contains(body, "42,000"), "did not write down the reading")
  check(contains(body, "diesel low"), "did not write down the alert")
  check(contains(body, "Creosote"), "did not write down the fluid")
  check(contains(body, "who can reach the internet"), "never asked for a gateway")

  local asked = false
  for _, packet in ipairs(outbound(modem)) do
    if packet.data == "ocstatus?" and packet.dest == "~" then
      asked = true
    end
  end
  check(asked, "never broadcast the question")
  if show then
    say(body)
  end
end)

test("ocdump --net says a peer went unanswered", function()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { INTERNET, modem }
  oc.files["/etc/ocgt.cfg"] = "{peers={\"tank-farm\"}}"
  startMinitel("tablet")
  oc.respond = function()
    return 201, "Created", "https://dpaste.com/TESTTESTT\n"
  end

  oc.run("ocdump", "--net")
  local body = oc.requests[1].body
  check(body:find("tank%-farm%s+no answer") ~= nil,
    "a satellite that stayed quiet was not named as quiet")
end)

test("ocdump --net reports a network it cannot use", function()
  -- no card at all, which is what a machine that was never on the mesh looks
  -- like. The dump is still worth having, so it is still written and uploaded.
  oc.components = { INTERNET }
  oc.respond = function()
    return 201, "Created", "https://dpaste.com/TESTTESTT\n"
  end

  local ok, reason = oc.run("ocdump", "--net")
  check(ok, "ocdump crashed with no network card: " .. tostring(reason))

  local body = oc.requests[1].body
  check(contains(body, "== network =="), "no network section")
  check(contains(body, "no network card"), "did not say why the network was unusable")
  check(contains(body, "only ever a relay"), "did not say there were no cards")
end)

test("ocdump refuses an argument it does not know", function()
  oc.components = { INTERNET }

  oc.run("ocdump", "--network")
  check(contains(oc.printed(), "unknown argument --network"),
    "a mistyped flag quietly dumped without the network")
  check(#oc.requests == 0, "uploaded anyway")
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
-- ocitems

-- a proxy entry that does something with what it is handed, which the plain
-- proxyMethod cannot: the builder is told an id before it is asked to build
local function proxyCall(name, work)
  return setmetatable({ name = name }, {
    __call = function(_, ...)
      return work(...)
    end,
    __tostring = function()
      return "function():" .. name
    end,
  })
end

-- Shaped like a real request pipe. getAvailableItems answers with one Pair an
-- item, whose getValue2 is the count and whose getValue1 is the ItemIdentifier
-- the name has to be read from. getItemAmount answers about one item, named by
-- an identifier the builder makes out of two numbers -- and answers 0 for a
-- tagged item, as the real one does, since two numbers do not say which variant
-- is meant.
local function requestPipe(stock, tally)
  tally = tally or {}
  tally.names, tally.reads, tally.counts = 0, 0, 0

  local stacks, byKey = {}, {}
  for index, entry in ipairs(stock) do
    entry.itemId = entry.itemId or (1000 + index)
    entry.itemData = entry.itemData or 0
    byKey[entry.itemId .. ":" .. entry.itemData] = entry

    -- read live, so a test can move the world under a running program
    local identifier = {
      type = "userdata",
      getName = proxyCall("getName", function() return entry.name end),
      getId = proxyCall("getId", function() return entry.itemId end),
      getData = proxyCall("getData", function() return entry.itemData end),
      hasTagCompound = proxyCall("hasTagCompound", function()
        return entry.tagged == true
      end),
      isDamageable = proxyCall("isDamageable", function()
        return entry.damaged == true
      end),
    }
    stacks[index] = {
      type = "userdata",
      getValue2 = proxyCall("getValue2", function()
        return entry.later or entry.amount
      end),
      getValue1 = proxyCall("getValue1", function()
        tally.names = tally.names + 1
        return identifier
      end),
    }
  end

  local building = {}
  local builder = {
    type = "userdata",
    setItemID = proxyCall("setItemID", function(value) building.itemId = value end),
    setItemData = proxyCall("setItemData", function(value) building.itemData = value end),
    build = proxyCall("build", function()
      return { type = "userdata",
        key = tostring(building.itemId) .. ":" .. tostring(building.itemData) }
    end),
  }

  return {
    address = "96cdfbc3-11fa-462f-adf2-2599720fbb33",
    kind = "logisticspipe",
    methods = { getPipe = "function():table" },
    values = {
      getPipe = function()
        return {
          type = "userdata",
          getRouterId = proxyMethod("getRouterId", 7),
          getLP = proxyMethod("getLP", {
            type = "userdata",
            getItemIdentifierBuilder = proxyMethod("getItemIdentifierBuilder", builder),
          }),
          -- a fresh list every call, as the real one hands back: the reader
          -- blanks entries as it lets them go, and the world does not lose them
          getAvailableItems = proxyCall("getAvailableItems", function()
            tally.reads = tally.reads + 1
            local fresh = {}
            for index, stack in ipairs(stacks) do
              fresh[index] = stack
            end
            return fresh
          end),
          getItemAmount = proxyCall("getItemAmount", function(id)
            tally.counts = tally.counts + 1
            local entry = byKey[id and id.key or ""]
            if not entry or entry.tagged then
              return 0
            end
            -- what the world holds now, which is not what the scan saw
            return entry.later or entry.amount
          end),
        }
      end,
    },
  }
end

test("ocitems lists the network with the most plentiful first", function()
  oc.width, oc.height = 160, 30
  oc.reset()
  oc.components = { requestPipe({
    { name = "Nickel Ingot", amount = 2182 },
    { name = "Cobblestone", amount = 22742 },
    { name = "Redstone", amount = 4094 },
  }) }

  local ok, reason = oc.run("ocitems")
  check(ok, "ocitems crashed: " .. tostring(reason))

  local frame = oc.frame()
  check(contains(frame, "Cobblestone"), "did not name what is in the network")
  check(contains(frame, "22,742"), "did not group a count into something readable")
  check(contains(frame, "3 items in the network"), "did not say how many there are")

  local most, next = frame:find("Cobblestone"), frame:find("Redstone")
  check(most and next and most < next, "did not put the most plentiful first")
  if show then
    say(frame)
  end
end)

-- Reading the whole network already costs most of the memory the computer has,
-- and every name read costs more that does not come back. Naming everything is
-- what ended the computer, so how many are named is what is left over divided
-- by what one costs, and a bigger machine simply holds more.
test("ocitems names as many items as the memory allows, and no more", function()
  oc.width, oc.height = 160, 30
  local stock = {}
  for index = 1, 4000 do
    stock[index] = { name = "thing " .. index, amount = index }
  end

  local named = {}
  for _, free in ipairs({ 600 * 1024, 3400 * 1024 }) do
    oc.reset()
    local tally = {}
    oc.components = { requestPipe(stock, tally) }
    oc.freeMemory = free

    local ok, reason = oc.run("ocitems")
    check(ok, "ocitems crashed: " .. tostring(reason))
    named[#named + 1] = tally.names

    local frame = oc.frame()
    check(contains(frame, "4,000 items in the network"), "lost the count")
    check(contains(frame, "thing 4000"), "did not name the one there is most of")
  end

  check(named[1] < 4000, "a machine short of memory named the whole network")
  check(named[2] > named[1] * 2, "a machine with room for more named "
    .. named[2] .. " against " .. named[1])
end)

-- Take 20 ingots out and it has to say 20. Scaling the figure to the window it
-- was measured over reported that withdrawal as 18, because the window had run
-- 200 seconds rather than 180, and it was the one number anybody could check.
test("an item reports what actually moved, on the reading that sees it", function()
  local lplib = require("oclogistics")
  local item = {}

  lplib.mark(item, 100, 1000)
  check(item.rate == nil, "claimed movement from a single reading")

  lplib.mark(item, 80, 1005)
  check(item.rate == -20, "reported " .. tostring(item.rate) .. ", not the 20 taken")
  check(item.amount == 80, "did not keep the count itself current")

  -- it adds up as it goes rather than waiting for a window to run out
  lplib.mark(item, 60, 1010)
  check(item.rate == -40, "did not add the second withdrawal on")

  -- a reading that changes nothing leaves it standing
  lplib.mark(item, 60, 1100)
  check(item.rate == -40, "forgot what moved while nothing was moving")

  -- and three quiet minutes clear it: it is what moved lately or it is nothing
  lplib.mark(item, 60, 1200)
  check(item.rate == 0, "still reporting movement three minutes after it stopped")

  -- a stock that moves all day reports what it did lately, not its whole life
  local steady = {}
  lplib.mark(steady, 0, 2000)
  lplib.mark(steady, 10, 2010)
  lplib.mark(steady, 20, 2100)
  check(steady.rate == 20, "lost track inside the window")
  lplib.mark(steady, 30, 2300)
  check(steady.rate == 10, "went on adding up past the window it names")
end)

-- Reading the names is nearly all of what a read costs, so a read can be taken
-- as counts alone against the names an earlier one established. That leans on
-- the network answering in the same order, so it is checked rather than assumed.
test("a read can be taken as counts alone, and is checked before it is", function()
  oc.reset()
  local lplib = require("oclogistics")
  local stock = {
    { name = "Cobblestone", amount = 100 },
    { name = "Redstone", amount = 50 },
  }
  oc.components = { requestPipe(stock) }

  local proxy = lplib.requestPipe()
  local items, total = lplib.available(proxy)
  check(#items == 2 and items[1].name == "Cobblestone", "did not read the list")

  stock[1].amount = 80
  check(lplib.recount(proxy, items, total, 2000), "would not take the counts")
  check(items[1].amount == 80 and items[1].rate == -20,
    "took the counts but not what they mean")

  -- a list that is not the length it was is a list whose positions have moved
  check(not lplib.recount(proxy, items, total + 1, 2100),
    "believed a read whose total had moved")

  -- and so is one where a position no longer holds what it held
  stock[1].itemId = 4242
  check(not lplib.recount(proxy, items, total, 2200),
    "believed a read that had been reordered underneath it")
end)

test("only what is moving is worth a place, gains first", function()
  local lplib = require("oclogistics")
  local items = {}
  for index = 1, 20 do
    items[index] = { name = "up " .. index, rate = index }
  end
  for index = 1, 20 do
    items[#items + 1] = { name = "down " .. index, rate = -index }
  end
  items[#items + 1] = { name = "still", rate = 0 }
  items[#items + 1] = { name = "never counted" }

  local few = lplib.movers(items, 3)
  check(#few == 6, "kept " .. #few .. " of them, not six")
  check(few[1].name == "up 20", "did not put the biggest gain first")
  check(few[6].name == "down 20", "did not put the biggest loss last")
  for _, item in ipairs(few) do
    check(item.name ~= "still" and item.name ~= "never counted",
      "made room for " .. item.name .. ", which is not moving")
  end
end)

-- A tool wears out and an enchantment is a tag, so one pair of golden boots
-- arrives as a dozen entries and an enchanted book as dozens more. None of them
-- is a stock anybody keeps tabs on, and they crowd out the ones that are.
test("a worn tool and an enchanted book are not stocks", function()
  oc.reset()
  local lplib = require("oclogistics")
  oc.components = { requestPipe({
    { name = "Cobblestone", amount = 22742 },
    { name = "Golden Boots", amount = 3, damaged = true },
    { name = "Enchanted Book", amount = 12, tagged = true },
    { name = "Red Wool", amount = 64, itemData = 14 },
  }) }

  local proxy = lplib.requestPipe()
  local items = lplib.available(proxy)
  local kept = {}
  for _, item in ipairs(items) do
    kept[item.name] = true
  end

  check(kept["Cobblestone"], "dropped a stock worth watching")
  -- a meta variant that is a real item is neither damageable nor tagged
  check(kept["Red Wool"], "dropped a colour, which is a different item")
  check(not kept["Golden Boots"], "kept a tool, which is one thing somebody has")
  check(not kept["Enchanted Book"], "kept an enchantment")
end)

-- computer.freeMemory() reports what has not been collected, not what is gone,
-- and nothing in this sandbox makes the collector run. Believing the low figure
-- is what left a server naming 158 items of 1,596 and calling itself full.
test("memory that has only not been collected yet is asked for back", function()
  oc.reset()
  local lplib = require("oclogistics")
  -- the fake answers what it is told to; what matters is that asking happens at
  -- all, and that the answer is the figure taken afterwards
  oc.freeMemory = 90 * 1024
  local before = require("computer").freeMemory()
  oc.freeMemory = 1800 * 1024
  local after = lplib.reclaim()

  check(before < after, "took the first figure for the last word")
  check(after == 1800 * 1024, "did not answer with what there was after asking")
end)

test("a fresh read keeps the windows a rate is being measured over", function()
  local lplib = require("oclogistics")
  local items = { { key = "4:0", name = "Cobblestone",
    amount = 100, was = 100, when = 1000 } }
  local fresh = {
    { key = "4:0", name = "Cobblestone", amount = 700 },
    { key = "9:1", name = "Redstone", amount = 5 },
  }

  local merged = lplib.merge(items, fresh, 1180)
  check(#merged == 2, "folded the read into " .. #merged .. " items, not two")
  check(merged[1].rate == 600, "threw away a window that was minutes old")
  check(merged[2].name == "Redstone" and merged[2].rate == nil,
    "claimed movement for an item it has only ever seen once")

  -- and what the network no longer has does not linger
  local after = lplib.merge(merged, { fresh[2] }, 1200)
  check(#after == 1 and after[1].name == "Redstone", "kept an item that is gone")
end)

-- One read is every count at once and finds items nobody has ever had. Counting
-- an item at a time is a server tick each. So the memory decides which way round
-- a machine refreshes, and one with room for the read uses it.
test("ocitems reads the network again when it has the room for it", function()
  oc.width, oc.height = 160, 30
  local stock = {
    { name = "Cobblestone", amount = 22742 },
    { name = "Redstone", amount = 4094 },
  }

  local reads = {}
  for _, free in ipairs({ 300 * 1024, 3000 * 1024 }) do
    oc.reset()
    local tally = {}
    oc.components = { requestPipe(stock, tally) }
    oc.freeMemory = free
    -- long enough for the clock to pass a re-read
    oc.idle = 700

    local ok, reason = oc.run("ocitems")
    check(ok, "ocitems crashed: " .. tostring(reason))
    reads[#reads + 1] = tally.reads
  end

  check(reads[1] == 1, "read the whole network " .. reads[1]
    .. " times with no memory for it")
  check(reads[2] > 1, "never read the network again on a machine with room")
end)

test("ocitems answers for the network it is watching", function()
  oc.width, oc.height = 160, 30
  oc.reset()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000003", true)
  oc.components = { modem,
    requestPipe({ { name = "Cobblestone", amount = 22742 } }) }
  startMinitel("store-room")
  deliver(modem, "bb000000", "store-room", "tablet", "ocstatus?")

  local ok, reason = oc.run("ocitems")
  check(ok, "ocitems crashed: " .. tostring(reason))
  oc.pump()

  local reply = firstReply(modem)
  check(reply ~= nil, "no answer went out")
  check(reply and reply.dest == "tablet", "answered somebody else")
  check(contains(oc.frame(), "answering for it"), "did not say it is answering")
end)

-- Reading the whole network is the one expensive thing this program can do, so
-- once it is done the counts are kept current an item at a time instead.
test("ocitems keeps the counts current without reading the network again", function()
  oc.width, oc.height = 160, 30
  oc.reset()
  local tally = {}
  oc.components = { requestPipe({
    { name = "Cobblestone", amount = 100, later = 9000 },
    { name = "Redstone", amount = 4094 },
    { name = "Dirt", amount = 200 },
  }, tally) }
  oc.idle = 3

  local ok, reason = oc.run("ocitems")
  check(ok, "ocitems crashed: " .. tostring(reason))
  check(tally.reads == 1, "read the whole network " .. tally.reads .. " times")
  check(tally.counts >= 3, "counted only " .. tally.counts .. " items")

  local frame = oc.frame()
  check(contains(frame, "9,000"), "did not take the new count")
  local most, next = frame:find("Cobblestone"), frame:find("Redstone")
  check(most and next and most < next, "did not settle the order after a pass")
end)

test("ocitems starts from what it wrote down, and asks the network nothing", function()
  oc.width, oc.height = 160, 30
  oc.reset()
  oc.components = { requestPipe({
    { name = "Cobblestone", amount = 22742 },
    { name = "Redstone", amount = 4094 },
  }) }
  oc.run("ocitems")

  local written = oc.files["/etc/ocitems.cache"]
  check(written and contains(written, "Cobblestone"), "wrote nothing down")

  local tally = {}
  oc.reset()
  oc.files["/etc/ocitems.cache"] = written
  oc.components = { requestPipe({
    { name = "Cobblestone", amount = 22742 },
    { name = "Redstone", amount = 4094 },
  }, tally) }

  local ok, reason = oc.run("ocitems")
  check(ok, "ocitems crashed: " .. tostring(reason))
  check(tally.reads == 0, "read the network anyway, " .. tally.reads .. " times")
  check(contains(oc.frame(), "22,742"), "did not show what it wrote down")
end)

-- Asking for the whole network without the memory for it does not fail the
-- call. It ends the computer.
test("reading the network again is refused when the memory is not there", function()
  oc.width, oc.height = 160, 30
  oc.reset()
  local tally = {}
  oc.components = { requestPipe({ { name = "Cobblestone", amount = 22742 } }, tally) }
  oc.freeMemory = 200 * 1024
  oc.push("key_down", "keyboard", 0, 0x13) -- r

  oc.run("ocitems")
  check(tally.reads == 1, "read the network with no room for it")
  check(contains(oc.frame(), "not enough memory"), "did not say why it refused")

  oc.reset()
  tally = {}
  oc.components = { requestPipe({ { name = "Cobblestone", amount = 22742 } }, tally) }
  oc.freeMemory = 4 * 1024 * 1024
  oc.push("key_down", "keyboard", 0, 0x13)

  oc.run("ocitems")
  check(tally.reads == 2, "would not read the network with room to spare")
end)

test("ocitems tells a basic pipe from the request pipe it needs", function()
  local written = { value = false }
  oc.width, oc.height = 160, 30
  oc.reset()
  oc.components = { logisticsPipe(written) }

  oc.run("ocitems")
  check(contains(oc.frame(), "no request pipe attached"),
    "took a pipe that cannot see the network for one that can")
  check(written.value == false, "called a method that writes")
end)

test("ocitems says so when no pipe is attached", function()
  oc.reset()
  oc.components = {}
  oc.run("ocitems")
  check(contains(oc.frame(), "no Logistics Pipe attached"), "did not say the list was empty")
end)

-- A computer with nothing configured has no row to select: both sections of the
-- editor are empty, so every row is a heading. Reading that as "the user asked
-- to leave" made adding the very first machine quit to the shell.
test("the first machine can be added on a computer with nothing configured", function()
  oc.width, oc.height = 160, 50
  oc.reset()
  local reader = transposer(3, 12000)
  oc.components = { reader }

  local function press(code)
    oc.push("key_down", "keyboard", 0, code)
  end
  press(0x32)   -- m, watch a machine
  press(0x1C)   -- enter, take the transposer
  press(0x1C)   -- enter, take the side its tank is on
  press(0x10)   -- q, done

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))

  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  local watch = saved and saved.watch or {}
  check(#watch == 1, "watching " .. #watch .. " machines after adding one")
  check(watch[1] and watch[1].side == 3, "did not record which face the tank is on")
  -- and it should have gone on to draw the dashboard rather than exiting
  check(contains(oc.frame(), "Creosote Oil"), "never reached the dashboard")
end)

test("ocdebug shows the tanks around a transposer, not just the transposer", function()
  oc.width, oc.height = 160, 40
  oc.reset()
  oc.components = { transposer(3, 12000) }

  local ok, reason = oc.run("ocdebug")
  check(ok, "ocdebug crashed: " .. tostring(reason))

  local frame = oc.frame()
  -- the transposer is a way of reaching a block that has no component of its
  -- own, so the tank is the thing worth seeing
  check(contains(frame, "south"), "did not say which face the tank is on")
  check(contains(frame, "Creosote Oil"), "did not name the fluid behind it")
  check(contains(frame, "12,000 / 64,000"), "did not show the level")
end)

-- A transposer can only say how much is in a pipe, so how fast that changes is
-- the one usage signal it can give. True throughput needs the pipe's own sensor
-- through an adapter, where GregTech reports it the way a cable reports amps.
test("a gauge says which way it is going and how fast", function()
  oc.width, oc.height = 160, 50
  oc.reset()

  local level = 19200
  local pipe = {
    address = "5150000e-0000-0000-0000-000000000001",
    kind = "transposer",
    methods = { getTankCount = "f", getFluidInTank = "f" },
    values = {
      getTankCount = function(side)
        if side == 3 then
          return 1
        end
        return 0
      end,
      getFluidInTank = function(side)
        if side ~= 3 then
          return {}
        end
        -- a pipe being drained faster than it is filled
        level = level - 640
        return { { name = "steam", label = "Steam",
          amount = level, capacity = 19200 } }
      end,
    },
  }
  oc.components = { pipe }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = { [pipe.address .. "/3"] = "S1" },
    watch = { { address = pipe.address, side = 3, hidden = {} } },
    alerts = {},
  })

  -- A rate is averaged across half a minute, and the fake clock only moves when
  -- an event is pulled, so this is how that half minute passes.
  for _ = 1, 400 do
    oc.push("nothing in particular")
  end
  oc.run("ocwatch")

  local frame = oc.frame()
  check(contains(frame, "S1"), "did not use the nickname given to the face")
  check(frame:find("%-%d[%d,]* L/s") ~= nil, "no rate on a falling gauge: " ..
    (frame:match("Steam[^\n]*") or "no steam row"))
end)

test("a fluid keeps its colour on the tablet watching the dashboard", function()
  oc.components = {}
  local net = require("ocnet")
  local report = net.report({ alerts = {} }, { {
    entry = {},
    name = "S1",
    readings = { { kind = "gauge", label = "Steam", value = 12000, max = 19200,
      current = "12,000", maximum = "19,200", unit = "L", colorCode = "f" } },
  } })

  local gauge = report.cards[1].gauges[1]
  -- ocview drew every bar green because the colour never left the satellite
  check(gauge.colorCode == "f", "the colour did not travel: " .. tostring(gauge.colorCode))
end)

-- Machines get named S1 and EBF2, and the older rule threw away any sensor line
-- with a digit in it, so every one of those lost its name.
test("a machine named with a number keeps its name", function()
  oc.components = {}
  local gtlib = require("ocgt")
  check(gtlib.looksLikeName("\194\1679EBF1\194\167r"), "EBF1 was not taken as a name")
  check(gtlib.looksLikeName("\194\1679S3\194\167r"), "S3 was not taken as a name")
  check(gtlib.looksLikeName("\194\1679Super Tank\194\167r"), "a plain name was lost")

  -- and a reading is still not a name, coloured or not
  check(not gtlib.looksLikeName("Progress: \194\167a0\194\167r s / \194\167e0\194\167r s"),
    "a coloured reading was taken as a name")
  check(not gtlib.looksLikeName("Average input: 0 EU/t"),
    "an uncoloured reading was taken as a name")
  check(not gtlib.looksLikeName("  "), "blank text was taken as a name")
end)

-- Three steam pipes belong under the steam tank, not as three cards of their
-- own. A compact machine draws as one line with no bar, and the order of the
-- watch list is what puts it under the card it belongs to.
local function steamPipe(address, amount)
  return {
    address = address,
    kind = "transposer",
    methods = { getTankCount = "f", getFluidInTank = "f" },
    values = {
      getTankCount = function(side)
        if side == 3 then
          return 1
        end
        return 0
      end,
      getFluidInTank = function(side)
        if side ~= 3 then
          return {}
        end
        return { { name = "steam", label = "Steam",
          amount = amount, capacity = 19200 } }
      end,
    },
  }
end

test("a compact machine draws as one line under the card above it", function()
  oc.width, oc.height = 140, 30
  oc.reset()
  local tank = tankAt("2,400,000")
  local one = steamPipe("11110000-0000-0000-0000-000000000001", 17920)
  local two = steamPipe("22220000-0000-0000-0000-000000000002", 12800)
  oc.components = { tank, one, two }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = {
      [tank.address] = "Steam Tank",
      [one.address .. "/3"] = "S1",
      [two.address .. "/3"] = "S2",
    },
    watch = {
      { address = tank.address, hidden = {} },
      { address = one.address, side = 3, hidden = {}, compact = true },
      { address = two.address, side = 3, hidden = {}, compact = true },
    },
    alerts = {},
  })

  oc.run("ocwatch")
  local frame = oc.frame()
  check(contains(frame, "Steam Tank"), "lost the machine it groups under")
  check(contains(frame, "S1"), "lost the first pipe")
  check(contains(frame, "S2"), "lost the second pipe")
  check(contains(frame, "17,920 / 19,200 L"), "a compact line lost its numbers")
  -- one bar for the tank, and none for the pipes under it
  local bars = select(2, frame:gsub("\226\150\136", ""))
  local tankRow = frame:match("[^\n]*2,400,000[^\n]*") or ""
  check(bars > 0 and select(2, tankRow:gsub("\226\150\136", "")) == bars,
    "a compact machine drew a bar")
end)

test("the watch list can be reordered", function()
  oc.width, oc.height = 140, 30
  oc.reset()
  local tank = tankAt("100000")
  local pipe = steamPipe("11110000-0000-0000-0000-000000000001", 17920)
  oc.components = { tank, pipe }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = {
      { address = pipe.address, side = 3, hidden = {} },
      { address = tank.address, hidden = {} },
    },
    alerts = {},
  })

  local function press(code)
    oc.push("key_down", "keyboard", 0, code)
  end
  press(0xD0)   -- down, onto the second machine
  press(0xC9)   -- page up, move it above the first
  press(0x10)   -- q, done

  oc.run("ocwatch", "--edit")
  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  local first = saved and saved.watch and saved.watch[1]
  check(first and first.address == tank.address,
    "the order on the dashboard cannot be changed, so nothing can be grouped")
end)

test("ocview keeps the numbers when the name of a reading will not fit", function()
  oc.width, oc.height = 80, 20
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  startMinitel("tablet")
  deliver(modem, "bb000000", "tablet", "satellite-1", answerOf({
    cards = { { name = "Super Tank", status = "idle", gauges = {
      { label = "Bio Diesel", current = "42,000", maximum = "4,000,000",
        unit = "L", percent = 1.05 } } } },
    alerts = {},
  }))

  oc.run("ocview", "--once")
  local frame = oc.screen()
  -- a truncated number is worse than no label at all
  check(contains(frame, "42,000 / 4,000,000 L"), "cut the numbers short")
end)

test("ocview groups a satellite into its own column", function()
  oc.width, oc.height = 160, 30
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  startMinitel("tablet")
  local function payload(name)
    return answerOf({
      cards = { { name = name, gauges = { { label = "Steam", current = "1",
        maximum = "2", unit = "L", percent = 50 } } } },
      alerts = {},
    })
  end
  deliver(modem, "bb000000", "tablet", "boiler-room", payload("EBF1"))
  deliver(modem, "dd000000", "tablet", "tank-farm", payload("Super Tank"))

  oc.run("ocview", "--once")
  local frame = oc.screen()
  -- side by side, not one under the other, or a wide screen shows a narrow strip
  local row = frame:match("[^\n]*boiler%-room[^\n]*") or ""
  check(row:find("tank%-farm") ~= nil, "the second satellite is not beside the first")
end)

-------------------------------------------------------------------------------
-- notification channels

local function alarmBlock(calls)
  return {
    address = "a1a70000-0000-0000-0000-000000000002",
    kind = "os_alarm",
    methods = { activate = "f", deactivate = "f", setAlarm = "f", listSounds = "f" },
    values = {
      activate = function()
        calls[#calls + 1] = "activate"
        return "Ok"
      end,
      deactivate = function()
        calls[#calls + 1] = "deactivate"
        return "Ok"
      end,
      setAlarm = function(sound)
        calls[#calls + 1] = "sound:" .. tostring(sound)
        return sound
      end,
    },
  }
end

local function lampBlock(colors)
  return {
    address = "1a300000-0000-0000-0000-000000000002",
    kind = "colorful_lamp",
    methods = { setLampColor = "f", getLampColor = "f" },
    values = {
      setLampColor = function(color)
        colors[#colors + 1] = color
        return true
      end,
    },
  }
end

local function chatBlock(said)
  return {
    address = "c8a70000-0000-0000-0000-000000000002",
    kind = "chat_box",
    methods = { say = "f" },
    values = {
      say = function(text)
        said[#said + 1] = text
        return true
      end,
    },
  }
end

-- A lamp, a siren and a line in chat are not alternatives to each other: they
-- do different jobs, in different rooms, at the same time.
test("every channel that is on carries the alert", function()
  local said, colors, calls = {}, {}, {}
  local tank = tankAt("100")
  oc.components = { tank, chatBlock(said), lampBlock(colors), alarmBlock(calls) }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = tank.address, hidden = {} } },
    alerts = { { name = "diesel low", address = tank.address,
      label = "Bio Diesel", below = 50000, above = 200000 } },
  })

  oc.run("ocwatch")
  check(#said == 1, "the chat box said " .. #said .. " things")
  check(#colors == 1 and colors[1] == 31 * 1024, "the lamp is not red")
  check(#calls >= 1 and calls[#calls] == "activate", "the siren did not sound")
end)

test("a channel that is switched off stays out of it", function()
  local said, colors, calls = {}, {}, {}
  local tank = tankAt("100")
  oc.components = { tank, chatBlock(said), lampBlock(colors), alarmBlock(calls) }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    -- the lamp is what this base likes; the siren is not
    notify = { siren = { on = false }, chat = { on = false } },
    watch = { { address = tank.address, hidden = {} } },
    alerts = { { name = "diesel low", address = tank.address,
      label = "Bio Diesel", below = 50000, above = 200000 } },
  })

  oc.run("ocwatch")
  check(#said == 0, "spoke on a channel that was switched off")
  check(#calls == 0, "sounded a siren that was switched off")
  check(#colors == 1, "switching one channel off silenced another")
end)

test("a lamp colour can be chosen", function()
  local colors = {}
  local tank = tankAt("100")
  oc.components = { tank, lampBlock(colors) }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    notify = { lamp = { on = true, tripped = "ff00ff" } },
    watch = { { address = tank.address, hidden = {} } },
    alerts = { { name = "diesel low", address = tank.address,
      label = "Bio Diesel", below = 50000, above = 200000 } },
  })

  oc.run("ocwatch")
  -- ff00ff packed into the five bits a channel the lamp takes
  check(colors[1] == 31 * 1024 + 31, "lit " .. tostring(colors[1]) .. ", not magenta")
end)

test("a siren is told it is over as well as that it started", function()
  oc.components = {}
  local notify = require("ocnotify")
  local calls = {}
  oc.components = { alarmBlock(calls) }

  notify.state({}, true)
  notify.state({}, false)
  -- an alarm never told the trouble ended goes on sounding
  check(calls[#calls] == "deactivate", "the siren was never stopped")
end)

-- Every action returns to the caller and comes straight back, so a cursor that
-- started at the top each time moved out from under whoever was pressing the
-- button: the second press moved a different machine.
test("moving a machine twice moves the same machine twice", function()
  oc.width, oc.height = 140, 30
  oc.reset()
  local tank = tankAt("100000")
  local one = steamPipe("11110000-0000-0000-0000-000000000001", 17920)
  local two = steamPipe("22220000-0000-0000-0000-000000000002", 12800)
  oc.components = { tank, one, two }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = {
      { address = one.address, side = 3, hidden = {} },
      { address = two.address, side = 3, hidden = {} },
      { address = tank.address, hidden = {} },
    },
    alerts = {},
  })

  local function press(code)
    oc.push("key_down", "keyboard", 0, code)
  end
  press(0xD0)   -- down, onto the second machine
  press(0xD0)   -- down, onto the third
  press(0xC9)   -- page up
  press(0xC9)   -- page up again, the same machine
  press(0x10)   -- q

  oc.run("ocwatch", "--edit")
  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  local watch = saved and saved.watch or {}
  check(watch[1] and watch[1].address == tank.address,
    "the second press moved something else: the tank is at position "
      .. (watch[2] and watch[2].address == tank.address and "2" or "3"))
end)

-------------------------------------------------------------------------------
-- ocup only fetches what changed

-- The manifest carries the version each file declares, so a copy already saying
-- the same thing is never downloaded to find out it was the same.
-- ocup is named at the version the file really is, so these stand for a
-- computer that is already current rather than one that is behind
local VERSIONED = table.concat({
  "lib/oclib.lua 0.1.0",
  "lib/ocgt.lua 0.1.0",
  "lib/oclogistics.lua 0.1.0",
  "programs/ocup.lua " .. declaredVersion("programs/ocup.lua"),
  "programs/ocdebug.lua 0.2.0",
  "programs/ocdump.lua 0.1.0",
}, "\n")

local function fetched()
  local paths = {}
  for _, request in ipairs(oc.requests) do
    local path = request.url:match("[^/]+%.lua")
    if path then
      paths[#paths + 1] = path
    end
  end
  return table.concat(paths, ",")
end

test("ocup does not fetch a file whose version it already has", function()
  oc.components = { INTERNET }
  -- everything already installed at the version the manifest names
  oc.files["/bin/ocup.lua"] = program(declaredVersion("programs/ocup.lua"))
  oc.files["/bin/ocdebug.lua"] = program("0.2.0")
  oc.files["/bin/ocdump.lua"] = program("0.1.0")
  oc.files["/lib/oclib.lua"] = program("0.1.0")
  oc.files["/lib/ocgt.lua"] = program("0.1.0")
  oc.files["/lib/oclogistics.lua"] = program("0.1.0")
  oc.respond = serveProgram({
    ["versions.txt"] = VERSIONED,
    ["programs/ocup.lua"] = program("0.3.0"),
    ["programs/ocdebug.lua"] = program("0.2.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
  })

  local ok, reason = oc.run("ocup")
  check(ok, "ocup crashed: " .. tostring(reason))
  -- the commit and the manifest, and nothing else
  check(fetched() == "", "downloaded " .. fetched())
  check(contains(oc.printed(), "up to date"), "did not say it was up to date")
end)

test("ocup fetches the one file whose version moved", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocup.lua"] = program(declaredVersion("programs/ocup.lua"))
  oc.files["/bin/ocdebug.lua"] = program("0.1.0") -- behind the manifest
  oc.files["/bin/ocdump.lua"] = program("0.1.0")
  oc.files["/lib/oclib.lua"] = program("0.1.0")
  oc.files["/lib/ocgt.lua"] = program("0.1.0")
  oc.files["/lib/oclogistics.lua"] = program("0.1.0")
  oc.respond = serveProgram({
    ["versions.txt"] = VERSIONED,
    ["programs/ocup.lua"] = program(declaredVersion("programs/ocup.lua")),
    ["programs/ocdebug.lua"] = program("0.2.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
  })

  oc.run("ocup")
  check(fetched() == "ocdebug.lua", "downloaded " .. fetched())
  check(oc.files["/bin/ocdebug.lua"] == program("0.2.0"), "did not install the new one")
end)

test("ocup still fetches everything when the manifest names no versions", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocdebug.lua"] = program("0.2.0")
  oc.respond = serveEverything()

  oc.run("ocup")
  -- a manifest written before versions were in it has to keep working
  check(fetched():find("ocdebug%.lua") ~= nil, "skipped a file it could not compare")
end)

test("versions.txt says the version every file declares", function()
  local wrong = {}
  for line in io.lines("versions.txt") do
    local path, stated, size = line:match("^%s*(%S+)%s+([^:%s]+):(%d+)%s*$")
    if not path then
      wrong[#wrong + 1] = "not a path and one word of version:size: " .. line
    else
      local text = contentsOf(path)
      local declared = text and text:match('VERSION%s*=%s*"([^"]+)"')
      if declared ~= stated then
        wrong[#wrong + 1] = path .. " says " .. tostring(declared)
          .. ", versions.txt says " .. stated
      elseif text and #text ~= tonumber(size) then
        wrong[#wrong + 1] = path .. " is " .. #text
          .. " bytes, versions.txt says " .. size
      end
    end
  end
  -- ocup trusts this to decide what to download, so a stale line here means a
  -- file that never updates. Run: nix develop -c lua machine/manifest.lua
  check(#wrong == 0, table.concat(wrong, "; "))
end)

-- An older ocup takes one path a line and skips any line with more on it, so a
-- version put beside the path made every line unreadable and the manifest look
-- empty. An ocup that cannot read the manifest cannot update itself out of it.
test("manifest.txt stays readable by an ocup that knows nothing of versions", function()
  local lines = 0
  for line in io.lines("manifest.txt") do
    lines = lines + 1
    local only = line:match("^%s*(%S+)%s*$")
    check(only ~= nil, "a line an older ocup would skip: " .. line)
  end
  check(lines > 0, "the manifest is empty")
end)

test("manifest.txt and versions.txt name the same files", function()
  local paths, versioned = {}, {}
  for line in io.lines("manifest.txt") do
    local path = line:match("^%s*(%S+)%s*$")
    if path then
      paths[#paths + 1] = path
    end
  end
  for line in io.lines("versions.txt") do
    local path = line:match("^%s*(%S+)%s+%S+%s*$")
    if path then
      versioned[#versioned + 1] = path
    end
  end
  check(table.concat(paths, ",") == table.concat(versioned, ","),
    "the two lists have drifted apart: run nix develop -c lua machine/manifest.lua")
end)

test("a rate is averaged over long enough to be readable", function()
  oc.width, oc.height = 140, 30
  oc.reset()
  local level = 19200
  local pipe = {
    address = "5150000e-0000-0000-0000-000000000002",
    kind = "transposer",
    methods = { getTankCount = "f", getFluidInTank = "f" },
    values = {
      getTankCount = function(side)
        if side == 3 then
          return 1
        end
        return 0
      end,
      getFluidInTank = function(side)
        if side ~= 3 then
          return {}
        end
        level = level - 100
        return { { name = "steam", label = "Steam",
          amount = level, capacity = 19200 } }
      end,
    },
  }
  oc.components = { pipe }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = pipe.address, side = 3, hidden = {} } },
    alerts = {},
  })

  -- a handful of seconds is not enough of a span to say anything with
  for _ = 1, 60 do
    oc.push("nothing in particular")
  end
  oc.run("ocwatch")
  check(oc.frame():find("L/s") == nil,
    "put a rate on screen before it had enough readings to mean one")
end)

test("ocview lights a lamp when a satellite reports a tripped alert", function()
  oc.width, oc.height = 120, 30
  oc.reset()
  local colors = {}
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem, lampBlock(colors) }
  startMinitel("tablet")
  deliver(modem, "bb000000", "tablet", "boiler-room", answerOf({
    cards = {},
    alerts = { { name = "diesel low", tripped = true } },
  }))

  oc.run("ocview", "--once")
  -- the screen is watching the whole base, so the lamp beside it should say so
  check(#colors > 0 and colors[#colors] == 31 * 1024,
    "the lamp ended " .. tostring(colors[#colors]) .. ", not red")
end)

-- A version alone is only as good as the discipline behind it. A library once
-- got rewritten and kept its number, so every computer went on running the old
-- one and crashed on a function that was no longer there.
test("ocup fetches a file whose bytes moved even when its version did not", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocup.lua"] = program(declaredVersion("programs/ocup.lua"))
  oc.files["/bin/ocdebug.lua"] = program("0.2.0")
  oc.files["/bin/ocdump.lua"] = program("0.1.0")
  oc.files["/lib/oclib.lua"] = program("0.1.0")
  oc.files["/lib/ocgt.lua"] = program("0.1.0")
  -- same version, different contents, which is what a rewrite looks like
  oc.files["/lib/oclogistics.lua"] = program("0.1.0") .. "-- and more besides\n"

  local sized = table.concat({
    "lib/oclib.lua 0.1.0:" .. #program("0.1.0"),
    "lib/ocgt.lua 0.1.0:" .. #program("0.1.0"),
    "lib/oclogistics.lua 0.1.0:" .. #program("0.1.0"),
    "programs/ocup.lua " .. declaredVersion("programs/ocup.lua") .. ":"
      .. #program(declaredVersion("programs/ocup.lua")),
    "programs/ocdebug.lua 0.2.0:" .. #program("0.2.0"),
    "programs/ocdump.lua 0.1.0:" .. #program("0.1.0"),
  }, "\n")

  oc.respond = serveProgram({
    ["versions.txt"] = sized,
    ["programs/ocup.lua"] = program(declaredVersion("programs/ocup.lua")),
    ["programs/ocdebug.lua"] = program("0.2.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
  })

  oc.run("ocup")
  check(fetched() == "oclogistics.lua", "downloaded " .. fetched())
  check(oc.files["/lib/oclogistics.lua"] == program("0.1.0"),
    "did not put the real one back")
end)

-- Twice now a new column in the manifest has made every line unreadable to the
-- ocup already installed, which then reports an empty manifest and stops: a
-- computer that cannot read the manifest cannot update itself out of it.
test("ocup reads a manifest with more on the line than it knows about", function()
  oc.components = { INTERNET }
  oc.respond = serveProgram({
    ["versions.txt"] = "programs/ocdebug.lua 0.2.0:120 sha256 whatever-comes-next",
    ["programs/ocdebug.lua"] = program("0.2.0"),
  })

  oc.run("ocup")
  check(oc.files["/bin/ocdebug.lua"] ~= nil,
    "a column it did not recognise stopped it")
end)

test("versions.txt keeps to one word after the path", function()
  for line in io.lines("versions.txt") do
    -- an older ocup takes exactly two words and reads the second as a version.
    -- It will not match, so it fetches the file, which is slow and right and
    -- ends with a newer ocup installed. Three words it cannot read at all.
    local path, rest = line:match("^%s*(%S+)%s+(%S+)%s*$")
    check(path ~= nil and rest ~= nil,
      "an older ocup cannot read this line: " .. line)
  end
end)

-- A bar says how full something is. Where the alert on it sits says how full it
-- has to get before anything happens, which is the other half of the question.
test("an alert threshold is marked on the bar", function()
  oc.width, oc.height = 160, 30
  oc.reset()
  local tank = tankAt("2,000,000")
  oc.components = { tank }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = tank.address, hidden = {} } },
    alerts = { { name = "diesel low", address = tank.address,
      label = "Bio Diesel", below = 1000000, above = 3000000, beep = false } },
  })

  oc.run("ocwatch")
  local row = oc.frame():match("[^\n]*Bio Diesel[^\n]*") or ""
  -- the mark sits inside the bar, not beside it
  check(row:find("\226\148\130") ~= nil, "no threshold marked on the bar: " .. row)
end)

test("the marks travel to the tablet with the reading", function()
  oc.components = {}
  local net = require("ocnet")
  local config = { alerts = { { name = "diesel low", label = "Bio Diesel",
    below = 1000000, above = 3000000 } } }
  local report = net.report(config, { {
    entry = {},
    name = "Super Tank",
    readings = { { kind = "gauge", label = "Bio Diesel", value = 2000000,
      max = 4000000, current = "2,000,000", maximum = "4,000,000", unit = "L" } },
  } })

  local marks = report.cards[1].gauges[1].marks
  check(marks ~= nil and #marks == 2, "sent " .. #(marks or {}) .. " marks")
  check(marks and marks[1] == 0.25, "the floor is at " .. tostring(marks and marks[1]))
end)

-- A pipe is drained by what is downstream and refilled from the tank, so what
-- is in it barely moves however much goes through. Adding up only the falls
-- measures what left, which is the usage of that one pipe.
test("a pipe can count only what leaves it", function()
  oc.width, oc.height = 140, 30
  oc.reset()
  local levels = { 19200, 18560, 19200, 18560, 19200, 18560, 19200, 18560 }
  local step = 0
  local pipe = {
    address = "5150000e-0000-0000-0000-000000000003",
    kind = "transposer",
    methods = { getTankCount = "f", getFluidInTank = "f" },
    values = {
      getTankCount = function(side)
        if side == 3 then
          return 1
        end
        return 0
      end,
      getFluidInTank = function(side)
        if side ~= 3 then
          return {}
        end
        step = step + 1
        return { { name = "steam", label = "Steam",
          amount = levels[(step - 1) % #levels + 1], capacity = 19200 } }
      end,
    },
  }
  oc.components = { pipe }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    nicknames = { [pipe.address .. "/3"] = "S1" },
    watch = { { address = pipe.address, side = 3, hidden = {}, usage = true } },
    alerts = {},
  })

  for _ = 1, 400 do
    oc.push("nothing in particular")
  end
  oc.run("ocwatch")

  -- the level ends where it began, so counting overall change says nothing at
  -- all, while counting what left says how much steam the pipe carried
  local row = oc.frame():match("[^\n]*Steam[^\n]*") or ""
  check(row:find("%-%d[%d,]* L/s") ~= nil, "no usage on a pipe that carried steam: " .. row)
end)

-- The version change is known the moment a file arrives, so the row says it
-- then rather than every row changing at once when the run finishes.
test("ocup shows what a file will do as soon as it has it", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocup.lua"] = program(declaredVersion("programs/ocup.lua"))
  oc.files["/bin/ocdebug.lua"] = program("0.1.0")
  oc.files["/bin/ocdump.lua"] = program("0.1.0")
  oc.files["/lib/oclib.lua"] = program("0.1.0")
  oc.files["/lib/ocgt.lua"] = program("0.1.0")
  oc.files["/lib/oclogistics.lua"] = program("0.1.0")
  oc.respond = serveProgram({
    ["versions.txt"] = VERSIONED,
    ["programs/ocup.lua"] = program(declaredVersion("programs/ocup.lua")),
    ["programs/ocdebug.lua"] = program("0.2.0"),
    ["programs/ocdump.lua"] = program("0.1.0"),
    ["lib/oclib.lua"] = program("0.1.0"),
    ["lib/ocgt.lua"] = program("0.1.0"),
    ["lib/oclogistics.lua"] = program("0.1.0"),
  })

  oc.run("ocup")
  local out = oc.printed()
  local ready = out:find("v0%.1%.0 %-> v0%.2%.0%s+ready")
  local updated = out:find("v0%.1%.0 %-> v0%.2%.0%s+updated")
  check(ready ~= nil, "the version change only appeared at the end")
  check(updated ~= nil, "never said it had installed it")
  check(ready < updated, "said it was installed before it had it")
end)

test("ocup leaves alone the rows that do not change", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocup.lua"] = program(declaredVersion("programs/ocup.lua"))
  oc.files["/bin/ocdebug.lua"] = program("0.2.0")
  oc.files["/bin/ocdump.lua"] = program("0.1.0")
  oc.files["/lib/oclib.lua"] = program("0.1.0")
  oc.files["/lib/ocgt.lua"] = program("0.1.0")
  oc.files["/lib/oclogistics.lua"] = program("0.1.0")
  oc.respond = serveProgram({ ["versions.txt"] = VERSIONED })

  oc.run("ocup")
  local said = 0
  for _ in oc.printed():gmatch("up to date") do
    said = said + 1
  end
  -- six files, each saying it once: repainting them all again at the end is
  -- what made the whole table appear to rewrite itself
  check(said == 6, "wrote 'up to date' " .. said .. " times for six files")
end)

-------------------------------------------------------------------------------
-- what the item network is doing, on somebody else's screen

test("a satellite sends what is moving, and ocview shows it", function()
  local netlib = require("ocnet")
  local report = netlib.report({}, {}, {
    { name = "Redstone", rate = 1240 },
    { name = "Iron Ingot", rate = -820 },
  })
  check(#report.items == 2, "carried " .. #report.items .. " items, not two")
  check(report.items[1].name == "Redstone", "lost the name")

  oc.width, oc.height = 160, 30
  oc.reset()
  local modem = fakeModem("cc000000-0000-0000-0000-000000000002", true)
  oc.components = { modem }
  startMinitel("tablet")
  deliver(modem, "bb000000", "tablet", "item-server", answerOf(report))

  oc.run("ocview", "--once")
  local frame = oc.screen()
  check(contains(frame, "changing, 3 minutes"), "did not say what the list is")
  check(contains(frame, "+1,240"), "did not show a rising stock")
  check(contains(frame, "-820"), "did not show a falling one")
  check(contains(frame, "Redstone"), "did not name the item")
end)

-------------------------------------------------------------------------------
-- GTP/1, the telemetry wire
--
-- The whole coupling to the telemetry service is the format of these bytes, so
-- what is asserted here is the bytes rather than our idea of them.

local function gtpOf(modem)
  local out = {}
  for _, packet in ipairs(outbound(modem)) do
    if type(packet.data) == "string" and packet.data:sub(1, 5) == "GTP1:" then
      out[#out + 1] = {
        dest = packet.dest,
        port = packet.port,
        message = require("serialization").unserialize(packet.data:sub(6)),
        bytes = #packet.data,
      }
    end
  end
  return out
end

-- Checked here rather than by asking the library whether it likes its own
-- output. A part at a time, because a Lua pattern cannot repeat a group.
local function wellNamed(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  if name:sub(1, 1) == "." or name:sub(-1) == "." or name:find("%.%.") then
    return false
  end
  for part in name:gmatch("[^%.]+") do
    if not part:find("^[a-z][a-z0-9_]*$") then
      return false
    end
  end
  return true
end

local function sampleNamed(message, name)
  for _, each in ipairs(message.data) do
    if each.name == name then
      return each
    end
  end
  return nil
end

test("a reading goes out as GTP on port 2000", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = {},
    telemetry = { host = "ovw-core-obs-01" },
  })
  startMinitel("ovw-pwr-steam-col-01")

  local ok, reason = oc.run("ocwatch")
  check(ok, "ocwatch crashed: " .. tostring(reason))
  oc.pump()

  local sent = gtpOf(modem)
  check(#sent > 0, "nothing went to the telemetry service")
  local first = sent[1]
  check(first and first.dest == "ovw-core-obs-01", "sent it to the wrong machine")
  check(first and first.port == 2000, "sent it on port " .. tostring(first and first.port))
  check(first and first.message.type == "metrics", "not a metrics message")
  check(first and first.message.interval == 10, "no interval on the message")
  check(first and first.message.id ~= nil, "no message id")
  check(first and type(first.message.data) == "table", "no samples")
end)

test("a tank becomes a fluid metric, with the fluid as a label", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = {},
  })
  startMinitel("ovw-pwr-steam-col-01")

  oc.run("ocwatch")
  oc.pump()

  local message = gtpOf(modem)[1] and gtpOf(modem)[1].message
  check(message ~= nil, "nothing went out")

  local amount = message and sampleNamed(message, "fluid.amount_liters")
  check(amount ~= nil, "the tank did not become fluid.amount_liters")
  -- our own numbers are grouped with commas for a screen, and a metric value
  -- must be a finite number and nothing else
  check(amount and type(amount.value) == "number",
    "sent " .. type(amount and amount.value) .. " rather than a number")
  check(amount and amount.kind == "gauge", "not marked as a gauge")
  check(amount and amount.labels and amount.labels.fluid ~= nil,
    "did not say which fluid it is")
  check(amount and amount.labels and amount.labels.machine ~= nil,
    "did not say which machine it is on")

  local ratio = message and sampleNamed(message, "fluid.fill_ratio")
  check(ratio ~= nil, "no fill ratio")
  -- the specification wants 0 to 1 where our screen wants 0 to 100
  check(ratio and ratio.value >= 0 and ratio.value <= 1,
    "sent a percentage where a ratio was asked for: " .. tostring(ratio and ratio.value))
end)

test("every metric name and label is one the specification allows", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = { { name = "Diesel Low!", tripped = true } },
  })
  startMinitel("ovw-pwr-steam-col-01")

  oc.run("ocwatch")
  oc.pump()

  local seen = 0
  for _, packet in ipairs(gtpOf(modem)) do
    check(packet.bytes <= 6144, "a message is " .. packet.bytes .. " bytes")
    for _, each in ipairs(packet.message.data) do
      seen = seen + 1
      check(wellNamed(each.name), "bad metric name: " .. each.name)
      check(each.kind == "gauge" or each.kind == "counter",
        "bad kind on " .. each.name .. ": " .. tostring(each.kind))
      check(type(each.value) == "number", "non-numeric value on " .. each.name)
      for key, value in pairs(each.labels or {}) do
        check(key:find("^[a-z][a-z0-9_]*$") ~= nil, "bad label key: " .. key)
        check(tostring(value):find("%s") == nil,
          "a space in a label value: " .. key .. "=" .. tostring(value))
        -- the telemetry service works these out from the sender, and a client
        -- claiming them would report under somebody else's identity
        check(key ~= "host" and key ~= "site" and key ~= "area",
          "claimed a label the server owns: " .. key)
      end
    end
  end
  check(seen > 0, "checked nothing")
end)

-- A version is not a number and cannot be made into one, so the series carries
-- a constant and the version rides in a label. Somebody looking at Grafana
-- wants one line per machine saying what it is on, and this is that line.
test("what a machine is running goes out as a metric of its own", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = {},
    telemetry = { host = "ovw-core-obs-01" },
    installed = { commit = "a1b2c3d4e5f6", files = {} },
  })
  startMinitel("ovw-pwr-steam-col-01")

  oc.run("ocwatch")
  oc.pump()

  local message = gtpOf(modem)[1] and gtpOf(modem)[1].message
  check(message ~= nil, "nothing went to the telemetry service")

  local build = message and sampleNamed(message, "software.build_info")
  check(build ~= nil, "no software.build_info went out")
  check(build and build.value == 1,
    "sent " .. tostring(build and build.value) .. " where the value must be a constant")
  check(build and build.labels and build.labels.program == "ocwatch",
    "did not say which program is running")
  check(build and build.labels and build.labels.version ~= nil,
    "did not say what version it is on")
  check(build and build.labels and build.labels.commit == "a1b2c3d",
    "did not carry the short commit: " .. tostring(build and build.labels
      and build.labels.commit))
  check(build and wellNamed(build.name), "the metric name is not one the spec allows")
end)

test("an alert becomes a number, because a metric value cannot be a boolean", function()
  oc.components = {}
  local gtp = require("ocgtp")
  local samples = gtp.samples({ alerts = {
    { name = "diesel low", tripped = true },
    { name = "steam full", tripped = false },
  } })
  local on, off
  for _, each in ipairs(samples) do
    if each.name == "alert.tripped" and each.labels.alert == "diesel-low" then
      on = each
    end
    if each.name == "alert.tripped" and each.labels.alert == "steam-full" then
      off = each
    end
  end
  check(on and on.value == 1, "a tripped alert did not come out as 1")
  check(off and off.value == 0, "a clear alert did not come out as 0")
end)

test("a unit nobody recognises is left alone rather than guessed at", function()
  oc.components = {}
  local gtp = require("ocgtp")
  local samples = gtp.samples({ cards = { {
    name = "Odd Machine",
    gauges = { { label = "Whatsits", current = "12", maximum = "20",
      unit = "wat", percent = 60 } },
  } } })
  for _, each in ipairs(samples) do
    check(each.name:find("^telemetry%.") ~= nil,
      "invented a series out of a unit it did not know: " .. each.name)
  end
end)

test("no item ever becomes a label", function()
  oc.components = {}
  local gtp = require("ocgtp")
  -- a base holds thousands of item names and each one as a label value is a
  -- series of its own, which is the one mistake the specification names twice
  local samples = gtp.samples({})
  for _, each in ipairs(samples) do
    check(each.name:find("^inventory%.") == nil, "sent an inventory metric")
    check((each.labels or {}).item == nil, "put an item into a label")
  end
end)

test("a name a metric cannot carry is refused and counted", function()
  oc.components = {}
  local gtp = require("ocgtp")
  check(gtp.validName("fluid.amount_liters") == true, "refused a good name")
  check(gtp.validName("energy.stored_eu") == true, "refused a good name")
  check(gtp.validName("Fluid.Amount") == false, "took capitals")
  check(gtp.validName("fluid.tank-01.amount") == false, "took a hyphen")
  check(gtp.validName("fluid..amount") == false, "took an empty component")
  check(gtp.validName("1fluid.amount") == false, "took a leading digit")

  check(gtp.validLabel("fluid") == true, "refused a good label")
  check(gtp.validLabel("host") == false, "took a label the server owns")
  check(gtp.validLabel("site") == false, "took a label the server owns")
  check(gtp.validLabel("area") == false, "took a label the server owns")
end)

test("a batch too big for one packet is split into whole messages", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", true)
  oc.components = { modem }
  startMinitel("ovw-pwr-steam-col-01")
  local gtp = require("ocgtp")
  local minitel = require("minitel")

  local fluids = {}
  for index = 1, 400 do
    fluids[index] = { name = "fluid-number-" .. index, amount = index * 1000 }
  end
  gtp.send(minitel, gtp.settings({}), gtp.samples({ fluids = fluids }))
  oc.pump(8)

  local sent = gtpOf(modem)
  check(#sent > 1, "sent " .. #sent .. " messages, so nothing was split")
  for _, packet in ipairs(sent) do
    check(packet.bytes <= 6144, "a split message is still " .. packet.bytes .. " bytes")
    check(packet.message ~= nil and packet.message.type == "metrics",
      "a split message is not a whole one")
    check(packet.message and #packet.message.data > 0, "sent an empty message")
  end
end)

test("telemetry can be switched off, and says nothing when it is", function()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000001", true)
  oc.components = { modem, SUPER_TANK }
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    watch = { { address = SUPER_TANK.address } },
    alerts = {},
    telemetry = { on = false },
  })
  startMinitel("ovw-pwr-steam-col-01")

  oc.run("ocwatch")
  oc.pump()
  check(#gtpOf(modem) == 0, "sent telemetry with it switched off")
end)

test("a machine name becomes something a label can hold", function()
  oc.components = {}
  local gtp = require("ocgtp")
  check(gtp.slug("Super Tank") == "super-tank", "got " .. gtp.slug("Super Tank"))
  check(gtp.slug("Bio Diesel") == "bio-diesel", "got " .. gtp.slug("Bio Diesel"))
  check(gtp.slug("EBF #1") == "ebf-1", "got " .. gtp.slug("EBF #1"))
  check(gtp.slug("") == "", "invented a name out of nothing")
end)

test("a reading grouped for a screen becomes a number for a metric", function()
  oc.components = {}
  local gtp = require("ocgtp")
  check(gtp.number("42,000") == 42000, "did not strip the grouping")
  check(gtp.number(42000) == 42000, "changed a number that was already one")
  check(gtp.number("nonsense") == nil, "took something that is not a number")
  check(gtp.number(0 / 0) == nil, "took a value that is not a finite number")
  check(gtp.number(math.huge) == nil, "took an infinite value")
end)

-------------------------------------------------------------------------------
-- occonnect and ocagent through a scripted proxy
--
-- The data card is faked with reversible arithmetic rather than AES, so what is
-- tested is the framing, the numbering and the two handshakes, and never the
-- cipher. The proxy and the controller are both played by the test, which
-- opens what the program wrote and seals what it sends back with the same
-- library.

local PROXY_SECRET = "the proxy secret"
local LINK_KEY = "the link key"

local function hex(raw)
  return (raw:gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

local function unhex(text)
  return (text:gsub("%x%x", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local function fakeData()
  local counter = 0
  local function mix(text, key)
    local out = {}
    for index = 1, #text do
      local k = key:byte((index - 1) % #key + 1)
      out[index] = string.char(text:byte(index) ~ k)
    end
    return table.concat(out)
  end
  local function digest(text)
    local h = {}
    for index = 1, 32 do
      h[index] = index * 7
    end
    for index = 1, #text do
      local slot = (index - 1) % 32 + 1
      h[slot] = (h[slot] * 31 + text:byte(index) + index) % 256
    end
    -- mixed across every slot, or a change late in the text stays out of the
    -- half of the digest a tag keeps
    for _ = 1, 2 do
      for index = 2, 32 do
        h[index] = (h[index] + h[index - 1] * 31 + 1) % 256
      end
      for index = 31, 1, -1 do
        h[index] = (h[index] + h[index + 1] * 31 + 1) % 256
      end
    end
    for index = 1, 32 do
      h[index] = string.char(h[index])
    end
    return table.concat(h)
  end
  return {
    address = "da7a0000-0000-0000-0000-000000000001",
    kind = "data",
    methods = { encrypt = "f", decrypt = "f", sha256 = "f", random = "f",
      encode64 = "f", decode64 = "f" },
    values = {
      encrypt = function(text, key, iv)
        return mix(text, key .. iv)
      end,
      decrypt = function(text, key, iv)
        return mix(text, key .. iv)
      end,
      sha256 = function(text, key)
        if key then
          return digest(key .. "\1" .. text)
        end
        return digest(text)
      end,
      random = function(n)
        local out = {}
        for index = 1, n do
          counter = counter + 1
          out[index] = string.char((counter * 13) % 256)
        end
        return table.concat(out)
      end,
    },
  }
end

local function fakeChat()
  return {
    address = "c4a7b0c0-0000-0000-0000-000000000001",
    kind = "chat_box",
    methods = { say = "f" },
    values = {
      say = function(text)
        oc.said = oc.said or {}
        oc.said[#oc.said + 1] = text
        return true
      end,
    },
  }
end

local function linkConfig()
  oc.said = {}
  oc.files["/etc/ocgt.cfg"] = require("serialization").serialize({
    link = { host = "vps.example", port = 7071, secret = PROXY_SECRET, key = LINK_KEY },
  })
end

local function agentMachine()
  local modem = fakeModem("aa000000-0000-0000-0000-000000000009")
  oc.components = { INTERNET, fakeData(), fakeChat(), modem }
  linkConfig()
  startMinitel("agent-01")
  return modem
end

-- The proxy and the controller in one. Every frame the program writes is
-- opened: a join is answered with joined and attached, a hello with welcome
-- and then handed to `script(message, far)`, and anything else goes to the
-- script as well. `far.send` seals a message for the program, `far.control`
-- a proxy message, `far.again` queues a raw frame a second time.
local function proxy(script)
  local link = require("oclink")
  local serialization = require("serialization")
  local data = require("component").proxy(fakeData().address)
  local proxyStatic = link.keys(data, PROXY_SECRET)
  local farStatic = link.keys(data, LINK_KEY)
  local proxyKeys, keys = proxyStatic, farStatic
  local challenge = string.rep("\7", 16)
  local controlSeq, seq = 0, 0
  local seen, received = 0, {}
  local queued = { link.frame(link.CONTROL, challenge) }

  local far = {}
  function far.control(message)
    controlSeq = controlSeq + 1
    message.seq = controlSeq
    queued[#queued + 1] = link.frame(link.CONTROL,
      link.seal(data, proxyKeys, serialization.serialize(message)))
  end
  function far.send(message)
    seq = seq + 1
    message.seq = seq
    local frame = link.frame(link.RELAY,
      link.seal(data, keys, serialization.serialize(message)))
    queued[#queued + 1] = frame
    return frame
  end
  function far.again(frame)
    queued[#queued + 1] = frame
  end

  oc.socket.answer = function(written)
    while seen < #written do
      seen = seen + 1
      local frame = written[seen]
      local channel, body = frame:byte(3), frame:sub(4)
      if channel == link.CONTROL then
        local text = link.open(data, proxyKeys, body)
        local message = text and serialization.unserialize(text)
        if message and message.kind == "join" then
          received[#received + 1] = message
          proxyKeys = link.session(data, proxyStatic, challenge .. unhex(message.nonce))
          far.control({ kind = "joined" })
          far.control({ kind = "attached" })
        end
      else
        -- a hello is under the static keys, whether it is the first or a later one
        local text = link.open(data, farStatic, body) or link.open(data, keys, body)
        local message = text and serialization.unserialize(text)
        if message then
          received[#received + 1] = message
          if message.kind == "hello" then
            keys = link.session(data, farStatic, unhex(message.nonce))
            seq = 0
            far.send({ kind = "welcome" })
          end
          if script then
            script(message, far)
          end
        end
      end
    end
    return table.remove(queued, 1)
  end
  return received, far
end

local function kinds(received)
  local out = {}
  for _, message in ipairs(received) do
    out[#out + 1] = message.kind
  end
  return table.concat(out, ",")
end

local function results(received)
  local out = {}
  for _, message in ipairs(received) do
    if message.kind == "result" then
      out[message.id] = message
    end
  end
  return out
end

test("oclink seals a body the other side can open, and refuses a forged one", function()
  oc.components = { fakeData() }
  local link = require("oclink")
  local data = link.card()
  check(data ~= nil, "did not find the data card")
  local keys = link.keys(data, LINK_KEY)
  local body = link.seal(data, keys, "hello there")
  check(link.open(data, keys, body) == "hello there", "did not open its own body")

  local frame = link.frame(link.RELAY, body)
  check(string.unpack(">I2", frame) == #body + 1, "the length does not cover the channel byte")
  check(frame:byte(3) == 1, "the channel byte is not the relay channel")

  local other = link.keys(data, "some other key")
  local text, why = link.open(data, other, body)
  check(text == nil and why == "bad tag", "opened a body under the wrong key: " .. tostring(why))

  local forged = body:sub(1, 18) .. string.char(body:byte(19) ~ 1) .. body:sub(20)
  check(link.open(data, keys, forged) == nil, "opened a body that was changed in flight")
end)

test("occonnect refuses to start without a link or a data card", function()
  oc.components = { INTERNET }
  local ok = oc.run("occonnect", "--once")
  check(ok, "crashed instead of saying so")
  check(contains(oc.printed(), "not linked"), "did not say what is missing")

  linkConfig()
  ok = oc.run("occonnect", "--once")
  check(ok, "crashed instead of saying so")
  check(contains(oc.printed(), "data card"), "did not say the card is missing")
  check(oc.socket.connections == nil, "connected anyway")
end)

test("occonnect --link writes the link in one line and says what it is", function()
  oc.components = { INTERNET, fakeData() }
  local ok = oc.run("occonnect", "--link", "vps.example:7071", "pq7rs2tv4wx", "k3m9n5p2q8r")
  check(ok, "crashed instead of linking")
  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  check(saved and saved.link and saved.link.host == "vps.example" and saved.link.port == 7071,
    "did not write the proxy address")
  check(saved and saved.link.secret == "pq7rs2tv4wx" and saved.link.key == "k3m9n5p2q8r",
    "did not write both secrets")
  check(oc.socket.connections == nil, "connected instead of only linking")

  oc.output = { "" }
  oc.run("occonnect", "--link")
  local shown = oc.printed()
  check(contains(shown, "vps.example:7071"), "did not say where it is linked: " .. shown)
  check(not contains(shown, "pq7rs2tv4wx") and contains(shown, "pq*******wx"),
    "showed a secret in full on the screen: " .. shown)
end)

test("occonnect --link refuses half a link and keeps the old one", function()
  oc.components = { INTERNET, fakeData() }
  linkConfig()
  oc.run("occonnect", "--link", "vps.example", "onlyone")
  check(contains(oc.printed(), "usage"), "did not say how to link")
  local saved = require("serialization").unserialize(oc.files["/etc/ocgt.cfg"] or "")
  check(saved and saved.link and saved.link.key == LINK_KEY, "lost the link that was there")
end)

test("occonnect joins the proxy under its name and runs what the controller sends", function()
  oc.components = { INTERNET, fakeData() }
  linkConfig()
  oc.files["/etc/hostname"] = "chem-01"
  oc.idle = 16
  local received = proxy(function(message, far)
    if message.kind == "hello" then
      far.send({ kind = "shell", id = "s1", command = "ocup" })
      far.send({ kind = "run", id = "r1", code = "print(2 + 3, [[answer]])\nreturn 7" })
      far.send({ kind = "run", id = "r2", code = "this is not lua" })
      far.send({ kind = "file", id = "f1", path = "/home/hello.lua", body = "print('hi')\n" })
    end
  end)

  local ok, reason = oc.run("occonnect")
  check(ok, "occonnect crashed: " .. tostring(reason))
  check(oc.socket.host == "vps.example" and oc.socket.port == 7071, "connected somewhere else")
  check(received[1] and received[1].kind == "join", "did not join first: " .. kinds(received))
  check(received[1] and received[1].role == "device" and received[1].name == "chem-01",
    "the join does not name this machine as a device")
  check(received[1] and received[1].challenge == hex(string.rep("\7", 16)),
    "the join does not answer the challenge")
  check(received[2] and received[2].kind == "hello" and received[2].host == "chem-01",
    "did not say hello once attached: " .. kinds(received))

  local got = results(received)
  check(oc.executed[1] == "ocup > /tmp/oclink.out",
    "did not run the shell line: " .. tostring(oc.executed[1]))
  check(got.s1 and got.s1.ok == true and contains(got.s1.output or "", "output of ocup"),
    "did not send back what the shell printed")
  check(got.r1 and got.r1.ok == true and contains(got.r1.output or "", "5\tanswer")
    and contains(got.r1.output or "", "7"), "lost what the chunk printed or returned")
  check(got.r2 and got.r2.ok == false and contains(got.r2.error or "", "compile"),
    "the broken chunk was not reported")
  check(oc.files["/home/hello.lua"] == "print('hi')\n", "did not write the file")
  check(got.f1 and got.f1.ok == true, "did not report the file written")
end)

test("occonnect goes back to waiting when its controller leaves, and greets the next", function()
  oc.components = { INTERNET, fakeData() }
  linkConfig()
  oc.files["/etc/hostname"] = "chem-01"
  oc.idle = 20
  local hellos = 0
  local received = proxy(function(message, far)
    if message.kind == "hello" then
      hellos = hellos + 1
      if hellos == 1 then
        far.control({ kind = "detached" })
        far.control({ kind = "attached" })
      end
    end
  end)

  local ok, reason = oc.run("occonnect")
  check(ok, "occonnect crashed: " .. tostring(reason))
  check(hellos == 2, "said hello " .. hellos .. " times, wanted one per controller: " .. kinds(received))
  check(contains(oc.printed(), "waiting"), "never showed itself waiting")
end)

test("ocagent says hello, and speaks what the harness says", function()
  agentMachine()
  oc.idle = 16
  local received = proxy(function(message, far)
    if message.kind == "hello" then
      far.send({ kind = "say", text = "diesel is at 42,000 L" })
    end
  end)

  local ok, reason = oc.run("ocagent")
  check(ok, "ocagent crashed: " .. tostring(reason))
  check(received[2] and received[2].kind == "hello", "did not say hello after joining: " .. kinds(received))
  check(received[2] and received[2].host == "agent-01", "hello does not name the machine")
  check(received[2] and received[2].protocol == 1, "hello does not name the protocol")
  check(oc.said[1] == "diesel is at 42,000 L", "did not say it in chat")
  check(contains(kinds(received), "heartbeat"), "never sent a heartbeat")
end)

test("ocagent forwards a chat line addressed to it and ignores the rest", function()
  agentMachine()
  oc.idle = 16
  oc.pushAfter(8, "chat_message", "c4a7b0c0", "Steve", "@c how much diesel?")
  oc.pushAfter(8, "chat_message", "c4a7b0c0", "Someone", "hello everyone")
  oc.pushAfter(9, "chat_message", "c4a7b0c0", "Steve", "@Computer Status")
  local received = proxy()

  local ok, reason = oc.run("ocagent")
  check(ok, "ocagent crashed: " .. tostring(reason))
  local chats = {}
  for _, message in ipairs(received) do
    if message.kind == "chat" then
      chats[#chats + 1] = message
    end
  end
  check(#chats == 2,
    "forwarded " .. #chats .. " lines, wanted the two for the agent: " .. kinds(received))
  check(chats[1] and chats[1].player == "Steve" and chats[1].text == "how much diesel?",
    "did not strip the trigger: " .. tostring(chats[1] and chats[1].text))
  check(chats[2] and chats[2].text == "Status", "did not take the long trigger in any case")
end)

test("ocagent tells chat when the proxy is away", function()
  agentMachine()
  oc.socket.refuse = true
  oc.idle = 4
  oc.pushAfter(3, "chat_message", "c4a7b0c0", "Steve", "@c anyone there?")

  local ok, reason = oc.run("ocagent")
  check(ok, "ocagent crashed: " .. tostring(reason))
  check(oc.said[1] ~= nil and contains(oc.said[1], "not connected"),
    "said nothing about being away: " .. tostring(oc.said[1]))
end)

test("ocagent runs a chunk and a shell line like occonnect does", function()
  agentMachine()
  oc.idle = 16
  local received = proxy(function(message, far)
    if message.kind == "hello" then
      far.send({ kind = "run", id = "r1", code = "print(2 + 3)" })
      far.send({ kind = "shell", id = "s1", command = "ocup" })
    end
  end)

  local ok, reason = oc.run("ocagent")
  check(ok, "ocagent crashed: " .. tostring(reason))
  local got = results(received)
  check(got.r1 and got.r1.ok == true and contains(got.r1.output or "", "5"),
    "the chunk did not run: " .. kinds(received))
  check(got.s1 and got.s1.ok == true, "the shell line did not run")
end)

test("ocagent asks the mesh and relays each answer", function()
  local modem = agentMachine()
  oc.idle = 30
  local received = proxy(function(message, far)
    if message.kind == "hello" then
      far.send({ kind = "ask", id = "a1", what = "status", wait = 1 })
    end
  end)
  -- a satellite answering, once the question has had time to go out
  local report = require("serialization").serialize({
    address = "bb", cards = { { name = "Super Tank", gauges = {} } }, alerts = {},
    fluids = { { name = "Diesel", amount = 42000 } },
  })
  deliverAfter(12, modem, "bb000000", "agent-01", "boiler-room", "ocstatus!\n" .. report)

  local ok, reason = oc.run("ocagent")
  check(ok, "ocagent crashed: " .. tostring(reason))
  local partial, result
  for _, message in ipairs(received) do
    if message.kind == "partial" and message.id == "a1" then
      partial = message
    elseif message.kind == "result" and message.id == "a1" then
      result = message
    end
  end
  local asked = false
  for _, packet in ipairs(outbound(modem)) do
    if packet.data == "ocstatus?" then
      asked = true
    end
  end
  check(asked, "never put the question on the wire")
  check(partial ~= nil, "did not relay the answer: " .. kinds(received))
  check(partial and partial.host == "boiler-room", "did not say who answered")
  check(partial and partial.data.fluids[1].name == "Diesel", "lost the fluids")
  check(result and result.ok == true and result.hosts == 1, "did not close the question with a count")
end)

test("ocagent drops a frame that goes backwards", function()
  agentMachine()
  oc.idle = 16
  local received = proxy(function(message, far)
    if message.kind == "hello" then
      local frame = far.send({ kind = "say", text = "once" })
      -- the same numbered frame again, as a recording played back would be
      far.again(frame)
      far.send({ kind = "say", text = "twice" })
    end
  end)

  local ok, reason = oc.run("ocagent")
  check(ok, "ocagent crashed: " .. tostring(reason))
  check(#received > 0, "heard nothing")
  check(#oc.said == 2 and oc.said[1] == "once" and oc.said[2] == "twice",
    "expected the two fresh lines only, got " .. table.concat(oc.said, "|"))
end)

-------------------------------------------------------------------------------
-- The summary belongs at the end. It once sat in the middle, where every check
-- written after it could fail without the run failing with it.

say("")
if failures > 0 then
  say(failures .. " check(s) failed")
  os.exit(1)
end
say("all checks passed")

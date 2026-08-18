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
  local ok, reason = pcall(fn)
  if not ok then
    failures = failures + 1
    say("  FAIL  " .. name .. ": crashed: " .. tostring(reason))
  else
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

local function serveProgram(bodies)
  return function(url)
    for name, body in pairs(bodies) do
      if url:find(name, 1, true) then
        return 200, "OK", body
      end
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
    ["ocup.lua"] = program("0.3.0"),
    ["ocdebug.lua"] = program("0.2.0"),
    ["ocdump.lua"] = program("0.1.0"),
  })

  local ok, reason = oc.run("ocup")
  check(ok, "ocup crashed: " .. tostring(reason))

  local out = oc.printed()
  check(contains(out, "ocup v"), "no version banner")
  check(contains(out, "installed"), "did not report a fresh install")
  check(contains(out, "3 programs ready"), "no success summary")
  check(oc.files["/bin/ocdump.lua"] == program("0.1.0"), "ocdump.lua not written to /bin")
  if show then
    say(out)
  end
end)

test("ocup reports a version bump", function()
  oc.components = { INTERNET }
  oc.files["/bin/ocdebug.lua"] = program("0.2.0")
  oc.respond = serveProgram({
    ["ocup.lua"] = program("0.3.0"),
    ["ocdebug.lua"] = program("0.3.0"),
    ["ocdump.lua"] = program("0.1.0"),
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
  oc.respond = serveProgram({ ["ocdebug.lua"] = program("0.2.0") })

  oc.run("ocup")
  check(contains(oc.printed(), "up to date"), "did not report an unchanged program")
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

test("ocdebug never invokes a setter", function()
  oc.components = { GT_MACHINE, REDSTONE }
  oc.push("key_down", "keyboard", 0, 0xD0) -- down, selects redstone

  local ok = oc.run("ocdebug")
  check(ok, "ocdebug crashed")
  for _, method in ipairs(oc.invoked) do
    check(method:sub(1, 3) == "get", "invoked a non-get method: " .. method)
  end
end)

test("ocdebug survives a getter that needs arguments", function()
  oc.components = { REDSTONE }

  local ok = oc.run("ocdebug")
  check(ok, "ocdebug crashed on a failing getter")
  check(contains(oc.frame(), "bad arguments"), "did not surface the getter error")
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
    check(method:sub(1, 3) == "get", "invoked a non-get method: " .. method)
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

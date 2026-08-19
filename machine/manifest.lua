-- Rewrites manifest.txt with the version each file currently declares.
--
--   nix develop -c lua machine/manifest.lua
--
-- ocup compares the version in the manifest against the one already installed
-- and only downloads a file when the two differ, so the manifest has to say the
-- truth about every file. A check in machine/test.lua fails when it does not.

local function versionOf(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read("*a") or ""
  file:close()
  return text:match('VERSION%s*=%s*"([^"]+)"')
end

local paths = {}
for line in io.lines("manifest.txt") do
  local path = line:match("^%s*(%S+)")
  if path then
    paths[#paths + 1] = path
  end
end

local out = {}
for _, path in ipairs(paths) do
  local version = versionOf(path)
  if not version then
    io.stderr:write("no VERSION in " .. path .. "\n")
    os.exit(1)
  end
  out[#out + 1] = path .. " " .. version
end

local file = assert(io.open("manifest.txt", "w"))
file:write(table.concat(out, "\n") .. "\n")
file:close()
print(#out .. " files written to manifest.txt")

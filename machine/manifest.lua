-- Rewrites manifest.txt and versions.txt from the files themselves.
--
--   nix develop -c lua machine/manifest.lua
--
-- Two files, because an older ocup has to keep working. Its parser takes one
-- path a line and skips any line with anything else on it, so a version put
-- beside the path made every line unreadable and the manifest look empty, and an
-- ocup that cannot read the manifest cannot update itself out of the problem.
--
--   manifest.txt   one path a line, and nothing else, for good
--   versions.txt   the same paths with the version each file declares
--
-- ocup asks for versions.txt first and uses manifest.txt only when that is not
-- there, so a new one costs two requests and an old one keeps working.

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

local plain, versioned = {}, {}
for _, path in ipairs(paths) do
  local version = versionOf(path)
  if not version then
    io.stderr:write("no VERSION in " .. path .. "\n")
    os.exit(1)
  end
  plain[#plain + 1] = path
  versioned[#versioned + 1] = path .. " " .. version
end

local function put(name, lines)
  local file = assert(io.open(name, "w"))
  file:write(table.concat(lines, "\n") .. "\n")
  file:close()
end

put("manifest.txt", plain)
put("versions.txt", versioned)
print(#plain .. " files written to manifest.txt and versions.txt")

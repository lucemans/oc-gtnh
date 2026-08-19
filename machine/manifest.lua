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
--   versions.txt   the same paths, the version each file declares, and its size
--
-- The size is there because a version alone is only as good as the discipline
-- behind it. A file edited without its VERSION moving is invisible to an update
-- that compares versions, and that has happened: a library was rewritten, kept
-- its number, and every computer went on running the old one. Bytes change
-- whatever anybody remembered to do.

local function contentsOf(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read("*a") or ""
  file:close()
  return text
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
  local text = contentsOf(path)
  local version = text and text:match('VERSION%s*=%s*"([^"]+)"')
  if not version then
    io.stderr:write("no VERSION in " .. path .. "\n")
    os.exit(1)
  end
  plain[#plain + 1] = path
  versioned[#versioned + 1] = path .. " " .. version .. " " .. #text
end

local function put(name, lines)
  local file = assert(io.open(name, "w"))
  file:write(table.concat(lines, "\n") .. "\n")
  file:close()
end

put("manifest.txt", plain)
put("versions.txt", versioned)
print(#plain .. " files written to manifest.txt and versions.txt")

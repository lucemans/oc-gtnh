-- OpenOS extends the standard Lua environment, so describe it to luacheck
stds.openos = {
  read_globals = {
    "_OSVERSION",
    os = { fields = { "sleep" } },
  },
}

std = "lua53+openos"

-- the fake machine deliberately replaces these to observe the programs
files["machine/oc.lua"] = {
  globals = { "print", "io", "os", "_OSVERSION" },
}

-- Minitel is vendored rather than written here, and it sets the globals `rc`
-- looks for a service to define. Linting it reports on somebody else's
-- repository every time we lint ours.
exclude_files = {
  "lib/minitel.lua",
  "lib/syslog.lua",
  "etc/minitel.lua",
  "etc/syslogd.lua",
  "etc/fserv.lua",
}

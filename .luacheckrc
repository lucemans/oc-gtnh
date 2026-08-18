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

-- syslog: pushes one logging event, with a severity from RFC 5424.
--
-- Vendored from https://github.com/ShadowKatStudios/OC-Minitel
--   syslog/OpenOS/usr/lib/syslog.lua
-- at commit c679ae36, under the Mozilla Public License 2.0.
--
-- Not ours to edit. To take a later upstream, replace the body below and put
-- the new commit in the two lines above and below this one.
-- VERSION = "minitel-c679ae36"

local process = require "process"
local computer = require "computer"

local syslog = {}
syslog.emergency = 0
syslog.alert = 1
syslog.critical = 2
syslog.error = 3
syslog.warning = 4
syslog.notice = 5
syslog.info = 6
syslog.debug = 7

setmetatable(syslog,{__call = function(_,msg, level, service)
 level, service = level or syslog.info, service or process.info().path
 computer.pushSignal("syslog",msg, level, service)
end})

return syslog

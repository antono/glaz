-- Menu module: about the app. ASCII only, see docs/PROTOCOL.md.
--
-- Name, version and author, one per line. The version is bumped by hand
-- here; it is not read from git, because the glasses never see the repo.
local _M = {}

_M.label = 'About'

local NAME    = 'glaz'
local VERSION = '0.9.2'
local AUTHOR  = 'Anton Vasiljev'

function _M.run()
  return NAME .. '\n' .. 'version ' .. VERSION .. '\n' .. 'by ' .. AUTHOR
end

return _M

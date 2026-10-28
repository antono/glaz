-- Menu module: about the app. ASCII only, see docs/PROTOCOL.md.
--
-- Name, version and author, one per line. The version is bumped by hand
-- here; it is not read from git, because the glasses never see the repo.
-- A part with lines() lays them out for its screen: Halo's round one
-- would cut the author's name short on its 11-character last row
-- (about.halo.lua).
-- Frame's part is empty, so not uploaded: nil here.
local D = select(2, ...) or {}
local _M = {}

_M.label = 'About'

local NAME    = 'glaz'
local VERSION = '0.41.1'
local AUTHOR  = 'Anton Vasiljev'

function _M.run()
  if D.lines then return D.lines(NAME, VERSION, AUTHOR) end
  return NAME .. '\n' .. 'version ' .. VERSION .. '\n' .. 'by ' .. AUTHOR
end

return _M

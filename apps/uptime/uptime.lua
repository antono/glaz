-- Menu module: time since boot. ASCII only, see docs/PROTOCOL.md.
--
-- frame.time.utc() counts monotonically from power-on and works even when
-- the clock was never set, so this needs no host and no time sync.
local _M = {}

_M.label = 'Uptime'

function _M.run()
  local s = math.floor(frame.time.utc())
  return string.format('%dh %02dm %02ds', s // 3600, (s % 3600) // 60, s % 60)
end

return _M

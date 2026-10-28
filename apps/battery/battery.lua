-- Menu module: battery level. ASCII only, see docs/PROTOCOL.md.
local _M = {}

_M.label = 'Battery'
_M.mode = 'info'  -- shows one value, then auto-closes

function _M.run()
  return string.format('%d%%', frame.battery_level())
end

return _M

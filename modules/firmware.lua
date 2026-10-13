-- Menu module: firmware version. ASCII only, see PROTOCOL.md.
local _M = {}

_M.label = 'Firmware'

function _M.run()
  return frame.FIRMWARE_VERSION
end

return _M

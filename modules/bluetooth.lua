-- Menu module: the Bluetooth link at a glance. ASCII only, see
-- docs/PROTOCOL.md.
--
-- Three lines, refreshed while open:
--   connected / not connected -- is a host attached right now
--   MAC                       -- this device's address
--   MTU                       -- the largest payload one packet can carry
--
-- That is all the firmware exposes: frame.bluetooth has is_connected,
-- address, max_length, send and receive_callback (docs/PLATFORM.md).
--
-- The MAC is printed as the firmware builds it, lowest byte first -- the
-- reverse of what AR Studio and macOS show (docs/FRAME.md). The MTU is the
-- one negotiated with the current host, so it only means something while
-- connected.
local _M = {}

_M.label = 'Bluetooth'
_M.mode = 'app'
_M.background = false  -- sleeps: stopped as soon as it leaves the screen

function _M.tick()
  local ok, connected = pcall(frame.bluetooth.is_connected)
  local _, address = pcall(frame.bluetooth.address)
  local _, mtu = pcall(frame.bluetooth.max_length)

  local status = (ok and connected) and 'connected' or 'not connected'
  local link = (ok and connected) and ('MTU ' .. tostring(mtu) .. ' bytes')
                                   or 'MTU -'
  return status .. '\n' .. 'MAC ' .. tostring(address) .. '\n' .. link
end

return _M

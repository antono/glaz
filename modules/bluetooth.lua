-- Menu module: the Bluetooth link at a glance. ASCII only, see
-- docs/PROTOCOL.md.
--
-- Three lines, refreshed while open:
--   up 5m12s  drops 3        -- the link now, for how long, drops since boot
--   heard 4s  in 137  MTU 247 -- the phone's last message, messages taken
--   MAC ...                  -- this device's address
--
-- The firmware exposes is_connected, address, max_length, send and
-- receive_callback (docs/PLATFORM.md); the rest is frame_app.lua's own
-- count, glaz_link, kept by its loop. heard is how long ago the phone last
-- sent anything: it asks for STATUS every minute, so a minute and more
-- with the link up means its app is gone or stuck.
--
-- The MAC is printed as the firmware builds it, lowest byte first -- the
-- reverse of what AR Studio and macOS show (docs/FRAME.md). The MTU is the
-- one negotiated with the current host, so it only means something while
-- connected.
local _M = {}

_M.label = 'Bluetooth'
_M.mode = 'app'
_M.background = false  -- sleeps: stopped as soon as it leaves the screen

local function span(s)
  s = math.floor(s)
  if s < 60 then return s .. 's' end
  if s < 3600 then return string.format('%dm%02ds', s // 60, s % 60) end
  return string.format('%dh%02dm', s // 3600, s % 3600 // 60)
end

function _M.tick()
  local ok, connected = pcall(frame.bluetooth.is_connected)
  local _, address = pcall(frame.bluetooth.address)
  local _, mtu = pcall(frame.bluetooth.max_length)
  local up = ok and connected
  local l = glaz_link
  local now = frame.time.utc()

  local first = up and 'up' or 'down'
  if l and l.since > 0 then first = first .. ' ' .. span(now - l.since) end
  if l then first = first .. '  drops ' .. l.drops end
  local second = 'heard ' .. ((l and l.heard) and span(now - l.heard) or '-')
  if l then second = second .. '  in ' .. l.rx end
  if up then second = second .. '  MTU ' .. tostring(mtu) end
  return first .. '\n' .. second .. '\n' .. 'MAC ' .. tostring(address)
end

return _M

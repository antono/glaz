-- Menu module: live head orientation. ASCII only, see docs/PROTOCOL.md.
--
-- mode = 'app': this one keeps running and refreshing until it is closed
-- with a double tap (back) or left alone for APP_TIMEOUT (a single tap
-- keeps it alive), unlike an 'info' module that shows one value and
-- auto-closes. Useful for retuning navigation -- PITCH_THRESHOLD and
-- DEADZONE in frame_app.lua come from these numbers. Note that resting
-- pitch is around -35, not 0, and heading is always 0.0 on v25.080.0838.
local _M = {}

_M.label = 'Tilt'
_M.mode = 'app'
_M.background = false  -- sleeps: stopped as soon as it leaves the screen

function _M.tick()
  local d = frame.imu.direction()
  return string.format('r%.0f  p%.0f  h%.0f', d.roll, d.pitch, d.heading)
end

return _M

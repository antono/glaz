-- Menu module: live head orientation. ASCII only, see docs/PROTOCOL.md.
--
-- mode = 'app': this one keeps running and refreshing until it is closed
-- with a double tap (back) or left alone for APP_TIMEOUT (a single tap
-- keeps it alive), unlike an 'info' module that shows one value and
-- auto-closes. Useful for retuning navigation -- PITCH_THRESHOLD and
-- DEADZONE in glaz.lua come from these numbers. Note that resting
-- pitch is around -35, not 0, and heading is always 0.0 on v25.080.0838.
local _M = {}

_M.label = 'Tilt'
_M.mode = 'app'
_M.background = false  -- sleeps: stopped as soon as it leaves the screen

-- Whole degrees, rounded half up. Not '%.0f': that prints -0.4 as '-0',
-- and a level head would flicker between r0 and r-0.
local function deg(x)
  return math.floor(x + 0.5)
end

function _M.tick()
  local d = frame.imu.direction()
  return string.format('r%d  p%d  h%d',
                       deg(d.roll), deg(d.pitch), deg(d.heading))
end

return _M

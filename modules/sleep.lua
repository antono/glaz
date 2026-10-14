-- Menu module: put the glasses to sleep now. ASCII only, see
-- docs/PROTOCOL.md.
--
-- Deep sleep is normally automatic, but it never happens while a host is
-- connected or a module runs in the background (frame_app.lua). This forces
-- it: everything is closed, the background module included, and the device
-- parks until a tap. Because that stops work the user may care about, the
-- screen first says which background module will be stopped.
--
--   single tap -- sleep
--   double tap -- back, nothing happens
--
-- frame_app.lua passes start() a table with the background module's label
-- (or nil), and treats 'sleep' as on_tap()'s "done" value as a request for
-- deep sleep.
local _M = {}

_M.label = 'Sleep'
_M.mode = 'app'
_M.background = false  -- sleeps: stopped as soon as it leaves the screen
_M.resume = false      -- a tap after waking must not bring this back

local warning = ''

function _M.start(app)
  local name = app and app.background
  if name then
    warning = 'will stop: ' .. name
  else
    warning = 'nothing in background'
  end
end

function _M.tick()
  return 'sleep now?\n' .. warning .. '\ntap = sleep, 2 taps = back'
end

function _M.on_tap()
  return nil, 'sleep'
end

return _M

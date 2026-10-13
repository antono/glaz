-- Menu module: stopwatch. ASCII only, see docs/PROTOCOL.md.
--
-- A 'background' module: leaving the screen does not stop it, it keeps
-- counting, and the background icon shows in the top bar. A single tap on the
-- blank screen brings back the last app, so a stopwatch left running is one
-- tap away.
--   single tap -- start / pause
--   tilt       -- reset, while paused
--   double tap -- back; the stopwatch keeps going in the background
-- It only asks to stay in the background while there is something to keep:
-- a reset stopwatch is closed for good when left. That is how a background
-- module stops itself -- see background() below.
--
-- Time is derived from frame.time.utc(), not counted in tick(), so it stays
-- exact however rarely the module is ticked.
local _M = {}

_M.label = 'Stopwatch'
_M.mode = 'app'

local started = nil   -- utc() when the current run began; nil while stopped
local banked  = 0     -- seconds collected by earlier runs, before a pause

local function elapsed()
  if started then
    return banked + (frame.time.utc() - started)
  end
  return banked
end

local function screen()
  local s = elapsed()
  local text = string.format('%d:%02d.%d', math.floor(s / 60),
                             math.floor(s % 60), math.floor(s * 10) % 10)
  if started then return text end
  if banked > 0 then return text .. '  paused, tilt = reset' end
  return text .. '  tap = start'
end

-- Asked each time the module leaves the screen: true keeps it running in the
-- background, false stops it like any sleeping module.
function _M.background()
  return started ~= nil or banked > 0
end

function _M.tick()
  return screen()
end

function _M.on_tap()
  if started then
    banked = elapsed()
    started = nil
  else
    started = frame.time.utc()
  end
  return screen()
end

function _M.on_roll()
  if not started then banked = 0 end
  return screen()
end

-- Closed for good: the next launch starts from zero.
function _M.stop()
  started = nil
  banked = 0
end

return _M

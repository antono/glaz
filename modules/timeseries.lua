-- Menu module: time series -- a photo every N seconds, sent to the host.
-- ASCII only, see docs/PROTOCOL.md.
--
--   tilt right / left -- next / previous interval: 1 2 4 8 10 20 30 40 60 s
--   single tap        -- start / stop shooting
--   double tap        -- back; a running series keeps shooting in the
--                        background, and the background icon shows
-- Screen: the interval scale (brackets mark the choice, as in Brightness),
-- the status, and how many photos were sent and how many failed.
--
-- A 'background' module while shooting, a sleeping one while stopped -- see
-- _M.background(). The interval can be changed while running; the next shot
-- moves accordingly.
--
-- Photos go out exactly as in modules/photo.lua: camera.min's
-- capture_and_send(), chunks flagged 0x07 / 0x08, saved by the host. Each
-- capture blocks the loop for about 1-3 s, so at 1-2 s the real rate is set
-- by the transfer, not the interval: shots that fall behind are dropped, not
-- queued. Without a host nothing is shot and the series waits.
--
-- In the background the module is ticked once per BG_TICK_PERIOD (1 s in
-- frame_app.lua), so shots land on whole seconds there.
local camera = require('camera.min')

local _M = {}

_M.label = 'Time series'
_M.mode = 'app'

local INTERVALS  = { 1, 2, 4, 8, 10, 20, 30, 40, 60 }   -- seconds
local RESOLUTION = 512       -- px, square; same as modules/photo.lua
local QUALITY    = 'MEDIUM'
local WARMUP     = 1.5       -- seconds of auto exposure before the first shot

local idx      = 3      -- INTERVALS[idx] is the chosen interval; 4 s
local shooting = false
local next_at  = 0      -- utc() of the next shot
local sent     = 0
local failed   = 0

local function interval() return INTERVALS[idx] end

-- '1 2 [4] 8 10 20 30 40 60' -- single spaces, or nine values do not fit
local function scale()
  local parts = {}
  for i, v in ipairs(INTERVALS) do
    parts[#parts + 1] = (i == idx) and ('[' .. v .. ']') or tostring(v)
  end
  return table.concat(parts, ' ') .. ' s'
end

local function status()
  if not shooting then return 'stopped, tap = start' end
  if not frame.bluetooth.is_connected() then return 'no host, waiting' end
  local wait = math.max(0, math.ceil(next_at - frame.time.utc()))
  return 'next in ' .. wait .. 's, tap = stop'
end

-- Three lines; frame_app.lua draws one per '\n'.
local function screen()
  return scale() .. '\n' .. status() .. '\n' ..
         string.format('sent %d  failed %d', sent, failed)
end

-- Keep running in the background only while there is a series to keep.
function _M.background()
  return shooting
end

local function shoot()
  local ok = pcall(camera.capture_and_send, {
    resolution = RESOLUTION, quality = QUALITY, pan = 0, raw = false,
  })
  if ok then
    sent = sent + 1
  else
    failed = failed + 1
    -- Most likely the camera was powered down under us -- the Camera module
    -- does that on exit. Power it back for the next shot.
    pcall(frame.camera.power_save, false)
  end
end

function _M.tick()
  if shooting then
    pcall(camera.run_auto_exposure)
    local now = frame.time.utc()
    if now >= next_at and frame.bluetooth.is_connected() then
      shoot()
      -- Keep the rhythm, but never schedule into the past: a transfer
      -- slower than the interval drops the backlog instead of bursting.
      next_at = math.max(next_at + interval(), frame.time.utc())
    end
  end
  return screen()
end

function _M.on_tap()
  if shooting then
    shooting = false
    pcall(frame.camera.power_save, true)
  else
    shooting = true
    sent, failed = 0, 0
    pcall(frame.camera.power_save, false)
    next_at = frame.time.utc() + WARMUP   -- exposure settles first
  end
  return screen()
end

function _M.on_roll(dir)
  local i = idx + dir
  if i < 1 or i > #INTERVALS then return nil end   -- at the end of the scale
  idx = i
  if shooting then
    -- a shorter interval should not wait out the old, longer one
    next_at = math.min(next_at, frame.time.utc() + interval())
  end
  return screen()
end

-- Closed for good. The interval is kept for next time; the counters stay on
-- screen until the next series starts.
function _M.stop()
  shooting = false
  pcall(frame.camera.power_save, true)
end

return _M

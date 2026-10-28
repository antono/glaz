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
-- Before each photo it sends PHOTO_FROM [0x1A, series]: the number of this
-- series, 1..255, new on every start. The phone puts a series in a folder of
-- its own, named by when it started (docs/PROTOCOL.md, "Photos").
--
-- In the background the module is ticked once per BG_TICK_PERIOD (1 s in
-- glaz.lua), so shots land on whole seconds there.
local camera = require('camera.min')

local _M = {}

_M.label = 'Time series'
_M.mode = 'app'

local INTERVALS  = { 1, 2, 4, 8, 10, 20, 30, 40, 60 }   -- seconds
-- Defaults; the phone may set others (Glaz > Menu > Time series).
local RESOLUTION = 512       -- px, square; same as modules/photo.lua
local QUALITY    = 'MEDIUM'
local QUALITIES  = { VERY_LOW = true, LOW = true, MEDIUM = true, HIGH = true,
                     VERY_HIGH = true }
local WARMUP     = 1.5       -- seconds of auto exposure before the first shot
local PHOTO_FROM = 0x1A

local idx      = 3      -- INTERVALS[idx] is the chosen interval; 4 s
local shooting = false
local next_at  = 0      -- utc() of the next shot
local sent     = 0
local failed   = 0
local series   = 0      -- number of the current series, for PHOTO_FROM

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

-- Three lines; glaz.lua draws one per '\n'.
local function screen()
  return scale() .. '\n' .. status() .. '\n' ..
         string.format('sent %d  failed %d', sent, failed)
end

-- Keep running in the background only while there is a series to keep.
function _M.background()
  return shooting
end

local function shoot()
  for _ = 1, 50 do
    if pcall(frame.bluetooth.send, string.char(PHOTO_FROM, series)) then
      break
    end
    frame.sleep(0.01)
  end
  local res = _M.host.setting('resolution', RESOLUTION)
  -- even, whole: the firmware's luaL_checkinteger fails a fraction, and
  -- every shot of the series would fail with it
  if res % 2 ~= 0 or res < 100 or res > 720 then res = RESOLUTION end
  local q = _M.host.setting('quality', QUALITY)
  if not QUALITIES[q] then q = QUALITY end
  local ok = pcall(camera.capture_and_send, {
    resolution = res, quality = q, pan = 0, raw = false,
  })
  if ok then
    sent = sent + 1
  else
    failed = failed + 1
    -- Most likely the camera was powered down under us -- by the app's
    -- release_hardware() between modules, or the host's break. Power it
    -- back for the next shot.
    pcall(frame.camera.power_save, false)
  end
end

function _M.tick()
  if shooting then
    pcall(camera.run_auto_exposure)
    local now = frame.time.utc()
    if now >= next_at and frame.bluetooth.is_connected() then
      shoot()
      -- Keep the rhythm, but drop a backlog instead of bursting: a shot a
      -- whole interval late (the link was gone, the transfer was slow)
      -- starts the rhythm again from itself, and a transfer slower than
      -- the interval is followed by the next shot straight away.
      next_at = next_at + interval()
      if next_at <= now then next_at = now + interval() end
      next_at = math.max(next_at, frame.time.utc())
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
    -- the phone's interval, if set, is where a new series starts; tilt
    -- still changes it while shooting
    local want = _M.host.setting('interval', 0)
    for i, v in ipairs(INTERVALS) do
      if v == want then idx = i end
    end
    -- from the clock, not a counter: glaz.lua drops this module when
    -- it stops, and a counter would start at 1 again and run into the
    -- previous series on the phone
    series = math.floor(frame.time.utc()) % 255 + 1
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

-- Closed for good. glaz.lua drops the module then, so it opens again at
-- 4 s with nothing counted; the phone's interval is where a series starts.
function _M.stop()
  shooting = false
  pcall(frame.camera.power_save, true)
end

return _M

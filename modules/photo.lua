-- Menu module: take a photo and send it to the host. ASCII only, see
-- docs/PROTOCOL.md.
--
--   single tap -- take a photo
--   double tap -- back to the menu (handled by frame_app.lua)
--
-- The glasses cannot show a JPEG (16-colour display, no decoder), so a photo
-- only makes sense with a host: it is sent over Bluetooth in chunks with the
-- frame_msg camera library (flags 0x07 / 0x08) and the host saves it. With no
-- host connected the module says so and does not shoot.
--
-- Named photo.lua, not camera.lua, so it is not confused with the library
-- camera.min.lua that it uses. Only capture_and_send() and
-- run_auto_exposure() are used from it: its auto-exposure and metering
-- messages use 0x11 / 0x12, which collide with this app's menu events.
--
-- Before each photo it sends PHOTO_FROM [0x1A, 0]: 0 says "a single shot",
-- so the phone files it under the day rather than in a series folder
-- (docs/PROTOCOL.md, "Photos").
--
-- The camera is powered only while this module is open. frame_app.lua powers
-- it down again on every exit path (release_hardware), stop() included.
local camera = require('camera.min')

local _M = {}

_M.label = 'Camera'
_M.mode = 'app'
_M.background = false  -- sleeps: stopped as soon as it leaves the screen

-- Defaults; the phone may set others (Glaz > Menu > Camera, _M.host.setting).
local RESOLUTION = 512       -- px, square; any even number 100..720
local QUALITY    = 'MEDIUM'  -- VERY_LOW .. VERY_HIGH; bigger = slower to send
local QUALITIES  = { VERY_LOW = true, LOW = true, MEDIUM = true, HIGH = true,
                     VERY_HIGH = true }

-- The capture settings, as the phone last set them, checked: a bad value
-- falls back to the default rather than failing the shot.
local function capture_args()
  local res = _M.host.setting('resolution', RESOLUTION)
  if res % 2 == 1 or res < 100 or res > 720 then res = RESOLUTION end
  local q = _M.host.setting('quality', QUALITY)
  if not QUALITIES[q] then q = QUALITY end
  return { resolution = res, quality = q, pan = 0, raw = false }
end
-- Auto exposure needs to run for a while before the first shot, or the
-- picture comes out dark. It is run on every tick while the module is open;
-- a tap that comes sooner runs it here until this much time has passed.
local WARMUP     = 1.5       -- seconds
local AE_STEP    = 0.1       -- seconds between exposure updates while warming

local PHOTO_FROM = 0x1A

local opened_at = 0
local shots = 0

local function status()
  if not frame.bluetooth.is_connected() then
    return 'no host'
  end
  if shots == 0 then
    return 'tap = photo'
  end
  return 'sent ' .. shots .. ', tap = photo'
end

function _M.start()
  frame.camera.power_save(false)
  opened_at = frame.time.utc()
  shots = 0
end

function _M.tick()
  pcall(camera.run_auto_exposure)
  return status()
end

function _M.on_tap()
  if not frame.bluetooth.is_connected() then
    return 'no host'
  end

  while frame.time.utc() - opened_at < WARMUP do
    pcall(camera.run_auto_exposure)
    frame.sleep(AE_STEP)
  end

  -- the photo's label; worth a retry, the radio may still be busy
  for _ = 1, 50 do
    if pcall(frame.bluetooth.send, string.char(PHOTO_FROM, 0)) then break end
    frame.sleep(0.01)
  end

  -- Blocks the app loop for the length of the transfer, about 1-3 s at this
  -- size. Taps that arrive meanwhile are counted by the callback and handled
  -- afterwards.
  local ok = pcall(camera.capture_and_send, capture_args())
  if not ok then
    return 'send failed'
  end
  shots = shots + 1
  return status()
end

function _M.stop()
  pcall(frame.camera.power_save, true)
end

return _M

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
-- The camera is powered only while this module is open. frame_app.lua powers
-- it down again on every exit path (release_hardware), stop() included.
local camera = require('camera.min')

local _M = {}

_M.label = 'Camera'
_M.mode = 'app'

local RESOLUTION = 512       -- px, square; any even number 100..720
local QUALITY    = 'MEDIUM'  -- VERY_LOW .. VERY_HIGH; bigger = slower to send
-- Auto exposure needs to run for a while before the first shot, or the
-- picture comes out dark. It is run on every tick while the module is open;
-- a tap that comes sooner runs it here until this much time has passed.
local WARMUP     = 1.5       -- seconds
local AE_STEP    = 0.1       -- seconds between exposure updates while warming

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

  -- Blocks the app loop for the length of the transfer, about 1-3 s at this
  -- size. Taps that arrive meanwhile are counted by the callback and handled
  -- afterwards.
  local ok = pcall(camera.capture_and_send, {
    resolution = RESOLUTION, quality = QUALITY, pan = 0, raw = false,
  })
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

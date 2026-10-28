-- Menu module: take a photo and send it to the host. ASCII only, see
-- docs/PROTOCOL.md.
--
--   single tap -- take a photo
--   double tap -- back to the menu (handled by glaz.lua)
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
-- A cross marks where the photo's centre is: the camera sees far wider
-- than the display -- the display is about half the photo's width and a
-- third of its height (measured: docs/PROTOCOL.md, "Photos") -- so no
-- frame round the photo fits on it, but its middle does. The camera sits
-- on the bridge, the display before the right eye: the centre falls left
-- of the display's and below it, by how much depends a little on the
-- distance. Where, the phone may set (aim_x, aim_y; Glaz > Menu > Camera).
--
-- The camera is powered only while this module is open. glaz.lua powers
-- it down again on every exit path (release_hardware, in quit()) but
-- with a module in the background; then stop() does, unless that one is
-- a Timeseries series, which shoots with it ('camera is asleep').
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
  -- % 2 ~= 0 also takes 137.5, which capture() cannot (luaL_checkinteger)
  local res = _M.host.setting('resolution', RESOLUTION)
  if res % 2 ~= 0 or res < 100 or res > 720 then res = RESOLUTION end
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

-- The cross: the photo's centre on the display, measured at 60 cm.
local AIM_X, AIM_Y = 261, 327
local ARM, GAP     = 24, 8    -- px: each arm's length, and the hole
local AIM_PALETTE  = 7        -- YELLOW
local H_ARM = string.rep('\xFF', ARM // 8 * 2)   -- 2 px high
local V_ARM = string.rep('\x18', ARM)            -- 2 px wide, in 8

local function aim()
  local x = _M.host.setting('aim_x', AIM_X)
  local y = _M.host.setting('aim_y', AIM_Y)
  local reach = ARM + GAP + 8
  x = math.max(reach, math.min(640 - reach, math.floor(x)))
  y = math.max(reach, math.min(400 - reach, math.floor(y)))
  return x, y
end

-- Called by glaz.lua under the top bar, before the status text.
function _M.draw()
  local bitmap = frame.display.bitmap
  local x, y = aim()
  bitmap(x - GAP - ARM, y - 1, ARM, 2, AIM_PALETTE, H_ARM)
  bitmap(x + GAP, y - 1, ARM, 2, AIM_PALETTE, H_ARM)
  bitmap(x - 4, y - GAP - ARM, 8, 2, AIM_PALETTE, V_ARM)
  bitmap(x - 4, y + GAP, 8, 2, AIM_PALETTE, V_ARM)
end

local opened_at = 0
local shots = 0
local failed = false   -- the last shot did not reach the phone
local beside = nil     -- the background module's label, at start()

-- What tick() shows too, so a failed shot stays said until the next one
-- goes through, rather than for a quarter of a second.
local function status()
  if not frame.bluetooth.is_connected() then
    return 'no host'
  end
  if failed then
    return 'send failed, tap = photo'
  end
  if shots == 0 then
    return 'tap = photo'
  end
  return 'sent ' .. shots .. ', tap = photo'
end

function _M.start(ctx)
  beside = ctx and ctx.background
  frame.camera.power_save(false)
  opened_at = frame.time.utc()
  shots = 0
  failed = false
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
  failed = not ok
  if not ok then
    return status()
  end
  shots = shots + 1
  return status()
end

function _M.stop()
  if beside ~= 'Time series' then pcall(frame.camera.power_save, true) end
end

return _M

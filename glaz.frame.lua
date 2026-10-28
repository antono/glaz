-- glaz.lua's part for Frame (glaz_app.frame.lua on the glasses): the
-- screen, drawing, the top bar and file modes. glaz.lua takes it as
-- D. ASCII only. The parts are docs/DEVICES.md; Halo's is
-- glaz.halo.lua, with the same names.
--
-- Measured on device, firmware v25.080.0838:
--   * frame.display.clear() does NOT exist; the buffer resets itself after
--     show(), so each frame redraws everything -- and nothing may be drawn
--     until that reset is over, see show()
--   * x=1 is outside the visible field of view -- the first character gets
--     clipped. Everything is drawn at LEFT_X instead.
--   * the framebuffer is 640x400 but the wearer does not see all of it:
--     y=340 is visible, y=370 is not, so the bottom is clipped. Centring
--     must use VISIBLE_BOTTOM, not 400, or it lands low.
--   * the built-in font is NOT monospaced, so positioning each piece of
--     text by a single character width never lines up: 'okulo' is narrower
--     than five average glyphs. The width of '<' is 22px; the firmware
--     handles every other advance itself, as long as a whole string is
--     drawn in one call. CHAR_W is only a rough average, for centring.
local disp = frame.display
local D = {}

local SCREEN_W, VISIBLE_BOTTOM = 640, 340
local CHAR_W, CHAR_H, BRACKET_W = 20, 24, 22
local LEFT_X = 60

-- The list: a row is 55px. The breadcrumb sits above it, close to the top
-- edge (y=1 is visible), so five rows still fit: the last one starts at 285
-- and ends near 326, inside VISIBLE_BOTTOM. Notifications get 26
-- characters a line, under the 29 of (640 - LEFT_X) / CHAR_W: the font is
-- proportional and overflow is dropped.
D.layout = {
  row_h = 55, top_y = 65, left_x = LEFT_X,
  visible_rows = 5, text_rows = 3,   -- module output: rows 3..5
  notice_chars = 26,
}

-- The most a file's read() gives: a line is cut at LUAL_BUFFERSIZE, and
-- its break comes with the next read() (file.c). Halo's reads whole lines.
D.read_piece = 512

-- Text at x, y in a palette colour (name; nil draws the default, WHITE).
function D.text(s, x, y, color)
  if color then
    disp.text(s, x, y, { color = color })
  else
    disp.text(s, x, y)
  end
end

-- show() only asks the FPGA to flip, and returns at once. The flip waits
-- for the panel to finish its frame, and then the new back buffer is
-- zeroed -- about 30 ms in all (display_buffers.sv). A draw in that window
-- lands in the buffer being shown or is wiped by the zeroing, so pixels go
-- missing. So every flip waits here until the FPGA's buffer status
-- (register 0x18, bit 1: switch pending or clearing) says the back buffer
-- is free again.
local SHOW_WAIT = 0.1   -- seconds; a stuck status must not hang the app

function D.show()
  disp.show()
  local deadline = frame.time.utc() + SHOW_WAIT
  while frame.time.utc() < deadline do
    local ok, status = pcall(frame.fpga_read, 0x18, 1)
    if not ok or string.byte(status) & 2 == 0 then return end
  end
end

-- A screen begins: the back buffer is empty after every flip already.
function D.begin() end

-- An empty screen. There is no clear(): a single space, flipped.
function D.blank()
  disp.text(' ', LEFT_X, D.layout.top_y)
  D.show()
end

-- The panel on or off (power_save keeps what is drawn).
function D.power(on)
  disp.power_save(not on)
end

-- The top bar, one row at CRUMB_Y, left to right: the breadcrumb, the
-- background icon, the Bluetooth icon, the clock and the battery level.
-- The right-hand pieces have fixed x positions, so the breadcrumb is cut
-- short in front of whichever comes first. Positions are estimates for a
-- proportional font: '100%' must end before x=640, or the firmware drops
-- the glyphs that do not fit.
local CRUMB_Y   = 10
local TIME_X    = 430   -- 'HH:MM', or '--:--' until the host sets it
local BATTERY_X = 545   -- '84%'

local ICON_X, BT_X, ICON_Y, ICON_W = 376, 400, CRUMB_Y + 10, 16

-- guarded: a bad bitmap call must not take the screen down
local function icon(x, pick)
  pcall(disp.bitmap, x, ICON_Y, ICON_W, 2, pick[1], pick[2])
end

-- bar: path(n) (the breadcrumb cut to n characters), icon (the background
-- or recording icon, or nil) and link (the link's), each { palette offset,
-- bits }, clock, level (percent or nil), low (the level is low). See
-- draw_top_bar in glaz.lua.
function D.top_bar(bar)
  if bar.icon then icon(ICON_X, bar.icon) end
  icon(BT_X, bar.link)
  -- the width is only estimated: the font is proportional, see CHAR_W
  local right_x = (bar.icon and ICON_X or BT_X) - CHAR_W // 2
  D.text(bar.path((right_x - LEFT_X) // CHAR_W), LEFT_X, CRUMB_Y, 'SKYBLUE')
  D.text(bar.clock, TIME_X, CRUMB_Y, 'GREY')
  if bar.level then
    D.text(bar.level .. '%', BATTERY_X, CRUMB_Y, bar.low and 'RED' or 'GREY')
  end
end

-- What a module may have left on: the camera, powered at boot too, and
-- the microphone. A module that wants the camera must call
-- frame.camera.power_save(false) first: while saving, only camera.read()
-- and camera.read_raw() remain available.
function D.release_hardware()
  pcall(frame.camera.power_save, true)
  pcall(frame.microphone.stop)
end

-- Taps: the firmware calls once for every hit, and glaz.lua counts them
-- (hit; see tap_hit there).
function D.taps(hit)
  frame.imu.tap_callback(hit)
end

-- What the accelerometer wakes the glasses with: the firmware's defaults.
-- A tap wakes the nRF; since firmware glaz it then takes a second
-- one for the glasses to stay awake. See docs/FIRMWARE.md.
local WAKE_TAPS = { threshold = 7, quiet = 0, duration = 0, latch = true,
                    axes = 0x08, rate = 256 }

-- Deep sleep, which a tap wakes from, as a reset. The accelerometer goes to
-- sleep with whatever it was last set to: Tap tune's harder threshold or
-- longer duration, and it took many taps or none woke them (firmware
-- glaz/main). The stock settings go back first; setting them also clears a
-- tap still latched, which would hold the wake-up line where no tap can
-- move it. Stock firmware has no tap_config, and needs neither.
function D.sleep()
  if frame.imu.tap_config then pcall(frame.imu.tap_config, WAKE_TAPS) end
  frame.sleep()
end

-- '<glaz>' centred, with the brackets in a second colour. Two overlapping
-- draws, not three adjacent ones. The whole string goes down in the
-- bracket colour first, so the firmware computes every advance; then the
-- word alone is drawn over it in the text colour, offset by the width of
-- '<'. This needs exactly one measured number; placing three separate
-- pieces needs two offsets, and with a proportional font neither can be
-- derived from a character count.
function D.splash(word, color, brackets)
  local full = '<' .. word .. '>'
  local x = (SCREEN_W - #full * CHAR_W) // 2
  local y = (VISIBLE_BOTTOM - CHAR_H) // 2
  D.text(full, x, y, brackets)
  D.text(word, x + BRACKET_W, y, color)
end

return D

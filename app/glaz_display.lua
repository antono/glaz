-- The display, Frame's or Halo's: what frame_app.lua draws through, so the
-- menu, the top bar and module text land right on either. ASCII only.
--
-- Frame: 640x400, a back buffer that show() flips, colours by palette name,
-- a proportional font; the bottom is clipped below y=340 (docs/PROTOCOL.md,
-- "Layout").
-- Halo: 256x256 and round, every call draws at once (show() does nothing),
-- colours are 0xRRGGBB, the font is Dogica, as wide as it is high, in
-- multiples of 8 px, printable ASCII only (docs/HALO.md). Each screen is
-- drawn from a cleared panel, and a line is cut to the circle at its height.
--
-- Halo answers frame.display.width() with 256; Frame has no width().

local D = frame.display
local M = {}

local ok, w = pcall(D.width)
M.halo = ok and w == 256

-- Frame's palette by name (DawnBringer 16, as the firmware sets it), for
-- Halo, which takes the colour itself.
local RGB = {
  VOID = 0x000000, WHITE = 0xFFFFFF, GREY = 0x9D9D9D, RED = 0xBE2633,
  PINK = 0xE06F8B, DARKBROWN = 0x493C2B, BROWN = 0xA46422,
  ORANGE = 0xEB8931, YELLOW = 0xF7E26B, DARKGREEN = 0x2F484E,
  GREEN = 0x44891A, LIGHTGREEN = 0xA3CE27, NIGHTBLUE = 0x1B2632,
  SEABLUE = 0x005784, SKYBLUE = 0x31A2F2, CLOUDBLUE = 0xB2DCEF,
}
M.RGB = RGB

-- Layout, in frame_app.lua's names. Frame's are the measured ones from
-- before Halo. Halo's: rows of 16 px text, 30 px apart, five of them
-- around the middle where the circle is widest; the clock and battery
-- (8 px) near the top edge, the breadcrumb under them, the icons at the
-- bottom.
if M.halo then
  M.layout = {
    screen_w = 256, visible_bottom = 256,
    row_h = 30, crumb_y = 42, top_y = 62, left_x = 20,
    visible_rows = 5, text_rows = 3,
    char_w = 16, char_h = 16, bracket_w = 16, small = 8,
    status_y = 26, icon_x = 104, bt_x = 136, icon_y = 206,
    notice_chars = 12,
  }
else
  M.layout = {
    screen_w = 640, visible_bottom = 340,
    row_h = 55, crumb_y = 10, top_y = 65, left_x = 60,
    visible_rows = 5, text_rows = 3,
    char_w = 20, char_h = 24, bracket_w = 22,
    icon_x = 376, bt_x = 400, icon_y = 20,
    notice_chars = 26,
  }
end

local L = M.layout
local CX, CY, R = 128, 128, 118   -- Halo: the circle, inside its edge

-- Halo's font has printable ASCII only: anything else becomes '?', one per
-- character, so lengths stay right.
local function ascii(s)
  s = utf8.len(s) and string.gsub(s, utf8.charpattern, function(c)
    return #c > 1 and '?' or c
  end) or s
  return (string.gsub(s, '[^\32-\126]', '?'))
end
M.ascii = ascii

-- Halo: how many characters of [size] px fit on a line whose top is y,
-- inside the circle. Frame: as many as asked for.
function M.fit(y, size)
  if not M.halo then return math.huge end
  size = size or L.char_w
  local d = math.max(math.abs(y - CY), math.abs(y + size - CY))
  if d >= R then return 0 end
  local half = math.sqrt(R * R - d * d)
  return math.max(math.floor((2 * half - 8) / size), 0)
end

-- Text in a palette colour (name, nil for WHITE). Frame draws it at x;
-- Halo ignores x: the text is cut to the circle at y and centred. size:
-- Halo's font size, the row size if nil.
function M.text(s, x, y, color, size)
  if not M.halo then
    if color then
      D.text(s, x, y, { color = color })
    else
      D.text(s, x, y)
    end
    return
  end
  size = size or L.char_w
  s = ascii(s)
  local n = M.fit(y, size)
  if #s > n then s = string.sub(s, 1, n) end
  if s == '' then return end
  D.set_font(0, size, 1)
  D.text(s, CX - (#s * size) // 2 + 1, math.floor(y), RGB[color or 'WHITE'])
end

-- Frame's show() only asks the FPGA to flip, and returns at once. The flip
-- waits for the panel to finish its frame, and then the new back buffer is
-- zeroed -- about 30 ms in all (display_buffers.sv). A draw in that window
-- lands in the buffer being shown or is wiped by the zeroing, so pixels go
-- missing. So every flip waits here until the FPGA's buffer status
-- (register 0x18, bit 1: switch pending or clearing) says the back buffer
-- is free again. Halo has drawn already.
local SHOW_WAIT = 0.1   -- seconds; a stuck status must not hang the app

function M.show()
  if M.halo then return end
  D.show()
  local deadline = frame.time.utc() + SHOW_WAIT
  while frame.time.utc() < deadline do
    local ok, status = pcall(frame.fpga_read, 0x18, 1)
    if not ok or string.byte(status) & 2 == 0 then return end
  end
end

-- A screen begins here. Frame's back buffer is empty after every flip;
-- Halo's panel keeps what was drawn, so it is cleared.
function M.begin()
  if M.halo then D.clear() end
end

-- An empty screen. Frame has no clear(): a single space, flipped.
function M.blank()
  if M.halo then
    D.clear()
  else
    D.text(' ', L.left_x, L.top_y)
    M.show()
  end
end

return M

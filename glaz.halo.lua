-- glaz.lua's part for Halo (glaz_app.halo.lua on the glasses): the
-- screen, drawing, the top bar and file modes. glaz.lua takes it as
-- D. ASCII only. The parts are docs/DEVICES.md; Frame's is
-- glaz.frame.lua, with the same names. Not yet tried on a Halo.
--
-- Halo's display (docs/HALO.md): 256x256 and round, every call draws at
-- once and the panel keeps it (no show(), clear() empties it), colours
-- are 0xRRGGBB numbers, the font is Dogica, as wide as it is high, in
-- multiples of 8 px, printable ASCII only. So text is centred on its row
-- and cut to the circle's width there, and each screen starts cleared.
local disp = frame.display
local D = {}

local CX, CY, R = 128, 128, 118   -- the circle, inside its edge
local SIZE, SMALL = 16, 8         -- rows; the top bar

-- Rows of 16 px text, 30 px apart, five of them around the middle where
-- the circle is widest; x is ignored (text is centred). The top and
-- bottom rows hold 11 characters, the middle ones 13 or 14 (fit()), so
-- notifications are wrapped at 11.
D.layout = {
  row_h = 30, top_y = 62, left_x = 0,
  visible_rows = 5, text_rows = 3,
  notice_chars = 11,
}

-- Frame's palette by name (DawnBringer 16, as Frame's firmware sets it),
-- so the app's colours look the same here.
local RGB = {
  VOID = 0x000000, WHITE = 0xFFFFFF, GREY = 0x9D9D9D, RED = 0xBE2633,
  PINK = 0xE06F8B, DARKBROWN = 0x493C2B, BROWN = 0xA46422,
  ORANGE = 0xEB8931, YELLOW = 0xF7E26B, DARKGREEN = 0x2F484E,
  GREEN = 0x44891A, LIGHTGREEN = 0xA3CE27, NIGHTBLUE = 0x1B2632,
  SEABLUE = 0x005784, SKYBLUE = 0x31A2F2, CLOUDBLUE = 0xB2DCEF,
}
D.RGB = RGB

-- The font has printable ASCII only: anything else becomes '?', one per
-- character, so lengths stay right.
local function ascii(s)
  s = utf8.len(s) and string.gsub(s, utf8.charpattern, function(c)
    return #c > 1 and '?' or c
  end) or s
  return (string.gsub(s, '[^\32-\126]', '?'))
end
D.ascii = ascii

-- How many characters of size px fit on a line whose top is y, inside the
-- circle.
function D.fit(y, size)
  size = size or SIZE
  local d = math.max(math.abs(y - CY), math.abs(y + size - CY))
  if d >= R then return 0 end
  local half = math.sqrt(R * R - d * d)
  return math.max(math.floor((2 * half - 8) / size), 0)
end

-- Text on the row at y in a palette colour (name, nil for WHITE), cut to
-- the circle there and centred; x is Frame's and ignored. size: the font
-- size, a row's if nil.
function D.text(s, _, y, color, size)
  size = size or SIZE
  s = ascii(s)
  local n = D.fit(y, size)
  if #s > n then s = string.sub(s, 1, n) end
  if s == '' then return end
  disp.set_font(0, size, 1)
  disp.text(s, CX - (#s * size) // 2 + 1, math.floor(y), RGB[color or 'WHITE'])
end

-- Drawn already: nothing to put on the screen.
function D.show() end

-- A screen begins: the panel keeps what was drawn, so it is cleared.
function D.begin()
  disp.clear()
end

function D.blank()
  disp.clear()
end

-- The panel on or off (power_save keeps what is drawn).
function D.power(on)
  pcall(disp.power_save, not on)
end

-- The top bar: the clock and the battery in one centred line near the top
-- edge, the breadcrumb under it, and the icons side by side at the bottom.
-- Halo's bitmap() takes Frame's icons as they are, palette and all.
local STATUS_Y, CRUMB_Y = 26, 42
local ICON_X, BT_X, ICON_Y, ICON_W = 104, 136, 206, 16

-- guarded: a bad bitmap call must not take the screen down
local function icon(x, pick)
  pcall(disp.bitmap, x, ICON_Y, ICON_W, 2, pick[1], pick[2])
end

-- bar: as in glaz.frame.lua's D.top_bar.
function D.top_bar(bar)
  local status = bar.clock .. (bar.level and '  ' .. bar.level .. '%' or '')
  D.text(status, 0, STATUS_Y, bar.low and 'RED' or 'GREY', SMALL)
  D.text(bar.path(D.fit(CRUMB_Y, SMALL)), 0, CRUMB_Y, 'SKYBLUE', SMALL)
  if bar.icon then icon(ICON_X, bar.icon) end
  icon(BT_X, bar.link)
end

-- What a module may have left on: the camera and the microphone.
function D.release_hardware()
  pcall(function() frame.camera.power_save(true) end)
  pcall(function() frame.microphone.stop() end)
end

-- Taps: the firmware counts them and says the gesture whole, 'single',
-- 'double' or 'triple' (gesture; see tap_gesture in glaz.lua).
local TAPS = { single = 1, double = 2, triple = 3 }
local on_tap = nil   -- the callback, wired again after standby

function D.taps(_, gesture)
  on_tap = function(kind)
    local n = TAPS[kind]
    if n then gesture(n) end
  end
  frame.imu.tap_callback(on_tap)
end

-- Sleep that a tap wakes from: standby() keeps Bluetooth and returns on a
-- tap, the button or sound. sleep() would drop Bluetooth, and only the
-- button would wake the glasses. The tap callback is set again after it:
-- Santos (docs/HALO.md) found taps gone after waking from standby.
function D.sleep()
  frame.standby()
  if on_tap then pcall(frame.imu.tap_callback, on_tap) end
end

-- '<glaz>' centred, the brackets in a second colour: one width for every
-- character, so the word drawn alone, centred too, lands inside them.
function D.splash(word, color, brackets)
  disp.clear()   -- over whatever was drawn: a notification, say
  local y = CY - SIZE // 2
  D.text('<' .. word .. '>', 0, y, brackets)
  D.text(word, 0, y, color)
end

return D

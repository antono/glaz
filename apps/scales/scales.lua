-- Menu module: scales on the fretboard of a guitar, bass, banjo, ukulele
-- or balalaika, two at once, so the player sees the safe minor pentatonic
-- and the mode it grows into, and picks the colour to improvise with.
-- ASCII only, see docs/PROTOCOL.md and docs/SCALES.md.
--
-- It opens on the instruments: tilt to one, tap to take it. Then:
--
--   tilt right / left -- the next box up / down the neck
--   single tap        -- the next scale
--   double tap        -- back to the instruments; there, to the menu
--
-- A Flipper or a keyboard does the same through the phone (docs/REMOTE.md):
-- Left and Right tilt, OK taps, Back is the double tap, and Up and Down
-- (on_up_down) pick the previous / next scale. The key and the view (two
-- scales or one) are set on the phone, Glaz > Menu > Scales.
--
-- Two at once: a scale under the pentatonic it grows from, the minor one
-- or, for a major scale, the major one. Colours: the root red, the scale's
-- own note -- the one that makes it what it is, Dorian's raised 6th --
-- green, the rest white. Frame only for now.
--
-- The scales live on the phone (flutter-glaz/lib/services/scales.dart):
-- the glasses keep only the one on screen, for their memory's sake. They
-- ask for scale n (0-based) with SCALE_GET [0x02, n]; the phone answers
-- with remote(arg) (MODULE_CALL 'scales'):
--   'g<n> <count> <name>|<short>|<notes>|<flavour>|<base short>|<base notes>'
-- notes a hex digit each, semitones above the root; flavour one digit or
-- none; the base empty for a pentatonic, which is shown alone. Without a
-- phone the minor pentatonic, built in, is all there is.
local _M = {}

_M.label = 'Scales'
_M.mode = 'app'
_M.background = false
_M.quiet = true           -- draw() is the screen; tick() text is not shown

-- semitones above C, for the key set on the phone
local KEYS = { C = 0, ['C#'] = 1, D = 2, Eb = 3, E = 4, F = 5, ['F#'] = 6,
               G = 7, Ab = 8, A = 9, Bb = 10, B = 11 }

local SCALE_GET = 0x02

-- Semitones above the root; flavour the scale's own note, drawn green;
-- base the pentatonic it is shown against, whose boxes it takes.
local MINOR_PENT = { name = 'minor pent', short = 'm pent',
                     notes = { 0, 3, 5, 7, 10 } }

-- Instruments: open strings as semitones above C, drawn from the first
-- (the highest) on top. Boxes start on the string ref (the lowest unless
-- said); last is the highest fret a box may reach. The banjo's 5th string
-- is short: it starts at fret 5 (from), nothing is drawn below that.
local INSTRUMENTS = {
  { name = 'Guitar',    strings = { 4, 11, 7, 2, 9, 4 }, last = 22 },  -- EADGBE
  { name = 'Bass',      strings = { 7, 2, 9, 4 }, last = 20 },         -- EADG
  { name = 'Banjo',     strings = { 2, 11, 7, 2, 7 }, ref = 4, last = 22,
    from = { [5] = 5 } },                                              -- gDGBD
  { name = 'Ukulele',   strings = { 9, 4, 0, 7 }, last = 15 },         -- GCEA
  { name = 'Balalaika', strings = { 9, 4, 4 }, last = 16 },            -- EEA
}

local FRETS    = 6        -- frets in a box, as wide as a hand reaches
local IDLE_MAX = 600      -- s without input before APP_TIMEOUT may close it

-- Layout. The top bar is the app's; this module draws the rest. What the
-- eye sees is x 60..600, y down to 340 (glaz.lua).
local LEFT_X  = 60
local TITLE_Y = 65
local LABEL_Y = 8         -- a label's text, below its board's top string
local DIGIT_W = 21        -- a digit and the space after it, in the font
local ROW_H   = 55        -- the instruments, one a row from TITLE_Y

-- One board: x of its left edge, column width, y of the top string, from
-- the top string to the bottom one, dot size; the top board's frets, y of
-- their numbers under it. Widths are multiples of 8: 1-bit rows of whole
-- bytes.
local DUAL = {
  { x = 192, col = 64, y = 122, h = 70, dot = 10, frets = 201 },
  { x = 192, col = 64, y = 258, h = 70, dot = 10 },
}
local SINGLE = { x = 72, col = 88, y = 135, h = 150, dot = 22, frets = 295 }

-- bitmap palette offsets: a set bit draws index 1 + offset
local WHITE, GREY, RED, LIGHTGREEN = 0, 1, 2, 10

-- A filled circle d px across, in rows of whole bytes
local function circle(d)
  local w = (d + 7) // 8 * 8
  local r = d / 2
  local rows = {}
  for y = 0, d - 1 do
    for b = 0, w // 8 - 1 do
      local byte = 0
      for i = 0, 7 do
        local x = b * 8 + i
        local dx, dy = x + 0.5 - r, y + 0.5 - r
        if x < d and dx * dx + dy * dy <= r * r then
          byte = byte | (0x80 >> i)
        end
      end
      rows[#rows + 1] = string.char(byte)
    end
  end
  return { w = w, d = d, data = table.concat(rows) }
end

local DOTS = {}           -- dot size -> circle

local key, dual = 9, true
local inst, picked = 1, false  -- the instrument; false: choosing it
local scale = MINOR_PENT   -- the one on screen
local n, count = 0, nil    -- its number, of count; nil: the phone not heard
local box = 5             -- the box on screen: its lowest fret
local last_input = 0

-- The boxes: one starting on each note of the pentatonic (the scale's
-- base) on the reference string, all along the neck, from fret 0 to the
-- last one a box fits under the instrument's last fret
local function root_fret()
  local it = INSTRUMENTS[inst]
  return (key - it.strings[it.ref or #it.strings]) % 12
end

local function top_box()
  return INSTRUMENTS[inst].last - FRETS + 1
end

local function is_box(f)
  if f < 0 or f > top_box() then return false end
  local d = (f - root_fret()) % 12
  for _, s in ipairs((scale.base or scale).notes) do
    if s == d then return true end
  end
  return false
end

-- The box nearest fret f, the lower of two as near
local function near_box(f)
  for d = 0, top_box() do
    if is_box(f - d) then return f - d end
    if is_box(f + d) then return f + d end
  end
  return 0
end

-- The next box up (dir 1) or down (-1) from fret f, round the neck
local function next_box(f, dir)
  local top = top_box()
  for _ = 0, top do
    f = f + dir
    if f > top then f = 0 elseif f < 0 then f = top end
    if is_box(f) then return f end
  end
  return near_box(f)
end

-- semitone above the root -> 1 a scale note, 2 the root, 3 the flavour
local function marks(m)
  local t = {}
  for _, n in ipairs(m.notes) do t[n] = 1 end
  t[0] = 2
  if m.flavour then t[m.flavour] = 3 end
  return t
end

local COLOUR = { WHITE, RED, LIGHTGREEN }

local function draw_board(b, m, start)
  local bitmap = frame.display.bitmap
  local it = INSTRUMENTS[inst]
  local strings = it.strings
  local gap = b.h // (#strings - 1)
  local width = b.col * FRETS
  local height = gap * (#strings - 1) + 1
  local line = string.rep('\xFF', width // 8) .. '\xC0'   -- to the last wire
  for i = 1, #strings do
    bitmap(b.x, b.y + (i - 1) * gap, width + 8, 2, GREY, line)
  end
  -- fret wires between the columns; at an open box, a nut after fret 0
  local wire = string.rep('\xC0', height)
  local nut = string.rep('\xF0', height)
  for c = 0, FRETS do
    local w = (start == 0 and c == 1) and nut or wire
    bitmap(b.x + c * b.col, b.y, 8, 2, GREY, w)
  end
  local dot = DOTS[b.dot]
  if not dot then dot = circle(b.dot); DOTS[b.dot] = dot end
  local half = dot.d // 2
  local t = marks(m)
  for i, open in ipairs(strings) do
    local y = b.y + (i - 1) * gap - half
    local from = it.from and it.from[i] or 0
    for c = 0, FRETS - 1 do
      local fret = start + c
      local mark = t[(open + fret - key) % 12]
      if mark and (fret >= from or fret == 0) then
        bitmap(b.x + c * b.col + b.col // 2 - half, y, dot.w, 2,
               COLOUR[mark], dot.data)
      end
    end
  end
end

-- The top board's frets: a number under each column
local function draw_frets(b, start)
  for c = 0, FRETS - 1 do
    local s = tostring(start + c)
    frame.display.text(s, b.x + c * b.col + (b.col - #s * DIGIT_W + 4) // 2,
                       b.frets, { color = 'GREY' })
  end
end

local NAMES = { 'C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A',
                'Bb', 'B' }

local function draw_instruments()
  for i, it in ipairs(INSTRUMENTS) do
    local on = i == inst
    frame.display.text((on and '> ' or '  ') .. it.name, LEFT_X,
                       TITLE_Y + (i - 1) * ROW_H,
                       { color = on and 'WHITE' or 'GREY' })
  end
end

function _M.draw()
  if not picked then return draw_instruments() end
  local m = scale
  local start = box
  local text = frame.display.text
  text(NAMES[key + 1] .. ' ' .. m.name, LEFT_X, TITLE_Y, { color = 'WHITE' })
  local base = m.base
  if dual and base then
    for i, s in ipairs({ base, m }) do
      local b = DUAL[i]
      text(s.short, LEFT_X, b.y + LABEL_Y, { color = 'GREY' })
      draw_board(b, s, start)
    end
    draw_frets(DUAL[1], start)
  else
    draw_board(SINGLE, m, start)
    draw_frets(SINGLE, start)
  end
end

local function m_name() return scale.name end

-- A hex digit a note: '0357a' -> { 0, 3, 5, 7, 10 }
local function semis(h)
  local t = {}
  for c in h:gmatch('%x') do t[#t + 1] = tonumber(c, 16) end
  return t
end

-- The scale dir away from this one, from the phone; the first if it has
-- not said how many there are
local function ask(dir)
  local want = count and (n + dir) % count or 0
  pcall(frame.bluetooth.send, string.char(SCALE_GET, want))
end

-- What is on screen: any change redraws it
local function state()
  return table.concat({ key, inst, tostring(picked), m_name(), box,
                        tostring(dual) }, ' ')
end

function _M.start()
  key = KEYS[_M.host.setting('key', 'A')] or 9
  dual = _M.host.setting('view', 'dual') ~= 'single'
  picked = false
  last_input = frame.time.utc()
end

function _M.tick()
  return state()
end

function _M.on_roll(dir)
  if picked then
    box = next_box(box, dir)
  else
    inst = (inst - 1 + dir) % #INSTRUMENTS + 1
  end
  last_input = frame.time.utc()
  return state()
end

function _M.on_tap()
  if picked then
    ask(1)
  else
    picked = true
    box = near_box(root_fret())   -- the root's box
    ask(0)   -- the scale on screen, fresh: the phone may have it newer
  end
  last_input = frame.time.utc()
  return state()
end

-- The remote's Up and Down: the previous / next scale; choosing the
-- instrument, the cursor, as a tilt
function _M.on_up_down(dir)
  if not picked then return _M.on_roll(dir) end
  ask(dir)
  last_input = frame.time.utc()
  return state()
end

-- The phone's answer: the scale asked for, as above
function _M.remote(arg)
  local i, c, name, short, notes, flav, bshort, bnotes =
    arg:match('^g(%d+) (%d+) ([^|]*)|([^|]*)|(%x+)|(%x?)|([^|]*)|(%x*)$')
  -- malformed, no scales, or more than SCALE_GET's one byte can ask for
  if not i or tonumber(c) == 0 or tonumber(c) > 256 then return end
  n, count = tonumber(i), tonumber(c)
  scale = { name = name, short = short, notes = semis(notes),
            flavour = flav ~= '' and tonumber(flav, 16) or nil,
            base = bnotes ~= '' and { short = bshort, notes = semis(bnotes) }
                   or nil }
  -- the box on screen, if this scale has one there; else the nearest
  box = near_box(box)
  last_input = frame.time.utc()
  return state()
end

-- From the fretboard back to the instruments; from them, the menu
function _M.on_back()
  if not picked then return false end
  picked = false
  last_input = frame.time.utc()
  return state()
end

-- Playing, the hands are on the guitar: tilts keep it open as taps do,
-- for IDLE_MAX after the last one
function _M.busy()
  return frame.time.utc() - last_input < IDLE_MAX
end

return _M

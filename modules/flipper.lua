-- Menu module: the Flipper Zero's screen, mirrored. ASCII only, see
-- docs/FLIPPER.md.
--
-- The phone holds the Flipper over Bluetooth, takes its screen as it
-- changes and sends the rows that changed; this draws them four times the
-- size, 512x256, lit where the Flipper's pixels are dark. The Flipper's own
-- buttons drive it. A tap keeps it open; frames do too, but not past
-- IDLE without a tap: the Flipper's desktop animates by itself, and would
-- keep the display lit and the glasses awake for good.
--
-- The phone calls remote(arg) (MODULE_CALL 'flipper'):
--   'f' seq mask rows  -- a frame: seq one byte, mask 8 bytes with a bit a
--                         row, row 0 in the high bit of the first, then 32
--                         bytes for each row whose bit is set: a nibble a
--                         byte, 0..15, the row's first four pixels first
--   's' text           -- no frame, the phone says why ('pair the Flipper')
--
-- Messages, Frame -> Host:
--   FLIPPER [0x0B, 1]       -- on screen: start the Flipper's screen
--   FLIPPER [0x0B, 0]       -- gone: stop it
--   FLIPPER [0x0B, 2, seq]  -- frame seq taken: the phone sends the next
-- The phone sends one frame at a time and waits for its seq, so a frame
-- never overwrites one not yet drawn (docs/PROTOCOL.md, "One message per
-- code at a time"). Without an answer it sends every row again.
local _M = {}

_M.label = 'Flipper'
_M.mode = 'app'
_M.fullscreen = true       -- no top bar: the picture and its frame only

local FLIPPER = 0x0B
local WANT, DONE, TAKEN = 1, 0, 2

local ROWS      = 64       -- the Flipper's screen: 128x64, 1 bit a pixel
local ROW_BYTES = 32       -- a row as the phone sends it, a nibble a byte
local SCALE     = 4
local WIDTH     = 128 * SCALE
-- 512x256 centred in what the wearer sees, 640x340 (docs/PROTOCOL.md):
-- x 65..576, y 43..298, Lua's 1-based coordinates.
local X, Y      = 65, 43
-- A set bit draws palette index 1 + PALETTE: ORANGE, the Flipper's own.
local PALETTE   = 6

-- A frame round it, GAP away, LINE thick: BROWN, under the picture's
-- orange. The firmware draws no lines, so bitmaps: the top and the bottom
-- rows of set bits, and the sides a byte wide, two bits of it set. Their
-- widths are whole bytes -- a sprite's height comes from its length, and a
-- part byte would spill onto a row of its own -- so the top and the bottom
-- are each a long piece and a byte-wide one at the right end, overlapping.
local GAP, LINE = 12, 2
local FRAME_PALETTE = 5
local BOX_X, BOX_Y = X - GAP - LINE, Y - GAP - LINE
local BOX_W = WIDTH + 2 * (GAP + LINE)
local BOX_H = ROWS * SCALE + 2 * (GAP + LINE)
local EDGE_W = BOX_W // 8 * 8
local EDGE = string.rep('\xFF', EDGE_W // 8 * LINE)
local END  = string.rep('\xFF', LINE)
local SIDE = string.rep('\xC0', BOX_H - 2 * LINE)
local ASK_AGAIN = 3        -- s without a word from the phone: ask again
local IDLE      = 300      -- s without a tap: closed

local BLANK = string.rep('\0', ROW_BYTES)

local rows = {}            -- row (1-based) -> its 16 bytes; nil if blank
local shown = false        -- a frame has come
local status = 'waiting for the phone'
local asked = nil          -- utc() when WANT went out; nil before
local heard = false        -- the phone has answered since
local touched = nil        -- utc() of the last tap, or of the start

-- A nibble's byte to its pixels, each four times as wide: 4 bits in, 16
-- out, first in the high bit. string.gsub widens a whole row with it in C.
-- Measured on the glasses, 64 rows: widened and drawn in 79 ms. Widening in
-- Lua a byte at a time took 145 ms before drawing, and a table for whole
-- bytes 20 KB of the 30 or so the app leaves free; so the phone splits the
-- bytes, and this table is 16 entries.
local WIDE = {}
for n = 0, 15 do
  local v = 0
  for b = 0, 3 do
    if n & (8 >> b) ~= 0 then v = v | (0xF000 >> (4 * b)) end
  end
  WIDE[string.char(n)] = string.pack('>I2', v)
end

-- Retried a little while the link is busy, as Recorder's: a lost answer
-- costs the phone 1.5 s and a whole frame.
local function send(...)
  local packet = string.char(...)
  for _ = 1, 20 do
    if pcall(frame.bluetooth.send, packet) then return end
    frame.sleep(0.005)
  end
end

-- One row of the Flipper's, as wide as it is drawn: 32 nibbles in, 64
-- bytes out. A byte above 15 would widen to nothing: a short row, which
-- the firmware draws short, never past the row.
local function widen(s)
  return (string.gsub(s, '.', WIDE))
end

-- Called by frame_app.lua under the top bar, the screen otherwise clear.
-- One bitmap a row, four pixel rows high; a blank row draws nothing.
function _M.draw()
  local bitmap = frame.display.bitmap
  for _, y in ipairs({ BOX_Y, BOX_Y + BOX_H - LINE }) do
    bitmap(BOX_X, y, EDGE_W, 2, FRAME_PALETTE, EDGE)
    bitmap(BOX_X + BOX_W - 8, y, 8, 2, FRAME_PALETTE, END)
  end
  bitmap(BOX_X, BOX_Y + LINE, 8, 2, FRAME_PALETTE, SIDE)
  bitmap(BOX_X + BOX_W - LINE, BOX_Y + LINE, 8, 2, FRAME_PALETTE, SIDE)
  for r = 1, ROWS do
    local s = rows[r]
    if s then
      frame.display.bitmap(X, Y + (r - 1) * SCALE, WIDTH, 2, PALETTE,
                           string.rep(widen(s), SCALE))
    end
  end
end

local function take(arg)
  local seq = string.byte(arg, 2)
  local mask = string.sub(arg, 3, 10)
  local at = 11
  for r = 0, ROWS - 1 do
    if string.byte(mask, (r >> 3) + 1) & (0x80 >> (r & 7)) ~= 0 then
      local s = string.sub(arg, at, at + ROW_BYTES - 1)
      at = at + ROW_BYTES
      rows[r + 1] = (#s == ROW_BYTES and s ~= BLANK) and s or nil
    end
  end
  shown = true
  -- answered before it is drawn, but the next frame cannot be collected
  -- before this one is: the loop draws first
  send(FLIPPER, TAKEN, seq)
end

function _M.remote(arg)
  heard = true
  local kind = string.sub(arg, 1, 1)
  if kind == 'f' and #arg >= 10 then
    take(arg)
    return ''
  elseif kind == 's' then
    rows, shown = {}, false
    status = string.sub(arg, 2)
    return status
  end
end

function _M.on_tap()
  touched = frame.time.utc()
end

-- WANT goes from the first tick, not start(): a stray frame after the
-- module closed starts it for a moment off screen, and that must not ask
-- the phone for more. Asked again while the phone says nothing: it was
-- away, or the link came back.
function _M.tick()
  local now = frame.time.utc()
  touched = touched or now
  if now - touched > IDLE then return 'no tap for a while', true end
  if not frame.bluetooth.is_connected() then
    asked, heard = nil, false
    rows, shown = {}, false
    return 'no phone'
  end
  if not heard and (not asked or now - asked > ASK_AGAIN) then
    asked = now
    send(FLIPPER, WANT)
  end
  if shown then return '' end
  return status
end

function _M.stop()
  if asked then send(FLIPPER, DONE) end
  rows, shown = {}, false
  status = 'waiting for the phone'
  asked, heard = nil, false
  touched = nil
end

return _M

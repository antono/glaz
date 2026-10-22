-- Menu module: a terminal, run by the phone. ASCII only.
--
-- The phone holds the SSH session and the terminal's screen, 45x12 cells,
-- and sends the rows that changed; this draws them with frame.display.mono
-- (firmware glaz/main), 28 px high, in the visible 640x340. A keyboard on
-- the phone types into it. A tap keeps it open, typing too; frames alone do
-- not past IDLE: top and the like redraw by themselves, and would keep the
-- display lit and the glasses awake for good.
--
-- The phone calls remote(arg) (MODULE_CALL 'term'):
--   'f' seq flags mask rows  -- a frame: seq one byte; flags bit 0 set
--                               when the wearer typed since the last;
--                               mask 2 bytes, a bit a row, row 1 in the
--                               high bit; then for each row whose bit is
--                               set: n, one byte, then n characters and
--                               n attribute bytes, a byte a cell, as
--                               frame.display.mono's attrs
--   's' text                 -- no screen, the phone says why
--
-- Messages, Frame -> Host:
--   TERM [0x0C, 1, cols, rows]  -- on screen: start the terminal this size
--   TERM [0x0C, 0]              -- gone: stop it
--   TERM [0x0C, 2, seq]         -- frame seq taken: the phone sends the next
-- One frame at a time, as Flipper's (docs/FLIPPER.md).
local _M = {}

_M.label = 'Terminal'
_M.mode = 'app'
_M.fullscreen = true       -- no top bar: the 12 rows take the screen

local TERM = 0x0C
local WANT, DONE, TAKEN = 1, 0, 2

local SIZE = 28            -- frame.display.mono's 14x28 cells
local CELL_W = SIZE // 2
local COLS, ROWS = 45, 12
-- 630x336 centred in the visible 640x340 (docs/PROTOCOL.md), 1-based
local X, Y = 6, 3

local ASK_AGAIN = 3        -- s without a word from the phone: ask again
local IDLE      = 600      -- s without a tap or a key: closed

local texts = {}           -- row -> its characters; nil if blank
local attrs = {}           -- row -> a byte a cell
local shown = false        -- a frame has come
local status = 'waiting for the phone'
local asked = nil          -- utc() when WANT went out; nil before
local heard = false        -- the phone has answered since
local touched = nil        -- utc() of the last tap or key, or of the start

-- Retried a little while the link is busy, as Flipper's.
local function send(...)
  local packet = string.char(...)
  for _ = 1, 20 do
    if pcall(frame.bluetooth.send, packet) then return end
    frame.sleep(0.005)
  end
end

-- Called by frame_app.lua with the screen clear. A row a call: mono sends
-- a sprite for each color in it, not one a cell.
function _M.draw()
  if not frame.display.mono then return end
  local mono = frame.display.mono
  for r = 1, ROWS do
    local t = texts[r]
    if t then
      mono(t, X, Y + (r - 1) * SIZE, { size = SIZE, attrs = attrs[r] })
    end
  end
end

local function take(arg)
  local seq, flags, mask = string.unpack('>BBI2', arg, 2)
  local at = 6
  for r = 1, ROWS do
    if mask & (0x8000 >> (r - 1)) ~= 0 then
      local n = string.byte(arg, at) or 0
      local t = string.sub(arg, at + 1, at + n)
      local a = string.sub(arg, at + n + 1, at + 2 * n)
      at = at + 1 + 2 * n
      if string.find(t, '[^ ]') or string.find(a, '[\x10-\xff]') then
        texts[r], attrs[r] = t, a
      else
        texts[r], attrs[r] = nil, nil
      end
    end
  end
  if flags & 1 ~= 0 then touched = frame.time.utc() end
  shown = true
  -- answered before it is drawn, but the next frame cannot be collected
  -- before this one is: the loop draws first
  send(TERM, TAKEN, seq)
end

function _M.remote(arg)
  heard = true
  local kind = string.sub(arg, 1, 1)
  if kind == 'f' and #arg >= 5 then
    take(arg)
    return ''
  elseif kind == 's' then
    texts, attrs, shown = {}, {}, false
    status = string.sub(arg, 2)
    return status
  end
end

function _M.on_tap()
  touched = frame.time.utc()
end

-- WANT goes from the first tick, not start(): a stray frame after the
-- module closed starts it for a moment off screen, and that must not ask
-- the phone for more.
function _M.tick()
  local now = frame.time.utc()
  touched = touched or now
  if now - touched > IDLE then return 'no key for a while', true end
  if not frame.display.mono then
    return 'needs the glaz\nfirmware'
  end
  if not frame.bluetooth.is_connected() then
    asked, heard = nil, false
    texts, attrs, shown = {}, {}, false
    return 'no phone'
  end
  if not heard and (not asked or now - asked > ASK_AGAIN) then
    asked = now
    send(TERM, WANT, COLS, ROWS)
  end
  if shown then return '' end
  return status
end

function _M.stop()
  if asked then send(TERM, DONE) end
  texts, attrs, shown = {}, {}, false
  status = 'waiting for the phone'
  asked, heard = nil, false
  touched = nil
end

return _M

-- Menu module: a translator. ASCII only, see docs/PROTOCOL.md,
-- "Translate". The text it shows is UTF-8: the font has Cyrillic.
--
--   on entry, a mode to pick: Voice or Photo
--   tilt right / left -- the next / previous mode; then a screen back
--                        through the log, or on to its end, where it
--                        follows again: new lines scroll in by themselves
--   single tap        -- pick the mode; in Voice, pause or listen again;
--                        in Photo, take a photo to translate
--   double tap        -- back to the modes; from them, to the menu
--
-- Voice: listening is Recorder's streaming with a fourth byte in
-- REC_START, 2, so the phone hands the sound to its Translate service.
-- The phone transcribes what the other speaker says, translates it on the
-- phone (ML Kit, Glaz > Menu > Translate: languages, 8 or 16 bit) and
-- keeps the whole log, cut into lines that fit the screen
-- (flutter-glaz/lib/services/translate.dart). The glasses hold a window
-- of it: TRANSLATE asks, '>BBBI2B': op, sess, from, count -- op 0 the
-- wearer left, 1 lines from `from` (stops following), 2 the last `count`
-- (follows). The phone answers, and pushes while it follows, through
-- remote(arg), and only while the glasses have it open:
--
--   'w:<sess>:<from>:<total>:<f>' then '\n<kind>|<text>' per line, from
--         line number <from> (0-based) of log <sess> (1..255, new when
--         the phone's log is cleared), <total> lines long; <f> 1 for the
--         tail, 0 for an answer to op 1. kind: T translation, S source,
--         P partial or pending, I info, E error.
--   'n:<sess>:<total>'  -- the log grew; sent while not following
--   's:<text>'          -- the status row: a download, a failure; '' clears
--   'x:<text>'          -- as s:, and the phone no longer hears: the
--                          microphone stops
--
-- Photo: a tap takes a photo as the phone's remote does (app/glaz_photo.frame.lua,
-- loaded for it alone), with PHOTO_FROM 255: the phone reads the text on
-- it and translates it into the same log, rather than filing the photo.
--
-- The link down and back, the phone has forgotten all that: the glasses
-- ask again, and say again that they listen.
--
-- The mode picked last is kept on the glasses (_M.host.pref 'mode').
local _M = {}

_M.label = 'Translate'
_M.mode = 'app'
_M.quiet = true           -- draw() is the screen; tick() text is not shown
_M.rec = false            -- true while listening: red dot in the top bar

local TRANSLATE = 0x0F
local REC_START = 0x1F
local AUDIO     = 0x05
local AUDIO_END = 0x06
local FOR_TRANSLATE = 2   -- REC_START's fourth byte
local PHOTO_FOR = 255     -- PHOTO_FROM's byte: a photo to translate
local PHOTO_SIZE = 720    -- px, the most: small print must stay legible
local PHOTO_QUALITY = 4   -- HIGH, of 1..5

local RATE = 8000
local BITS = 16           -- or 8; Glaz > Menu > Translate
local MAX_LISTEN = 1800   -- s; then it pauses by itself
local ROWS = 4            -- log rows; the fifth is the status
local BEFORE = 4          -- lines asked for above the first on screen
local ASK = 8             -- lines asked for when scrolling back
local RETRY = 5           -- s without an answer before asking again

-- Layout: rows under the top bar, the cursor left of the text
local LEFT_X, TEXT_X = 60, 88
local TOP_Y, ROW_H = 65, 55
local STATUS_Y = TOP_Y + ROW_H * 4
local COLORS = { T = 'WHITE', S = 'GREY', P = 'GREY', I = 'SKYBLUE',
                 E = 'RED' }
local MODES = { 'voice', 'photo' }
local LABELS = { 'Voice', 'Photo' }

local state = 'choose'    -- 'choose', 'voice' or 'photo'
local sel = 1             -- the mode under the cursor
local note = ''           -- the chooser's hint, or the phone's s: text
local opened = false      -- the phone was asked for lines since start()
local sess = 0            -- the log held, 0 before the first answer
local lines = {}          -- number -> { kind, text }
local lo, hi = 0, 0
local total = nil         -- lines in the log; nil until the phone says
local top = 0             -- the line on the first row
local follow = true       -- the view keeps to the end of the log
local asked = nil         -- 't' for the tail, or `from` of a window
local asked_at = 0
local short = false       -- the last window did not cover the view
local tailing = false     -- the phone pushes the end: a tail came since op 2
local down = false        -- the link was seen down since the last ask

local started = nil       -- utc() when listening began; nil when not
local size = 0            -- bytes per packet, even (16-bit samples)
local per_second = 0      -- bytes of sound a second
local lost = 0            -- bytes the link did not take

local function send(packet)
  for _ = 1, 20 do
    if pcall(frame.bluetooth.send, packet) then return true end
    frame.sleep(0.005)
  end
  if not frame.bluetooth.is_connected() then down = true end
  return false
end

-- As Recorder's: at most two seconds' worth a call.
local function drain()
  local done = 0
  while done < per_second * 2 do
    local ok, s = pcall(frame.microphone.read, size)
    if not ok or s == nil or s == '' then return end
    done = done + #s
    if not send(string.char(AUDIO) .. s) then lost = lost + #s end
  end
end

-- No REC_DROP here: the phone's assistant takes it as its own.
local function finish()
  _M.rec = false
  if not started then return end
  pcall(frame.microphone.stop)
  drain()
  send(string.char(AUDIO_END))
  started = nil
end

local function req(op, from, count)
  if not frame.bluetooth.is_connected() then
    note, down = 'no phone', true
    return
  end
  if op == 2 then tailing = false end
  if send(string.pack('>BBBI2B', TRANSLATE, op, sess, from, count))
     and (op == 1 or op == 2) then
    opened = true
    asked = op == 2 and 't' or from
    asked_at = frame.time.utc()
  end
end

-- The notes the glasses set themselves; listening again clears them.
local OWN = { ['no phone'] = true, ['no microphone'] = true,
              ['paused (30 min)'] = true, ['no camera'] = true }

local function listen()
  finish()
  if OWN[note] then note = '' end
  if not frame.bluetooth.is_connected() then
    note, down = 'no phone', true
    return
  end
  local bits = _M.host.setting('bits', BITS)
  if bits ~= 8 and bits ~= 16 then bits = BITS end
  size = frame.bluetooth.max_length() - 1
  if size % 2 == 1 then size = size - 1 end
  per_second = RATE * bits // 8
  lost = 0
  pcall(frame.microphone.stop)
  if not pcall(frame.microphone.start, { sample_rate = RATE,
                                         bit_depth = bits })
     or not send(string.char(REC_START, bits, RATE // 1000, FOR_TRANSLATE))
  then
    pcall(frame.microphone.stop)
    note = 'no microphone'
    return
  end
  started = frame.time.utc()
  _M.rec = true
end

local function view_loaded()
  if total == nil then return false end
  for i = top, math.min(top + ROWS, total) - 1 do
    if not lines[i] then return false end
  end
  return true
end

local function tail_top()
  return math.max(0, (total or 0) - ROWS)
end

-- What the screen shows, in short: tick() returns it, so a change redraws.
local function state_str()
  return table.concat({ state, sel, note, sess, tostring(total), top, lo, hi,
                        tostring(follow), tostring(started ~= nil),
                        lost // 1024 }, '|')
end

-- Passive: nothing listens and nothing is asked until Voice is picked. A
-- MODULE_CALL to a module not running starts it in the background, and
-- that must do nothing here.
function _M.start()
  sel = (_M.host.pref('mode', 'voice') == 'photo') and 2 or 1
  state, note, opened, sess = 'choose', '', false, 0
  lines, lo, hi, total, top, follow, asked = {}, 0, 0, nil, 0, true, nil
  short, tailing, down = false, false, false
end

-- Leaving a mode stops the sound and tells the phone, which then sends
-- nothing.
local function close()
  if started then finish() end
  if state == 'photo' then pcall(frame.camera.power_save, true) end
  if opened then req(0, 0, 0) end
  opened, lines, state, _M.rec = false, {}, 'choose', false
end

function _M.stop()
  close()
end

-- Back to the modes, the cursor on the one left; from them, false: the
-- app leaves.
function _M.on_back()
  if state == 'choose' then return false end
  close()
  note, lo, hi, total, top, follow, asked = '', 0, 0, nil, 0, true, nil
  short, tailing = false, false
  return state_str()
end

function _M.busy()
  return started ~= nil
end

function _M.tick()
  local now = frame.time.utc()
  local up = frame.bluetooth.is_connected()
  local again = false
  if not up then
    down = true
  elseif down then
    -- back: the phone dropped the session and the sound; ask again, from
    -- the end or for the lines on screen, and listen again if listening:
    -- after the ask, so a refusal ('x:') finds the session open
    down = false
    if note == 'no phone' then note = '' end
    if state ~= 'choose' then
      asked, tailing = nil, false
      if not follow then lines, lo, hi = {}, 0, 0 end
      again = started ~= nil
    end
  end
  if started then
    if not up then
      finish()
      note = 'no phone'
    elseif now - started > MAX_LISTEN then
      finish()
      note = 'paused (30 min)'
    else
      drain()
    end
  end
  if state ~= 'choose' and note ~= 'no phone' and
     (asked == nil or now - asked_at > RETRY) then
    if follow and (not tailing or not view_loaded()) then
      req(2, 0, ROWS)
    elseif not follow and not view_loaded() then
      req(1, short and top or math.max(0, top - BEFORE),
          short and ROWS or ASK)
    end
  end
  if again and started then
    local since = started
    listen()
    if started then started = since end
  end
  return state_str()
end

function _M.on_roll(dir)
  if state == 'choose' then
    sel = (sel - 1 + dir) % #MODES + 1
    note = ''
    return state_str()
  end
  if dir < 0 then
    if total == nil then return nil end
    local base = follow and tail_top() or top
    if base == 0 then return nil end
    follow, short = false, false
    top = math.max(0, base - (ROWS - 1))
    if not view_loaded() then req(1, math.max(0, top - BEFORE), ASK) end
  else
    if follow then return nil end
    top = top + (ROWS - 1)
    if top >= tail_top() then
      follow, top = true, tail_top()
      req(2, 0, ROWS)
    elseif not view_loaded() then
      req(1, math.max(0, top - BEFORE), ASK)
    end
  end
  return state_str()
end

-- A photo to translate: the loop waits meanwhile, about 1.5 s of
-- exposure and the transfer. The camera stays on until Translate closes.
local function shoot()
  if not frame.bluetooth.is_connected() then
    note, down = 'no phone', true
    return
  end
  if OWN[note] then note = '' end
  local ok, take = pcall(require, 'glaz_photo')
  if not ok or not pcall(take, PHOTO_SIZE, PHOTO_QUALITY, false, nil,
                         PHOTO_FOR) then
    note = 'no camera'
  end
end

function _M.on_tap()
  if state == 'choose' then
    local mode = MODES[sel]
    if _M.host.pref('mode', 'voice') ~= mode then
      _M.host.set_pref('mode', mode)
    end
    state, note, follow = mode, '', true
    req(2, 0, ROWS)
    if mode == 'voice' then listen() end
    return state_str()
  end
  if state == 'photo' then
    shoot()
  elseif started then
    finish()
  else
    listen()
  end
  return state_str()
end

function _M.remote(arg)
  if state == 'choose' then return nil end
  local stop, text = string.match(arg, '^([sx]):(.*)$')
  if stop then
    if stop == 'x' then finish() end
    note = text
    return state_str()
  end
  local s, n = string.match(arg, '^n:(%d+):(%d+)$')
  if s then
    s, n = tonumber(s), tonumber(n)
    if s ~= sess then
      -- a new log: start again from its end; tick() asks for it
      sess, lines, lo, hi = s, {}, 0, 0
      follow, total, asked = true, nil, nil
    else
      total = n
      if follow then
        -- the phone does not know: the op 2 that said so was lost
        tailing = false
      else
        -- pending and partial lines are at the end, and change: those
        -- held go from the first of them, and the screen asks again
        local held = hi
        if hi > n then hi = math.max(lo, n) end
        for i = lo, hi - 1 do
          if lines[i] and lines[i][1] == 'P' then hi = i break end
        end
        for i = hi, held - 1 do lines[i] = nil end
      end
    end
    return state_str()
  end
  local from, f, body
  s, from, n, f, body =
    string.match(arg, '^w:(%d+):(%d+):(%d+):(%d)\n?(.*)$')
  if not s then return nil end
  s, from, n, f = tonumber(s), tonumber(from), tonumber(n), tonumber(f)
  local fresh = s ~= sess
  if not fresh then
    if f == 1 and not follow then
      total = n             -- a push from before scrolling back
      return state_str()
    end
    if f == 0 and asked ~= from then
      return nil            -- an answer to a request since replaced
    end
  end
  sess, total = s, n
  lines = {}
  lo, hi = from, from
  for kind, t in string.gmatch(body, '(%a)|([^\n]*)') do
    lines[hi] = { kind, t }
    hi = hi + 1
  end
  asked = nil
  tailing = f == 1
  if note == 'no phone' then note = '' end
  if fresh or f == 1 then
    follow, top = true, tail_top()
  else
    short = not view_loaded()
  end
  return state_str()
end

function _M.draw()
  if state == 'choose' then
    for r = 1, #MODES do
      local y = TOP_Y + ROW_H * (r - 1)
      if r == sel then
        frame.display.text('>', LEFT_X, y, { color = 'YELLOW' })
      end
      frame.display.text(LABELS[r], TEXT_X, y,
                         { color = r == sel and 'YELLOW' or 'WHITE' })
    end
    frame.display.text(_M.host.setting('from', 'en') .. ' > ' ..
                       _M.host.setting('to', 'ru'), TEXT_X, TOP_Y + ROW_H * 2,
                       { color = 'GREY' })
    if note ~= '' then
      frame.display.text(note, TEXT_X, TOP_Y + ROW_H * 3, { color = 'ORANGE' })
    end
    frame.display.text('tap = pick', LEFT_X, STATUS_Y, { color = 'GREY' })
    return
  end
  if total == nil or not view_loaded() then
    frame.display.text('loading..', TEXT_X, TOP_Y + ROW_H, { color = 'GREY' })
  elseif total == 0 then
    frame.display.text(state == 'photo' and 'tap = photo' or
                       (started and 'listening..' or 'paused, tap to listen'),
                       TEXT_X, TOP_Y + ROW_H, { color = 'GREY' })
  else
    for r = 0, ROWS - 1 do
      local l = lines[top + r]
      if l and l[2] ~= '' then
        frame.display.text(l[2], LEFT_X, TOP_Y + ROW_H * r,
                           { color = COLORS[l[1]] or 'WHITE' })
      end
    end
  end
  local pos = total and total > 0 and
              (math.min(top + ROWS, total) .. '/' .. total) or '-'
  frame.display.text(pos .. '  ' ..
                     (note ~= '' and note or
                      (state == 'photo' and 'tap = photo' or
                       (started and 'listening' or 'paused'))) ..
                     (follow and '' or '  ^') ..
                     (lost > 0 and ('  lost ' .. lost // 1024 .. 'K') or ''),
                     LEFT_X, STATUS_Y, { color = 'GREY' })
end

return _M

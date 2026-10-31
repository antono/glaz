-- Menu module: a fact checker. ASCII only, see docs/PROTOCOL.md,
-- "Factchecker". The text it shows is UTF-8: the font has Cyrillic.
--
--   on entry, it listens: the conversation, everyone in it
--   tilt        -- the list: the cursor up to a fact / down to the
--                  bottom row; a fact: a screen back / on
--   single tap  -- the bottom row: check what was said since the last
--                  tap; a fact: open it; an open fact: back to the list
--   double tap  -- an open fact: back to the list; the list: leave
--
-- Listening is Recorder's streaming with a fourth byte in REC_START, 4,
-- so the phone hands the sound to its Factchecker service
-- (flutter-glaz/lib/services/factcheck.dart). It transcribes as it comes;
-- a tap cuts it there, and the agent pulls the claims out of the piece
-- and checks each. The phone keeps it all; the glasses hold what is on
-- screen, four rows, and ask for the next four as the view moves: a long
-- session costs them no more memory than a short one. FACTS asks,
-- '>BBI2I2': op, a, b -- 0 the wearer left, 1 check since the last cut,
-- 2 fact <a>'s check from its line <b>, 3 the facts from number <a>
-- (oldest first, from 1; 0 the newest, followed). The phone answers, and
-- sends the window again as it changes, through remote(arg):
--
--   'f:<pending>:<total>:<from>' then '\n<id>|<v>|<text>' per fact, at
--         most four from number <from> -- <pending> the pieces still
--         being read; v: P checking, T true, F false, M partly, U unknown
--   'd:<id>:<v>:<total>:<from>' then '\n<line>' per line, at most four
--         from line <from> of fact <id>'s check, <total> lines long
--   'e:<text>'  -- went wrong: red in the status row
--   'n:<text>'  -- a note: grey in the status row
--
-- Glanced at, not read: each fact has a mark as well as a colour (+ true,
-- x false, ~ partly, ? unknown, . checking), so a verdict does not hang on
-- telling red from green through the lens; a tap shows at once that it
-- was taken ('reading..' before the phone says); notes go after
-- NOTE_TIME; the list keeps to the newest fact while the cursor is on the
-- bottom row.
local _M = {}

_M.label = 'Factchecker'
_M.mode = 'app'
_M.quiet = true           -- draw() is the screen; tick() text is not shown
_M.rec = false            -- true while listening: red dot in the top bar

local REC_START = 0x1F
local AUDIO     = 0x05
local FACTS     = 0x01    -- '>BBI2I2': op, a, b
local FOR_FACTCHECK = 4   -- REC_START's fourth byte

local RATE = 8000
local BITS = 16           -- or 8; Glaz > Menu > Factchecker
local MAX_LISTEN = 1800   -- s; then it pauses by itself
local ROWS = 4            -- rows of facts; the fifth is the bottom row
local RETRY = 5           -- s without an answer before asking again
local NOTE_TIME = 5       -- s a note shows; the link's and pauses stay

-- Layout, as Assistant's: rows under the top bar, the cursor left of the
-- text
local LEFT_X, TEXT_X = 60, 88
local TOP_Y, ROW_H = 65, 55
local BOTTOM_Y = TOP_Y + ROW_H * ROWS
local COLORS = { T = 'GREEN', F = 'RED', M = 'YELLOW', U = 'GREY',
                 P = 'WHITE' }
local MARKS = { T = '+', F = 'x', M = '~', U = '?', P = '.' }
-- the notes the glasses set themselves, shown until they no longer hold
local STAY = { ['no phone'] = true, ['no microphone'] = true,
               ['paused (30 min)'] = true }

local started = nil       -- utc() when listening began; nil when not
local since = nil         -- utc() of the first listen: the clock shown
local size = 0            -- bytes per packet, even (16-bit samples)
local per_second = 0      -- bytes of sound a second
local lost = 0            -- bytes the link did not take
local want = false        -- the wearer wants it listening
local down = false        -- the link was seen down
local total = nil         -- facts in the session; nil until the phone says
local rows = {}           -- the facts on screen: number -> {id, v, text}
local pending = 0         -- pieces the phone is still reading
local sel = 0             -- the fact under the cursor; 0 the bottom row
local top = 1             -- the fact on the first row
local open = nil          -- the fact open, its id; nil in the list
local lines = {}          -- its check on screen: line number -> text
local ltotal = 0          -- lines in the check; 0 until the phone says
local verdict = 'P'       -- its v: the first line's colour
local ltop = 1            -- its line on the first row
local note, red = '', false
local note_at = 0         -- utc() the note came
local asked = nil         -- the request not yet answered, {op, a, b}
local tailing = false     -- the list asked for is the newest, followed
local asked_at = 0        -- utc() it was sent

local function txt(text, x, y, color)
  frame.display.text(text, x, y, { color = color })
end

local function say(text, is_red)
  note, red, note_at = text, is_red, frame.time.utc()
end

local function send(packet)
  for _ = 1, 20 do
    if pcall(frame.bluetooth.send, packet) then return true end
    frame.sleep(0.005)
  end
  return false
end

local function ask(op, a, b)
  return frame.bluetooth.is_connected()
    and send(string.pack('>BBI2I2', FACTS, op, a or 0, b or 0))
end

-- A window asked for: asked again after RETRY until it comes.
local function want_window(op, a, b)
  asked, asked_at = { op, a, b }, frame.time.utc()
  ask(op, a, b)
end

-- As Recorder's: at most two seconds' worth a call.
local function drain()
  local done = 0
  while done < per_second * 2 do
    local ok, s = pcall(frame.microphone.read, size)
    if not ok or s == nil or s == '' then return end
    done = done + #s
    if not send(string.char(AUDIO) .. s) then lost = lost + #s end
    -- as Recorder's: two seconds of sound is 32 KB of strings, a quarter
    -- of the heap, unless each goes as it is sent
    s = nil
    collectgarbage('step')
  end
end

-- No AUDIO_END: the sound is not a whole, the phone keeps what it has
-- heard until the next cut.
local function hush()
  _M.rec = false
  if not started then return end
  pcall(frame.microphone.stop)
  started = nil
end

local function listen()
  hush()
  if not frame.bluetooth.is_connected() then
    say('no phone', true)
    down = true
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
     or not send(string.char(REC_START, bits, RATE // 1000, FOR_FACTCHECK))
  then
    pcall(frame.microphone.stop)
    say('no microphone', true)
    return
  end
  if note == 'no phone' or note == 'no microphone' then note = '' end
  started = frame.time.utc()
  since = since or started
  _M.rec = true
end

local function tail_top()
  return math.max(1, (total or 0) - ROWS + 1)
end

-- The facts on screen, asked for: the newest while the cursor is on the
-- bottom row, else from the first row.
local function ask_list()
  tailing = sel == 0
  want_window(3, tailing and 0 or top, 0)
end

-- The cursor's fact on screen; on the bottom row, the newest facts. A
-- view moved asks for its facts.
local function scroll()
  local was = top
  if sel == 0 then
    top = tail_top()
  elseif sel < top then
    top = sel
  elseif sel > top + ROWS - 1 then
    top = sel - ROWS + 1
  end
  if top ~= was then
    rows = {}
    ask_list()
  elseif tailing ~= (sel == 0) then
    -- the same rows, but followed or not: the phone is told
    ask_list()
  end
end

local function state_str()
  return table.concat({ tostring(open), sel, top, ltop, ltotal, pending,
                        total or -1, tostring(rows[top] ~= nil),
                        tostring(lines[ltop] ~= nil), note, tostring(red),
                        tostring(started ~= nil), lost // 1024,
                        since and math.floor(frame.time.utc() - since)
                        or '-' }, '|')
end

local function take(arg)
  local kind, text = string.match(arg, '^(%a):(.*)$')
  if kind == 'f' then
    local p, n, from, body =
      string.match(text, '^(%d+):(%d+):(%d+)\n?(.*)$')
    if not p then return end
    pending, total, from = tonumber(p), tonumber(n), tonumber(from)
    -- facts are only added: the cursor's number stays its fact
    if sel > total then sel = 0 end
    if sel == 0 then top = tail_top() end
    if from ~= top then
      -- for a view since left; none asked for: the view is asked again
      if not asked then ask_list() end
      return
    end
    rows = {}
    local i = from
    for id, v, t in string.gmatch(body, '(%d+)|(%a)|([^\n]*)') do
      rows[i] = { tonumber(id), v, t }
      i = i + 1
    end
    if asked and asked[1] == 3 then asked = nil end
  elseif kind == 'd' then
    local id, v, n, from, body =
      string.match(text, '^(%d+):(%a):(%d+):(%d+)\n?(.*)$')
    if not id or tonumber(id) ~= open or tonumber(from) ~= ltop then
      return
    end
    lines, ltotal, verdict = {}, tonumber(n), v
    local i = ltop
    for l in string.gmatch(body, '[^\n]+') do
      lines[i] = l
      i = i + 1
    end
    if asked and asked[1] == 2 then asked = nil end
  elseif kind == 'e' or kind == 'n' then
    say(text, kind == 'e')
  end
end

function _M.start(info)
  total, rows, pending, sel, top = nil, {}, 0, 0, 1
  open, lines, ltotal, asked = nil, {}, 0, nil
  note, red, since, down = '', false, nil, false
  -- a MODULE_CALL to it while not running: a late answer, not the wearer
  want = not (info and info.background)
  if not want then return end
  listen()
  ask_list()
end

function _M.tick()
  local now = frame.time.utc()
  local up = frame.bluetooth.is_connected()
  if not up then
    if started then hush() end
    if note ~= 'no phone' then say('no phone', true) end
    down = true
  elseif down then
    -- back: the phone dropped the sound; listen and ask again
    down = false
    if note == 'no phone' then note = '' end
    if want then listen() end
    ask_list()
  end
  if started then
    if now - started > MAX_LISTEN then
      hush()
      want = false
      say('paused (30 min)', false)
    else
      drain()
    end
  end
  if note ~= '' and not STAY[note] and now - note_at > NOTE_TIME then
    note, red = '', false
  end
  if up and asked and now - asked_at > RETRY then
    want_window(asked[1], asked[2], asked[3])
  end
  return state_str()
end

-- Listening is not being left alone: without this glaz.lua's APP_TIMEOUT
-- (60 s) would stop the module long before MAX_LISTEN.
function _M.busy()
  return started ~= nil
end

function _M.on_tap()
  if open then
    open, lines, ltotal = nil, {}, 0
    ask_list()
  elseif sel > 0 and rows[sel] then
    open, lines, ltotal, ltop = rows[sel][1], {}, 0, 1
    want_window(2, open, 1)
  elseif started then
    -- seen at once: the phone's list says so later
    if ask(1) then note, red, pending = '', false, pending + 1 end
  else
    want = true
    listen()
  end
  return state_str()
end

function _M.on_roll(dir)
  if open then
    if ltotal == 0 then return nil end
    local was = ltop
    ltop = math.max(1, math.min(ltop + dir * (ROWS - 1),
                                math.max(1, ltotal - ROWS + 1)))
    if ltop == was then return nil end
    lines = {}
    want_window(2, open, ltop)
    return state_str()
  end
  if not total or total == 0 then return nil end
  -- the bottom row is under the newest fact
  local pos = sel == 0 and total + 1 or sel
  pos = math.max(1, math.min(pos + dir, total + 1))
  sel = pos > total and 0 or pos
  scroll()
  return state_str()
end

-- An open fact: back to the list; the list: false, the app leaves.
function _M.on_back()
  if not open then return false end
  open, lines, ltotal = nil, {}, 0
  ask_list()
  return state_str()
end

function _M.remote(arg)
  take(arg)
  return state_str()
end

local function bottom()
  if note ~= '' then return note end
  if not started then return 'paused  tap = listen' end
  local s = math.floor(frame.time.utc() - (since or started))
  local what = pending > 0 and 'reading..' or
               string.format('%d:%02d', s // 60, s % 60)
  return what .. '  tap = check'
    .. (lost > 0 and string.format('  lost %dK', lost // 1024) or '')
end

function _M.draw()
  if open then
    if not lines[ltop] then txt('loading..', LEFT_X, TOP_Y, 'GREY') end
    for r = 0, ROWS - 1 do
      local i = ltop + r
      if lines[i] then
        txt(lines[i], LEFT_X, TOP_Y + ROW_H * r,
            i == 1 and COLORS[verdict] or 'WHITE')
      end
    end
    txt('tap = back' .. (ltop > 1 and '  ^' or '') ..
        (ltop + ROWS <= ltotal and '  v' or ''), LEFT_X, BOTTOM_Y, 'GREY')
    return
  end
  if not total or total == 0 then
    txt(started and 'Tap when you hear' or 'Not listening', TEXT_X, TOP_Y,
        'GREY')
    if started then
      txt('a claim to check', TEXT_X, TOP_Y + ROW_H, 'GREY')
    end
  else
    for i = top, math.min(top + ROWS - 1, total) do
      local y = TOP_Y + ROW_H * (i - top)
      local f = rows[i]
      if i == sel then txt('>', LEFT_X, y, 'YELLOW') end
      if f then
        txt((MARKS[f[2]] or ' ') .. ' ' .. f[3], TEXT_X, y,
            COLORS[f[2]] or 'WHITE')
      else
        txt('..', TEXT_X, y, 'GREY')
      end
    end
  end
  if sel == 0 then txt('>', LEFT_X, BOTTOM_Y, 'YELLOW') end
  txt(bottom(), TEXT_X, BOTTOM_Y, red and 'RED' or
      ((sel == 0 and note == '') and 'YELLOW' or 'GREY'))
end

-- Leaving: the microphone off, the phone told; checks under way still
-- end up in its history.
function _M.stop()
  local was = want or started
  hush()
  want = false
  if was then ask(0) end
  total, rows, lines, open, asked = nil, {}, {}, nil, nil
end

return _M

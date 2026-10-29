-- Menu module: voice assistant. ASCII only, see docs/PROTOCOL.md,
-- "Assistant". The text it shows is UTF-8: the font has Cyrillic.
--
--   on entry, the chats kept on the phone, newest first, under 'New chat';
--   the cursor on the one still going on, if any
--   tilt        -- the chats: the next / previous one; a chat: a screen
--                  back / on; at the end it follows again
--   single tap  -- 'New chat': listen, in a new chat; a chat: show it,
--                  the next tap asks in it; listening: stop and ask
--   double tap  -- back to the chats, from them to the menu; a question
--                  being asked is dropped, sent nowhere
--
-- A chat is a log of lines, coloured by kind: the wearer's questions, the
-- agent's tool calls (a photo taken, notes read), its answers. The phone
-- keeps it; the glasses hold the four lines on screen and ask for the
-- next four as the view moves, so a long chat costs them no more memory
-- than a short one (docs/PROTOCOL.md, "Memory on the glasses").
--
-- Only taps start and stop it: nothing guesses where a question ends.
-- Listening is Recorder's streaming with a fourth byte in REC_START, 1, so
-- the phone hands the sound to the assistant instead of saving it. 16-bit
-- by default (Glaz > Menu > Assistant): 8-bit sound was misheard. The
-- phone transcribes, asks the agent and answers through remote(arg), or
-- APP_OPEN 'assistant' with arg, which comes to start() when the module
-- was not running:
--
--   'stop'      -- stop listening and ask
--   't:<busy>:<total>:<from>' then '\n<kind>|<text>' per line -- at most
--                  four of the chat's lines from line <from>, already cut
--                  to the screen; <total> lines in all; <busy> 1 while the
--                  agent thinks. kind: Q question, T tool call, A answer,
--                  C a command run, E went wrong. Sent again as it changes
--   'e:<text>'  -- went wrong outside a chat (nothing heard, no agent):
--                  red under the chat, its last four lines
--   'listen'    -- listen again
--   'c:<live>' then '\n<id>|<title>' per chat -- the chats, newest first;
--                  <live> the id of the one still going on, or 0
--
-- ASSIST asks, '>BBI2I2': op, id, from -- 1 the chats, 2 go on with chat
-- <id> (the phone answers 't:', its newest lines), 3 a new chat, sent
-- just before listening, 4 the chat's lines from line <from> (from 1; 0
-- the newest, followed), asked again after RETRY until they come.
local _M = {}

_M.label = 'Assistant'
_M.mode = 'app'
_M.quiet = true           -- draw() is the screen; tick() text is not shown

local REC_START = 0x1F
local AUDIO     = 0x05
local AUDIO_END = 0x06
local REC_DROP  = 0x10    -- [0x10]: the question is dropped, not asked
local ASSIST    = 0x04    -- '>BBI2I2': 1 the chats, 2 open one, 3 a new
                          -- one, 4 the chat's lines from <from>
local FOR_ASSISTANT = 1   -- REC_START's fourth byte

local RATE = 8000
local BITS = 16           -- or 8; Glaz > Menu > Assistant
local MAX_LISTEN = 120    -- s; only so a forgotten one does not run on
local ROWS = 5            -- the chats' rows
local LOG_ROWS = 4        -- the chat's rows; the fifth is the status
local RETRY = 5           -- s without an answer before asking again

-- Layout, as Translate's: rows under the top bar, the cursor left of the
-- text
local LEFT_X, TEXT_X = 60, 88
local TOP_Y, ROW_H = 65, 55
local STATUS_Y = TOP_Y + ROW_H * LOG_ROWS
local COLORS = { Q = 'SKYBLUE', T = 'ORANGE', A = 'WHITE', C = 'GREY',
                 E = 'RED' }

local started = nil       -- utc() when listening began; nil when not
local size = 0            -- bytes per packet, even (16-bit samples)
local per_second = 0      -- bytes of sound a second
local lost = 0            -- bytes the link did not take
local view = ''           -- '', 'chats' or 'chat'
local busy = false        -- asked; the agent is thinking
local note = ''           -- the status row's own: 'no phone', ...
local rows = {}           -- the chat's lines on screen: number -> {kind, text}
local total = 0           -- lines in the chat; 0 until the phone says
local errs = {}           -- 'e:' lines, at most LOG_ROWS, under the chat
local top = 1             -- the chat's line on the first row
local follow = true       -- the view keeps to the end of the chat
local asked = nil         -- the window asked for and not come: its from
local chats = nil         -- { {id, title}, ... } once the phone says
local sel, ctop = 0, 0    -- the chat under the cursor, on the first row;
                          -- 0 is 'New chat'
local asked_at = nil      -- utc() the chats were asked for
local wanted_at = 0       -- utc() the window was asked for
local ver = 0             -- goes up with every change the phone brings

local function send(packet)
  for _ = 1, 20 do
    if pcall(frame.bluetooth.send, packet) then return true end
    frame.sleep(0.005)
  end
  return false
end

local function assist(op, id, from)
  return frame.bluetooth.is_connected()
    and send(string.pack('>BBI2I2', ASSIST, op, id or 0, from or 0))
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

local function finish()
  if not started then return end
  pcall(frame.microphone.stop)
  drain()
  send(string.char(AUDIO_END))
  started = nil
end

local function tail_top()
  return math.max(1, total - LOG_ROWS + 1)
end

-- The lines on screen, asked for: the newest while following.
local function want_window()
  asked, wanted_at = follow and 0 or top, frame.time.utc()
  assist(4, 0, asked)
end

local function listen()
  finish()
  view, busy, note = 'chat', false, ''
  if not frame.bluetooth.is_connected() then
    note = 'no phone'
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
     or not send(string.char(REC_START, bits, RATE // 1000, FOR_ASSISTANT))
  then
    pcall(frame.microphone.stop)
    note = 'no microphone'
    return
  end
  started = frame.time.utc()
  follow, top = true, tail_top()
end

-- Stops listening and asks.
local function ask()
  finish()
  busy = true
end

-- What the screen shows, in short: tick() returns it, so a change redraws.
local function state_str()
  return table.concat({ view, ver, sel, ctop, top, total, #errs,
                        tostring(follow),
                        tostring(busy), note, lost // 1024,
                        started and math.floor(frame.time.utc() - started)
                        or '-' }, '|')
end

local function take(arg)
  local kind, text = string.match(arg, '^(%a):(.*)$')
  if arg == 'listen' then
    listen()
  elseif arg == 'stop' then
    if started then ask() end
  elseif kind == 'c' then
    if view ~= 'chats' then return end
    local live, body = string.match(text, '^(%d+)\n?(.*)$')
    chats, sel, ctop = {}, 0, 0
    for id, title in string.gmatch(body or '', '(%d+)|([^\n]*)') do
      chats[#chats + 1] = { tonumber(id), title }
      if id == live then sel = #chats end
    end
    if sel >= ROWS then ctop = sel - ROWS + 1 end
  elseif kind == 't' or kind == 'e' then
    -- the list up: for a question dropped by going back
    if view == 'chats' then return end
    view = 'chat'
    if kind == 't' then
      local b, n, from, body =
        string.match(text, '^(%d):(%d+):(%d+)\n?(.*)$')
      if not b then return end
      busy, total, from = b == '1', tonumber(n), tonumber(from)
      if follow then
        top = tail_top()
      elseif top > tail_top() then
        -- shorter than the view: the chat changed under it
        top, follow = tail_top(), true
      end
      if from ~= top then
        -- for a view since left: the one on screen is asked for
        if asked == nil then want_window() end
        return
      end
      rows, errs = {}, {}
      for k, t in string.gmatch(body, '(%a)|([^\n]*)') do
        rows[from] = { k, t }
        from = from + 1
      end
      if asked == 0 or asked == top then asked = nil end
    else
      finish()
      busy = false
      for line in string.gmatch(text, '[^\n]+') do
        errs[#errs + 1] = line
        if #errs > LOG_ROWS then table.remove(errs, 1) end
      end
    end
  end
  ver = ver + 1
end

local function ask_chats()
  chats, sel, ctop = nil, 0, 0
  asked_at = assist(1) and frame.time.utc() or nil
end

local function reset()
  rows, total, errs, top, follow = {}, 0, {}, 1, true
  busy, note, asked = false, '', nil
end

function _M.start(info)
  reset()
  if info and info.arg then
    view = 'chat'
    take(info.arg)
  else
    view = 'chats'
    ask_chats()
  end
end

function _M.tick()
  if view == 'chats' and not chats
     and (not asked_at or frame.time.utc() - asked_at > RETRY) then
    ask_chats()
  end
  if view == 'chat' and asked and frame.bluetooth.is_connected()
     and frame.time.utc() - wanted_at > RETRY then
    want_window()
  end
  if started then
    if not frame.bluetooth.is_connected() then
      finish()
      note = 'no phone'
    elseif frame.time.utc() - started > MAX_LISTEN then
      ask()
    else
      drain()
    end
  end
  return state_str()
end

-- Listening is not being left alone: without this glaz.lua's APP_TIMEOUT
-- (60 s) would stop the module, dropping the question, long before
-- MAX_LISTEN.
function _M.busy()
  return started ~= nil
end

function _M.on_tap()
  if started then
    ask()
  elseif view == 'chats' and chats and sel > 0 then
    reset()
    view = 'chat'
    assist(2, chats[sel][1])
    note = 'loading..'
  else
    if view == 'chats' then
      reset()
      if chats then assist(3) end
    end
    listen()
  end
  return state_str()
end

function _M.on_roll(dir)
  if view == 'chats' then
    if not chats then return nil end
    sel = math.max(0, math.min(sel + dir, #chats))
    if sel < ctop then ctop = sel end
    if sel > ctop + ROWS - 1 then ctop = sel - ROWS + 1 end
  else
    local was = top
    top = math.max(1, math.min(top + dir * (LOG_ROWS - 1), tail_top()))
    follow = top == tail_top()
    if top == was then return nil end
    -- the rows kept are drawn where they still are, until the rest come
    errs = {}
    want_window()
  end
  return state_str()
end

function _M.remote(arg)
  if note == 'loading..' then note = '' end
  take(arg)
  return state_str()
end

local function status()
  if started then
    return string.format('listening %ds  tap = ask',
                         math.floor(frame.time.utc() - started))
      .. (lost > 0 and string.format('  lost %dK', lost // 1024) or '')
  end
  if busy then return 'thinking..' end
  if note ~= '' then return note end
  return 'tap = ask'
end

function _M.draw()
  if view == 'chats' then
    if not chats then
      frame.display.text(frame.bluetooth.is_connected() and 'loading..'
                         or 'no phone, tap = ask', TEXT_X, TOP_Y,
                         { color = 'GREY' })
      return
    end
    for i = ctop, math.min(ctop + ROWS - 1, #chats) do
      local y = TOP_Y + ROW_H * (i - ctop)
      if i == sel then
        frame.display.text('>', LEFT_X, y, { color = 'YELLOW' })
      end
      frame.display.text(i == 0 and 'New chat' or chats[i][2], TEXT_X, y,
                         { color = i == sel and 'YELLOW' or
                                   (i == 0 and 'GREY' or 'WHITE') })
    end
    return
  end
  -- the errors under the chat's lines, the last four of both shown
  local shown = math.max(0, math.min(LOG_ROWS, total - top + 1))
  local skip = math.max(0, shown + #errs - LOG_ROWS)
  for r = 0, LOG_ROWS - 1 do
    local l
    if r + skip < shown then
      l = rows[top + skip + r]
    else
      local e = errs[r + skip - shown + 1]
      l = e and { 'E', e }
    end
    if l and l[2] ~= '' then
      frame.display.text(l[2], LEFT_X, TOP_Y + ROW_H * r,
                         { color = COLORS[l[1]] or 'WHITE' })
    end
  end
  frame.display.text(status() .. (follow and '' or '  ^'), LEFT_X, STATUS_Y,
                     { color = (note ~= '' and note ~= 'loading..'
                                and not started and not busy)
                               and 'RED' or 'GREY' })
end

-- Going back to the chats or leaving drops the question: the sound is not
-- finished, the phone is told to forget it, and an answer still on its
-- way is thrown away.
local function drop()
  if started or busy then
    if started then pcall(frame.microphone.stop) end
    started, busy = nil, false
    send(string.char(REC_DROP))
  end
end

-- Back to the chats, asked for again: the one just left may be new or
-- renamed. From the chats, false: the app leaves.
function _M.on_back()
  if view == 'chats' then return false end
  drop()
  reset()
  view = 'chats'
  ask_chats()
  return state_str()
end

-- Leaving: a double tap from the chats, or anything else that stops it.
function _M.stop()
  drop()
  view, chats = '', nil
  reset()
end

return _M

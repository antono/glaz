-- Menu module: voice assistant. ASCII only, see docs/PROTOCOL.md,
-- "Assistant".
--
--   on entry, the chats kept on the phone, newest first, under 'New chat';
--   the cursor on the one still going on, if any
--   tilt        -- the chats: the next / previous one; an answer: its pages
--   single tap  -- 'New chat': listen, in a new chat; a chat: show its last
--                  question and answer, the next tap asks in it;
--                  otherwise listen, tapped again, stop and ask
--   double tap  -- back; a question being asked is dropped, sent nowhere
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
--   'h:<text>'  -- what was heard; the agent is thinking
--   'a:<text>'  -- the answer, ASCII, already in lines of at most LINE
--   'e:<text>'  -- went wrong, why
--   'listen'    -- listen again
--   'c:<live>' then '\n<id>|<title>' per chat -- the chats, newest first;
--                  <live> the id of the one still going on, or 0
--
-- ASSIST asks, '>BBI2': op, id -- 1 the chats, 2 go on with chat <id>
-- (the phone answers 'a:' with its last question and answer), 3 a new
-- chat, sent just before listening.
local _M = {}

_M.label = 'Assistant'
_M.mode = 'app'
_M.rows = 5               -- every row under the top bar (frame_app.lua)

local REC_START = 0x1F
local AUDIO     = 0x05
local AUDIO_END = 0x06
local REC_DROP  = 0x10    -- [0x10]: the question is dropped, not asked
local ASSIST    = 0x04    -- '>BBI2': 1 the chats, 2 open one, 3 a new one
local FOR_ASSISTANT = 1   -- REC_START's fourth byte

local RATE = 8000
local BITS = 16           -- or 8; Glaz > Menu > Assistant
local MAX_LISTEN = 120    -- s; only so a forgotten one does not run on
local ROWS = _M.rows      -- rows it has on screen
local RETRY = 5           -- s without the chats before asking again

local started = nil       -- utc() when listening began; nil when not
local size = 0            -- bytes per packet, even (16-bit samples)
local per_second = 0      -- bytes of sound a second
local lost = 0            -- bytes the link did not take
local state = ''          -- '', 'chats', 'listen', 'think', 'answer',
                          -- 'error'
local lines = {}          -- the answer, or what was heard, line by line
local page = 1
local chats = nil         -- { {id, title}, ... } once the phone says
local sel, top = 0, 0     -- the chat under the cursor, on the first row;
                          -- 0 is 'New chat'
local asked_at = nil      -- utc() the chats were asked for

local function send(packet)
  for _ = 1, 20 do
    if pcall(frame.bluetooth.send, packet) then return true end
    frame.sleep(0.005)
  end
  return false
end

local function assist(op, id)
  return frame.bluetooth.is_connected()
    and send(string.pack('>BBI2', ASSIST, op, id or 0))
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

local function finish()
  if not started then return end
  pcall(frame.microphone.stop)
  drain()
  send(string.char(AUDIO_END))
  started = nil
end

local function listen()
  finish()
  lines, page = {}, 1
  if not frame.bluetooth.is_connected() then
    state = 'error'
    lines = { 'no phone' }
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
    state = 'error'
    lines = { 'no microphone' }
    return
  end
  started = frame.time.utc()
  state = 'listen'
end

local function split(text)
  local out = {}
  for line in string.gmatch(text, '[^\n]+') do out[#out + 1] = line end
  return out
end

local function chats_screen()
  if not chats then
    return frame.bluetooth.is_connected() and 'loading..'
      or 'no phone\ntap = ask'
  end
  local rows = {}
  for i = top, math.min(top + ROWS - 1, #chats) do
    rows[#rows + 1] = (i == sel and '> ' or '  ')
      .. (i == 0 and 'New chat' or chats[i][2])
  end
  return table.concat(rows, '\n')
end

-- One page of ROWS rows; with more than one page the last row says which.
local function screen()
  if state == 'chats' then return chats_screen() end
  if state == 'listen' then
    local text = string.format('listening... %ds',
                               math.floor(frame.time.utc() - started))
    if lost > 0 then text = text .. string.format('  lost %d KB', lost // 1024) end
    return text .. '\ntap = ask'
  end
  if state == 'think' then
    local heard = ''
    for i = 1, math.min(#lines, ROWS - 1) do
      heard = heard .. (i == 1 and '"' or '') .. lines[i]
        .. (i == math.min(#lines, ROWS - 1) and '"' or '') .. '\n'
    end
    return heard .. 'thinking...'
  end
  if #lines == 0 then return 'tap = ask' end
  if #lines <= ROWS then return table.concat(lines, '\n') end
  local per = ROWS - 1
  local pages = (#lines + per - 1) // per
  if page > pages then page = pages end
  local out = {}
  for i = (page - 1) * per + 1, math.min(page * per, #lines) do
    out[#out + 1] = lines[i]
  end
  out[#out + 1] = string.format('- %d/%d -', page, pages)
  return table.concat(out, '\n')
end

local function take(arg)
  local kind, text = string.match(arg, '^(%a):(.*)$')
  if arg == 'listen' then
    listen()
  elseif arg == 'stop' then
    if started then finish(); state = 'think' end
  elseif kind == 'h' then
    finish()
    state, lines = 'think', split(text)
  elseif kind == 'a' or kind == 'e' then
    finish()
    state, lines, page = kind == 'a' and 'answer' or 'error', split(text), 1
  elseif kind == 'c' and state == 'chats' then
    local live, body = string.match(text, '^(%d+)\n?(.*)$')
    chats, sel, top = {}, 0, 0
    for id, title in string.gmatch(body or '', '(%d+)|([^\n]*)') do
      chats[#chats + 1] = { tonumber(id), title }
      if id == live then sel = #chats end
    end
    if sel >= ROWS then top = sel - ROWS + 1 end
  end
end

local function ask_chats()
  chats, sel, top = nil, 0, 0
  asked_at = assist(1) and frame.time.utc() or nil
end

function _M.start(info)
  state, lines, page = '', {}, 1
  if info and info.arg then
    take(info.arg)
  else
    state = 'chats'
    ask_chats()
  end
end

function _M.tick()
  if state == 'chats' and not chats
     and (not asked_at or frame.time.utc() - asked_at > RETRY) then
    ask_chats()
  end
  if started then
    if not frame.bluetooth.is_connected() then
      finish()
      state, lines = 'error', { 'no phone' }
    elseif frame.time.utc() - started > MAX_LISTEN then
      finish()
      state = 'think'
    else
      drain()
    end
  end
  return screen()
end

function _M.on_tap()
  if started then
    finish()
    state = 'think'
  elseif state == 'chats' and chats and sel > 0 then
    assist(2, chats[sel][1])
    state, lines, page = 'answer', { 'loading..' }, 1
  else
    if state == 'chats' and chats then assist(3) end
    listen()
  end
  return screen()
end

function _M.on_roll(dir)
  if state == 'chats' then
    if not chats then return nil end
    sel = math.max(0, math.min(sel + dir, #chats))
    if sel < top then top = sel end
    if sel > top + ROWS - 1 then top = sel - ROWS + 1 end
    return chats_screen()
  end
  page = math.max(1, page + dir)
  return screen()
end

function _M.remote(arg)
  take(arg)
  return screen()
end

-- Leaving -- a double tap, or anything else that stops it -- drops the
-- question: the sound is not finished, the phone is told to forget it,
-- and an answer still on its way is thrown away.
function _M.stop()
  if started or state == 'think' then
    if started then pcall(frame.microphone.stop) end
    started = nil
    send(string.char(REC_DROP))
  end
  state, chats = '', nil
end

return _M

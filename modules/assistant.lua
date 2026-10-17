-- Menu module: voice assistant. ASCII only, see docs/PROTOCOL.md,
-- "Assistant".
--
--   single tap  -- listen; tapped again, stop and ask
--   tilt        -- page through a long answer
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
local _M = {}

_M.label = 'Assistant'
_M.mode = 'app'
_M.rows = 5               -- every row under the top bar (frame_app.lua)

local REC_START = 0x1F
local AUDIO     = 0x05
local AUDIO_END = 0x06
local REC_DROP  = 0x10    -- [0x10]: the question is dropped, not asked
local FOR_ASSISTANT = 1   -- REC_START's fourth byte

local RATE = 8000
local BITS = 16           -- or 8; Glaz > Menu > Assistant
local MAX_LISTEN = 120    -- s; only so a forgotten one does not run on
local ROWS = _M.rows      -- rows it has on screen

local started = nil       -- utc() when listening began; nil when not
local size = 0            -- bytes per packet, even (16-bit samples)
local per_second = 0      -- bytes of sound a second
local lost = 0            -- bytes the link did not take
local state = ''          -- '', 'listen', 'think', 'answer', 'error'
local lines = {}          -- the answer, or what was heard, line by line
local page = 1

local function send(packet)
  for _ = 1, 20 do
    if pcall(frame.bluetooth.send, packet) then return true end
    frame.sleep(0.005)
  end
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

-- One page of ROWS rows; with more than one page the last row says which.
local function screen()
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
  end
end

function _M.start(info)
  state, lines, page = '', {}, 1
  if info and info.arg then take(info.arg) end
end

function _M.tick()
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
  else
    listen()
  end
  return screen()
end

function _M.on_roll(dir)
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
  state = ''
end

return _M

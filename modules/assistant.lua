-- Menu module: voice assistant. ASCII only, see docs/PROTOCOL.md,
-- "Assistant".
--
--   opening it  -- listens straight away
--   single tap  -- listening: stop and ask; otherwise ask again
--   tilt        -- page through a long answer
--   double tap  -- back
--
-- Listening is Recorder's streaming with a fourth byte in REC_START, 1, so
-- the phone hands the sound to the assistant instead of saving it. The
-- phone also stops it once the speaker goes quiet. It transcribes, asks
-- the agent and answers through remote(arg), or APP_OPEN 'assistant' with
-- arg, which comes to start() when the module was not running:
--
--   'stop'      -- the speaker went quiet: stop listening
--   'h:<text>'  -- what was heard; the agent is thinking
--   'a:<text>'  -- the answer, ASCII, already in lines of at most LINE
--   'e:<text>'  -- went wrong, why
--   'listen'    -- listen again
local _M = {}

_M.label = 'Assistant'
_M.mode = 'app'

local REC_START = 0x1F
local AUDIO     = 0x05
local AUDIO_END = 0x06
local FOR_ASSISTANT = 1   -- REC_START's fourth byte

local RATE = 8000
local BITS = 8
local MAX_LISTEN = 30     -- s; the phone stops it sooner, on a pause
local ROWS = 3            -- rows a module has on screen

local started = nil       -- utc() when listening began; nil when not
local size = 0            -- bytes per packet
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
  while done < RATE * 2 do
    local ok, s = pcall(frame.microphone.read, size)
    if not ok or s == nil or s == '' then return end
    done = done + #s
    send(string.char(AUDIO) .. s)
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
  size = frame.bluetooth.max_length() - 1
  pcall(frame.microphone.stop)
  if not pcall(frame.microphone.start, { sample_rate = RATE,
                                         bit_depth = BITS })
     or not send(string.char(REC_START, BITS, RATE // 1000, FOR_ASSISTANT))
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
    return string.format('listening... %ds\ntap = ask',
                         math.floor(frame.time.utc() - started))
  end
  if state == 'think' then
    local heard = lines[1] and ('"' .. lines[1] .. '"\n') or ''
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
  if info and info.arg then take(info.arg) else listen() end
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

function _M.stop()
  finish()
end

return _M

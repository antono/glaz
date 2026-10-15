-- Menu module: voice recorder. ASCII only, see docs/PROTOCOL.md, "Recorder".
--
--   single tap -- start / stop recording
--   double tap -- back; a recording goes on in the background
--
-- The phone's record button calls remote('on') or remote('off')
-- (MODULE_CALL), and frame_app.lua starts the module straight into the
-- background when it is not running. _M.rec is
-- true while recording: the top bar shows a red dot for it.
--
-- The glasses keep nothing: the sound is streamed to the phone as it is
-- recorded, and the phone saves each recording as a WAV file (Glaz >
-- Recordings). With no host connected the module says so and does not start.
--
-- The microphone fills a buffer of about 2 s in the firmware; every tick
-- empties it into Bluetooth packets. A background module is ticked once a
-- second, so recording goes on with the screen elsewhere. Whatever the link
-- cannot take is dropped, never kept here: there is no room for it.
--
-- Messages, Frame -> Host:
--   REC_START [0x1F, bits, rate / 1000]  a recording begins
--   AUDIO     [0x05, samples...]         the frame_msg audio library's codes
--   AUDIO_END [0x06, samples...]         the last part; the recording ends
local _M = {}

_M.label = 'Recorder'
_M.mode = 'app'

local REC_START = 0x1F
local AUDIO     = 0x05
local AUDIO_END = 0x06

local RATE = 8000         -- Hz; 16000 is more than the link carries
local BITS = 8            -- 8 or 16; the phone may set 16 (Glaz > Menu)

local started = nil       -- utc() when recording began; nil when not
local sent = 0            -- bytes of sound sent
local lost = 0            -- bytes the link did not take
local size = 0            -- bytes per packet, even (16-bit samples)
local per_second = 0      -- bytes of sound a second

local function send(packet)
  for _ = 1, 20 do
    if pcall(frame.bluetooth.send, packet) then return true end
    frame.sleep(0.005)
  end
  return false
end

-- What the microphone has gathered, sent. After stop() the firmware hands
-- out what is left, then nil. At most two seconds' worth a call: should the
-- link be slower than the microphone, the loop still gets its turn.
local function drain()
  local most = per_second * 2
  local done = 0
  while done < most do
    local ok, s = pcall(frame.microphone.read, size)
    if not ok or s == nil or s == '' then return end
    done = done + #s
    if send(string.char(AUDIO) .. s) then
      sent = sent + #s
    else
      lost = lost + #s
    end
  end
end

-- At most three rows of about 26 characters each.
local function screen()
  if not started then
    if not frame.bluetooth.is_connected() then return 'no host' end
    if sent > 0 then
      return string.format('saved %d KB\ntap = record', sent // 1024)
    end
    return 'tap = record'
  end
  local s = math.floor(frame.time.utc() - started)
  local text = string.format('REC %d:%02d  %d KB', s // 60, s % 60,
                             sent // 1024)
  if lost > 0 then text = text .. string.format('\nlost %d KB', lost // 1024) end
  return text .. '\ntap = stop'
end

local function begin()
  if not frame.bluetooth.is_connected() then return end
  local bits = _M.host.setting('bits', BITS)
  if bits ~= 8 and bits ~= 16 then bits = BITS end
  size = frame.bluetooth.max_length() - 1
  if size % 2 == 1 then size = size - 1 end
  per_second = RATE * bits // 8
  pcall(frame.microphone.stop)   -- left running by someone else
  if not pcall(frame.microphone.start, { sample_rate = RATE,
                                         bit_depth = bits }) then
    return
  end
  if not send(string.char(REC_START, bits, RATE // 1000)) then
    pcall(frame.microphone.stop)
    return
  end
  started = frame.time.utc()
  sent, lost = 0, 0
  _M.rec = true
end

local function finish()
  if not started then return end
  pcall(frame.microphone.stop)
  drain()
  send(string.char(AUDIO_END))
  started = nil
  _M.rec = false
end

-- Keeps running off screen while recording; stopped for good otherwise.
function _M.background()
  return started ~= nil
end

function _M.tick()
  if started and not frame.bluetooth.is_connected() then
    finish()   -- nobody to send to; the phone keeps what it got
  elseif started then
    drain()
  end
  return screen()
end

function _M.on_tap()
  if started then finish() else begin() end
  return screen()
end

-- The phone's button: 'on' starts, 'off' stops; either is a no-op when
-- already so.
function _M.remote(arg)
  if arg == 'on' and not started then begin()
  elseif arg == 'off' then finish() end
  return screen()
end

function _M.stop()
  finish()
  sent, lost = 0, 0
end

return _M

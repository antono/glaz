-- Menu module: an instrument tuner. ASCII only, see docs/PROTOCOL.md,
-- "Tuner".
--
-- First a list of instruments; then the chosen one's tuning, its strings
-- from the lowest-numbered string's opposite end as players name them
-- (a guitar's E A D G B E), and the note heard: the string nearest to it
-- lit, how far off in cents on a scale, and the note itself.
--
--   list:   tilt -- the cursor, tap -- tune that instrument
--   tuning: double tap -- back to the list
--
-- The list opens at the instrument tuned last, kept on the glasses as a
-- pref (_M.host.pref 'instrument'): a module's locals go when it stops.
--
-- The glasses only draw. The phone hears and finds the pitch, from its own
-- microphone or from the glasses' (the setting 'mic', Glaz > Menu > Tuner),
-- and calls remote(arg) (MODULE_CALL 'tuner'):
--   'p<pitch> <hz>' -- a note: pitch in hundredths of a semitone, MIDI
--                      numbering (4512: A2 and 12 cents), hz in tenths
--   'p'             -- nothing heard any more
--   's<text>'       -- no note, the phone says why ('allow the microphone')
--
-- Messages, Frame -> Host:
--   TUNER [0x03, 1, mic]  -- tuning on screen: listen; mic 0 the phone's,
--                            1 the glasses', which then stream it as
--                            Recorder does, REC_START's for = 3
--   TUNER [0x03, 0]       -- back to the list or gone: stop
local _M = {}

_M.label = 'Tuner'
_M.mode = 'app'
_M.quiet = true           -- draw() is the screen; tick() text is not shown
_M.period = 0.1           -- the glasses' microphone is drained this often

local TUNER     = 0x03
local REC_START = 0x1F
local AUDIO     = 0x05
local AUDIO_END = 0x06
local FOR_TUNER = 3

local RATE = 8000         -- Hz, 16 bit: the glasses' microphone, streamed
local BITS = 16
local ASK_AGAIN = 3       -- s without a word from the phone: ask again
local AWAKE     = 30      -- s after the last note the module stays open
                          -- without a tap: tuning takes no taps

-- MIDI note numbers of the open strings, in the order players name them.
local INSTRUMENTS = {
  { name = 'Guitar',    notes = { 40, 45, 50, 55, 59, 64 } },  -- E A D G B E
  { name = 'Banjo',     notes = { 67, 50, 55, 59, 62 } },      -- g D G B D
  { name = 'Balalaika', notes = { 64, 64, 69 } },              -- E E A
  { name = 'Domra',     notes = { 64, 69, 74 } },              -- E A D
  { name = 'Ukulele',   notes = { 67, 60, 64, 69 } },          -- G C E A
  { name = 'Bass',      notes = { 28, 33, 38, 43 } },          -- E A D G
  { name = 'Violin',    notes = { 55, 62, 69, 76 } },          -- G D A E
}
local NAMES = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#',
                'B' }

-- Layout. The top bar is the app's; this module draws the rest, inside
-- what the wearer sees, 640x340 from y 43 (docs/PROTOCOL.md).
local LEFT_X   = 60
local LIST_Y   = 65       -- the list: up to LIST_ROWS rows of ROW_H
local ROW_H    = 55
local LIST_ROWS = 4
local TUNING_X = 300      -- each instrument's tuning, beside its name
local STRINGS_X, STRINGS_W = 64, 512   -- the strings, a slot each
local LABEL_Y  = 65       -- string names
local LINE_Y, LINE_H = 110, 32         -- under each, the string itself
local NOTE_Y   = 152      -- the note heard, its cents, its Hz
local SCALE_X, SCALE_W = 80, 480       -- -50..+50 cents, multiple of 8
local SCALE_Y  = 240      -- the scale's line; the needle stands on it
local NEEDLE_H = 36
local TICK_H   = 10
local HINT_Y   = 268
local CENTS_PX = SCALE_W / 100

-- bitmap palette offsets: n draws palette index n + 1
local GREY, RED, YELLOW, GREEN = 1, 2, 7, 9

local LINE   = string.rep('\x18', LINE_H)              -- 8 wide, 2 lit
local RULE   = string.rep('\xFF', SCALE_W * 2 // 8)    -- 2 px high
local TICK   = string.rep('\x18', TICK_H)
local CENTRE = string.rep('\x18', TICK_H * 2)
local NEEDLE = string.rep('\x7E', NEEDLE_H)            -- 6 of 8 lit

local cursor = 1          -- the list's
local chosen = nil        -- the instrument being tuned; nil: the list
local pitch = nil         -- the last note, in semitones; nil before one
local hz = 0
local live = false        -- the phone still hears it
local heard_at = nil      -- utc() of the last note
local status = ''         -- what the phone says instead of a note
local asked = nil         -- utc() when TUNER 1 went out; nil when not
local heard = false       -- the phone has answered since
local mic = 0             -- 0 the phone's, 1 the glasses'
local streaming = false   -- the glasses' microphone is on
local size, per_second = 0, 0

local function send(packet)
  for _ = 1, 20 do
    if pcall(frame.bluetooth.send, packet) then return true end
    frame.sleep(0.005)
  end
  return false
end

local function name_of(n)
  return NAMES[n % 12 + 1] .. (n // 12 - 1)
end

-- The glasses' microphone to the phone, as Recorder sends it: at most two
-- seconds' worth a call, a garbage collector step a packet.
local function drain()
  local most = per_second * 2
  local done = 0
  while done < most do
    local ok, s = pcall(frame.microphone.read, size)
    if not ok or s == nil or s == '' then return end
    done = done + #s
    send(string.char(AUDIO) .. s)
    s = nil
    collectgarbage('step')
  end
end

local function mic_on()
  size = frame.bluetooth.max_length() - 1
  if size % 2 == 1 then size = size - 1 end
  per_second = RATE * BITS // 8
  pcall(frame.microphone.stop)   -- left running by someone else
  if not pcall(frame.microphone.start, { sample_rate = RATE,
                                         bit_depth = BITS }) then
    status = 'no microphone'
    return
  end
  if not send(string.char(REC_START, BITS, RATE // 1000, FOR_TUNER)) then
    pcall(frame.microphone.stop)
    return
  end
  streaming = true
end

local function mic_off()
  if not streaming then return end
  pcall(frame.microphone.stop)
  drain()
  send(string.char(AUDIO_END))
  streaming = false
end

local function listen()
  asked, heard = frame.time.utc(), false
  mic = _M.host.setting('mic', 'phone') == 'glasses' and 1 or 0
  send(string.char(TUNER, 1, mic))
  if mic == 1 and not streaming then mic_on() end
end

local function quit_listening()
  mic_off()
  if asked then send(string.char(TUNER, 0)) end
  asked, heard = nil, false
end

local function choose(i)
  chosen = INSTRUMENTS[i]
  pitch, live, heard_at, status = nil, false, nil, ''
end

-- The open string nearest to the note, and how far off it is in cents.
local function nearest(p)
  local best
  for _, n in ipairs(chosen.notes) do
    if not best or math.abs(p - n) < math.abs(p - best) then best = n end
  end
  return best, math.floor((p - best) * 100 + 0.5)
end

local function colour_of(cents)
  local a = math.abs(cents)
  if a <= 5 then return GREEN, 'GREEN' end
  if a <= 20 then return YELLOW, 'YELLOW' end
  return RED, 'RED'
end

local function draw_list()
  local first = math.max(1, math.min(cursor - LIST_ROWS // 2,
                                     #INSTRUMENTS - LIST_ROWS + 1))
  for row = 0, LIST_ROWS - 1 do
    local i = first + row
    local it = INSTRUMENTS[i]
    if not it then break end
    local y = LIST_Y + row * ROW_H
    local on = i == cursor
    frame.display.text((on and '> ' or '  ') .. it.name, LEFT_X, y,
                       { color = on and 'YELLOW' or 'WHITE' })
    local names = {}
    for k, n in ipairs(it.notes) do names[k] = NAMES[n % 12 + 1] end
    frame.display.text(table.concat(names, ' '), TUNING_X, y,
                       { color = 'GREY' })
  end
end

local function draw_tuning()
  local target, cents
  if pitch then target, cents = nearest(pitch) end
  local palette, colour = GREY, 'GREY'
  if pitch and live then palette, colour = colour_of(cents) end

  -- the strings, the one nearest the note lit
  local notes = chosen.notes
  local slot = STRINGS_W // #notes
  for k, n in ipairs(notes) do
    local cx = STRINGS_X + (k - 1) * slot + slot // 2
    local lit = live and n == target
    frame.display.text(name_of(n), cx - 22, LABEL_Y,
                       { color = lit and colour or 'WHITE' })
    frame.display.bitmap(cx - 4, LINE_Y, 8, 2, lit and palette or GREY, LINE)
  end

  -- the scale: -50 .. +50 cents from that string
  local mid = SCALE_X + SCALE_W // 2
  frame.display.bitmap(SCALE_X, SCALE_Y, SCALE_W, 2, GREY, RULE)
  for k = -5, 5 do
    local x = mid + math.floor(k * 10 * CENTS_PX) - 4
    if k == 0 then
      frame.display.bitmap(x, SCALE_Y - TICK_H * 2, 8, 2, GREY, CENTRE)
    else
      frame.display.bitmap(x, SCALE_Y - TICK_H, 8, 2, GREY, TICK)
    end
  end

  if not pitch then
    frame.display.text(status ~= '' and status or 'play a string', LEFT_X,
                       HINT_Y, { color = status ~= '' and 'YELLOW' or 'GREY' })
    return
  end

  local c = math.max(-50, math.min(50, cents))
  frame.display.bitmap(mid + math.floor(c * CENTS_PX) - 4,
                       SCALE_Y - NEEDLE_H, 8, 2, palette, NEEDLE)

  -- the note as heard, then how far from the string
  local heard_note = math.floor(pitch + 0.5)
  frame.display.text(name_of(heard_note), LEFT_X, NOTE_Y,
                     { color = live and 'WHITE' or 'GREY' })
  frame.display.text(string.format('%+d c', cents), 200, NOTE_Y,
                     { color = colour })
  frame.display.text(string.format('%.1f Hz', hz), 380, NOTE_Y,
                     { color = 'GREY' })

  local hint
  if status ~= '' then hint = status
  elseif not live then hint = 'play a string'
  elseif cents < -5 then hint = 'tune up'
  elseif cents > 5 then hint = 'tune down'
  else hint = 'in tune' end
  frame.display.text(hint, LEFT_X, HINT_Y,
                     { color = status ~= '' and 'YELLOW' or colour })
end

function _M.draw()
  if chosen then draw_tuning() else draw_list() end
end

function _M.start()
  chosen = nil
  cursor = _M.host.pref('instrument', 1)
  if not INSTRUMENTS[cursor] then cursor = 1 end
end

function _M.on_roll(dir)
  if chosen then return end
  cursor = (cursor - 1 + dir) % #INSTRUMENTS + 1
  return 'list ' .. cursor
end

function _M.on_tap()
  if chosen then return end
  choose(cursor)
  _M.host.set_pref('instrument', cursor)
  listen()
  return 'tune ' .. cursor
end

-- One level up: the tuning to the list; the list leaves.
function _M.on_back()
  if not chosen then return false end
  quit_listening()
  chosen = nil
  return 'list ' .. cursor
end

function _M.remote(arg)
  heard = true
  local kind = string.sub(arg, 1, 1)
  if kind == 'p' then
    local p, h = string.match(arg, '^p(%d+) (%d+)$')
    if p then
      pitch, hz, live = tonumber(p) / 100, tonumber(h) / 10, true
      heard_at = frame.time.utc()
    else
      live = false
    end
    status = ''
  elseif kind == 's' then
    status = string.sub(arg, 2)
  end
  return ''
end

-- Open while notes come, though nobody taps.
function _M.busy()
  return heard_at ~= nil and frame.time.utc() - heard_at < AWAKE
end

-- Only says when to redraw: any change of what draw() shows does.
function _M.tick()
  if not chosen then return 'list ' .. cursor end
  local now = frame.time.utc()
  if not frame.bluetooth.is_connected() then
    if streaming then mic_off() end
    asked, heard = nil, false
    status = 'no phone'
  elseif not heard and (not asked or now - asked > ASK_AGAIN) then
    if status == 'no phone' then status = '' end
    listen()
  end
  if streaming then drain() end
  return string.format('%s %s %s %s %s', chosen.name, tostring(pitch),
                       tostring(live), hz, status)
end

function _M.stop()
  quit_listening()
  chosen = nil
  pitch, live, heard_at, status = nil, false, nil, ''
end

return _M

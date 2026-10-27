-- Menu module: speed reader (RSVP). ASCII only, see docs/PROTOCOL.md,
-- "Reader". The words it shows are UTF-8: the font has Cyrillic.
--
-- One word at a time, always at the same spot: the letter the eye should
-- land on (the optimal recognition point, a little left of the middle) is
-- red and sits at PIVOT_X whatever the word, so the eye never moves.
--
--   single tap  -- pause / go on; at the end, from the start again
--   tilt        -- reading: faster / slower by WPM_STEP
--                  paused: back / on by a sentence
--   double tap  -- back; the phone keeps the place
--
-- The text lives on the phone (Glaz > Menu > Reader), which also keeps the
-- place in it. The glasses hold only a few dozen words: they ask for the
-- next BATCH with TEXT_GET when fewer than LOW are left, and the phone
-- answers through remote(arg):
--
--   't:<from>:<total>:<text>:<words>'
--         words from number <from> (0-based), one space between them, of
--         text number <text> (1..255), <total> words long. A <text> other
--         than the one held: the phone reads another text now (its
--         library, Glaz > Menu > Reader), from that text's place.
--   'new' -- start again from the phone's place: Read on glasses
--
-- The phone has already kept to what the font has and cut long words into
-- pieces that fit (flutter-glaz/lib/services/reader.dart).
local _M = {}

_M.label = 'Reader'
_M.mode = 'app'
_M.period = 0.02          -- s between ticks: a word is due every 60/wpm
_M.quiet = true           -- draw() is the screen; tick() text is not shown

local TEXT_GET = 0x0A     -- '>I4I4BI2B': place, from, count, wpm, text;
                          -- count 0 only tells the phone the place and
                          -- the speed
local RESUME   = 0xFFFFFFFF  -- from: wherever the phone says the place is

local WPM      = 300      -- default; Glaz > Menu > Reader
local WPM_MIN  = 100
local WPM_MAX  = 800
local WPM_STEP = 25
local BATCH    = 60       -- words asked for at a time
local LOW      = 20       -- ask for more when fewer than this are left
local BEHIND   = 30       -- words kept behind the place, to go back to
local RETRY    = 5        -- s without an answer before asking again

-- Layout. The top bar is the app's; this module draws the rest.
local PIVOT_X  = 250      -- centre of the red letter: a third of the way
                          -- across what the eye sees, so the longer part
                          -- of a word, after the pivot, has the room
local WORD_Y   = 146      -- the word, glyphs 48 px high
local RULE_X   = 64       -- guide rules above and below the word
local RULE_W   = 544      -- multiple of 8: 1-bit rows of whole bytes
local RULE_TOP = 126
local RULE_BOT = 202
local NOTCH_H  = 12       -- the notches on the rules point at the pivot
local INFO_Y   = 285      -- the bottom row: speed, state, progress
local LEFT_X   = 60
local GREY     = 1        -- bitmap palette offsets: 1 draws GREY
local SPACING  = 4        -- the firmware's default gap between glyphs

-- Advance of each glyph of the firmware font, ' ' to '~': the byte minus
-- 48 is its width in px (system_font.h in the firmware; '/' has no glyph).
-- Then U+00A0..U+00FF and Cyrillic U+0400..U+045F the same way; 0: none.
local WIDTHS = '=5=CARD5:;EC8A60B@@?B?A?BA68CCC>OFB@CAABC<>C@GCDBFDADCEGEGA' ..
               '9?:DI;CB=B@?DB5;B8LBBBB;?>ACNDD@<5<A'
local LATIN1 = '06>B0F000L0A00M0?D000A06000A000>FGGGGGP@A@AA<;@?FCDDDDDBDCC' ..
               'CCCFBCCCCCCCM>A@AA;;@?B@BBBABCBAA@ADBD'
local CYRILLIC = 'AAH?AA<?>PPHCDECF@B?FAP@DDCDGCDCB@DEHEDALNEG@AMBCCB=F@P@BBCC' ..
                 'HABAB=BDIDDAKNEF@@LBAAF=@?5?;MLFCBCC'
local OTHER_W = 18        -- the font's other Cyrillic (Kazakh, Tatar..): an 'o'
local EMOJI_W = 40        -- the font's emoji (U+203C, U+2600 on): the widest

local RULE  = string.rep('\xFF', RULE_W * 2 // 8)        -- 2 px high
local NOTCH = string.rep('\x18', NOTCH_H)                -- 8 wide, 2 lit

local words = {}          -- number -> word, for lo <= number < hi
local lo, hi = 0, 0
local pos = 0             -- the word on screen
local total = nil         -- words in the text; nil until the phone says
local text = 0            -- its number, 0 before the first answer
local asked = nil         -- from of the request on its way, or nil
local asked_at = 0
local wpm = WPM
local wpm_set = nil       -- the phone's setting, as last seen
local playing = false
local due = 0             -- utc() when the next word is due
local timed = nil         -- the word due is for; nil: time the one shown
local lead = false        -- the first word of a run stays twice as long
local note = ''           -- why there is no word: no phone, no text
local shown = false       -- ticked on screen: only then is the place real

-- c: a code point
local function glyph_w(c)
  local t, base
  if c >= 32 and c <= 126 then
    t, base = WIDTHS, 32
  elseif c >= 0xA0 and c <= 0xFF then
    t, base = LATIN1, 0xA0
  elseif c >= 0x400 and c <= 0x45F then
    t, base = CYRILLIC, 0x400
  elseif c >= 0x490 and c <= 0x4FF then
    return OTHER_W + SPACING
  elseif c == 0x203C or c >= 0x2600 then
    return EMOJI_W + SPACING
  else
    return 0
  end
  local w = string.byte(t, c - base + 1) - 48
  return w > 0 and w + SPACING or 0
end

-- s as code points and where each starts, one past the end last. Not
-- valid UTF-8 (it always is from the phone), byte by byte.
local function chars(s)
  local cs, at = {}, {}
  if utf8.len(s) then
    for i, c in utf8.codes(s) do cs[#cs + 1] = c; at[#at + 1] = i end
  else
    for i = 1, #s do cs[i] = string.byte(s, i); at[i] = i end
  end
  at[#cs + 1] = #s + 1
  return cs, at
end

local function text_w(s)
  local w = 0
  for _, c in ipairs((chars(s))) do w = w + glyph_w(c) end
  return w
end

-- A letter or digit: ASCII ones, and all from U+00C0 on but the times and
-- divide signs
local function letter(c)
  if c < 128 then return string.find(string.char(c), '%w') ~= nil end
  return c >= 0xC0 and c ~= 0xD7 and c ~= 0xF7
end

-- w with its closing guillemets as '"', for the patterns below
local function plain(w)
  return (string.gsub(w, '\xC2\xBB', '"'))
end

-- The letter to look at, by the length of the word without its
-- punctuation: the second of two to five letters, the third of six to
-- nine, and so on -- a little left of the middle, where a word is
-- recognised fastest.
local function pivot(cs)
  local a = 1
  while a < #cs and not letter(cs[a]) do a = a + 1 end
  if not letter(cs[a]) then a = 1 end
  local b = #cs
  while b > a and not letter(cs[b]) do b = b - 1 end
  local n = b - a + 1
  local p = n <= 1 and 1 or n <= 5 and 2 or n <= 9 and 3 or n <= 13 and 4
            or 5
  return a + p - 1
end

-- How long a word stays: longer at the end of a sentence or a clause, and
-- for a long word.
local function delay(w)
  local d = 60 / wpm
  local mark = string.match(plain(w), '([%.!?,;:])[%)"\']*$')
  if mark == '.' or mark == '!' or mark == '?' then
    d = d * 2
  elseif mark then
    d = d * 1.5
  end
  if (utf8.len(w) or #w) > 8 then d = d * 1.25 end
  return d
end

local function sentence_start(i)
  if i <= 0 then return true end
  local prev = words[i - 1]
  return prev ~= nil and string.find(plain(prev), '[%.!?][%)"\']*$') ~= nil
end

local function send(from, count)
  local packet = string.char(TEXT_GET) ..
                 string.pack('>I4I4BI2B', pos, from, count, wpm, text)
  for _ = 1, 20 do
    if pcall(frame.bluetooth.send, packet) then return true end
    frame.sleep(0.005)
  end
  return false
end

local function ask(from)
  if not frame.bluetooth.is_connected() then
    note = 'no phone'
    return
  end
  if send(from, BATCH) then
    asked, asked_at = from, frame.time.utc()
  end
end

-- Start over at word number at: what is held is dropped, the phone sends
-- the words from there.
local function jump(at)
  words, lo, hi, pos = {}, at, at, at
  ask(at)
end

-- From wherever the phone says the place is: on start, and for a new text.
-- Nothing is asked here: tick() asks, and only a module on screen is
-- ticked. An answer that comes after the module was left starts it in the
-- background for remote() (glaz.lua, MODULE_CALL); asking from
-- start() would then ask again, and the phone answer again, for ever.
local function resume()
  words, lo, hi, pos, total, asked = {}, 0, 0, 0, nil, nil
end

-- Fewer than LOW words left: ask for the next ones. No answer within
-- RETRY: ask again.
local function refill(now)
  if asked and now - asked_at < RETRY then return end
  if total == nil then
    asked = nil
    ask(RESUME)
  elseif hi < total and hi - pos < LOW then
    asked = nil
    ask(hi)
  end
end

local function forget_behind()
  while lo < pos - BEHIND do
    words[lo] = nil
    lo = lo + 1
  end
end

-- The speed set on the phone, when it changes: also while reading. A tilt
-- changes it here only, until the next pause, when the phone keeps it.
local function follow_setting()
  local set = _M.host.setting('wpm', WPM)
  if set ~= wpm_set then
    wpm_set = set
    wpm = math.max(WPM_MIN, math.min(WPM_MAX, set))
  end
end

function _M.start(info)
  wpm_set = nil
  follow_setting()
  playing, note, shown = false, '', false
  resume()
end

function _M.stop()
  if shown and total and total > 0 then send(pos, 0) end
  words = {}
end

function _M.busy() return playing end

-- The place, the speed and what is shown: the screen is redrawn when it
-- changes (glaz.lua; draw() paints it).
local function state()
  return table.concat({ pos, tostring(words[pos]), wpm, tostring(playing),
                        tostring(total), note }, '|')
end

function _M.tick()
  local now = frame.time.utc()
  shown = true
  follow_setting()
  refill(now)
  if playing and words[pos] then
    if timed ~= pos then
      -- the word has just come: on play, or after waiting for the phone
      timed = pos
      due = now + delay(words[pos]) * (lead and 2 or 1)
      lead = false
    elseif now >= due then
      if words[pos + 1] then
        pos = pos + 1
        timed = pos
        due = now + delay(words[pos])
        forget_behind()
      elseif total and pos + 1 >= total then
        playing = false   -- the end
        send(pos, 0)
      end
      -- else the next words are on their way
    end
  end
  return state()
end

function _M.remote(arg)
  if arg == 'new' then
    playing, note = false, ''
    resume()
    return state()
  end
  local from, count, num, body =
    string.match(arg, '^t:(%d+):(%d+):(%d+):(.*)$')
  if not from then return nil end
  from, total, num = tonumber(from), tonumber(count), tonumber(num)
  note = total == 0 and 'no text' or ''
  if asked == RESUME or num ~= text then
    -- the first words, or of another text: start over there
    words, lo, hi, pos = {}, from, from, from
    text, timed = num, nil
  elseif from ~= hi then
    return nil            -- an answer to a request since replaced
  end
  asked = nil
  for w in string.gmatch(body, '%S+') do
    words[hi] = w
    hi = hi + 1
  end
  return state()
end

function _M.on_tap()
  if total == 0 or note == 'no phone' then
    note = ''
    resume()
  elseif total and pos + 1 >= total and not playing then
    jump(0)               -- the end: again from the start
    playing, timed, lead = true, nil, true
  elseif words[pos] then
    playing = not playing
    -- the first word of a run stays longer: the eye has to find it
    timed, lead = nil, true
    if not playing then send(pos, 0) end
  end
  return state()
end

function _M.on_roll(dir)
  if playing then
    wpm = math.max(WPM_MIN, math.min(WPM_MAX, wpm + dir * WPM_STEP))
    return state()
  end
  -- paused: to the start of the previous / next sentence
  local i = pos + dir
  while words[i] and not sentence_start(i) do i = i + dir end
  if words[i] then
    pos = i
  elseif dir < 0 then
    if lo > 0 then jump(math.max(0, pos - BEHIND)) else pos = lo end
  elseif total and hi < total then
    jump(hi)
  end
  return state()
end

-- The word, its pivot letter red and centred on PIVOT_X: the part before
-- it ends just left of the letter, the part after starts just right of it.
-- Each piece is one text() call, so the firmware spaces each piece itself;
-- only their starts come from WIDTHS.
local function draw_word(w)
  local cs, at = chars(w)
  local p = pivot(cs)
  local c = string.sub(w, at[p], at[p + 1] - 1)
  local cw = glyph_w(cs[p] or 32)
  local x = PIVOT_X - (cw - SPACING) // 2
  local before, after = string.sub(w, 1, at[p] - 1), string.sub(w, at[p + 1])
  if before ~= '' then
    frame.display.text(before, x - text_w(before), WORD_Y,
                       { color = 'WHITE' })
  end
  frame.display.text(c, x, WORD_Y, { color = 'RED' })
  if after ~= '' then
    frame.display.text(after, x + cw, WORD_Y, { color = 'WHITE' })
  end
end

function _M.draw()
  pcall(frame.display.bitmap, RULE_X, RULE_TOP, RULE_W, 2, GREY, RULE)
  pcall(frame.display.bitmap, RULE_X, RULE_BOT, RULE_W, 2, GREY, RULE)
  pcall(frame.display.bitmap, PIVOT_X - 4, RULE_TOP + 2, 8, 2, GREY, NOTCH)
  pcall(frame.display.bitmap, PIVOT_X - 4, RULE_BOT - NOTCH_H, 8, 2, GREY,
        NOTCH)

  local w = words[pos]
  if w then
    draw_word(w)
  else
    local why = note ~= '' and note or 'loading'
    frame.display.text(why, PIVOT_X - text_w(why) // 2, WORD_Y,
                       { color = 'GREY' })
  end

  -- the speed, always; what state it is in; how far through
  frame.display.text(wpm .. ' wpm', LEFT_X, INFO_Y, { color = 'SKYBLUE' })
  local status = note == 'no text' and 'text: Glaz > Menu'
                 or note == 'no phone' and 'tap to retry'
                 or (total and total > 0 and pos + 1 >= total and not playing)
                    and 'the end'
                 or (not playing and w) and 'paused' or ''
  if status ~= '' then
    frame.display.text(status, 240, INFO_Y, { color = 'YELLOW' })
  end
  if total and total > 0 then
    frame.display.text((pos + 1) * 100 // total .. '%', 540, INFO_Y,
                       { color = 'GREY' })
  end
end

return _M

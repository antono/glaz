-- Menu module: a Gemini browser. ASCII only, see docs/PROTOCOL.md,
-- "Gemini". The text it shows is UTF-8: the font has Cyrillic.
--
--   tilt right / left -- the next / previous link on screen; past the
--                        last / first one, a screen down / up
--   single tap        -- open the link under the cursor; with none, a
--                        screen down
--   double tap        -- back to the page before, as '< back' does; on
--                        the home page, back to the menu: the phone
--                        keeps the page, and it is there when this
--                        opens again
--
-- The phone fetches the pages (gemini://, over TLS), keeps the one open
-- and where it came from, and cuts it into lines that fit the screen
-- (flutter-glaz/lib/services/gemini.dart). Its home page is the bookmarks
-- set on the phone (Glaz > Menu > Gemini); every other page starts and
-- ends with '< back', and ends with 'home'. The glasses hold a few dozen
-- lines and ask for others as they scroll. GEM_GET asks, the phone
-- answers through remote(arg):
--
--   'p:<page>:<from>:<total>:<top>:<back>' then '\n<kind><link>|<text>'
--         per line, from line number <from> (0-based) of page <page>
--         (1..255, new on every page opened), <total> lines long; <top>
--         is the line to show first, for a page just opened; <back> 1
--         when there is a page to go back to (not the home page), and
--         missing from an older phone. kind: T text, H heading, L link
--         (<link> its number), Q quote, P preformatted.
local _M = {}

_M.label = 'Gemini'
_M.mode = 'app'
_M.quiet = true           -- draw() is the screen; tick() text is not shown

local GEM_GET = 0x0D      -- '>BBI2I2': op, page, n, top; op 1 opens link
                          -- n of the page, op 2 asks for lines from n
local BACK = 0            -- the link number of '< back'
local ROWS = 5
local BEFORE = 8          -- lines asked for above the first on screen
local RETRY = 5           -- s without lines before asking again
local OPEN_WAIT = 25      -- s for a page to come: the phone gives up at 15

-- Layout: rows under the top bar, the cursor left of the text
local LEFT_X, TEXT_X = 60, 88
local TOP_Y, ROW_H = 65, 55
local COLORS = { T = 'WHITE', H = 'ORANGE', L = 'SKYBLUE', Q = 'GREY',
                 P = 'LIGHTGREEN' }

local lines = {}          -- number -> { kind, link or nil, text }
local lo, hi = 0, 0
local page = 0            -- the page held, 0 before the first answer
local total = nil         -- its lines; nil until the phone says
local back = false        -- the page held has a page before it
local top = 0             -- the line on the first row
local sel = nil           -- the line the link under the cursor starts on
local asked = nil         -- 'l<from>' for lines, 'o' for a page to open
local asked_at = 0
local note = ''

local function link_at(i)
  return lines[i] and lines[i][2]
end

-- the first line of a link: a link on it, another on the line above
local function starts(i)
  local l = link_at(i)
  return l ~= nil and (i == lo or link_at(i - 1) ~= l)
end

local function last_row()
  return math.min(top + ROWS, total or 0) - 1
end

local function view_loaded()
  for i = top, last_row() do
    if not lines[i] then return false end
  end
  return total ~= nil
end

local function send(op, n)
  local packet = string.pack('>BBBI2I2', GEM_GET, op, page, n, top)
  for _ = 1, 20 do
    if pcall(frame.bluetooth.send, packet) then return true end
    frame.sleep(0.005)
  end
  return false
end

local function ask(op, n)
  if not frame.bluetooth.is_connected() then
    note = 'no phone'
    return
  end
  if send(op, n) then
    asked = op == 1 and 'o' or ('l' .. n)
    asked_at = frame.time.utc()
  end
end

local function state()
  return table.concat({ page, top, tostring(sel), tostring(total), lo, hi,
                        tostring(asked), note }, '|')
end

-- The phone keeps the page; its lines are asked for again from tick()
-- (glaz.lua drops the module when it is left: nothing here stays).
-- Nothing is asked here (as Reader, modules/reader.lua): an answer after
-- the module was left starts it in the background for remote().
function _M.start()
  lines, lo, hi, asked, note = {}, 0, 0, nil, ''
end

function _M.stop()
  lines, lo, hi, asked = {}, 0, 0, nil
end

function _M.tick()
  local now = frame.time.utc()
  if note == 'no phone' and frame.bluetooth.is_connected() then note = '' end
  if asked == 'o' then
    if now - asked_at > OPEN_WAIT then
      asked, note = nil, 'no answer'
    end
  elseif note == '' and not view_loaded() and
         (asked == nil or now - asked_at > RETRY) then
    ask(2, math.max(0, top - BEFORE))
  end
  return state()
end

function _M.remote(arg)
  local p, from, count, at, b, body =
    string.match(arg, '^p:(%d+):(%d+):(%d+):(%d+):?(%d*)\n?(.*)$')
  if not p then return nil end
  p, from, count = tonumber(p), tonumber(from), tonumber(count)
  local fresh = p ~= page
  if not fresh and asked ~= 'l' .. from then
    return nil            -- an answer to a request since replaced
  end
  asked, note = nil, ''
  page, total, back = p, count, b == '1'
  lines, lo, hi = {}, from, from
  for kind, link, text in string.gmatch(body, '(%a)(%d*)|([^\n]*)') do
    lines[hi] = { kind, tonumber(link), text }
    hi = hi + 1
  end
  if fresh then
    -- a page just opened, or the one the phone has open: the cursor on
    -- its first link on screen
    top, sel = tonumber(at), nil
    for i = top, math.min(last_row(), hi - 1) do
      if starts(i) then sel = i break end
    end
  elseif sel and not lines[sel] then
    sel = nil
  end
  return state()
end

-- The link to select among lines a..b, walking by step; nil for none
local function find(a, b, step)
  for i = a, b, step do
    if starts(i) then return i end
  end
  return nil
end

function _M.on_roll(dir)
  if asked == 'o' or not view_loaded() then return nil end
  local last = last_row()
  if dir > 0 then
    local i = find(sel and sel + 1 or top, last, 1)
    if i then sel = i return state() end
    if last >= total - 1 then return nil end      -- the end of the page
    top = math.max(0, math.min(top + ROWS - 1, total - ROWS))
    sel = find(last + 1, last_row(), 1)
  else
    local i = find(sel and sel - 1 or last, top, -1)
    if i then sel = i return state() end
    if top == 0 then return nil end
    local was = top
    top = math.max(0, top - (ROWS - 1))
    sel = find(was - 1, top, -1)
  end
  return state()
end

function _M.on_tap()
  if note ~= '' then
    note, asked = '', nil  -- tick() asks again
    return state()
  end
  if asked == 'o' then return nil end
  if sel and link_at(sel) then
    ask(1, link_at(sel))
    if asked == 'o' then sel = nil end
    return state()
  end
  return _M.on_roll(1)
end

-- Back to the page before, as its '< back' link does. False -- the app
-- leaves -- on the home page, while a page is opening, or with no phone.
function _M.on_back()
  if not back or asked == 'o' or not frame.bluetooth.is_connected() then
    return false
  end
  ask(1, BACK)
  -- after 'no answer' too: the note goes, 'opening..' is shown
  if asked == 'o' then sel, note = nil, '' end
  return state()
end

function _M.draw()
  local why = note ~= '' and (note == 'no phone' and 'no phone' or
                              note .. ', tap to retry')
              or asked == 'o' and 'opening..'
              or not view_loaded() and 'loading..'
  if why then
    frame.display.text(why, TEXT_X, TOP_Y + ROW_H * 2, { color = 'GREY' })
    return
  end
  -- the link under the cursor may run over several lines
  local link = sel and link_at(sel)
  local inside = false
  for r = 0, ROWS - 1 do
    local i = top + r
    local l = lines[i]
    if not l then break end
    inside = link ~= nil and l[2] == link and (i == sel or (inside and i > sel))
    local y = TOP_Y + ROW_H * r
    if i == sel then
      frame.display.text('>', LEFT_X, y, { color = 'YELLOW' })
    end
    if l[3] ~= '' then
      frame.display.text(l[3], TEXT_X, y,
                         { color = inside and 'YELLOW' or COLORS[l[1]] or
                                   'WHITE' })
    end
  end
end

return _M

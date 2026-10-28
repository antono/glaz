-- Menu module: the phone's notifications, newest first. ASCII only, see
-- docs/PROTOCOL.md, "Notifications".
--
--   tilt right / left -- list: the next / previous (older / newer) one
--                        open: page down / up
--   single tap        -- list: open the one under the cursor, all of it
--                        open: back to the list
--   double tap        -- open: back to the list; list: back to the menu
--
-- The list lives on the phone. The glasses hold a window of it, a few
-- lines, and ask for another as the cursor leaves it; an open one comes
-- as lines cut to the screen. NOTICES_GET asks, the phone answers
-- through remote(arg):
--
--   'l:<from>:<total>' then '\n<id>|<line>' per notification, from
--         number <from> (0 the newest), <total> kept on the phone
--   'f:<id>' then '\n<line>' per line: notification <id>, all of it
local _M = {}

_M.label = 'Notifications'
_M.mode = 'app'
_M.background = false
_M.rows = 5               -- every row under the top bar

local NOTICES_GET = 0x0E  -- '>BI4': 1 list from number, 2 one by id
local ROWS  = 5
local RETRY = 5           -- s without an answer before asking again

local items = {}          -- number -> { id, line }, lo <= number < hi
local lo, hi = 0, 0
local total = nil         -- nil until the phone says
local sel = 0             -- the number under the cursor
local top = 0             -- the number on the first row
local open = nil          -- the open one's lines, or nil in the list
local first = 1           -- the open one's line on the first row
local asked = nil         -- what was asked: 'l<from>' or 'f<id>'
local asked_at = 0
local note = ''

local function send(op, arg)
  local packet = string.pack('>BBI4', NOTICES_GET, op, arg)
  for _ = 1, 20 do
    if pcall(frame.bluetooth.send, packet) then return true end
    frame.sleep(0.005)
  end
  return false
end

local function ask(op, arg)
  if not frame.bluetooth.is_connected() then
    note = 'no phone'
    return
  end
  if send(op, arg) then
    note = ''
    asked = (op == 1 and 'l' or 'f') .. arg
    asked_at = frame.time.utc()
  end
end

local function list_screen()
  if total == nil then return note ~= '' and note or 'loading..' end
  if total == 0 then return 'no notifications' end
  local rows = {}
  for i = top, math.min(top + ROWS - 1, total - 1) do
    local it = items[i]
    rows[#rows + 1] = (i == sel and '> ' or '  ') .. (it and it[2] or '..')
  end
  return table.concat(rows, '\n')
end

local function open_screen()
  if open == true then return 'loading..' end
  local rows = {}
  for i = first, math.min(first + ROWS - 1, #open) do
    rows[#rows + 1] = open[i]
  end
  return table.concat(rows, '\n')
end

local function screen()
  if open then return open_screen() end
  return list_screen()
end

-- Nothing is asked here: tick() asks, and only a module on screen is
-- ticked (as Reader, apps/reader/reader.lua: an answer coming after it was
-- left starts it in the background for remote()).
function _M.start()
  items, lo, hi, total = {}, 0, 0, nil
  sel, top, open, asked, note = 0, 0, nil, nil, ''
end

function _M.stop()
  items, open = {}, nil
end

function _M.tick()
  local now = frame.time.utc()
  if not (asked and now - asked_at < RETRY) then
    asked = nil
    if open == true then
      ask(2, items[sel] and items[sel][1] or 0)
    elseif not open and (total == nil or
                         (total > 0 and (sel < lo or sel >= hi or
                                         top < lo or
                                         math.min(top + ROWS, total) > hi))) then
      ask(1, math.max(0, top - 2))
    end
  end
  return screen()
end

function _M.remote(arg)
  local kind, a, b, body = string.match(arg, '^(%a):(%d+):?(%d*)\n?(.*)$')
  if kind == 'l' and b ~= '' and asked == 'l' .. a then
    asked, note = nil, ''
    lo, total = tonumber(a), tonumber(b)
    items, hi = {}, lo
    for id, line in string.gmatch(body, '(%d+)|([^\n]*)') do
      items[hi] = { tonumber(id), line }
      hi = hi + 1
    end
    if sel >= total then sel = math.max(0, total - 1) end
    if top > sel then top = sel end
  elseif kind == 'f' and open == true and asked == 'f' .. a then
    asked = nil
    open = {}
    for line in string.gmatch(body, '[^\n]+') do open[#open + 1] = line end
    if #open == 0 then open[1] = '(empty)' end
    first = 1
  else
    return nil            -- an answer to a request since replaced
  end
  return screen()
end

function _M.on_roll(dir)
  if open then
    if open == true then return nil end
    first = math.max(1, math.min(first + dir * (ROWS - 1),
                                 #open - ROWS + 1))
    return open_screen()
  end
  if not total or total == 0 then return nil end
  sel = math.max(0, math.min(sel + dir, total - 1))
  if sel < top then top = sel end
  if sel > top + ROWS - 1 then top = sel - ROWS + 1 end
  return list_screen()
end

function _M.on_tap()
  if open then
    open, asked = nil, nil
    return list_screen()
  end
  if total == nil and note == 'no phone' then
    note = ''
    return screen()
  end
  if items[sel] then
    open, asked = true, nil
    return open_screen()
  end
  return nil
end

-- Back from an open one to the list; from the list, false: the app leaves.
function _M.on_back()
  if not open then return false end
  open, asked = nil, nil
  return list_screen()
end

return _M

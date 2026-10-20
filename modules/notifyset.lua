-- Menu module: how phone notifications pop up. ASCII only, see
-- docs/PROTOCOL.md, "Notifications".
--
--   tilt right / left -- the next / previous setting
--   single tap        -- change it: the next value, kept at once
--   double tap        -- back to the menu (handled by frame_app.lua)
--
-- Picked here, on the glasses, and kept in prefs.txt (_M.host.set_pref):
-- frame_app.lua reads them for every notification that comes. Off, a
-- notification does not cover the screen; the phone still keeps it, for
-- Apps > Notifications.
local _M = {}

_M.label = 'Notifications'
_M.mode = 'app'
_M.background = false

-- key, what it is called, its values; the first is the default
local ITEMS = {
  { 'popup',   'pop-up',  { 'on', 'off' } },
  { 'seconds', 'stays',   { '5', '3', '10', '20' } },
}

local sel = 1

local function value(item)
  return tostring(_M.host.pref(item[1], item[3][1]))
end

local function screen()
  local rows = {}
  for i, item in ipairs(ITEMS) do
    local v = value(item)
    if item[1] == 'seconds' then v = v .. ' s' end
    rows[#rows + 1] = (i == sel and '> ' or '  ') .. item[2] .. ': ' .. v
  end
  rows[#rows + 1] = 'tap = change'
  return table.concat(rows, '\n')
end

function _M.start()
  sel = 1
end

function _M.tick()
  return screen()
end

function _M.on_roll(dir)
  sel = (sel - 1 + dir) % #ITEMS + 1
  return screen()
end

function _M.on_tap()
  local item = ITEMS[sel]
  local values, v = item[3], value(item)
  local next_v = values[1]
  for i, x in ipairs(values) do
    if x == v then next_v = values[i % #values + 1] end
  end
  _M.host.set_pref(item[1], next_v)
  return screen()
end

return _M

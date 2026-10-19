-- Menu module: the last phone notifications. ASCII only, see
-- docs/PROTOCOL.md.
--
--   tilt right / left -- next / previous (older / newer)
--   double tap        -- back to the menu (handled by frame_app.lua)
--
-- New ones pop up over the screen by themselves (frame_app.lua, NOTIFY);
-- this is where to read one that went by too fast. The phone sends them only
-- while Glaz runs with the Notifications service on, and the glasses keep the
-- last NOTICE_KEEP, until they restart.
local _M = {}

_M.label = 'Notifications'
_M.mode = 'app'
_M.background = false

local LINE_MAX = 26   -- characters that fit a line, roughly (proportional font)

local sel = 1

-- UTF-8: LINE_MAX counts characters (Cyrillic is two bytes each)
local function clip(s)
  if (utf8.len(s) or #s) <= LINE_MAX then return s end
  local cut = utf8.len(s) and utf8.offset(s, LINE_MAX - 1) or LINE_MAX - 1
  return string.sub(s, 1, cut - 1) .. '..'
end

function _M.start()
  sel = 1
end

-- Three lines: position and app, the title, the start of the text.
function _M.tick()
  local list = _M.host.notices()
  if #list == 0 then return 'no notifications' end
  if sel > #list then sel = #list end
  local n = list[sel]
  return clip(sel .. '/' .. #list .. ' ' .. n[1]) .. '\n' ..
         clip(n[2] ~= '' and n[2] or ' ') .. '\n' ..
         clip(n[3] ~= '' and n[3] or ' ')
end

function _M.on_roll(dir)
  local count = #_M.host.notices()
  if count > 0 then
    sel = (sel - 1 + dir) % count + 1
  end
  return _M.tick()
end

return _M

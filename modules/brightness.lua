-- Menu module: pick the display brightness. ASCII only, see docs/PROTOCOL.md.
--
-- An 'app' module that takes input itself (on_roll / on_tap):
--   tilt right / left -- next / previous level, applied live as a preview
--   single tap        -- select: keep this level, back to the menu
--   double tap        -- back: cancel, the previous level is restored
-- Leaving any other way (timeout, menu, deep sleep) also cancels. Only an
-- explicit select changes the brightness for good.
--
-- The firmware has no getter for brightness, so the level is tracked here.
-- It lives in RAM: after a reboot the panel is back at the firmware default
-- and so is this (0).
local _M = {}

_M.label = 'Brightness'
_M.mode = 'app'
_M.background = false  -- sleeps: stopped as soon as it leaves the screen

local MIN, MAX = -2, 2

local level = 0      -- the confirmed level
local preview = 0    -- the level being shown while the picker is open
local picked = false

local function apply(l)
  frame.display.set_brightness(l)
end

-- '-2  -1  [0]  1  2' -- the brackets mark the level being previewed
local function scale()
  local parts = {}
  for l = MIN, MAX do
    if l == preview then
      parts[#parts + 1] = '[' .. l .. ']'
    else
      parts[#parts + 1] = tostring(l)
    end
  end
  return table.concat(parts, '  ')
end

function _M.start()
  preview = level
  picked = false
end

function _M.tick()
  return scale()
end

function _M.on_roll(dir)
  local l = preview + dir
  if l < MIN or l > MAX then return nil end  -- at the end of the scale
  preview = l
  apply(preview)
  return scale()
end

function _M.on_tap()
  level = preview
  picked = true
  return nil, true   -- done: the menu comes straight back
end

function _M.stop()
  if not picked then apply(level) end  -- cancelled: undo the preview
end

return _M

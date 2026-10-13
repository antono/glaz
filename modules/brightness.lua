-- Menu module: cycle display brightness. ASCII only, see PROTOCOL.md.
--
-- Demonstrates a module that holds state between selections and changes
-- something on the device rather than just reporting a value.
local _M = {}

_M.label = 'Brightness'

local level = 0  -- firmware accepts -2 .. 2

function _M.run()
  level = level + 1
  if level > 2 then level = -2 end
  frame.display.set_brightness(level)
  return 'level ' .. level
end

return _M

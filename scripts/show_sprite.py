#!/usr/bin/env python3
"""Show one sprite from sprites/ on the glasses, with no app running.

For judging the art on the real display: uploads the sprite and a small
drawing helper, then draws it centred and leaves it on screen.

    .venv/bin/python scripts/show_sprite.py eye 2
    .venv/bin/python scripts/show_sprite.py flipper 3

Arguments: sprite name (a file in sprites/, without .lua) and scale.
The drawing is the same as the splash in glaz.lua: 16-colour
frame.display.bitmap, one call per art row.
"""
import asyncio
import sys
from pathlib import Path

from frame_ble import FrameBle

SPRITES_DIR = Path(__file__).parent.parent / "sprites"

# Kept short and ASCII: it is uploaded as a file, then called from the REPL.
HELPER = """
return function(name, scale)
  -- require, not loadfile: on Frame loadfile()() comes back nil
  local sprite = require(name)
  local rows, w = {}, 0
  for i, line in ipairs(sprite.art) do
    local px = {}
    for c in string.gmatch(line, '.') do
      local v = sprite.colors[c] or 0
      for _ = 1, scale do px[#px + 1] = v end
    end
    if #px % 2 == 1 then px[#px + 1] = 0 end
    local bytes = {}
    for k = 1, #px, 2 do bytes[#bytes + 1] = string.char(px[k] * 16 + px[k + 1]) end
    rows[i] = string.rep(table.concat(bytes), scale)
    w = #px
  end
  local x = (640 - w) // 2
  local y = (340 - #rows * scale) // 2
  frame.display.power_save(false)
  for i, row in ipairs(rows) do
    frame.display.bitmap(x, y + (i - 1) * scale, w, 16, 0, row)
  end
  frame.display.show()
  collectgarbage('collect')
  return w .. 'x' .. (#rows * scale) .. ' at ' .. x .. ',' .. y ..
         ', mem ' .. math.floor(collectgarbage('count')) .. ' KB'
end
"""


async def main(name: str, scale: int) -> None:
    path = SPRITES_DIR / f"{name}.lua"
    frame = FrameBle()
    await frame.connect()
    print("Connected.")
    await frame.send_break_signal()   # stop whatever is running

    await frame.upload_file(str(path), path.name)
    await frame.upload_file_from_string(HELPER, "show_sprite.lua")
    result = await frame.send_lua(
        f"print(require('show_sprite')('{name}', {scale}))", await_print=True)
    print(f"Drawn: {result}")
    await frame.disconnect()


if __name__ == "__main__":
    name = sys.argv[1] if len(sys.argv) > 1 else "eye"
    scale = int(sys.argv[2]) if len(sys.argv) > 2 else 2
    asyncio.run(main(name, scale))

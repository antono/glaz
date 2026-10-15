-- The splash sprite: part of frame_app.lua, in a file of its own, loaded to
-- draw and dropped after. ASCII only.
--
-- Called with the sprite's name, its scale and the visible area; returns
-- false when the file is missing or holds no art.
local SPLASH_SCALE, SCREEN_W, VISIBLE_BOTTOM

-- The splash sprite, drawn with frame.display.bitmap one art row at a time.
-- 16-colour sprites take 4 bits a pixel, first pixel in the high nibble
-- (sprite_engine.sv), and palette index 0 is transparent.
--
-- Memory is what runs out on Frame, and the firmware reboots when it cannot
-- allocate. So the sprite file is never compiled: require would keep the art
-- cached for good (Frame's Lua has no package table to evict it from),
-- loadfile(name)() comes back nil on Frame, and reading the file into one
-- string to load() it died with 'not enough memory' next to the running
-- app (all measured, firmware v25.080.0838). Instead the file is scanned as
-- text, line by line, in the fixed format of sprites/*.lua:
--   colours:  "  w = 1," or "  ['.'] = 0,"
--   art rows: "  '....',"
-- Two passes: the first collects the colours and the size, the second packs
-- and draws each row as it is read. Only one row is ever held.
local function scan_sprite(name, on_row)
  local fh = frame.file.open(name .. '.lua', 'read')
  while true do
    local line = fh:read()
    if line == nil then break end
    local row = string.match(line, "^%s*'([^']*)',?%s*$")
    if row then
      on_row(row)
    else
      local key, value = string.match(line, "^%s*%['(.)'%]%s*=%s*(%d+)")
      if not key then
        key, value = string.match(line, "^%s*(%a)%s*=%s*(%d+),")
      end
      if key then on_row(nil, key, tonumber(value)) end
    end
  end
  fh:close()
end

-- One art row as a bitmap strip: widened SPLASH_SCALE times, then repeated
-- SPLASH_SCALE times to make it as tall.
local function pack_row(line, colors)
  local px = {}
  for c in string.gmatch(line, '.') do
    local v = colors[c] or 0
    for _ = 1, SPLASH_SCALE do px[#px + 1] = v end
  end
  if #px % 2 == 1 then px[#px + 1] = 0 end   -- whole bytes per row
  local bytes = {}
  for k = 1, #px, 2 do
    bytes[#bytes + 1] = string.char(px[k] * 16 + px[k + 1])
  end
  return string.rep(table.concat(bytes), SPLASH_SCALE), #px
end

-- Draw the sprite centred in the visible area. Returns false when the file
-- is missing or holds no art, so the caller can fall back to text.
return function(name, scale, screen_w, visible_bottom)
  SPLASH_SCALE, SCREEN_W, VISIBLE_BOTTOM = scale, screen_w, visible_bottom
  local colors, rows, width = {}, 0, 0
  scan_sprite(name, function(row, key, value)
    if row then
      rows = rows + 1
      width = #row * SPLASH_SCALE
    else
      colors[key] = value
    end
  end)
  if rows == 0 then return false end

  width = width + width % 2
  local x = (SCREEN_W - width) // 2
  local y = (VISIBLE_BOTTOM - rows * SPLASH_SCALE) // 2
  scan_sprite(name, function(row)
    if row then
      local strip, w = pack_row(row, colors)
      frame.display.bitmap(x, y, w, 16, 0, strip)
      y = y + SPLASH_SCALE
    end
  end)
  return true
end

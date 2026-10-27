-- main.lua on Halo: Halo's part of glaz_boot.lua, which it loads and
-- starts. ASCII only. The glasses' own parts are docs/DEVICES.md; Frame's
-- is glaz_boot.frame.lua, with the same names. Not yet tried on a Halo.
--
-- Halo's firmware (docs/HALO.md) has none of Frame's trouble with
-- require(): a 5 s watchdog fed by a thread of its own, and memory to
-- spare. It loads text only, though, and so does this: the phone uploads
-- source to Halo, never Frame's bytecode. File names are relative: the
-- firmware puts them under /lfs.
local open = frame.file.open
local CHUNK = 4096   -- bytes a read(n) takes

local D = {
  device = 'halo',           -- the suffix of this glasses' parts
}

-- The file compiled, not run: nil when there is no such file, nil and the
-- error when it does not compile.
function D.load(file)
  local ok, f = pcall(open, file, 'read')
  if not ok or not f then return nil end
  local parts = {}
  while true do
    local s = f:read(CHUNK)
    if s == nil or s == '' then break end
    parts[#parts + 1] = s
  end
  f:close()
  return load(table.concat(parts), '=' .. file, 't')
end

-- Says on the screen that the app is being started again.
function D.restarted()
  local disp = frame.display
  disp.clear()
  disp.set_font(0, 16, 1)
  disp.text('restarted', 56, 120, 0xFFFFFF)
end

local boot, err = D.load('glaz_boot.lua')
if not boot then error(err or 'cannot open file: glaz_boot.lua') end
return boot('glaz_boot', D)

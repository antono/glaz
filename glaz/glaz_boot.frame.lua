-- main.lua on Frame: Frame's part of glaz_boot.lua, which it loads and
-- starts. ASCII only. The glasses' own parts are docs/DEVICES.md.
--
-- Something has to know the glasses before anything is loaded, so here the
-- device part comes first: the phone uploads this file, and only this one
-- of glaz_boot's parts, as main.lua on Frame.
--
-- Files are loaded here, not with the firmware's require(). That one reads
-- a file a byte at a time into one buffer it grows by a byte each time
-- (lua_file_require in file.c), with no Lua running meanwhile: the
-- watchdog, fed only by Lua's hook, resets the glasses after 6 s without
-- it. Bytecode of 19 KB took seconds -- longer the more broken up the heap
-- -- and sometimes past 6 s: the glasses dropped the link on start, saying
-- nothing. A failed realloc there is not checked either. See docs/FRAME.md.
--
-- This one reads 512 bytes a read() and gives them to load() as they come:
-- no buffer the size of the file, and every piece is a Lua call, which
-- feeds the watchdog. read() stops at a line break and drops it; the size
-- listdir() gives tells a dropped one from the end of the file.
local open, listdir = frame.file.open, frame.file.listdir
local PIECE = 512   -- the most one read() gives (LUAL_BUFFERSIZE)
local sizes = nil   -- file name -> bytes; files do not change while it runs

local function size(file)
  if not sizes then
    sizes = {}
    for _, e in ipairs(listdir('/')) do sizes[e.name] = e.size end
  end
  return sizes[file]
end

local D = {
  device = 'frame',          -- the suffix of this glasses' parts
  -- the host's break: raised once (luaport.c), so a pcall that catches
  -- it must raise it again
  BREAK = 'break signal',
}

-- The file compiled, not run: nil when there is no such file, nil and the
-- error when it does not compile.
function D.load(file)
  local left = size(file)
  if not left then return nil end
  local f = open(file, 'read')
  local fn, err = load(function()
    if left <= 0 then return nil end
    local s = f:read()
    if s == nil then left = 0 return nil end
    left = left - #s
    if #s < PIECE and left > 0 then   -- a line break was dropped
      left = left - 1
      s = s .. '\n'
    end
    return s
  end, '=' .. file)
  f:close()
  return fn, err
end

-- Says on the screen that the app is being started again.
function D.restarted()
  frame.display.text('restarted', 50, 65)
  frame.display.show()
end

local boot, err = D.load('glaz_boot.lua')
if not boot then error(err or 'cannot open file: glaz_boot.lua') end
return boot('glaz_boot', D)

-- main.lua on the glasses: loads the app, glaz_app.lua (frame_app.lua in
-- the repository). ASCII only.
--
-- It replaces require(). The firmware's reads a file a byte at a time into
-- one buffer it grows by a byte each time (lua_file_require in file.c),
-- with no Lua running meanwhile: the watchdog, fed only by Lua's hook,
-- resets the glasses after 6 s without it. Bytecode of 19 KB took seconds
-- -- longer the more broken up the heap -- and sometimes past 6 s: the
-- glasses dropped the link on start, saying nothing. A failed realloc
-- there is not checked either. See docs/FRAME.md.
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

function require(name)
  local file = name .. '.lua'
  local left = size(file)
  if not left then error('cannot open file: ' .. file, 2) end
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
  if not fn then error("exiting module '" .. name .. "': " .. err, 2) end
  return fn(name)
end

require('glaz_app')

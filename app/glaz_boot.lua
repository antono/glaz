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

-- Restart. An error the app does not catch would end it, the link still
-- up: no app to answer taps, the remote or the phone, and the firmware's
-- "Frame is paired" on screen. So the app is started again. What it left
-- behind goes first, for the old app to be freed before the new one
-- loads: the globals it set and its tap and Bluetooth callbacks. The
-- error is printed (the phone's Log has it) and kept in CRASH_FILE. More
-- than RESTARTS in WITHIN seconds, and it is left stopped: an app that
-- fails on start would only fail again. The host's break signal ends the
-- app without an error, and an error with it is passed on: no restart.
local CRASH_FILE = 'crash.txt'
local RESTARTS, WITHIN = 3, 60
local crashes = {}   -- utc() of each restart within WITHIN

local before = {}
for k in pairs(_G) do before[k] = true end

while true do
  local ok, err = pcall(require, 'glaz_app')
  if ok then break end
  err = tostring(err)
  if string.find(err, 'break signal', 1, true) then error(err, 0) end

  for k in pairs(_G) do
    if not before[k] then _G[k] = nil end
  end
  pcall(frame.imu.tap_callback, nil)
  pcall(frame.bluetooth.receive_callback, nil)
  collectgarbage('collect')

  local now = frame.time.utc()
  pcall(function()
    local f = open(CRASH_FILE, 'write')
    f:write(string.format('%d %s', math.floor(now), err))
    f:close()
  end)

  for i = #crashes, 1, -1 do
    if now - crashes[i] > WITHIN then table.remove(crashes, i) end
  end
  if #crashes >= RESTARTS then error(err, 0) end
  crashes[#crashes + 1] = now
  print('glaz app error, restarting: ' .. err)

  frame.display.text('restarted', 50, 65)
  frame.display.show()
  frame.sleep(1)
end

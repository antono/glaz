-- glaz_boot: loads the app, glaz_app.lua (glaz.lua in the
-- repository), and starts it again after an error. ASCII only.
--
-- Started by main.lua, which is this file's part for the glasses at hand
-- (glaz_boot.frame.lua, glaz_boot.halo.lua) and hands it in as D: how a
-- file is loaded there, its file modes, its suffix. See docs/DEVICES.md.
local _, D = ...

-- require(), for the app and its modules. A name's part for these glasses
-- (name.frame.lua on Frame) is loaded first and handed to name.lua, which
-- takes it as `local D = select(2, ...)`. A name with a part and no
-- name.lua is one only these glasses have: the part is the module. The
-- phone uploads only this glasses' parts, so nothing here asks which
-- glasses these are.
local function run(file, name, part)
  local fn, err = D.load(file)
  if not fn then
    if err then error("exiting module '" .. name .. "': " .. err, 3) end
    return false
  end
  return true, fn(name, part)
end

function require(name)
  local _, part = run(name .. '.' .. D.device .. '.lua', name)
  local found, mod = run(name .. '.lua', name, part)
  if found then return mod end
  if part ~= nil then return part end
  error('cannot open file: ' .. name .. '.lua', 2)
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

-- Whether an error is the host's break, as these glasses raise it
-- (D.BREAK): for every pcall in the app that must let it through.
function glaz_break(e)
  return string.find(tostring(e), D.BREAK, 1, true) ~= nil
end

local before = {}
for k in pairs(_G) do before[k] = true end

while true do
  local ok, err = pcall(require, 'glaz_app')
  if ok then break end
  err = tostring(err)
  if glaz_break(err) then error(err, 0) end

  for k in pairs(_G) do
    if not before[k] then _G[k] = nil end
  end
  pcall(frame.imu.tap_callback, nil)
  pcall(frame.bluetooth.receive_callback, nil)
  collectgarbage('collect')

  local now = frame.time.utc()
  pcall(function()
    local f = frame.file.open(CRASH_FILE, 'write')
    f:write(string.format('%d %s', math.floor(now), err))
    f:close()
  end)

  for i = #crashes, 1, -1 do
    if now - crashes[i] > WITHIN then table.remove(crashes, i) end
  end
  if #crashes >= RESTARTS then error(err, 0) end
  crashes[#crashes + 1] = now
  print('glaz app error, restarting: ' .. err)

  pcall(D.restarted)
  frame.sleep(1)
end

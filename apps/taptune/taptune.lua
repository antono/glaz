-- Menu module: tune hardware tap detection live. ASCII only.
--
-- Needs the custom firmware branch glaz/main, which adds
-- frame.imu.tap_config{} -- see docs/FIRMWARE.md. Degrades to a message on
-- stock firmware rather than failing.
--
-- What the knobs do (MC6470 datasheet 9.6-9.8):
--   threshold 0..255  how hard a knock has to be
--   quiet     0..15   enforced silence AFTER a tap; this is the anti-bounce
--                     control, and stock firmware leaves it at 0
--   duration  0..15   minimum length of the impulse
--   axes      08 or 3F  which way a knock must push the chip (hex): -Y
--                     only (stock), or all six directions
--
-- Tilt moves the cursor: threshold, quiet, duration, axes, test. A tap on a
-- setting steps it to its next value and reprograms the accelerometer; on
-- test a tap changes nothing, so knock there and watch the hit count --
-- one knock should add one, not five. The count restarts with every change.
-- Hits come from the app (on_hit), bounces included: a module must not take
-- frame.imu.tap_callback over, or the app loses its taps for good.
--
-- Which side was tapped: the last row shows the last knock's status byte
-- (its first hit, not the rebound), raw and decoded. Set axes to 3F,
-- knock the left arm, the right arm, the front, and note which bits light
-- up. Firmware that passes no byte says so.
-- Axes go back to what they were when the module closes; the other knobs
-- stay, as before.
local _M = {}

_M.label = 'Tap tune'
_M.mode = 'app'
_M.rows = 4               -- one more than the app's TEXT_ROWS

local FIELDS = {
  { name = 'threshold', short = 'thr',
    values = { 3, 5, 7, 10, 15, 20, 30, 50 } },
  { name = 'quiet',     short = 'q',
    values = { 0, 1, 2, 3, 4, 6, 8, 12, 15 } },
  { name = 'duration',  short = 'dur',
    values = { 0, 1, 2, 3, 4, 6, 8, 12, 15 } },
  { name = 'axes',      short = 'ax',  fmt = '%02X',
    values = { 0x08, 0x3F } },
}
local TEST = #FIELDS + 1

local supported = false
local sel = TEST
local hits = 0
local cfg = {}
local axes0 = nil   -- axes when the module started, put back on stop
local flags = nil   -- status byte of the last knock, nil before one
local hit_seen = false

-- Status register 0x03, bits 0..5, in the order of INTEN 0x06 and TAPEN
-- (MC6470 datasheet, table 17). Which bits each knock sets is still to be
-- measured on the glasses; that is what this row is for.
local DIRS = { 'X+', 'X-', 'Y+', 'Y-', 'Z+', 'Z-' }

local function show(field, v)
  if v == nil then return '?' end
  return field.fmt and string.format(field.fmt, v) or tostring(v)
end

-- 'last 0x08 Y-'; bits 6 and 7 are in the raw value only.
local function flags_row()
  if not hit_seen then return 'last -' end
  if flags == nil then return 'firmware sends no flags' end
  local set = {}
  for bit = 0, 5 do
    if flags & (1 << bit) ~= 0 then set[#set + 1] = DIRS[bit + 1] end
  end
  return string.format('last 0x%02X %s', flags, table.concat(set, ' '))
end

local function next_value(field)
  local current = cfg[field.name]
  for i, v in ipairs(field.values) do
    if v == current then
      return field.values[(i % #field.values) + 1]
    end
  end
  return field.values[1]
end

function _M.start()
  supported = (type(frame.imu.tap_config) == 'function')
  if supported then cfg = frame.imu.tap_config() end
  axes0 = cfg.axes
  hits = 0
  flags, hit_seen = nil, false
end

function _M.stop()
  if supported and axes0 and cfg.axes ~= axes0 then
    cfg.axes = axes0
    frame.imu.tap_config{ axes = axes0 }
  end
  hits = 0
end

-- Four rows from the top, each under the screen's 29 characters (26 at most,
-- 'thr 50 q 12 dur 12 [ax 3F]'): every setting with the cursor's in
-- brackets, what a tap does here, the hit count, the last knock's direction.
local function screen()
  if not supported then
    return 'needs the glaz\nfirmware'
  end

  local parts = {}
  for i, field in ipairs(FIELDS) do
    local s = field.short .. ' ' .. show(field, cfg[field.name])
    parts[i] = (i == sel) and ('[' .. s .. ']') or s
  end

  local hint
  if sel == TEST then
    hint = '[test] knock to count'
  else
    local field = FIELDS[sel]
    hint = string.format('tap: %s %s > %s', field.name,
                         show(field, cfg[field.name]),
                         show(field, next_value(field)))
  end
  return table.concat(parts, ' ') .. '\n' .. hint .. '\nhits ' .. hits
         .. '\n' .. flags_row()
end

function _M.on_roll(direction)
  sel = (sel - 1 + direction) % TEST + 1
  return screen()
end

-- A tap on a setting steps it and reprograms the accelerometer; the count
-- restarts so the next knocks measure the new settings. On test it only
-- counts, through on_hit.
function _M.on_tap()
  if supported and sel ~= TEST then
    local field = FIELDS[sel]
    cfg[field.name] = next_value(field)
    frame.imu.tap_config(cfg)
    hits = 0
    flags, hit_seen = nil, false
  end
  return screen()
end

-- f is the status byte of the first hit of the last knock (nil on firmware
-- that passes none); its bounces, the rebound, are not kept.
function _M.on_hit(n, f)
  hits = hits + n
  flags, hit_seen = f, true
  return screen()
end

function _M.tick()
  return screen()
end

return _M

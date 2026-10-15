-- Menu module: tune hardware tap detection live. ASCII only.
--
-- Needs the custom firmware branch okulo/tap-tuning, which adds
-- frame.imu.tap_config{} -- see docs/FIRMWARE.md. Degrades to a message on
-- stock firmware rather than failing.
--
-- What the knobs do (MC6470 datasheet 9.6-9.8):
--   threshold 0..255  how hard a knock has to be
--   quiet     0..15   enforced silence AFTER a tap; this is the anti-bounce
--                     control, and stock firmware leaves it at 0
--   duration  0..15   minimum length of the impulse
--
-- Tilt moves the cursor: threshold, quiet, duration, test. A tap on a
-- setting steps it to its next value and reprograms the accelerometer; on
-- test a tap changes nothing, so knock there and watch the hit count --
-- one knock should add one, not five. The count restarts with every change.
-- Hits come from the app (on_hit), bounces included: a module must not take
-- frame.imu.tap_callback over, or the app loses its taps for good.
local _M = {}

_M.label = 'Tap tune'
_M.mode = 'app'

local FIELDS = {
  { name = 'threshold', short = 'thr',
    values = { 3, 5, 7, 10, 15, 20, 30, 50 } },
  { name = 'quiet',     short = 'quiet',
    values = { 0, 1, 2, 3, 4, 6, 8, 12, 15 } },
  { name = 'duration',  short = 'dur',
    values = { 0, 1, 2, 3, 4, 6, 8, 12, 15 } },
}
local TEST = #FIELDS + 1

local supported = false
local sel = TEST
local hits = 0
local cfg = {}

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
  hits = 0
end

function _M.stop()
  hits = 0
end

-- Three rows, each well under the screen's width: every setting with the
-- cursor's in brackets, what a tap does here, the hit count.
local function screen()
  if not supported then
    return 'needs the okulo/tap-tuning\nfirmware'
  end

  local parts = {}
  for i, field in ipairs(FIELDS) do
    local s = field.short .. ' ' .. cfg[field.name]
    parts[i] = (i == sel) and ('[' .. s .. ']') or s
  end

  local hint
  if sel == TEST then
    hint = '[test] knock to count'
  else
    local field = FIELDS[sel]
    hint = string.format('tap: %s %d > %d', field.name, cfg[field.name],
                         next_value(field))
  end
  return table.concat(parts, ' ') .. '\n' .. hint .. '\nhits ' .. hits
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
  end
  return screen()
end

function _M.on_hit(n)
  hits = hits + n
  return screen()
end

function _M.tick()
  return screen()
end

return _M

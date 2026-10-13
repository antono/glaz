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
-- Tilt moves between fields, tap cycles the selected field's value. The hit
-- counter shows taps seen since the last change, which is the whole point:
-- knock once and watch whether the count goes up by one or by five.
local _M = {}

_M.label = 'Tap tune'
_M.mode = 'app'

local FIELDS = {
  { name = 'threshold', values = { 3, 5, 7, 10, 15, 20, 30, 50 } },
  { name = 'quiet',     values = { 0, 1, 2, 3, 4, 6, 8, 12, 15 } },
  { name = 'duration',  values = { 0, 1, 2, 3, 4, 6, 8, 12, 15 } },
}

local supported = false
local sel = 1
local hits = 0
local cfg = {}

local function cycle(field)
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
  if not supported then return end

  cfg = frame.imu.tap_config()
  hits = 0

  -- Count every tap the hardware reports. The app framework also sees these
  -- taps, so a double tap still leaves the module; that is deliberate --
  -- there has to be a way out while the settings are bad.
  frame.imu.tap_callback(function() hits = hits + 1 end)
end

function _M.stop()
  hits = 0
end

local function screen()
  if not supported then
    return 'needs okulo/tap-tuning firmware'
  end

  local out = {}
  for i, field in ipairs(FIELDS) do
    out[#out + 1] = string.format('%s%s %d',
                                  (i == sel) and '>' or ' ',
                                  field.name, cfg[field.name])
  end
  out[#out + 1] = string.format('hits %d', hits)
  return table.concat(out, '  ')
end

-- Tilt moves between fields. Returns the text to show, per the module_input
-- contract in frame_app.lua.
function _M.on_roll(direction)
  if not supported then return screen() end
  sel = sel + direction
  if sel < 1 then sel = #FIELDS end
  if sel > #FIELDS then sel = 1 end
  return screen()
end

-- A single tap cycles the selected field and reprograms the accelerometer.
-- The hit counter resets so the next knocks measure the new settings.
function _M.on_tap()
  if not supported then return screen() end
  local field = FIELDS[sel]
  cfg[field.name] = cycle(field)
  frame.imu.tap_config(cfg)
  hits = 0
  return screen()
end

-- Also refreshed on a timer, so the hit counter moves without any input.
function _M.tick()
  return screen()
end

return _M

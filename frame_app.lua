-- In-glasses menu and app launcher. Frame-side application.
--
-- ASCII ONLY. frame_ble's uploader chunks by characters but checks the MTU
-- limit in bytes, so any non-ASCII byte here breaks upload_file() with
-- "payload length is too large". See docs/PROTOCOL.md.
--
-- Menu state lives here, not on the host. Each item is a module in modules/
-- that declares a label and either run() or tick(). Adding an item means
-- adding one file and listing it in MENU below. The host still receives
-- every event, so it can react too, but nothing here needs a host.
--
-- The menu is a tree: submenus hold modules or further submenus. The top row
-- of the screen is a breadcrumb -- the path from the root to what is shown.
--
-- States:
--   IDLE    -- blank display, nothing on screen
--   MENU    -- one level of the tree; tilting the head scrolls it
--   RUNNING -- a module owns the display
--
-- Modules either sleep or run in the background (_M.background). A sleeping
-- module is stopped as soon as it leaves the screen; a background one keeps
-- being ticked off screen, one at a time, and a play icon in the top bar says
-- so. Either way a single tap on the blank screen brings back the last module
-- that was launched.
--
-- Roll (tilt toward a shoulder, then back): right scrolls down, left scrolls
-- up. The return to neutral is part of the gesture -- see the latch below.
-- Inside a running module tilt only moves that module's own cursor (if it
-- has one, see on_roll); it never leaves the module. Leaving is a double tap.
--
-- Taps (Frame has no buttons; count is the only way to tell intents apart):
--   single -- select: run the item under the cursor, or enter a submenu;
--             on the blank screen, return to the last module
--   double -- back, one level up: module -> its menu level -> parent menu
--             -> ... -> root -> blank
--   triple -- toggle the menu, from any state. Hiding it returns to the root.
-- One meaning per count, everywhere. A single tap elsewhere is harmless: it
-- flashes the banner when idle and nothing was launched yet, and keeps an
-- 'app' module alive.
--
-- A multi-tap can only be classified once TAP_WINDOW has expired, so single
-- and double taps are deliberately delayed by that much. Triple taps fire
-- immediately on the third tap.
--
-- Measured on device, firmware v25.080.0838:
--   * resting angles are not 0 (pitch sits near -35) => the baseline is
--     sampled at runtime, every time the menu opens
--   * pitch/roll noise is about +-4 degrees => hence DEADZONE and threshold
--   * roll swings about +-30 degrees in use, far more than a nod
--   * heading is always 0.0, the compass is dead => unusable for navigation
--   * frame.display.clear() does NOT exist; the buffer resets itself after
--     show(), so each frame redraws everything
--   * x=1 is outside the visible field of view -- the first character gets
--     clipped. Everything is drawn at LEFT_X instead.

local data = require('data.min')

-- The menu tree, in display order. A string names a module in modules/; a
-- table is a submenu -- its label, then its entries, which may themselves be
-- submenus. Each module must return a table with a .label and either .run()
-- (mode 'info') or .tick() (mode 'app'), and may set .background.
local MENU = {
  { label = 'Apps',     'photo', 'timeseries', 'stopwatch' },
  { label = 'Sensors',  'battery', 'tilt', 'taptune' },
  { label = 'Settings', 'bluetooth', 'brightness' },
  { label = 'Info',     'uptime', 'firmware', 'about' },
}
local ROOT_LABEL = 'Menu'   -- first crumb of the breadcrumb
local CRUMB_SEP  = ' > '

-- Host -> Frame
local MENU_SET  = 0x20    -- override items, one per line; see docs/PROTOCOL.md
local MENU_HIDE = 0x21    -- no payload; hide the menu
local MENU_SHOW = 0x22    -- no payload; show the menu
local CLOCK_SET = 0x23    -- '>I4i2': unix time, UTC offset in minutes

-- Frame -> Host
local MENU_SELECT = 0x11  -- [0x11, index] item index was selected (1-based)
local MENU_CURSOR = 0x12  -- [0x12, index] cursor moved to index
local MENU_OPEN   = 0x13  -- [0x13, index] menu became visible
local MENU_CLOSE  = 0x14  -- [0x14, index] menu was hidden
local APP_START   = 0x15  -- [0x15, index] module index started
local APP_STOP    = 0x16  -- [0x16, index] module index stopped
local MENU_LEVEL  = 0x17  -- [0x17, depth] entered a submenu / went back up
local APP_BACKGROUND = 0x18  -- [0x18, index] module index left the screen
                             -- but keeps running

-- Navigation tuning. Scrolling is driven by roll -- tilting the head toward
-- a shoulder -- not by pitch. Roll has the wider usable swing of the two
-- (about +-30 degrees measured, against a few for a comfortable nod), and it
-- leaves nodding free. Yaw is not an option at all: heading is always 0.0
-- because the magnetometer's Z axis is railed. See docs/PROTOCOL.md.
-- The gesture is tilt-and-return: tilting past ROLL_THRESHOLD only *arms* a
-- step, and the step fires when the head comes back inside DEADZONE. Holding
-- a tilt therefore does nothing, and a step always ends with the head level.
-- Measured on the wearer, not guessed: resting roll about -6 with +-4.4 of
-- noise; a deliberate tilt reaches 25 to the left and 16 to the right. The
-- threshold is set at twice the noise floor, which still leaves the weaker
-- side almost a factor of two of headroom.
local ROLL_THRESHOLD  = 9     -- degrees from baseline to arm a step
local DEADZONE        = 5     -- coming back inside this fires the armed step
-- Tilting right drives roll negative, so right-is-down needs the sign flipped.
local ROLL_SIGN       = -1

-- Taps and tilts are read by the SAME accelerometer, so a tap on the arm
-- shakes the glasses and shows up as roll. Measured: a tap throws roll by up
-- to 56 degrees -- six times the threshold, and twice the largest deliberate
-- tilt. Amplitude therefore cannot separate the two; duration can. A tap is
-- an impulse lasting a sample or two, a real tilt is held.
local ROLL_HOLD_SAMPLES = 3    -- consecutive samples past the threshold to arm
local ROLL_MUTE         = 0.4  -- seconds of roll ignored after a tap
local IMU_PERIOD      = 0.05  -- seconds between orientation samples

-- Loop pacing. Frame has no power switch and does not sleep on its own while
-- an app loop is running -- it simply drains, rated about 4 hours. A loop
-- spinning at frame.sleep(0.001) wakes the CPU a thousand times a second
-- even with a blank display, so the idle state is paced far slower.
-- These are decoupled from IMU_PERIOD on purpose: counting loop iterations
-- instead would make navigation slow down whenever the loop is slowed down.
local IDLE_PERIOD     = 0.15  -- blank screen, only waiting for a tap
local ACTIVE_PERIOD   = 0.01  -- menu up or a module running
local APP_TICK_PERIOD = 0.25  -- refresh rate of an 'app' module
local BG_TICK_PERIOD  = 1     -- tick rate of a module in the background
local MENU_TIMEOUT    = 10    -- seconds of inactivity before auto-hiding
local INFO_TIMEOUT    = 5     -- seconds an 'info' module stays on screen
-- An 'app' module keeps the display lit and the loop at ACTIVE_PERIOD for as
-- long as it runs, so one left open drains the battery. A single tap counts
-- as activity and restarts the clock. See docs/BATTERY.md.
local APP_TIMEOUT     = 60    -- seconds of inactivity before closing an 'app'
local SLEEP_AFTER     = 30    -- idle seconds before parking in frame.sleep()
                              -- (never while a module runs in the background)

-- Startup banner. IDLE is a blank screen, which is indistinguishable from
-- "the app is not running" -- this is the sign of life. It is the sprite in
-- sprites/flipper.lua, drawn SPLASH_SCALE times its size; the '<glaz>' text is
-- only a fallback for when the sprite cannot be loaded.
local SPLASH_SPRITE   = 'flipper'
local SPLASH_SCALE    = 3
local SPLASH_TEXT     = 'glaz'
local SPLASH_COLOR    = 'GREEN'
local SPLASH_BRACKETS = 'RED'
local SPLASH_SECONDS  = 3   -- counted from when drawing ends: drawing the
                            -- 128x64 sprite at 3x takes about 1.5 s itself

-- Tap tuning
local TAP_BOUNCE = 0.15  -- taps closer than this are sensor bounce, not input
local TAP_WINDOW = 0.75  -- max gap between taps belonging to one multi-tap
local TAP_TOGGLE = 3     -- taps required to toggle the menu

-- Layout. Display is 640x400. x=1 is clipped, so nothing starts left of
-- LEFT_X. A row is 55px. The breadcrumb sits above the list, close to the
-- top edge (y=1 is visible), so five rows still fit: the last one starts at
-- 285 and ends near 326, inside the measured VISIBLE_BOTTOM of 340.
local ROW_H        = 55
local CRUMB_Y      = 10
local TOP_Y        = 65
local LEFT_X       = 60
local VISIBLE_ROWS = 5
local TEXT_ROWS    = 3     -- lines of module output: rows 3..5

-- The top bar, one row at CRUMB_Y, left to right: the breadcrumb, the
-- background icon, the clock and the battery level. The right-hand pieces have fixed x positions, so the
-- breadcrumb is cut short in front of whichever comes first. Positions are
-- estimates for a proportional font: '100%' must end before x=640, or the
-- firmware drops the glyphs that do not fit.
local TIME_X       = 430   -- 'HH:MM', or '--:--' until the host sets it
local BATTERY_X    = 545   -- '84%'
local BATTERY_LOW  = 15    -- percent; drawn in red at or below this
-- The battery reading is a voltage estimate and swings by 10-15 points
-- between samples while the radio transmits (docs/BATTERY.md), so the top bar
-- shows the mean of every sample from the last BATTERY_WINDOW instead.
local BATTERY_SAMPLE = 10  -- seconds between battery samples, in any state
local BATTERY_WINDOW = 300 -- seconds of samples averaged for the top bar
local STATUS_PERIOD  = 1   -- seconds between checks for a new minute

-- Background icon: a play triangle left of the clock, shown while a module
-- runs in the background. 16x16, 1 bit per pixel, rows
-- of two bytes, first pixel in the high bit (sprite_engine.sv). A set bit
-- draws palette index 1 + ICON_PALETTE, a clear bit is transparent; 9 makes
-- it index 10, GREEN.
local ICON_X       = 400
local ICON_Y       = CRUMB_Y + 10
local ICON_W       = 16
local ICON_PALETTE = 9
local ICON_PLAY    = '\x00\x00\x18\x00\x1E\x00\x1F\x00\x1F\xC0\x1F\xF0' ..
                     '\x1F\xF8\x1F\xFE\x1F\xFE\x1F\xF8\x1F\xF0\x1F\xC0' ..
                     '\x1F\x00\x1E\x00\x18\x00\x00\x00'

-- The framebuffer is 640x400 but the wearer does not see all of it. Measured
-- by probing: y=340 is visible, y=370 is not, so the bottom is clipped.
-- Centring must use these numbers, not 640x400, or it lands low.
local SCREEN_W       = 640
local VISIBLE_BOTTOM = 340

-- The built-in font is NOT monospaced, so positioning each piece of text by
-- a single character width never lines up: 'okulo' is narrower than five
-- average glyphs. Measured width of '<' specifically is 22px; the firmware
-- handles every other advance itself, as long as a whole string is drawn in
-- one call. CHAR_W below is only a rough average, used for centring.
local BRACKET_W = 22
local CHAR_W    = 20
local CHAR_H    = 24

-- Parsers. MENU_SET carries plain text; HIDE/SHOW carry nothing and the mere
-- presence of the item is the signal.
data.parsers[MENU_SET]  = function(block) return block end
data.parsers[MENU_HIDE] = function(block) return block end
data.parsers[MENU_SHOW] = function(block) return block end
data.parsers[CLOCK_SET] = function(block) return block end

-- Load the modules and build the tree. A broken module must not take the
-- whole menu down, so each require is guarded and failures become visible
-- menu entries.
--
-- A level is { label, items, sel, top }; sel and top live on the level, so
-- going back up lands on the submenu just left. An item is either a level
-- (it has .items) or a leaf { label, id }. id indexes mods and numbers the
-- modules in tree order; it is what APP_START / APP_STOP report.
--
-- paths[id] is the chain of levels leading to a module. Bringing a module
-- back from the blank screen restores it, so the breadcrumb is right and a
-- double tap lands in the module's own submenu.
local mods  = {}   -- id -> module table; false if it failed to load
local paths = {}   -- id -> { root, ..., the level holding the module }

local function new_level(label)
  return { label = label, items = {}, sel = 1, top = 1 }
end

-- pcall(require, ...) that lets the host's break signal through. Loading
-- guards each module so a broken one cannot take the menu down, but a guard
-- that catches everything also catches 'break signal': the host's break
-- landed during loading, was taken for a load error, and the app kept
-- running. Loading takes seconds, so that happened on most connects.
local function try_require(name)
  local ok, mod = pcall(require, name)
  if not ok and string.find(tostring(mod), 'break signal', 1, true) then
    error(mod, 0)
  end
  return ok, mod
end

local function build(spec, label, parent)
  local level = new_level(label or spec.label)
  local path = { table.unpack(parent or {}) }
  path[#path + 1] = level
  for _, entry in ipairs(spec) do
    local item
    if type(entry) == 'table' then
      item = build(entry, nil, path)
    else
      local id = #mods + 1
      paths[id] = path
      local ok, mod = try_require(entry)
      if ok and type(mod) == 'table' and mod.label then
        mods[id] = mod
        item = { label = mod.label, id = id }
      else
        mods[id] = false
        item = { label = entry .. ' (load failed)', id = id }
      end
    end
    level.items[#level.items + 1] = item
  end
  return level
end

local root  = build(MENU, ROOT_LABEL)
local stack = { root }  -- path from the root to the level being shown

local function level() return stack[#stack] end

local base     = 0      -- baseline roll, sampled when the menu opens
local armed     = 0     -- 0 = level, 1/-1 = tilt seen, waiting for the return
local roll_dir  = 0     -- direction currently being held past the threshold
local roll_hold = 0     -- how many consecutive samples it has been held
local visible  = false  -- menu on screen
local running  = nil    -- id of the module on screen, or nil
local bg       = nil    -- id of the module running in the background, or nil
local last     = nil    -- id of the last module launched; a tap brings it back
local run_name = ''     -- its label, the last crumb while it runs
local run_text = ''     -- what the running module last produced
local run_at   = 0      -- utc() when the running module started
local last_act = 0      -- utc() of the last input, drives the menu timeout

-- Tap state, filled by the callback and drained by the main loop
local tap_n     = 0   -- taps in the current multi-tap window (set in callback)
local tap_at    = 0   -- utc() of the last accepted tap (set in callback)
local tap_shake = 0   -- utc() of the last hit of any kind, bounces included
local tap_mute  = 0   -- swallow taps until this time, after a toggle

local function split_lines(s)
  local out = {}
  for line in string.gmatch(s, '[^\r\n]+') do
    out[#out + 1] = line
  end
  return out
end

local function send(code, value)
  -- if the host is gone, fail silently: this must work without one
  pcall(frame.bluetooth.send, string.char(code, value))
end

-- There is no frame.display.clear() in this firmware, so "blank" means
-- drawing a single space and flipping the buffer.
local function blank()
  frame.display.text(' ', LEFT_X, TOP_Y)
  frame.display.show()
end

-- The micro-OLED keeps drawing power even with a blank frame on it, and the
-- firmware only powers it down by itself around frame.sleep(), which this app
-- does not use. So the panel is switched off explicitly whenever the app has
-- nothing to show. Draw commands remain valid while it is off and appear as
-- normal once it is back on, so nothing else has to know about this.
local display_on = true

local function set_display(on)
  if on == display_on then return end
  display_on = on
  pcall(frame.display.power_save, not on)
end

-- Wall clock. frame.time.utc() is NOT set to real time here: it counts from
-- boot, and every timer in this app relies on that. Setting it would make
-- each of them jump by fifty years. The host sends the real time instead
-- (CLOCK_SET) and only the offset is kept, so utc() stays monotonic.
local clock_offset = nil   -- seconds to add to utc() for local time

local function clock_text()
  if not clock_offset then return '--:--' end
  local t = math.floor(frame.time.utc() + clock_offset)
  return string.format('%02d:%02d', (t // 3600) % 24, (t // 60) % 60)
end

-- Battery samples, oldest first: { utc(), level }. Taken from the main loop
-- whatever the state, so the average is ready when the top bar is drawn.
-- Samples older than the window are dropped by age, not count: after deep
-- sleep, the samples from before it are simply gone.
local battery_samples = {}
local battery_next = 0   -- utc() of the next sample

local function sample_battery(now)
  if now < battery_next then return end
  battery_next = now + BATTERY_SAMPLE
  local ok, level = pcall(frame.battery_level)
  if ok then battery_samples[#battery_samples + 1] = { now, level } end
  while #battery_samples > 0 and now - battery_samples[1][1] > BATTERY_WINDOW do
    table.remove(battery_samples, 1)
  end
end

-- Mean of the last BATTERY_WINDOW of samples, rounded; nil before the first.
local function battery_level()
  sample_battery(frame.time.utc())
  if #battery_samples == 0 then return nil end
  local sum = 0
  for _, s in ipairs(battery_samples) do sum = sum + s[2] end
  return math.floor(sum / #battery_samples + 0.5)
end

-- What the right end of the top bar shows; a change means a redraw.
local function status_text()
  return clock_text() .. ' ' .. tostring(battery_level())
end

-- 'Menu > Settings > Brightness'. When it is too wide for right_x, the
-- leading crumbs give way to '..': the end of the path is what matters. The
-- width is only estimated -- the font is proportional, see CHAR_W.
local function draw_crumbs(parts, right_x)
  local fit = (right_x - LEFT_X) // CHAR_W
  local text = table.concat(parts, CRUMB_SEP)
  local first = 1
  while #text > fit and first < #parts do
    first = first + 1
    text = '..' .. CRUMB_SEP .. table.concat(parts, CRUMB_SEP, first)
  end
  frame.display.text(text, LEFT_X, CRUMB_Y, { color = 'SKYBLUE' })
end

-- The whole top bar. last: an extra crumb (the running module's name).
local function draw_top_bar(last)
  local parts = {}
  for i, l in ipairs(stack) do parts[i] = l.label end
  if last then parts[#parts + 1] = last end

  -- the icon, guarded: a bad bitmap call must not take the screen down
  if bg then
    pcall(frame.display.bitmap, ICON_X, ICON_Y, ICON_W, 2, ICON_PALETTE,
          ICON_PLAY)
  end
  draw_crumbs(parts, (bg and ICON_X or TIME_X) - CHAR_W // 2)

  frame.display.text(clock_text(), TIME_X, CRUMB_Y, { color = 'GREY' })
  local level = battery_level()
  if level then
    frame.display.text(level .. '%', BATTERY_X, CRUMB_Y,
                       { color = (level <= BATTERY_LOW) and 'RED' or 'GREY' })
  end
end

local function render()
  -- panel on before drawing, off only after the screen has been cleared
  if running or visible then set_display(true) end

  if running then
    draw_top_bar(run_name)
    -- a module may return several lines, separated by '\n'
    local row = 0
    for line in string.gmatch(run_text, '[^\n]+') do
      if row >= TEXT_ROWS then break end
      frame.display.text(line, LEFT_X, TOP_Y + ROW_H * (2 + row),
                         { color = 'WHITE' })
      row = row + 1
    end
    frame.display.show()
    return
  end

  if not visible then
    blank()
    set_display(false)
    return
  end

  local lv = level()
  local items = lv.items

  if #items == 0 then
    draw_top_bar()
    frame.display.text('empty', LEFT_X, TOP_Y + ROW_H * 2, { color = 'GREY' })
    frame.display.show()
    return
  end

  -- keep the cursor inside the scroll window
  if lv.sel < lv.top then lv.top = lv.sel end
  if lv.sel > lv.top + VISIBLE_ROWS - 1 then
    lv.top = lv.sel - VISIBLE_ROWS + 1
  end

  draw_top_bar()

  local row = 0
  for i = lv.top, math.min(lv.top + VISIBLE_ROWS - 1, #items) do
    local y = TOP_Y + row * ROW_H
    local label = items[i].label
    if items[i].items then label = label .. ' >' end   -- a submenu
    if i == lv.sel then
      frame.display.text('> ' .. label, LEFT_X, y, { color = 'WHITE' })
    else
      frame.display.text('  ' .. label, LEFT_X, y, { color = 'GREY' })
    end
    row = row + 1
  end

  frame.display.show()
end

local function move(delta)
  local lv = level()
  if #lv.items == 0 then return end
  lv.sel = lv.sel + delta
  if lv.sel < 1 then lv.sel = #lv.items end
  if lv.sel > #lv.items then lv.sel = 1 end
  last_act = frame.time.utc()
  send(MENU_CURSOR, lv.sel)
  render()
end

-- Idle baseline for the shared hardware: everything a module might have
-- switched on, switched off. Applied at boot and after every module exits,
-- so a module that forgets to clean up in stop() -- or whose stop() errors --
-- still cannot leave the camera or the microphone draining the battery.
-- The camera is powered at boot, so this also shuts it down then. A module
-- that wants it must call frame.camera.power_save(false) first: while
-- saving, only camera.read() and camera.read_raw() remain available.
local function release_hardware()
  pcall(frame.camera.power_save, true)
  pcall(frame.microphone.stop)
end

-- Does this module want to keep running once it leaves the screen?
-- .background is true, or a function asked at that moment -- which is how a
-- background module stops itself: it answers false. Anything else sleeps.
local function wants_background(mod)
  if not mod then return false end
  if type(mod.background) == 'function' then
    local ok, keep = pcall(mod.background)
    return ok and keep == true
  end
  return mod.background == true
end

-- The ONLY way a module stops, from the screen or from the background. Rule:
-- a stopped module has no activity left, so stop() always runs here. The
-- hardware goes back to idle too -- unless a background module is still
-- running, because it may be using it.
local function quit(id)
  local mod = mods[id]
  if mod and mod.stop then pcall(mod.stop) end
  if bg == id then bg = nil end
  if not bg then release_hardware() end
  send(APP_STOP, id)
end

-- The ONLY way a module leaves the screen. Every exit path -- double tap,
-- timeout, menu opened over it, host replacing the menu, deep sleep, break
-- signal -- goes through here. A sleeping module is stopped; a background
-- one keeps running off screen, replacing any previous background module.
--
-- keep_screen: the caller draws something else straight away (the menu), so
-- skip the blank frame and leave the panel powered. Blanking first meant two
-- show() calls milliseconds apart with the panel switched off and on between
-- them, and the menu came up with its top rows missing.
--
-- stop: stop it even if it would rather stay in the background.
local function stop_app(keep_screen, stop)
  if not running then return end
  local id = running
  running = nil
  run_name = ''
  run_text = ''
  if not stop and wants_background(mods[id]) then
    if bg and bg ~= id then quit(bg) end
    bg = id
    send(APP_BACKGROUND, id)
  else
    quit(id)
  end
  if not keep_screen then render() end
end

-- Sample the roll baseline and drop any half-made gesture. Done every time
-- the menu opens or a module launches, not once at startup: whatever pose the
-- head is in right now counts as neutral.
local function reset_roll()
  armed, roll_dir, roll_hold = 0, 0, 0
  base = frame.imu.direction().roll
end

-- at_root: opening from a blank screen starts at the root, however the
-- screen got blank -- close_menu() already resets, but a module that timed
-- out did not go through it. Out of a module, the menu opens at its level.
local function open_menu(at_root)
  if at_root and #stack > 1 then
    stack = { root }
    send(MENU_LEVEL, 1)
  end
  -- the menu replaces whatever owns the display, without a blank in between
  if running then stop_app(true) end
  visible = true
  last_act = frame.time.utc()
  reset_roll()
  send(MENU_OPEN, level().sel)
  render()
end

-- Hiding the menu also returns it to the root, so opening it always starts
-- from the top. The cursor on every level is kept.
local function close_menu()
  visible = false
  send(MENU_CLOSE, level().sel)
  if #stack > 1 then
    stack = { root }
    send(MENU_LEVEL, 1)
  end
  render()
end

-- Back from the menu: one level up, or hide it when already at the root.
local function menu_back()
  if #stack == 1 then
    close_menu()
    return
  end
  stack[#stack] = nil
  last_act = frame.time.utc()
  send(MENU_LEVEL, #stack)
  render()
end

-- Put module id on screen. The module gets the whole display; the menu gets
-- out of the way. A module coming back from the background is not started
-- again -- it never stopped.
local function run_module(id)
  if running then stop_app(true) end   -- the module draws next

  -- the breadcrumb, and where a double tap leads, follow the module's path
  local path = paths[id]
  if path and stack[#stack] ~= path[#path] then
    stack = { table.unpack(path) }
    send(MENU_LEVEL, #stack)
  end
  local lv = level()
  local name = '?'
  for _, item in ipairs(lv.items) do
    if item.id == id then name = item.label end
  end

  visible = false
  running = id
  last = id
  run_name = name
  run_at = frame.time.utc()
  run_text = ''
  reset_roll()   -- the back gesture is measured from the launch pose

  send(APP_START, id)

  local mod = mods[id]
  if not mod then
    -- a host-supplied item has no module behind it; the host does the work
    run_text = '(host item)'
    render()
    return
  end

  if bg == id then
    bg = nil                 -- back in the foreground, still running
  elseif mod.start then
    pcall(mod.start)
  end

  -- an 'info' module produces its value once; an 'app' module is ticked
  if mod.mode == 'app' then
    if mod.tick then
      local ok, text = pcall(mod.tick)
      run_text = ok and tostring(text or '') or ('err: ' .. tostring(text))
    end
  else
    local ok, text = pcall(mod.run)
    run_text = ok and tostring(text or '') or ('err: ' .. tostring(text))
  end

  render()
end

-- Select the item under the cursor: enter a submenu, or launch a module.
local function launch(index)
  local item = level().items[index]
  if not item then return end
  send(MENU_SELECT, index)

  if item.items then
    stack[#stack + 1] = item
    last_act = frame.time.utc()
    send(MENU_LEVEL, #stack)
    render()
    return
  end

  run_module(item.id)
end

-- Hand an input event to the running module. A module that defines
-- on_tap() / on_roll(dir) takes over that input; each returns the text to
-- show and, optionally, true to say "done" -- the module then stops, even a
-- background one, and the menu comes back. Any input counts as activity for
-- APP_TIMEOUT.
local function module_input(handler, ...)
  run_at = frame.time.utc()
  local ok, text, done = pcall(handler, ...)
  if not ok then
    run_text = 'err: ' .. tostring(text)
  elseif text ~= nil then
    run_text = tostring(text)
  end
  if ok and done then
    stop_app(true, true)
    open_menu()
  else
    render()
  end
end

-- Counting happens HERE, not in the loop, because this is the only place with
-- accurate timing. The loop drained one queued tap per iteration, and idle
-- iterations are IDLE_PERIOD apart -- far enough that three real taps looked
-- like sensor bounce and were thrown away, so the menu never opened. Loop
-- pacing and gesture recognition must not be coupled.
frame.imu.tap_callback(function()
  local t = frame.time.utc()
  tap_shake = t                       -- every hit shakes the glasses
  if t - tap_at < TAP_BOUNCE then return end   -- bounce, not a new tap
  if t - tap_at > TAP_WINDOW then
    tap_n = 1
  else
    tap_n = tap_n + 1
  end
  tap_at = t
end)

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
local function draw_sprite(name)
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

-- '<glaz>' centred, with the brackets in a second colour: the fallback. Two
-- overlapping draws, not three adjacent ones. The whole string goes down in
-- the bracket colour first, so the firmware computes every advance; then the
-- word alone is drawn over it in the text colour, offset by the width of
-- '<'. This needs exactly one measured number; placing three separate pieces
-- needs two offsets, and with a proportional font neither can be derived
-- from a character count.
local function draw_splash_text()
  local full = '<' .. SPLASH_TEXT .. '>'
  local x = (SCREEN_W - #full * CHAR_W) // 2
  local y = (VISIBLE_BOTTOM - CHAR_H) // 2
  frame.display.text(full, x, y, { color = SPLASH_BRACKETS })
  frame.display.text(SPLASH_TEXT, x + BRACKET_W, y, { color = SPLASH_COLOR })
end

-- The sprite, or the text if it cannot be drawn. Guarded: a missing or
-- broken sprite file must not stop the app from starting.
local function draw_splash()
  set_display(true)
  local ok, drawn = pcall(draw_sprite, SPLASH_SPRITE)
  if not ok and string.find(tostring(drawn), 'break signal', 1, true) then
    error(drawn, 0)
  end
  if not (ok and drawn) then draw_splash_text() end
  frame.display.show()
  collectgarbage('collect')
end

function app_loop()
  release_hardware()

  draw_splash()

  -- the host waits for this line on await_print
  print('Frame app is running')
  -- what everything above costs; Frame reboots when Lua runs out of memory
  collectgarbage('collect')
  print(string.format('mem %d KB', math.floor(collectgarbage('count'))))

  -- Hold the banner on a timer rather than sleeping: the host sends its
  -- first message immediately after start_frame_app() returns, and the loop
  -- has to stay responsive. render() is deliberately NOT called here -- in
  -- IDLE it would blank the screen and the banner would never be seen.
  local splash_until = frame.time.utc() + SPLASH_SECONDS

  -- Start the idle clock now. Left at 0 it would already be older than
  -- SLEEP_AFTER, and the app would park itself the moment it booted.
  last_act = frame.time.utc()

  local next_imu = 0   -- utc() of the next orientation sample
  local next_app = 0   -- utc() of the next 'app' module refresh
  local next_bg  = 0   -- utc() of the next background tick
  local next_status = 0  -- utc() of the next clock / battery check
  local status_shown = ''

  -- Head-tilt recogniser, shared by the menu and running modules. Poll
  -- rarely: the sensor is slow, but the loop must spin fast for incoming
  -- Bluetooth traffic. Returns the direction of a COMPLETED tilt-and-return
  -- (1 right, -1 left), or 0.
  local function roll_step(now)
    if now < next_imu then return 0 end
    next_imu = now + IMU_PERIOD
    local delta = (frame.imu.direction().roll - base) * ROLL_SIGN

    if now - tap_shake < ROLL_MUTE then
      -- still ringing from a tap; throw the reading away
      armed, roll_dir, roll_hold = 0, 0, 0
    elseif armed == 0 then
      -- Tilting only arms the step, and only once it has been HELD:
      -- a tap spikes roll far past the threshold for a sample or two.
      local dir = 0
      if delta > ROLL_THRESHOLD then
        dir = 1      -- tilt right -> cursor down, on the way back
      elseif delta < -ROLL_THRESHOLD then
        dir = -1     -- tilt left -> cursor up, on the way back
      end

      if dir ~= 0 and dir == roll_dir then
        roll_hold = roll_hold + 1
        if roll_hold >= ROLL_HOLD_SAMPLES then
          armed, roll_hold = dir, 0
        end
      else
        roll_dir = dir
        roll_hold = (dir ~= 0) and 1 or 0
      end
    elseif math.abs(delta) < DEADZONE then
      -- Head is level again: that completes the gesture.
      local dir = armed
      armed, roll_dir, roll_hold = 0, 0, 0
      return dir
    end
    return 0
  end

  while true do
    local rc, err = pcall(function()
      local now = frame.time.utc()

      -- 0. retire the startup banner. Anything that draws (a tap, a host
      --    command) supersedes it, so only the quiet case needs this.
      if splash_until > 0 and now > splash_until then
        splash_until = 0
        render()
      end

      -- 1. incoming messages from the host
      if data.process_raw_items() > 0 then
        if data.app_data[MENU_SET] ~= nil then
          -- Host overrides the module menu with one flat level. Such items
          -- have no module behind them, so launching one only notifies the
          -- host; their id is their line number.
          local lines = split_lines(data.app_data[MENU_SET])
          data.app_data[MENU_SET] = nil
          -- stop every module while mods still points at it
          stop_app(false, true)
          if bg then quit(bg) end
          mods = {}
          paths = {}
          last = nil
          root = new_level(ROOT_LABEL)
          for i, line in ipairs(lines) do
            root.items[i] = { label = line, id = i }
            paths[i] = { root }
          end
          stack = { root }
          if visible then open_menu() else render() end
        end

        if data.app_data[CLOCK_SET] ~= nil then
          local block = data.app_data[CLOCK_SET]
          data.app_data[CLOCK_SET] = nil
          if #block >= 6 then
            local unix, tz = string.unpack('>I4i2', block)
            clock_offset = unix + tz * 60 - frame.time.utc()
            if visible or running then render() end
          end
        end

        if data.app_data[MENU_SHOW] ~= nil then
          data.app_data[MENU_SHOW] = nil
          if not visible then open_menu(not running) end
        end

        if data.app_data[MENU_HIDE] ~= nil then
          data.app_data[MENU_HIDE] = nil
          if visible then close_menu() end
        end
      end

      -- 2. taps. The callback has already counted them; this only decides
      --    what the count means. Nothing here depends on the loop's pace.

      -- The glasses were just hit, so roll is ringing: drop a half-finished
      -- tilt rather than letting the impulse complete it.
      if now - tap_shake < ROLL_MUTE then
        armed, roll_dir, roll_hold = 0, 0, 0
      end

      if tap_n >= TAP_TOGGLE then
        tap_n = 0
        if now < tap_mute then
          -- trailing taps of a previous toggle; keep swallowing them until
          -- tapping actually stops
          tap_mute = tap_at + TAP_WINDOW
        else
          tap_mute = now + TAP_WINDOW
          -- The menu must ALWAYS be reachable, from every state.
          if visible then
            close_menu()
          else
            open_menu(not running)
          end
        end

      -- classify a shorter multi-tap once no further tap can join it
      elseif tap_n > 0 and now - tap_at > TAP_WINDOW then
        local n = tap_n
        tap_n = 0

        if now < tap_mute then
          tap_mute = tap_at + TAP_WINDOW
          n = 0   -- trailing taps of a toggle mean nothing
        end

        if n == 1 then
          if visible then
            launch(level().sel)
          elseif not running and last then
            -- The blank screen: back to the last module, wherever it was in
            -- the tree. A background one is still running; a sleeping one
            -- starts again.
            splash_until = 0
            last_act = now
            run_module(last)
          elseif not running then
            -- Nothing launched yet. The tap is the sign of life: flash the
            -- banner, then fall back to blank on its own.
            draw_splash()
            splash_until = frame.time.utc() + SPLASH_SECONDS
            last_act = now   -- a tap postpones deep sleep
          elseif mods[running] and mods[running].on_tap then
            module_input(mods[running].on_tap)
          elseif mods[running] and mods[running].mode == 'app' then
            run_at = now     -- a tap keeps an 'app' module alive
          end
        elseif n == 2 then
          -- back, one level up: module -> its level -> parent -> blank
          if running then
            open_menu()   -- the module leaves the screen first
          elseif visible then
            menu_back()
          end
        end
      end

      -- 3. the running module. Tilt only reaches a module that takes it
      --    (on_roll), and only moves its cursor -- it never leaves the
      --    module. A module without on_roll does not poll the IMU at all.
      if running then
        local mod = mods[running]
        local dir = (mod and mod.on_roll) and roll_step(now) or 0

        if dir ~= 0 then
          module_input(mod.on_roll, dir)

        elseif mod and mod.mode == 'app' then
          -- keep refreshing until closed or left alone for APP_TIMEOUT;
          -- a background module then carries on off screen
          if now - run_at > APP_TIMEOUT then
            stop_app()
          elseif now >= next_app then
            next_app = now + APP_TICK_PERIOD
            if mod.tick then
              local ok, text, done = pcall(mod.tick)
              local fresh = ok and tostring(text or '')
                              or ('err: ' .. tostring(text))
              if ok and done then
                stop_app(true, true)   -- finished on its own
                open_menu()
              elseif fresh ~= run_text then
                run_text = fresh
                render()
              end
            end
          end
        elseif now - run_at > INFO_TIMEOUT then
          -- an 'info' module has said its piece; clear the display
          stop_app()
        end

      -- 4. head tilt scrolls the menu. Nothing polls the IMU while IDLE,
      --    which saves battery.
      elseif visible and #level().items > 0 then
        local dir = roll_step(now)
        if dir ~= 0 then move(dir) end

        -- 5. auto-hide after a spell of inactivity
        if now - last_act > MENU_TIMEOUT then
          close_menu()
        end
      end

      -- 6. the background module, ticked rarely and never drawn. Returning
      --    true as tick()'s second value stops it from there too.
      if bg and now >= next_bg then
        next_bg = now + BG_TICK_PERIOD
        local mod = mods[bg]
        if mod and mod.tick then
          local ok, _, done = pcall(mod.tick)
          if ok and done then
            quit(bg)
            if visible or running then render() end   -- the icon goes
          end
        end
      end

      -- 7. battery samples for the average, taken in every state; then, if
      --    the clock turned over a minute or the average moved, the top bar
      --    is out of date
      sample_battery(now)
      if (visible or running) and now >= next_status then
        next_status = now + STATUS_PERIOD
        local status = status_text()
        if status ~= status_shown then
          status_shown = status
          render()
        end
      end

      -- Pace the loop by state. Idling with a blank screen needs nothing but
      -- tap latency, so it runs far slower and stops burning battery; the
      -- tap callback is interrupt-driven and loses nothing by it. While the
      -- menu or a module is up the loop must stay quick, partly for feel and
      -- partly because incoming Bluetooth data may be queued.
      if visible or running then
        frame.sleep(ACTIVE_PERIOD)

      elseif now - last_act > SLEEP_AFTER and not bg
             and not frame.bluetooth.is_connected() then
        -- Deep sleep: frame.sleep() with no argument parks the device until a
        -- tap, which is far beyond what loop pacing can save. Two conditions
        -- make it safe to use here.
        --
        -- Only with no host attached, because a sleeping app cannot be
        -- reached over Bluetooth -- otherwise development would stall.
        --
        -- Never with a module in the background: it would be frozen, which
        -- is exactly what background means it must not be.
        --
        -- And the tap state is cleared on the way out. It is unknown whether
        -- the firmware also delivers the waking tap to tap_callback; by
        -- zeroing the counter either way, the gesture count cannot be thrown
        -- off by one, so a triple tap stays a triple tap.
        --
        -- Rule: going to sleep closes whatever is open. The branch order
        -- above already keeps a running module or the menu out of here, but
        -- that is incidental; this makes it hold even if the pacing changes,
        -- so nothing wakes up half-alive with a stale screen.
        if running then stop_app() end
        if visible then close_menu() end
        set_display(false)
        frame.sleep()

        local woke = frame.time.utc()
        tap_n, tap_at, tap_shake = 0, 0, woke
        armed, roll_dir, roll_hold = 0, 0, 0
        last_act = woke

        draw_splash()
        splash_until = frame.time.utc() + SPLASH_SECONDS

      else
        frame.sleep(IDLE_PERIOD)
      end
    end)

    -- the host's break signal also lands here -- exit cleanly
    if rc == false then
      pcall(stop_app, true, true)
      if bg then pcall(quit, bg) end
      print(err)
      frame.display.text(' ', LEFT_X, TOP_Y)
      frame.display.show()
      break
    end
  end
end

app_loop()

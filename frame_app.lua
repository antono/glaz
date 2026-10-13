-- In-glasses menu and app launcher. Frame-side application.
--
-- ASCII ONLY. frame_ble's uploader chunks by characters but checks the MTU
-- limit in bytes, so any non-ASCII byte here breaks upload_file() with
-- "payload length is too large". See PROTOCOL.md.
--
-- Menu state lives here, not on the host. Each item is a module in modules/
-- that declares a label and either run() or tick(). Adding an item means
-- adding one file and listing it in MODULES below. The host still receives
-- every event, so it can react too, but nothing here needs a host.
--
-- States:
--   IDLE    -- blank display, nothing running
--   MENU    -- the list; tilting the head scrolls it
--   RUNNING -- a module owns the display
--
-- Roll (tilt toward a shoulder, then back): right scrolls down, left scrolls
-- up. The return to neutral is part of the gesture -- see the latch below.
--
-- Taps (Frame has no buttons; count is the only way to tell intents apart):
--   single -- run the item under the cursor (MENU only)
--   double -- launch the default app, or close the running one
--   triple -- toggle the menu
-- The default app is simply whatever the cursor was last left on, so the
-- common case is: double tap, read, double tap (or let it time out).
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

-- One module per menu item, in display order. Each must return a table with
-- a .label and either .run() (mode 'info') or .tick() (mode 'app').
local MODULES = { 'battery', 'uptime', 'brightness', 'firmware', 'tilt' }

-- Host -> Frame
local MENU_SET  = 0x20    -- override items, one per line; see PROTOCOL.md
local MENU_HIDE = 0x21    -- no payload; hide the menu
local MENU_SHOW = 0x22    -- no payload; show the menu

-- Frame -> Host
local MENU_SELECT = 0x11  -- [0x11, index] item index was selected (1-based)
local MENU_CURSOR = 0x12  -- [0x12, index] cursor moved to index
local MENU_OPEN   = 0x13  -- [0x13, index] menu became visible
local MENU_CLOSE  = 0x14  -- [0x14, index] menu was hidden
local APP_START   = 0x15  -- [0x15, index] module index started
local APP_STOP    = 0x16  -- [0x16, index] module index stopped

-- Navigation tuning. Scrolling is driven by roll -- tilting the head toward
-- a shoulder -- not by pitch. Roll has the wider usable swing of the two
-- (about +-30 degrees measured, against a few for a comfortable nod), and it
-- leaves nodding free. Yaw is not an option at all: heading is always 0.0
-- because the magnetometer's Z axis is railed. See PROTOCOL.md.
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
local IDLE_PERIOD     = 0.05  -- blank screen, only waiting for a tap
local ACTIVE_PERIOD   = 0.01  -- menu up or a module running
local APP_TICK_PERIOD = 0.25  -- refresh rate of an 'app' module
local MENU_TIMEOUT    = 10    -- seconds of inactivity before auto-hiding
local INFO_TIMEOUT    = 5     -- seconds an 'info' module stays on screen

-- Startup banner. IDLE is a blank screen, which is indistinguishable from
-- "the app is not running" -- this is the sign of life.
local SPLASH_TEXT     = 'okulo'
local SPLASH_COLOR    = 'GREEN'
local SPLASH_BRACKETS = 'RED'
local SPLASH_SECONDS  = 2

-- Tap tuning
local TAP_BOUNCE = 0.15  -- taps closer than this are sensor bounce, not input
local TAP_WINDOW = 0.75  -- max gap between taps belonging to one multi-tap
local TAP_TOGGLE = 3     -- taps required to toggle the menu

-- Layout. Display is 640x400. x=1 is clipped, so nothing starts left of
-- LEFT_X. A row is 55px.
local ROW_H        = 55
local TOP_Y        = 30
local LEFT_X       = 60
local VISIBLE_ROWS = 5

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

-- Load the modules. A broken module must not take the whole menu down, so
-- each require is guarded and failures become visible menu entries.
local mods  = {}
local items = {}
for _, name in ipairs(MODULES) do
  local ok, mod = pcall(require, name)
  if ok and type(mod) == 'table' and mod.label then
    mods[#mods + 1] = mod
    items[#items + 1] = mod.label
  else
    mods[#mods + 1] = false
    items[#items + 1] = name .. ' (load failed)'
  end
end

local sel      = 1      -- cursor position, 1-based; this is the default app
local top      = 1      -- first visible item (scroll window)
local base     = 0      -- baseline roll, sampled when the menu opens
local armed     = 0     -- 0 = level, 1/-1 = tilt seen, waiting for the return
local roll_dir  = 0     -- direction currently being held past the threshold
local roll_hold = 0     -- how many consecutive samples it has been held
local visible  = false  -- menu on screen
local running  = nil    -- index of the running module, or nil
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

local function render()
  if running then
    local mod = mods[running]
    frame.display.text(mod and mod.label or '?', LEFT_X, TOP_Y,
                       { color = 'GREY' })
    frame.display.text(run_text, LEFT_X, TOP_Y + ROW_H * 2,
                       { color = 'WHITE' })
    frame.display.show()
    return
  end

  if not visible then
    blank()
    return
  end

  if #items == 0 then
    frame.display.text('no modules', LEFT_X, 180, { color = 'GREY' })
    frame.display.show()
    return
  end

  -- keep the cursor inside the scroll window
  if sel < top then top = sel end
  if sel > top + VISIBLE_ROWS - 1 then top = sel - VISIBLE_ROWS + 1 end

  local row = 0
  for i = top, math.min(top + VISIBLE_ROWS - 1, #items) do
    local y = TOP_Y + row * ROW_H
    if i == sel then
      frame.display.text('> ' .. items[i], LEFT_X, y, { color = 'WHITE' })
    else
      frame.display.text('  ' .. items[i], LEFT_X, y, { color = 'GREY' })
    end
    row = row + 1
  end

  -- scroll indicator, only when the list does not fit
  if #items > VISIBLE_ROWS then
    frame.display.text(
      string.format('%d/%d', sel, #items),
      560, TOP_Y, { color = 'SKYBLUE' })
  end

  frame.display.show()
end

local function move(delta)
  if #items == 0 then return end
  sel = sel + delta
  if sel < 1 then sel = #items end
  if sel > #items then sel = 1 end
  last_act = frame.time.utc()
  send(MENU_CURSOR, sel)
  render()
end

local function open_menu()
  visible = true
  armed = 0
  last_act = frame.time.utc()
  -- Sample the baseline every time the menu opens, not once at startup:
  -- whatever pose the head is in right now counts as neutral.
  base = frame.imu.direction().roll
  send(MENU_OPEN, sel)
  render()
end

local function close_menu()
  visible = false
  send(MENU_CLOSE, sel)
  render()
end

local function stop_app()
  if not running then return end
  local mod = mods[running]
  if mod and mod.stop then pcall(mod.stop) end
  send(APP_STOP, running)
  running = nil
  run_text = ''
  render()
end

-- Launch the module under the cursor. The menu gets out of the way, so the
-- module owns the whole display.
local function launch(index)
  if #items == 0 then return end
  if running then stop_app() end

  visible = false
  running = index
  run_at = frame.time.utc()
  run_text = ''

  send(MENU_SELECT, index)
  send(APP_START, index)

  local mod = mods[index]
  if not mod then
    -- a host-supplied item has no module behind it; the host does the work
    run_text = '(host item)'
    render()
    return
  end

  if mod.start then pcall(mod.start) end

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

-- '<okulo>' centred, with the brackets in a second colour. Drawn as three
-- pieces because frame.display.text() takes one colour per call.
-- Two overlapping draws, not three adjacent ones. The whole string goes down
-- in the bracket colour first, so the firmware computes every advance; then
-- the word alone is drawn over it in the text colour, offset by the width of
-- '<'. The brackets keep showing, and this needs exactly one measured
-- number. Placing three separate pieces needs two offsets, and with a
-- proportional font neither can be derived from a character count.
local function draw_splash()
  local full = '<' .. SPLASH_TEXT .. '>'
  local x = (SCREEN_W - #full * CHAR_W) // 2
  local y = (VISIBLE_BOTTOM - CHAR_H) // 2

  frame.display.text(full, x, y, { color = SPLASH_BRACKETS })
  frame.display.text(SPLASH_TEXT, x + BRACKET_W, y, { color = SPLASH_COLOR })
  frame.display.show()
end

function app_loop()
  draw_splash()

  -- the host waits for this line on await_print
  print('Frame app is running')

  -- Hold the banner on a timer rather than sleeping: the host sends its
  -- first message immediately after start_frame_app() returns, and the loop
  -- has to stay responsive. render() is deliberately NOT called here -- in
  -- IDLE it would blank the screen and the banner would never be seen.
  local splash_until = frame.time.utc() + SPLASH_SECONDS

  local next_imu = 0   -- utc() of the next orientation sample
  local next_app = 0   -- utc() of the next 'app' module refresh

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
          -- Host overrides the module menu. Such items have no module
          -- behind them, so launching one only notifies the host.
          items = split_lines(data.app_data[MENU_SET])
          data.app_data[MENU_SET] = nil
          mods = {}
          sel = 1
          top = 1
          if visible then open_menu() else render() end
        end

        if data.app_data[MENU_SHOW] ~= nil then
          data.app_data[MENU_SHOW] = nil
          if not visible then open_menu() end
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
            if running then stop_app() end
            open_menu()
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
            launch(sel)
          elseif not running then
            -- Waking from a blank idle screen. A lone tap had no meaning
            -- here before, so it costs nothing to make it the sign of life:
            -- flash the banner, then fall back to blank on its own.
            draw_splash()
            splash_until = now + SPLASH_SECONDS
          end
        elseif n == 2 then
          if running then stop_app() else launch(sel) end
        end
      end

      -- 3. the running module
      if running then
        local mod = mods[running]

        if mod and mod.mode == 'app' then
          -- keep refreshing until closed; no timeout
          if now >= next_app then
            next_app = now + APP_TICK_PERIOD
            if mod.tick then
              local ok, text = pcall(mod.tick)
              local fresh = ok and tostring(text or '')
                              or ('err: ' .. tostring(text))
              if fresh ~= run_text then
                run_text = fresh
                render()
              end
            end
          end
        elseif now - run_at > INFO_TIMEOUT then
          -- an 'info' module has said its piece; clear the display
          stop_app()
        end

      -- 4. head tilt, only while the menu is up. Poll rarely: the sensor is
      --    slow, but the loop must spin fast for incoming Bluetooth traffic.
      --    Skipping the poll while IDLE also saves battery.
      elseif visible and #items > 0 then
        if now >= next_imu then
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
            move(dir)
          end
        end

        -- 5. auto-hide after a spell of inactivity
        if now - last_act > MENU_TIMEOUT then
          close_menu()
        end
      end

      -- cannot sleep long: a burst of incoming Bluetooth data may be queued
      -- Pace the loop by state. Idling with a blank screen needs nothing but
      -- tap latency, so it runs far slower and stops burning battery; the
      -- tap callback is interrupt-driven and loses nothing by it.
      if visible or running then
        frame.sleep(ACTIVE_PERIOD)
      else
        frame.sleep(IDLE_PERIOD)
      end
    end)

    -- the host's break signal also lands here -- exit cleanly
    if rc == false then
      print(err)
      frame.display.text(' ', LEFT_X, TOP_Y)
      frame.display.show()
      break
    end
  end
end

app_loop()

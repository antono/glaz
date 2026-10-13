# Frame Menu Protocol

## Plain-language summary

The menu lives **inside the glasses**, not in the phone or laptop. The host
(whatever program drives the glasses) sends a list of items once. From then on
the glasses draw the list, scroll it when you tilt your head, and move the
cursor on their own. The host only receives a short message saying "the user
picked item 4".

Why this split: the host is not chosen yet — it might be Python, it might be
Flutter. With the logic on the glasses, swapping the host does not require
rewriting anything that already works.

---

## Division of responsibility

| | Glasses (`frame_app.lua`) | Host (anything) |
| --- | --- | --- |
| Item list | stores | sends once |
| Cursor, scrolling | **yes** | no |
| Rendering | **yes** | no |
| Reading sensors | **yes** | no |
| Acting on a selection | no | **yes** |

The glasses work without a host. If the link drops, the menu still scrolls;
selection events just go nowhere (`frame.bluetooth.send` is wrapped in `pcall`).

---

## Modules

Each menu item is a Lua module in `modules/`. A module declares a label and
what to do when it is picked:

```lua
local _M = {}

_M.label = 'Battery'

function _M.run()
  return string.format('%d%%', frame.battery_level())
end

return _M
```

A launched module owns the whole display — the menu gets out of the way.

There are two kinds, chosen with `_M.mode`:

**`info`** (the default) — produces one value and **clears itself after
`INFO_TIMEOUT` (5 s)**. Implement `run()`, returning the string to show.

**`app`** — keeps running until closed with a double tap (back), or **until
`APP_TIMEOUT` (60 s) passes with no tap**; a single tap restarts that clock.
Going to deep sleep also closes it. Implement `tick()`,
which is called periodically and returns the current string; the display is
only redrawn when the text actually changes. Optional `start()` and `stop()`
bracket the lifetime.

**Rule: a module that has left the screen has no activity left.** Whatever
`start()` or `run()` switched on, `stop()` must switch off. `stop()` is called
on **every** exit path, for both kinds, and all of them go through
`stop_app()`:

- the `INFO_TIMEOUT` / `APP_TIMEOUT` timeouts;
- the menu opening over the module (a double or triple tap, or the host's
  `MENU_SHOW`);
- the host replacing the menu with `MENU_SET`;
- deep sleep;
- the host's break signal.

As a safety net, after `stop()` the app also returns the shared hardware to
idle: camera in power save, microphone stopped (`release_hardware()`). This
also runs when `stop()` is missing or throws an error. A module must not rely
on it; it exists so a buggy module cannot drain the battery.

**Input hooks (optional, `app` modules).** A module can take input itself:

- `on_roll(dir)` — a completed tilt-and-return, `1` right, `-1` left. This
  is the only thing tilt does inside a module: move the module's own cursor.
  Without `on_roll` tilt is ignored and the IMU is not even polled.
- `on_tap()` — a single tap. Without it a single tap only keeps the module
  alive.

Each returns the text to show (`nil` keeps the current text) and, optionally,
`true` as a second value meaning "done": the module is stopped and the menu
comes back. Double and triple taps are never passed to a module, so back and
menu always work. `modules/brightness.lua` is the example: tilt previews a
level, a single tap keeps it, a double tap cancels.

```lua
local _M = {}

_M.label = 'Tilt'
_M.mode = 'app'

function _M.tick()
  local d = frame.imu.direction()
  return string.format('r%.0f  p%.0f  h%.0f', d.roll, d.pitch, d.heading)
end

return _M
```

Adding an item means adding one file and listing its name in `MODULES` at the
top of `frame_app.lua`:

```lua
local MODULES = { 'battery', 'uptime', 'brightness', 'firmware', 'tilt',
                  'photo' }
```

The order of that list is the display order. The host uploads every
`modules/*.lua` to the device root, because `frame_app.lua` requires them by
bare name.

Two failures are contained deliberately:

- a module that fails to `require` becomes a visible `name (load failed)` entry
  instead of taking the whole menu down;
- a module whose `run()` throws shows `err: ...` in the status line and leaves
  the menu usable.

Selecting an item still emits `MENU_SELECT` to the host, so modules and a
host-side reaction are not mutually exclusive — both run.

---

## States

Frame has no buttons and only one kind of tap event exists, so intents are
separated by **tap count** and by **state**.

Each tap count means one thing everywhere:

| Taps | Meaning |
| --- | --- |
| **1** | select — run the item under the cursor |
| **2** | back — one level up: module → menu → blank |
| **3** | menu — open or hide it, from any state |

```
              triple tap / MENU_SHOW
        IDLE ─────────────────────────> MENU
          ▲  <─────────────────────────  │  ▲
          │   double tap, triple tap,    │  │ double tap,
          │   10s timeout                │  │ triple tap,
          │                       single │  │
          │ 5s info / 60s app     tap    ▼  │
          └──────────────────────────── RUNNING
            timeout
```

| State | Display | 1 tap | 2 taps | 3 taps | Tilt |
| --- | --- | --- | --- | --- | --- |
| **IDLE** | blank | banner (sign of life) | — | menu | not polled |
| **MENU** | the list | launch | hide | hide | scrolls |
| **RUNNING** | the module | `on_tap()`, else keep `app` alive | back to menu | menu | `on_roll()` only, never leaves |

Returning to the menu leaves the cursor on the module just closed, so it can
be run again with a single tap.

**Tilt never leaves a module.** Inside a module tilt only moves the module's
own cursor, and only if it defines `on_roll()`. The roll baseline is sampled
at launch, so it works from any head pose. The way out is a double tap.

While IDLE the IMU is not polled at all, which saves battery.

### Why taps are counted in the loop, not the callback

`frame.imu.tap_callback` only increments a counter; classification happens in
the main loop. The callback stays trivial so it cannot stall the sensor.

Three tap constants do the work:

```lua
local TAP_BOUNCE = 0.15  -- closer than this is sensor bounce, not input
local TAP_WINDOW = 0.5   -- max gap between taps of one multi-tap
local TAP_TOGGLE = 3     -- taps required to toggle the menu
```

`TAP_BOUNCE` exists because it was measured: a single physical tap fired the
callback 3 and even 7 times in a row, which made the host run the selected
action repeatedly.

**Single and double taps are only confirmed once `TAP_WINDOW` has expired**,
because until then the sequence could still turn out to be a triple. They are
therefore delayed by about 0.75 s by design. Triple taps fire immediately on the
third tap.

`TAP_WINDOW` started at 0.5 s and that was too tight: taps at a natural pace
landed outside the window, so each one was classified as a lone tap and ran a
module instead of forming a triple.

After a triple fires, further taps are **muted** for another `TAP_WINDOW`, and
the mute extends while tapping continues. Without it the fourth tap of a
deliberate triple would be read as a lone tap and launch something.

---

## Messages

Layered on the standard `frame_msg` transport (`data.min` on the Frame side),
which splits long messages into MTU-sized packets and reassembles them.

### Host → Frame

| Code | Name | Payload |
| --- | --- | --- |
| `0x20` | `MENU_SET` | UTF-8 text, one item per line (`\n`) |
| `0x21` | `MENU_HIDE` | none — hide the menu, return to IDLE |
| `0x22` | `MENU_SHOW` | none — open the menu without resending items |

`MENU_SET` is an **override**: it replaces the module-defined menu with
host-supplied labels and resets the cursor. Those items have no module behind
them, so picking one only notifies the host — nothing runs on the glasses.

Whether it also opens the menu depends on the current state:

- **IDLE** — items load silently, the display stays blank. The user opens the
  menu with a triple tap. Use `MENU_SHOW` to force it open.
- **MENU** — the menu stays on screen. This is what makes **nested menus**
  work: the host answers `MENU_SELECT` with another `MENU_SET`, and the new
  level appears without a flicker through IDLE.

If the host never sends `MENU_SET`, the menu is entirely module-driven and the
host is a pure observer.

### Frame → Host

Every event is exactly 2 bytes.

| Code | Name | Bytes | Meaning |
| --- | --- | --- | --- |
| `0x11` | `MENU_SELECT` | `[0x11, index]` | item `index` was tapped |
| `0x12` | `MENU_CURSOR` | `[0x12, index]` | cursor moved to `index` |
| `0x13` | `MENU_OPEN` | `[0x13, index]` | menu became visible |
| `0x14` | `MENU_CLOSE` | `[0x14, index]` | menu was hidden |
| `0x15` | `APP_START` | `[0x15, index]` | module `index` started |
| `0x16` | `APP_STOP` | `[0x16, index]` | module `index` stopped |
| `0x07` | photo chunk | `[0x07, jpeg bytes...]` | part of a photo (Camera module) |
| `0x08` | photo end | `[0x08]` | last chunk; the photo is complete |

`0x07` / `0x08` are the frame_msg `camera` library's codes, not this app's:
`modules/photo.lua` sends through its `capture_and_send()`, and the host
reassembles with `RxPhoto` and saves to `photos/`. The library must be
uploaded next to `data` (`upload_stdlua_libs(["data", "camera"])`).

**Do not use the library's `send_autoexp_result()` or
`send_metering_data()`**: they send `0x11` and `0x12`, the same codes as
`MENU_SELECT` and `MENU_CURSOR`.

`index` is **1-based**, as in Lua.

Launching an item emits `MENU_SELECT` and then `APP_START`; `APP_STOP` follows
when it closes, whether by going back to the menu, by a timeout, or because
another module was launched.

Only `MENU_SELECT` is required. The rest are advisory: `MENU_CURSOR` is useful
if the host wants to show something in sync with the cursor (a preview, a hint),
and the others let the host track what is on screen.

> The code byte arrives **first in the payload**: the handler receives the whole
> message, not just the tail. Verified against `frame_msg.py:166`.

---

## Input

Two channels, no buttons:

- **head tilt** (`frame.imu.direction().pitch`) — scroll
- **tap on the arm** (`frame.imu.tap_callback`) — summon / select

Measured on the device, firmware `v25.080.0838`:

- Resting `pitch` is about **−35°**, not zero. Absolute angles are unusable —
  the baseline is sampled at runtime, every time the menu opens.
- `pitch` and `roll` noise is about **±4°**, which is where the 12° threshold
  and the 6° dead zone come from.
- `heading` is always `0.0` — unusable.

**Only two of the three axes exist.** `pitch` (nodding) and `roll` (tilting
toward a shoulder, ±30° swing) both work; `heading` (turning the head) does not,
because the magnetometer's Z axis is railed at `8191` = `2^13 - 1`. Roll and
pitch come from the gravity vector, which the accelerometer measures; yaw cannot
be derived from gravity at all.

So navigation has **one spare axis**: `roll` is currently unused and is the
natural place to put "back" / "forward" through nested menus.

**Latch.** After one scroll step the head must return to the dead zone before
the next step is allowed. Without it a single tilt would scroll the whole list
in a fraction of a second.

Tuning lives at the top of `frame_app.lua`:

```lua
local PITCH_THRESHOLD = 12   -- degrees to scroll one step
local DEADZONE        = 6    -- return here before the next step
local PITCH_SIGN      = 1    -- set to -1 if scrolling feels inverted
local IMU_EVERY       = 40   -- poll the sensor once per N loop iterations
local MENU_TIMEOUT    = 10   -- seconds of inactivity before auto-hiding
```

The timeout uses `frame.time.utc()`, which counts monotonically from boot and
works even when the clock was never set (measured: 687.83 → 691.998 over ~4s).

---

## Layout

The display is 640 × 400 and a row is 55 px, so **5 items fit**. Longer lists
scroll within a window and a `3/9` counter appears in the top-right corner.

### The visible area is smaller than the framebuffer

The docs say "possible values for `x` are between 1 and 640, and possible values
for `y` are between 1 and 400" and **describe no safe area at all**. The
hardware manual only covers the optics: a 0.23" micro-OLED through a prism with
a 20° field of view. Neither mentions that part of the buffer never reaches the
eye. It does.

Measured by drawing markers and asking the wearer which ones are visible:

| Probe | Result |
| --- | --- |
| `x = 1`, mid-height | visible |
| `x = 600`, mid-height | visible |
| `y = 1`, mid-width | visible |
| `y = 340`, mid-width | visible |
| `y = 370`, mid-width | **not visible** |

So the **bottom is clipped below roughly `y = 340`**, while the left, right and
top edges are reachable at mid-height. Useful vertical space is about 340 px,
not 400.

The layout keeps rows at `y` = 30, 85, 140, 195, 250 — five rows, the last one
well inside the bound. A sixth row would land at 305 and, with a glyph height
near 41 px, finish around 346: past the measured limit.

Independently of this, `frame_msg`'s `print_short_text()` helper hardcodes
`(1, 1)` and comes out clipped, so the host draws its own loading text instead.

### The built-in font is proportional

This costs more time than it should, so: **glyph advances differ**, and no
single character width will position separate pieces of text correctly.
`okulo` is narrower than five average glyphs, so `>` placed at
`x + 6 * CHAR_W` lands wrong for every value of `CHAR_W` — too small overlaps
the word, too large leaves a gap, and nothing in between is right either.

The "25 characters per line" figure floating around the hardware notes implies
a 26 px advance and does not hold.

**The technique that works** for two-coloured text is two overlapping draws
rather than several adjacent ones:

```lua
frame.display.text('<okulo>', x, y, { color = 'RED' })    -- firmware spaces it
frame.display.text('okulo', x + 22, y, { color = 'GREEN' })  -- covers the word
```

The first call lets the firmware compute every advance. The second overdraws
just the word, leaving the brackets showing. This needs exactly **one**
measured number — the width of `<`, which is **22 px** — instead of two
offsets that cannot be derived from a character count.

Vertical note: `<` and `>` sit higher than lowercase letters, on the
typographic math axis rather than the baseline. They look vertically offset
from the word even though both are drawn at the same `y`. Drawing them as part
of one string, as above, reproduces exactly the font's intended geometry.

### Screen redraws race the firmware

`frame.display.show()` **does** clear the back buffer — verified by drawing
text, showing, then drawing elsewhere and showing again: only the second text
remains.

Overlapping text therefore is not a buffer problem. The firmware paints its own
banners (`frame is paired`) after the link comes up, landing on top of whatever
the app drew. The host works around it by drawing its loading text twice, a
second apart.

Text is drawn with the built-in font (`frame.display.text`), which is
**ASCII only** — the firmware has no Cyrillic glyphs, and such a string simply
does not render.

If non-ASCII labels are ever needed, the host must rasterize text into sprites
and send `TxTextSpriteBlock` (available in both the Python and Flutter builds of
`frame_msg`). That removes the font limit but makes the host considerably
heavier, which defeats the thin-host design above.

---

## Running

The Python reference host is **throwaway, for exercising the protocol**:

```bash
.venv/bin/python host_test.py
```

What it does, in the order any host should:

1. `connect()`
2. `upload_stdlua_libs(['data'])` — the transport, onto the glasses
3. `upload_file(m, m.name)` for every `modules/*.lua` — the menu items
4. `upload_frame_app('frame_app.lua')` — the application itself
5. `start_frame_app()` — waits for the line `Frame app is running`
6. `register_data_response_handler(..., [0x11, 0x12, 0x13, 0x14], handler)`
7. optionally `send_message(0x20, ...)` to override the module menu

Shutdown: `stop_frame_app()` (break + reset) then `disconnect()`. The reset
boots `main.lua`, so the menu comes straight back.

Modules must land at the device root as `<name>.lua`, because the app requires
them by bare name.

### Deploy as `main.lua`, or it will not survive

The app is uploaded as **`main.lua`**, not the SDK's default `frame_app.lua`.
This is what makes the glasses autonomous: the firmware auto-runs `main.lua` on
power-on and after a reset. Anything under another name has to be `require()`d
by a host on every connection, and `stop_frame_app()`'s reset signal leaves it
stopped — which looks exactly like the app being "unloaded from memory".

It is not unloaded. The files persist in flash; `frame.file.listdir('/')` shows
them after a power cycle. Only the *running* chunk is lost.

Re-uploading over a running `main.lua` is safe: `FrameMsg.connect()` sends
break → reset → break, and that trailing break exists precisely to interrupt an
auto-starting `main.lua`.

Verifying autonomy: connect with plain `FrameBle` (which does **not** send a
break) and try `send_lua('print(1)', await_print=True)`. If the app is running
it owns the interpreter, the call fails with `device didn't respond`, and a
subsequent break returns `[string "main.lua"]:NNN: break signal`.

Every step has a counterpart in the Flutter `frame_ble` / `frame_msg` packages —
the Lua side and the message codes are identical there.

---

## Static checks

```bash
./check.sh
```

Catches syntax errors and non-ASCII bytes without needing the glasses, which
matters because the device gives poor feedback and is often asleep.

**Check against Lua 5.4.** Frame runs 5.4; Lua 5.2 rejects valid code — the
`//` integer division operator only arrived in 5.3, so `modules/uptime.lua`
fails there for no real reason.

---

## Gotchas

### Lua files must be ASCII

Uploading a file with non-ASCII bytes anywhere in it — including comments —
fails with:

```
Exception: payload length is too large
```

This is a **bug in `frame_ble`**, not in this code. At `frame_ble.py:270` the
chunk size is computed in characters:

```python
chunk_size = self.max_lua_payload() - 22
```

while the limit is enforced in bytes at `frame_ble.py:178`. A 2-byte UTF-8
character turns a 221-character chunk into up to 442 bytes, which overflows.

> The limit applies to the **Lua source**, not to data. Non-ASCII in a
> `MENU_SET` payload will not break the protocol — it just will not render,
> because of the font.

### A broken upload leaves the glasses stuck

If `upload_frame_app()` dies partway, the glasses keep showing `loading...` and
the app never starts. Re-running the host fixes it: it begins with
`print_short_text` and re-uploads the file from scratch.

### Power: nothing sleeps by itself

Frame has **no power switch**, and the firmware does **not** put the device to
sleep while an app loop is running — it just drains, rated around 4 hours.
Snapping on the Mister Power dock is the only physical way to stop it.

So loop pacing is a battery decision, not a style one. `frame.sleep(0.001)`
wakes the CPU a thousand times a second even with a blank display. The loop is
paced per state instead:

```lua
local IDLE_PERIOD   = 0.05  -- blank screen, only waiting for a tap
local ACTIVE_PERIOD = 0.01  -- menu up or a module running
```

Sensor polling is driven by **elapsed time**, not by counting loop iterations.
Counting iterations couples the two: slow the loop down to save power and
navigation slows with it.

```lua
local IMU_PERIOD      = 0.05
local APP_TICK_PERIOD = 0.25
```

**Deeper sleep is available but not used.** `frame.sleep()` with no argument
sleeps until a tap — "The tap gesture will always wake up Frame from
`frame.sleep()`" — and the display powers down and back up on its own around
it. Two reasons it is not wired in yet:

- a host cannot reach the app while it is parked in `frame.sleep()`;
- it is unclear whether the waking tap is also delivered to
  `tap_callback`. If it is swallowed, the triple-tap count breaks.

`frame.stay_awake(true)` does the opposite and is for development on the dock;
the docs warn about display burn-in.

### The loop must not sleep long

`frame.sleep(0.001)` in the main loop is deliberate. While the loop sleeps,
incoming Bluetooth packets queue up. `IMU_EVERY` exists for the same reason: the
sensor is slow, so it cannot be polled every iteration, but the loop must not be
slowed down to accommodate it.

### The REPL is blocked while the app runs

`send_lua()` will not reach a running app. Send the break signal first
(`0x03`, i.e. `stop_frame_app()`).

---

## Next steps

- **nested menus** — host answers `MENU_SELECT` with a new `MENU_SET`; the
  protocol already supports this, nothing to change
- **submenus from modules** — let a module return a list instead of a string
- **camera settings** — resolution and quality picked by tilt, as in
  Brightness; `modules/photo.lua` has them fixed (512 px, `MEDIUM`)
- **module-defined host actions** — a module that only emits an event, leaving
  the work to whichever host happens to be connected

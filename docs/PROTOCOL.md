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
bracket the lifetime. `start(info)` gets a table: `info.background` is the
label of the module running in the background, if any, and `info.arg` the
argument of the phone's `APP_OPEN`, when the phone opened it with one (see
[Assistant](#assistant)).

The returned text may hold up to **three lines** separated by `\n`; they are
drawn on rows 3–5, below the breadcrumb. A module that sets `_M.rows` (at
most 5) gets that many lines from row 1, every row under the top bar:
Assistant's answers. `modules/timeseries.lua` uses all
three: interval scale, status, sent/failed counters.

**Sleeping or background (`_M.background`).** Every module is one of two:

- **sleeping** (the default, `_M.background = false`) — stopped the moment it
  leaves the screen. Bringing it back runs `start()` again; anything it wants
  to remember lives in the module's own locals.
- **background** (`_M.background = true`) — leaving the screen does not stop
  it. It keeps getting `tick()` once per `BG_TICK_PERIOD` (1 s), nothing is
  drawn, and a green play icon shows at the right end of the breadcrumb row
  for as long as it runs. Bringing it back does **not** call `start()` — it
  never stopped.

`background` may also be a **function**, asked each time the module leaves the
screen: `true` keeps it running, `false` stops it like a sleeping one. That is
how a background module ends itself — `modules/stopwatch.lua` answers `false`
once it has been reset. A background module can also finish on its own by
returning `true` as the second value of `tick()`, on screen or off.

Only **one** module runs in the background at a time: a second one leaving the
screen stops the first. While one runs, the glasses **never enter deep sleep**
— a parked CPU would freeze it — so it costs battery until it stops.

**Rule: a module that has stopped has no activity left.** Whatever `start()` or
`run()` switched on, `stop()` must switch off. `stop()` is called on **every**
exit path, for both kinds; a sleeping module leaves through `stop_app()`, and
every stop goes through `quit()`:

- the `INFO_TIMEOUT` / `APP_TIMEOUT` timeouts;
- the menu opening over the module (a double tap, the remote's Menu, or
  the host's `MENU_SHOW`);
- the host replacing the menu with `MENU_SET`;
- deep sleep;
- the host's break signal.

As a safety net, after `stop()` the app also returns the shared hardware to
idle: camera in power save, microphone stopped (`release_hardware()`). This
also runs when `stop()` is missing or throws an error. A module must not rely
on it; it exists so a buggy module cannot drain the battery. It is **skipped
while a background module runs**, since that module may be using the
hardware.

**Input hooks (optional, `app` modules).** A module can take input itself:

- `on_roll(dir)` — a completed tilt-and-return, `1` right, `-1` left. This
  is the only thing tilt does inside a module: move the module's own cursor.
  Without `on_roll` tilt is ignored and the IMU is not even polled.
- `on_tap()` — a single tap. Without it a single tap only keeps the module
  alive.
- `on_hit(n)` — `n` raw hits from the accelerometer since the last call,
  bounces and the taps of a double or triple included. For measuring taps
  (`modules/taptune.lua`); a module never takes `frame.imu.tap_callback`
  over, which would leave the app without taps.
- `remote(arg)` — the phone calls the module (`MODULE_CALL`, see
  [Recorder](#recorder)), `arg` a string whose meaning is the module's. A
  module not running is started into the background for it. Recorder's is
  the phone's record button: `'on'` / `'off'`.

Each returns the text to show (`nil` keeps the current text) and, optionally,
`true` as a second value meaning "done": the module is stopped — even a
background one — and the menu comes back. Double and triple taps are never
passed to a module, so back and sleep always work. `modules/brightness.lua` is the example: tilt previews a
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

Adding an item means adding one file and listing its name in the `MENU` tree
at the top of `frame_app.lua`:

```lua
local MENU = {
  { label = 'Apps',     'photo', 'timeseries', 'stopwatch', 'files' },
  { label = 'Sensors',  'battery', 'tilt', 'taptune' },
  { label = 'Settings', 'brightness', 'sleep' },
  { label = 'Info',     'bluetooth', 'uptime', 'firmware', 'about' },
}
```

A string is a module; a table is a submenu — its `label`, then its entries,
which can be submenus again. The order is the display order. Modules are
numbered in tree order (`photo` = 1, `timeseries` = 2, ...); that number is the
`index` in `APP_START` / `APP_STOP`. The host uploads every
`modules/*.lua` to the device root, because `frame_app.lua` requires them by
bare name.

Two failures are contained deliberately:

- a module that fails to `require` becomes a visible `name (load failed)` entry
  instead of taking the whole menu down;
- a module whose `run()` throws shows `err: ...` in the status line and leaves
  the menu usable.

Either way the error is also printed, once until it changes, as
`Label err: file.lua:12: ...` -- with the line, as the bytecode keeps line
numbers -- and the phone keeps what the app prints in its log (Glaz > More
> Log), with the link going up and down, Upload's steps, the assistant and
the messages either way.

Selecting an item still emits `MENU_SELECT` to the host, so modules and a
host-side reaction are not mutually exclusive — both run.

---

## States

Frame has no buttons and only one kind of tap event exists, so intents are
separated by **tap count** and by **state**.

Each tap count means one thing everywhere:

| Taps | Meaning |
| --- | --- |
| **1** | select — run the item under the cursor, or enter the submenu; on the blank screen, back to the last module |
| **2** | back — one level up: module → its submenu → parent → … → root → blank; on the blank screen, the menu; asleep, wake into the last module (or the menu) |
| **3** | sleep — deep sleep, from any state |

```
              double tap / MENU_SHOW
        IDLE ─────────────────────────> MENU
          ▲  <─────────────────────────  │  ▲
          │   double tap at the root,    │  │
          │   10s timeout                │  │ double tap
          │                       single │  │
          │ 5s info / 60s app     tap    ▼  │
          └──────────────────────────── RUNNING
            timeout

        any state ── triple tap ──> SLEEP ── double tap ──> last module, or MENU
```

| State | Display | 1 tap | 2 taps | 3 taps | Tilt |
| --- | --- | --- | --- | --- | --- |
| **IDLE** | blank | last module, or the banner if none yet | menu, at the root | sleep | not polled |
| **MENU** | one level of the tree | launch / enter | up a level, hide at root | sleep | scrolls |
| **RUNNING** | the module | `on_tap()`, else keep `app` alive | back to menu (background modules keep running) | sleep | `on_roll()` only, never leaves |

Returning to the menu leaves the cursor on the module just closed, so it can
be run again with a single tap. Each level keeps its own cursor, so going up
lands on the submenu just left.

**A single tap on the blank screen brings back the last module launched**,
wherever it sits in the tree: a background one as it was, a sleeping one
started afresh. The breadcrumb shows its full path, and a double tap from it
lands in its submenu. Before anything was launched, the tap flashes the
banner instead.

**Two taps wake the glasses and carry on**: the last module comes back, as
a tap on the blank screen would bring it, or the menu at the root when
nothing was launched yet. One tap is not enough: it woke them far too
often by accident. The accelerometer cannot count taps, so the first wakes
the nRF and the firmware waits up to about 0.9 s for the second, before
anything else is powered; without it, straight back to sleep (firmware
`glaz`, docs/FIRMWARE.md). Waking is a reset, so the app writes the last
module's file name to `last.txt` on the way into `frame.sleep()`; the boot
reads and deletes it, and on `frame.imu.woke_by_tap()` runs that module
instead of showing the banner. Modules with `resume = false` (Sleep) are
never the last one. On older firmware one tap wakes them and the banner
shows.

**Three taps put the glasses to sleep**, from any state: the module on
screen stops, the menu closes, a background module is stopped too (as the
Sleep module does, without its warning), and the device parks in
`frame.sleep()` -- with a phone connected as well. The remote's Menu button
also sends a triple, and that one still shows or hides the menu: only taps
on the arm mean sleep.

**Opening the menu from a blank screen starts at the root** — double tap or
`MENU_SHOW`, whether the screen went blank by hiding the menu, a timeout or
deep sleep. Out of a running module (double tap) the menu opens at the level
the module was launched from.

### Breadcrumbs

The top row shows the path to what is on screen, in sky blue: `Glaz`,
`Glaz > Settings`, and while a module runs `Glaz > Settings > Brightness`.
Submenus carry a trailing `>` in the list.

The same row is the **top bar**, left to right:

| Piece | x | Notes |
| --- | --- | --- |
| breadcrumb | 60 | sky blue |
| background icon | 376 | green play triangle, a 16×16 1-bit `frame.display.bitmap`; only while a module runs in the background. A red dot instead while the module on screen or in the background sets `_M.rec` (Recorder, recording) |
| Bluetooth icon | 400 | the Bluetooth rune, same bitmap format; sky blue while a host is connected, grey when not; always shown |
| clock | 430 | `HH:MM`, grey; `--:--` until the host sends `CLOCK_SET` |
| battery | 545 | `84%`, grey; red at 15 % or below |

The breadcrumb is cut short in front of the icon or the clock. Positions are
estimates for a proportional font; the firmware silently drops any glyph that
would cross `x = 640`, so `100%` must end before it. The clock and battery
are checked once a second and the screen is redrawn only when the text
changes; the battery itself is read every 30 s.

**The clock never sets `frame.time.utc()`.** That counter runs from boot and
every timer in the app (timeouts, taps, the stopwatch) is built on it; setting
it to unix time would make each of them jump by decades. The app keeps only
the offset between host time and `utc()`. It lives in RAM, so after a reboot
the clock shows `--:--` until a host connects again. If the path is too wide, leading
crumbs collapse to `..` — the width is estimated from `CHAR_W`, since the font
is proportional (see Layout).

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
local TAP_TOGGLE = 3     -- taps that fire at once: sleep, or the remote's Menu
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
| `0x23` | `CLOCK_SET` | 6 bytes, big-endian: `uint32` unix time, `int16` UTC offset in minutes |
| `0x24` | `NOTIFY` | ASCII text `app\ntitle\ntext` — see [Host services](#host-services) |
| `0x25` | `NET_RESPONSE` | `uint8` request id, `uint16` HTTP status (big-endian), then the body |
| `0x26` | `STATUS_GET` | any one byte — ask for `STATUS`; see [Status](#status) |
| `0x27` | `SETTINGS_SET` | text, `module.key=value` per line — every module's settings; see [Settings](#settings) |
| `0x28` | `LOCATION` | 14 bytes `>BBi4i4I2I2`: id, status, lat and lon in microdegrees, accuracy m, age s — see [Location](#location) |
| `0x29` | `FILES_GET` | `[id]` + path (`''` the root): list a folder — see [Files](#files) |
| `0x2A` | `FILE_GET` | `[id]` + path: read a file — see [Files](#files) |
| `0x2B` | `INPUT` | `[kind, value]`: the phone's remote — `[1, n]` n taps, `[2, 1]` tilt right, `[2, 255]` tilt left; see [Remote](#remote) |
| `0x2C` | `PHOTO_TAKE` | `>I2B`: size in px (square, even, 100..720), JPEG quality 1 very low .. 5 very high — the remote's photo; see [Remote](#remote) |
| `0x2D` | `MODULE_CALL` | text, `module` `\n` `arg`: calls that module's `remote(arg)` — the remote's record button is `recorder\non` / `recorder\noff`; see [Recorder](#recorder) |
| `0x2F` | `APP_OPEN` | text, `module`, optionally `\n` `arg`: puts that module on screen as if picked in the menu; `arg` goes to its `start()`, or to `remote(arg)` if it is not started again -- on screen already or back from the background; see [Assistant](#assistant) |
| `0x30` | `LUA_EVAL` | `[id]` + Lua: runs it inside the app — see [Lua console](#lua-console) |
| `0x2E` | `HANDS_OFF` | `[1]`: the remote is in front, the wearer's own gestures are off but a triple tap (sleep) and one or two taps on a blank screen; `[0]`: all back; see [Remote](#remote) |

`MENU_SET` is an **override**: it replaces the module-defined menu with
host-supplied labels and resets the cursor. Those items have no module behind
them, so picking one only notifies the host — nothing runs on the glasses.

Whether it also opens the menu depends on the current state:

- **IDLE** — items load silently, the display stays blank. The user opens the
  menu with a double tap. Use `MENU_SHOW` to force it open.
- **MENU** — the menu stays on screen. This is what makes **nested menus**
  work: the host answers `MENU_SELECT` with another `MENU_SET`, and the new
  level appears without a flicker through IDLE.

If the host never sends `MENU_SET`, the menu is entirely module-driven and the
host is a pure observer.

### Frame → Host

Every event is exactly 2 bytes, except `NET_REQUEST` and the photo chunks.

| Code | Name | Bytes | Meaning |
| --- | --- | --- | --- |
| `0x11` | `MENU_SELECT` | `[0x11, index]` | item `index` was tapped |
| `0x12` | `MENU_CURSOR` | `[0x12, index]` | cursor moved to `index` |
| `0x13` | `MENU_OPEN` | `[0x13, index]` | menu became visible |
| `0x14` | `MENU_CLOSE` | `[0x14, index]` | menu was hidden |
| `0x15` | `APP_START` | `[0x15, index]` | module `index` started |
| `0x16` | `APP_STOP` | `[0x16, index]` | module `index` stopped |
| `0x17` | `MENU_LEVEL` | `[0x17, depth]` | entered a submenu or went up; root is 1 |
| `0x18` | `APP_BACKGROUND` | `[0x18, index]` | module `index` left the screen but keeps running |
| `0x19` | `NET_REQUEST` | `[0x19, id, more, bytes...]` | part of a module's HTTP request — see [Host services](#host-services) |
| `0x1A` | `PHOTO_FROM` | `[0x1A, series]` | the next photo is a single shot (`0`) or part of series `series` — see [Photos](#photos) |
| `0x1B` | `STATUS` | `[0x1B, battery, version...]` | answer to `STATUS_GET` — see [Status](#status) |
| `0x1C` | `LOCATION_GET` | `[0x1C, id, module...]` | a module asks where the phone is — see [Location](#location) |
| `0x1D` | `FILES` | `[0x1D, id, more, bytes...]` | a folder listing, in packets — see [Files](#files) |
| `0x1E` | `FILE_DATA` | `[0x1E, id, more, bytes...]` | a file's contents, in packets — see [Files](#files) |
| `0x09` | `LUA_RESULT` | `[0x09, id, more, bytes...]` | what `LUA_EVAL`'s Lua printed and returned, or its error, in packets — see [Lua console](#lua-console) |
| `0x07` | photo chunk | `[0x07, jpeg bytes...]` | part of a photo (Camera module) |
| `0x08` | photo end | `[0x08]` | last chunk; the photo is complete |
| `0x1F` | `REC_START` | `[0x1F, bits, rate / 1000, for]` | Recorder starts a recording — see [Recorder](#recorder); `for` = `1`: the Assistant listening, see [Assistant](#assistant) |
| `0x10` | `REC_DROP` | `[0x10]` | Assistant was left mid-question (a double tap): forget it, ask nothing, drop an answer on its way — see [Assistant](#assistant) |
| `0x05` | audio chunk | `[0x05, samples...]` | part of a recording |
| `0x06` | audio end | `[0x06, samples...]` | last part; the recording is complete |

`0x07` / `0x08` are the frame_msg `camera` library's codes, not this app's:
`modules/photo.lua` sends through its `capture_and_send()`, and the host
reassembles with `RxPhoto` and saves to `photos/`. The library must be
uploaded next to `data` (`upload_stdlua_libs(["data", "camera"])`).

**Do not use the library's `send_autoexp_result()` or
`send_metering_data()`**: they send `0x11` and `0x12`, the same codes as
`MENU_SELECT` and `MENU_CURSOR`.

`index` is **1-based**, as in Lua. In `MENU_SELECT`, `MENU_CURSOR`,
`MENU_OPEN` and `MENU_CLOSE` it is the position **within the current level**;
in `APP_START` / `APP_STOP` it is the module's number in tree order. Selecting
a submenu emits `MENU_SELECT` and then `MENU_LEVEL` with the new depth.

Launching an item emits `MENU_SELECT` and then `APP_START`; `APP_STOP` follows
when it stops, whether by going back to the menu, by a timeout, or because
another module was launched. A background module leaving the screen emits
`APP_BACKGROUND` instead, `APP_START` again when it comes back, and `APP_STOP`
only when it really stops.

Only `MENU_SELECT` is required. The rest are advisory: `MENU_CURSOR` is useful
if the host wants to show something in sync with the cursor (a preview, a hint),
and the others let the host track what is on screen.

> The code byte arrives **first in the payload**: the handler receives the whole
> message, not just the tail. Verified against `frame_msg.py:166`.

---

## Host services

### Plain-language summary

The glasses have no Internet and no phone of their own. While the Glaz app
on the phone is connected, it lends them both: notifications from the phone
pop up on the glasses, and an app on the glasses can ask the phone to fetch
a web page for it. Which apps may do that is up to the user, per app, in
Glaz > Menu.

### Notifications

`NOTIFY` (`0x24`) carries one notification as three lines: the app's name,
the title, the text. The phone turns everything into ASCII before sending —
the display font has nothing else — transliterating Cyrillic and dropping
what it cannot map, and cuts the text to 200 bytes.

On the glasses it covers whatever is on screen for `NOTICE_SECONDS` (5 s):
the app name in the top bar, the title in yellow, the text wrapped over the
four rows below. A tap dismisses it early, and that tap does nothing else.
What it covered keeps running and comes back. The last `NOTICE_KEEP` (10)
are kept for the Notifications module (Info > Notifications).

The glasses park in deep sleep only with no host connected, so a connected
phone always reaches them.

### Internet

A module asks through `_M.host`, which `frame_app.lua` gives every module
when it loads it:

```lua
local id, err = _M.host.http('GET', 'https://wttr.in/?format=%t')
-- later, from tick():
local status, body = _M.host.result(id)   -- nil while pending
```

On the wire the request is one text, `module\nMETHOD\nurl\nbody`, cut into
`NET_REQUEST` packets of at most `frame.bluetooth.max_length()` bytes:
`[0x19, id, more, bytes...]`, with `more = 0` on the last. `id` runs 1 to
255 and wraps. `module` is the file name in `modules/`, without `.lua` —
the name the phone checks the permission against.

The phone answers with one `NET_RESPONSE` (`0x25`): `id`, the HTTP status
and the body, cut to 4 KB because that is what fits next to the app in the
glasses' memory. Status `0` means the request never got an answer — no
permission is not one of those, that is a real `403`. The body then says
why, as text:

| Status | Body | When |
| --- | --- | --- |
| `403` | `not allowed: Glaz > Menu` | the module has no Internet permission, or the service is off |
| `400` | `bad request` | not `GET` or `POST`, or not an `http(s)` URL |
| `0` | the error | network error, or no answer within 15 s |

The glasses give up on their own after `NET_TIMEOUT` (20 s): `result()` then
returns `0, 'timeout'`. A module's requests are dropped when it stops.

`host_test.py` answers these too, so modules like Weather work from a
laptop. Its permission is the `FRAME_NET_ALLOW` environment variable: module
names, comma separated, or `*` (the default) for all.

The permission is per module, not per URL: a module that has it may fetch
anything. Modules are plain Lua the user installed, so one could pass
another's name; the permission is consent, not a sandbox.

### Photos

Camera and Time series send each JPEG as `0x07` chunks and a final `0x08`
(the frame_msg camera library). Right before each photo they send
`PHOTO_FROM` (`0x1A`): `[0x1A, 0]` from Camera, `[0x1A, series]` from Time
series, where `series` is 1 to 255 and new on every start of a series. It
also tells the phone a new photo begins, so a photo cut short is not glued
to the next one.

The phone rotates each photo upright (the sensor is mounted turned by 90
degrees) and files it by date:

```
photos/2026-10-14/2026-10-14 17-35-01-137.jpg   single shot, by time taken
photos/2026-10-14/2026-10-14 17-52-10/          a series, by time started
    2026-10-14 17-52-14-002.jpg                 ... its photos, by time taken
```

Every name is a date and time, down to the millisecond for photos, so the
names alone sort them and say when each was taken.

On Android `photos/` is the shared `Pictures/Glaz`, so the photos outlive the
app and show in the phone's gallery; elsewhere it is the app's own documents
folder (`flutter-glaz/lib/services/photo_dir.dart`).

A photo with the same `series` as the previous one, less than 10 minutes
after it, goes into the same folder; anything else starts a new one. The
counter lives on the glasses and restarts at 1 when they do, so the gap is
what keeps an old folder from being reused. A photo with no `PHOTO_FROM`
before it counts as a single shot.

### Recorder

Recorder (`modules/recorder.lua`) streams the microphone to the phone as it
records; the glasses keep nothing. A tap sends `REC_START`
(`[0x1F, bits, rate / 1000]`: 8 or 16 bits, 8 kHz), then the samples follow
as `0x05` packets and a final `0x06` when a tap stops it. `0x05` / `0x06` are
the frame_msg `audio` library's codes; the module sends them itself and does
not load the library.

Samples are mono PCM. 8-bit ones are signed, as the firmware gives them;
16-bit ones are little-endian. 8 kHz 8-bit is 8 KB a second, well within
the link; 16 kHz would not be. The firmware buffers about 2 s, and the
module empties it every tick -- also in the background, once a second -- so
a recording goes on with the screen elsewhere. What the link does not take
is dropped, and counted on the glasses' screen.

The phone writes the WAV as the sound comes in, and fixes its sizes at the
end, or when the glasses disconnect:

```
recordings/2026-10-15/2026-10-15 13-07-01.wav   by time started
```

On Android `recordings/` is the shared `Recordings/Glaz`. The Voice tab lists
them by day and plays them. The Recordings service (Services) turns saving
off.

**From the phone.** The Remote tab's record button sends `MODULE_CALL`
(`0x2D`) with `recorder\non` or `recorder\noff`. `MODULE_CALL` is generic:
`frame_app.lua` knows no module by name, it finds the one named and calls
its `remote(arg)` where it is: on screen, in the background, or -- not
running -- started straight into the background, so the screen stays as it
was (another background module is stopped for it: there is only one). A
module without `remote()` is not called. Recorder takes `on` and `off`. The sound comes back exactly as for a
tap. The phone shows the state the glasses report, not the one it asked
for: red from `REC_START` to `0x06` (or a disconnect), the button and a strip
over every screen with the time, a tap on the strip stops it; the glasses
show a red dot in the top bar while Recorder's `_M.rec` is true. A
background module that no longer wants the background -- Recorder after the
link cut a recording short -- is stopped at its next background tick.

### Assistant

Assistant (`modules/assistant.lua`) is the glasses' voice assistant. A tap
starts listening, the next stops it and asks; nothing guesses where a
question ends (a pause cut questions short). Leaving it -- a double tap --
drops the question: the glasses send `REC_DROP` (`0x10`) instead of the
end of the sound, and the phone asks nothing, or throws away the answer
if it already asked. The glasses stop on their own
only after 120 s. The sound streams as Recorder's does, 16-bit unless
Glaz > Menu > Assistant says 8 (8-bit was misheard), but `REC_START` has a
fourth byte, `1`, and the phone does not save it as a recording. What the
link did not take shows as `lost N KB` while listening.

The phone (`flutter-glaz/lib/services/assistant.dart`) transcribes it as it
comes, with ML Kit as for recordings but in a language of its own (Glaz >
Menu > Assistant; the recordings' until one is picked), and asks the agent: any server with
the OpenAI chat completions API -- Hermes Agent's API server on the user's
tailnet, model `hermes-agent` -- set in Glaz > Menu > Assistant. The phone
keeps the conversation, the last six questions and answers, and starts a new
one after ten minutes of silence. Hermes runs its own tools on its own host
and does not hand tool calls back, so what the glasses can do comes as
commands in the answer, each on a line of its own:

| Command | Does |
| --- | --- |
| `@open weather` | `APP_OPEN` (`0x2F`): the app on screen |
| `@notify text` | `NOTIFY` from "Assistant" |
| `@set weather.city=Minsk` | a module's setting, as in Glaz > Menu: only the settings it has, a choice only to one of its options |
| `@press ok` | `INPUT`: `ok`, `back`, `menu`, `left`, `right` |

Other commands bring the agent something instead -- tool calls, made in
text. The agent writes only them; the phone runs them and sends what they
bring as the next user message, photos as `image_url` parts with `data:`
URLs, which Hermes takes; then the agent answers the wearer. At most three
rounds a question; after that its last answer is what is shown.

| Query | Brings |
| --- | --- |
| `@photo` | a photo from the glasses now, as the Remote's photo button takes it (`PHOTO_TAKE`; Camera's size and quality, saved in Photos) |
| `@photos [day]` | the photos in Glaz, newest first, 20 at most: name and time; `day` is `today`, `yesterday` or `2026-10-17` |
| `@getphoto name` | one of them |
| `@recordings [day]` | the recordings, with their length and the start of the transcript |
| `@transcript name` | a recording's whole transcript, transcribed first if it was not |

Photos go upright: the phone turns them as their Exif says, which models do
not read (`withOrientation`). The conversation keeps the text of the
results, not the photos. Glaz > Menu > Assistant, Photos and recordings,
takes all of this away from the agent, prompt included.

The system prompt describes all the commands, with the installed apps,
their settings and what they are set to. The phone runs the commands, takes them out, and
sends the rest to the glasses as `APP_OPEN` `assistant` with an argument the
module takes in `start()` or `remote()`:

| Argument | Means |
| --- | --- |
| `stop` | stop listening and ask (`MODULE_CALL`) |
| `h:text` | what was heard; the agent is thinking (`MODULE_CALL`, only seen with Assistant on screen) |
| `a:text` | the answer |
| `e:text` | went wrong: no agent set up, no answer, nothing heard |
| `listen` | listen again |

Text is ASCII, Cyrillic transliterated, in lines of at most 26 characters,
24 lines at most. Five fit on screen (`_M.rows`); a longer answer shows four
a page and `- 1/4 -` under them, and a tilt turns the page. With an `@open` the answer
is not shown: the app it opened covers it. A tap on an answer asks again.

The answer is also read aloud, as the agent wrote it (Cyrillic and all),
in headphones only: before each answer the phone asks Android where speech
with these audio attributes would go (`getAudioDevicesForAttributes`), and
says nothing unless that is wired, USB or hearing-aid headphones, or a
Bluetooth device whose class says headphones or a headset -- never the
phone's loudspeaker, a Bluetooth speaker or a car. Headphones gone mid-
sentence (`ACTION_AUDIO_BECOMING_NOISY`) stop it; so do a new question and
a drop. Glaz > Menu > Assistant, Read answers aloud, turns it off: then
the glasses' screen only (`android/.../Voice.kt`).

`APP_OPEN` brings Assistant back to the screen for the answer even if the
wearer went elsewhere meanwhile. An answer to a question that was asked
again in between is dropped.

### Status

The phone shows the glasses' battery and firmware version. While the app
runs the REPL is blocked, so it cannot simply evaluate
`frame.battery_level()`; it sends `STATUS_GET` (`0x26`) instead, on connect
and every minute after. The payload is ignored, but it must not be empty:
`frame_ble`'s `sendMessage` sends nothing at all for an empty one.

The glasses answer `[0x1B, battery, version...]`: the battery as the same
smoothed percentage the top bar shows (255 before the first sample), then
`frame.FIRMWARE_VERSION` as text, for example `v25.080.0838`.

### Location

A module asks where the phone is:

```lua
local id = _M.host.locate()
-- later, from tick():
local fix, why = _M.host.location(id)   -- nil, nil while pending
-- fix = { lat, lon, accuracy, age }: degrees, metres, seconds since measured
```

On the wire `LOCATION_GET` (`0x1C`) is `[0x1C, id, module]`, the module's
file name, which the phone checks the permission against: Location access on
the module's page in Glaz > Menu, and the Location service in Services. The
phone answers one `LOCATION` (`0x28`), 14 bytes big-endian:

| Bytes | Field |
| --- | --- |
| 1 | `id` |
| 1 | status: `0` a fix, `1` not allowed, `2` no fix (location off, no permission on the phone, nothing within 10 s) |
| 4 + 4 | latitude, longitude, signed, in microdegrees |
| 2 | accuracy, metres |
| 2 | age of the fix, seconds |

Coordinates are zero unless status is `0`. `location()` turns the status
into `why`: `'not allowed'` or `'no fix'`; with no answer in `NET_TIMEOUT`
it is `'timeout'`. A module's requests are dropped when it stops.

The phone's own location permission is asked for when the Location service
is switched on in Services, never because of a request from the glasses:
those come when the phone may be in a pocket.

Weather uses it: with no city set it asks, and fetches the weather for
`lat,lon`; refused or without a fix, it lets wttr.in guess from the phone's
Internet address.

### Files

The phone can look at the files on the glasses while their app runs (Glaz >
Glasses > Files) -- the REPL is blocked then, so `frame_app.lua` answers:

- `FILES_GET` (`0x29`), `[id]` and a path, `''` for the root, is answered
  with `FILES` (`0x1D`): one line per entry, `d\tname` for a folder,
  `f\tsize\tname` for a file; `.` and `..` left out.
- `FILE_GET` (`0x2A`), `[id]` and a path, is answered with `FILE_DATA`
  (`0x1E`): the file's text.

Both answers come in packets `[code, id, more, bytes...]`, `more = 0` on the
last, and start with `+`, or with `-` and the error (no such file, say).

The firmware reads files a line at a time and drops the `\n`; the glasses
send each line with a `\n` after it, as they read it, never holding the
whole file -- `frame_app.lua` alone is over 50 KB. The main loop waits while
a file goes out, so a file stops at `FILE_MAX` (64 KB) with a
`... cut at 65536 bytes` line. Viewing only: nothing is written or removed.

### Lua console

The phone can run Lua on the glasses while their app runs (Glaz > More >
Lua console) -- the REPL is blocked then, so `frame_app.lua` runs it, in
`app/glaz_lua.lua`, loaded for the request:

- `LUA_EVAL` (`0x30`), `[id]` and the Lua, is answered with `LUA_RESULT`
  (`0x09`), in packets as in [Files](#files), `+` and the text, or `-` and
  the error.
- The Lua is tried with `return ` in front first, so an expression answers
  with its value: `frame.battery_level()` gives `100`. What it `print()`s
  comes first, one line each, then each value it returns; a table shows
  its first 40 entries, one level deep. The answer stops at 8 KB.
- It runs in the app's globals: `frame.*`, the libraries, and the globals
  of earlier requests, which stay. The app's own locals are out of reach.
  It runs on the main loop, which waits for it; Lua that never ends hangs
  the app, as it would in the REPL.
- What it draws stays on screen until the app draws again.

Completion asks the glasses too: the names in a table (`_G`, `frame`,
`frame.display`...) are one `LUA_EVAL`, kept until the next Run.

**From a computer.** With *Open to a computer* on, the phone also listens
on its own loopback, `127.0.0.1:8137`: `POST /lua` with the Lua as the body
(200 and the answer, 422 and the error, 503 when there is no answer), and
`GET /complete?q=frame.disp`, one name a line. Nothing on the network
reaches it; `adb forward` does. `utils/phone_lua.py` does both: a command,
stdin, or an interactive prompt with Tab completion. The glasses stay
connected to the phone the whole time.

### Remote

The phone has a remote for the glasses (Glaz > Remote): arrows, OK, Back
and Menu. Each press is one `INPUT` (`0x2B`), and the glasses take it as the
wearer's own gesture, through the same code:

| Press | `INPUT` | Same as |
| --- | --- | --- |
| up, left | `[2, 255]` | a tilt toward the left shoulder: previous item |
| down, right | `[2, 1]` | a tilt toward the right shoulder: next item |
| OK | `[1, 1]` | a single tap: select, or bring back the last app |
| Back | `[1, 2]` | a double tap |
| Menu | `[1, 3]` | show or hide the menu (a triple on the arm is sleep instead) |

Taps go into the tap counter as a finished gesture, classified at once
(no waiting out the multi-tap window), and do not fall under the mute that
follows a triple tap. A tilt reaches the menu's cursor, or the running
module's `on_roll`, exactly where a head tilt would; with neither on screen
it does nothing. Either counts as activity, keeping the menu or an app up.

**While the Remote tab is in front** the phone sends `HANDS_OFF` `[1]`, so
the glasses do not also react to the wearer's head and fingers: tilts are
not read (the IMU is not polled), raw hits do not reach `on_hit`, and taps
on the arm count only as a triple tap -- sleep, always reachable -- or as
one or two taps on a blank screen: bringing back the last app, opening the
menu or dismissing a notification. Taps from the remote work as before. Leaving the
tab, or the app leaving the screen, sends `[0]`; the phone sends `[1]` again
on every connect while the tab is open. The glasses drop it themselves the
moment Bluetooth goes, so a lost phone never leaves them deaf. The user can
turn it off: Glaz > More > Settings, Glasses gestures off.

**A keyboard is a remote too** (`flutter-glaz/lib/services/keys.dart`, the
Keyboard remote service). Any keyboard the phone has -- Bluetooth or USB, a
presentation clicker, a gamepad's D-pad, a Flipper Zero in Bluetooth Remote
> Keynote -- sends the same `INPUT`s: arrows, Page Up/Down and the track
keys move the cursor; Space, Enter or the D-pad centre select, held 0.6 s
they open the menu; Backspace or Esc go back; Menu or Start open the menu.
Only while the glasses are connected and no text field has the focus, and
only with the app on screen: Android gives key events to the foreground
app. Keynote's Back sends Backspace and then Android's Back; the second is
dropped so it does not also close the app.

**In the background** too, once the user turns on Glaz keyboard remote in
Android's Accessibility settings (Glaz > Services has a button for it):
`KeyRemoteService.kt` filters the keys before any app gets them. With Glaz
on screen it lets them through to Flutter as above; otherwise, while the
glasses are connected and the service is on, it takes the keys listed above
from whatever app is in front and hands them to `keys.dart` on the
`glaz/keys` channel, which turns them into the same `INPUT`s. Keynote's
echoed Back is dropped there too. Other keys, and all keys while the glasses
are away, pass untouched. It needs the app alive with its Flutter engine:
swiped away from the recent apps, Glaz stops taking keys.

The remote also takes photos: `PHOTO_TAKE` (`0x2C`) carries the size and the
quality, the same two settings as Camera's (the phone shares them). The
glasses load the camera library for it, give auto exposure 1.5 s, send
`PHOTO_FROM 0` and the photo as Camera does, so it lands in Photos with the
single shots, and switch the camera off again unless a module still uses it.
The main loop waits meanwhile.

### Settings

Some modules have settings the user picks on the phone (Glaz > Menu, tap a
module): Camera's resolution and quality, Time series' starting interval,
Weather's city and country. The phone sends **all** of them in one
`SETTINGS_SET` (`0x27`) on every connect and shortly after each change, one
line each, defaults filled in:

```
photo.resolution=512
photo.quality=HIGH
timeseries.interval=4
weather.city=Minsk
weather.country=BY
```

The glasses replace what they had with it and write the text to
`settings.txt`, so the settings hold after a reboot without the phone. A
module reads one with `_M.host.setting(key, default)`: the default when it
is unset or empty, converted to a number when the default is one. Modules
read them when they need them -- at a shot, at a fetch -- so a change
applies from the next one and nothing restarts. Values are UTF-8 (a city may
be in Cyrillic); a module that shows one must make it ASCII first.

### Codes the glasses do not know

`frame_app.lua` drops a message with a code it has no parser for. Without
that, `data.lua` prints `Error: No parser for flag` and keeps the message,
so the print repeats on every pass of the main loop and each one goes out
over Bluetooth -- a phone newer than the app on the glasses flooded the link
that way (seen: thousands of notifications a minute after `SETTINGS_SET`
reached an older app), and its own requests drowned. The phone also stops
waiting for a folder listing after 8 s and says to Upload.

### One message per code at a time

`data.lua` on the glasses keeps one finished message per code until the
main loop collects it, so a second `NOTIFY` arriving before the loop runs
would overwrite the first. The phone therefore sends one message at a time
and waits 200 ms after each before the next of the same code.

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

The display is 640 × 400 and a row is 55 px. The top bar takes the top row
at `y = 10`, and **5 items fit** below it. Longer lists scroll within a window
with no position counter; the cursor alone shows where you are.

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

The layout puts the breadcrumb at `y = 10` and list rows at `y` = 65, 120,
175, 230, 285 — five rows, the last one finishing near 326 with a glyph height
near 41 px, inside the bound. A sixth row would land at 340: past the measured
limit. (The old layout, without a breadcrumb, used 30 … 250.)

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
7. `send_message(0x23, ...)` — the wall clock for the top bar
8. optionally `send_message(0x20, ...)` to override the module menu

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

- **host-defined trees** — `MENU_SET` is still one flat level; a host can
  nest by answering `MENU_SELECT` with a new `MENU_SET`, but gets no
  breadcrumb for it
- **submenus from modules** — let a module return a list instead of a string
- **camera settings** — resolution and quality picked by tilt, as in
  Brightness; `modules/photo.lua` has them fixed (512 px, `MEDIUM`)
- **module-defined host actions** — a module that only emits an event, leaving
  the work to whichever host happens to be connected

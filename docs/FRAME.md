# Brilliant Labs Frame — connecting and working with the glasses

## Plain-language summary

Frame is a pair of glasses with a tiny computer inside. It has a display
(projected into the right lens), a camera, a microphone and a motion sensor.
The computer understands **Lua**. From a laptop we send snippets of Lua over
**Bluetooth**, and the glasses execute them: draw text, take photos, record
audio.

Two ways to work:

1. **Live commands** — send code line by line, the glasses run it immediately.
   Good for experiments.
2. **Resident app** — upload a `main.lua` to the glasses; it starts on its own
   and runs without a laptop.

---

## Hardware status (verified 2026-10-13)

| Field | Value |
| --- | --- |
| Device | `Frame AA` |
| MAC | `FF:EE:DD:CC:BB:AA` (as shown by AR Studio); BlueZ/macOS: `AA:BB:CC:DD:EE:FF` |
| Firmware | `v25.080.0838` |
| MTU | 243 bytes |
| Display | 640 × 400, 16 colors |
| Camera | up to 720 × 720 |
| Microphone | 8000 / 16000 Hz, 32 KB buffer |

---

## Environment

Already set up in this repository:

```bash
python3 -m venv .venv
.venv/bin/pip install frame-ble frame-msg
```

- `frame-ble` — low level: BLE connection, sending Lua strings.
- `frame-msg` — application level: images, audio, IMU and rasterized text as
  typed objects instead of hand-rolled byte wrangling.

Run anything with `.venv/bin/python <file>.py`.

> On first run macOS asks the terminal for Bluetooth permission. If a script
> hangs silently, check *System Settings → Privacy → Bluetooth*.

---

## Quick connect

**Glasses connected to the phone?** Leave them there: the Glaz app's Lua
console runs Lua inside the app on the glasses, and with *Open to a
computer* on, a laptop reaches it over adb
([`utils/phone_lua.py`](../utils/phone_lua.py), docs/PROTOCOL.md, "Lua
console"):

```bash
python utils/phone_lua.py 'frame.file.space()'
```

Straight over Bluetooth instead, with the phone off the glasses:
[`utils/connect.py`](../utils/connect.py).

```bash
.venv/bin/python utils/connect.py
```

Minimal version:

```python
import asyncio
from frame_ble import FrameBle

async def main():
    frame = FrameBle()
    await frame.connect()                     # finds Frame and pairs
    await frame.send_lua(
        "frame.display.text('Hello', 50, 137);frame.display.show();print(nil)",
        await_print=True,                     # wait for the reply, else you race
    )
    await frame.disconnect()

asyncio.run(main())
```

To read a value back, wrap it in `print(...)` and wait:

```python
battery = await frame.send_lua("print(frame.battery_level())", await_print=True)
```

---

## Checklist when it will not connect

1. **The glasses are asleep.** Frame sleeps on its own. Wake it — tap the arm
   or put the glasses on.
2. **Battery.** `frame.battery_level()`. Below ~10% the link drops. Charge in
   the case.
3. **Another host holds them.** Frame accepts **one** connection. Close AR
   Studio in VS Code, the Noa phone app, other Python scripts.
4. **macOS Bluetooth permission** (see above).
5. **Broken bond.** Frame requires BLE bonding. If you moved to another host,
   reset the glasses with the pinhole button **on the charging dock** and
   remove the old pairing in Bluetooth settings. Detailed walkthrough below.
6. **A script is stuck on the glasses.** Send the break signal — a single
   `0x03` byte aborts the running script. `0x04` clears variables and restarts
   `main.lua`.

---

## Draining to zero breaks the pairing (hit in practice)

**Symptom.** The glasses are visible on air, but connecting fails:

```
Error connecting: failed to connect: Error Domain=CBErrorDomain Code=15
"Failed to encrypt the connection, the connection has timed out unexpectedly."
```

Reproduces every attempt.

**Cause.** The glasses drained to 0%, reset, and lost their half of the BLE
bond. macOS still remembers its half and tries to encrypt with the stale key;
the glasses reject it and the handshake times out.

**Diagnosis.** If macOS remembers the device while connecting fails with
Code=15, this is it:

```bash
system_profiler SPBluetoothDataType | grep -iA2 frame
# Frame AA:
#     Address: AA:BB:CC:DD:EE:FF        <- MAC reversed relative to
#                                          what AR Studio shows
```

**Fix** (retrying does not help, this needs hands):

1. Open the Bluetooth pane:
   `open "x-apple.systempreferences:com.apple.Bluetooth-Settings.extension"`
2. `Frame AA` → (ⓘ) → **Forget This Device**. If it is not listed, enable
   "Show all devices" — macOS hides BLE-only hardware.
3. Reset the glasses through the pinhole button — it is on the **Mister Power
   charging dock**, not on the frame itself.
4. Reconnect and **accept the system pairing prompt**.

Confirm the bond is gone: the same `system_profiler` command should find
nothing.

**Prevention:** do not let the battery hit zero.

---

## Connecting from Linux / NixOS (hit 2026-10-14)

**In short:** the laptop's Bluetooth worked, but the glasses were not on air.
Everything below follows from that.

1. **No Python deps outside devenv.** There is no `.venv` in the repo, so
   `python3 utils/connect.py` fails with `No module named 'frame_ble'`. Use
   `devenv shell`, or a throwaway venv from the system `python3`:
   `python3 -m venv /tmp/venv && /tmp/venv/bin/pip install -r requirements.txt`.
   On NixOS that venv's pip wheels (numpy, pulled in by `frame-msg`) fail with
   `libstdc++.so.6` / `libz.so.1: cannot open shared object file`. Point them
   at the nix libraries (`utils/connect.py` only needs `frame-ble` and works
   without this):

   ```bash
   export LD_LIBRARY_PATH=$(nix build --no-link --print-out-paths \
     nixpkgs#stdenv.cc.cc.lib)/lib:$(nix build --no-link --print-out-paths \
     nixpkgs#zlib | grep -v dev)/lib
   ```
2. **`devenv shell` can be busy/slow.** A parallel `devenv shell` (e.g. a
   Flutter build) makes a second one slow; the venv above avoids it.
3. **Wrong MAC for BlueZ.** The table above lists the AR Studio form
   `FF:EE:DD:CC:BB:AA`; BlueZ uses the reversed `AA:BB:CC:DD:EE:FF`.
   `bluetoothctl info 15:08:...` says "not available" even when all is fine.
4. **"Settings sees Frame AA" does not mean it is on air.** GNOME Settings and
   `bluetoothctl devices` list the **cached** device. Check that it is live:

   ```bash
   bluetoothctl info AA:BB:CC:DD:EE:FF | grep RSSI   # no RSSI -> not heard
   bluetoothctl --timeout 30 scan le | grep -i frame
   ```

   A `[DEL] Device AA:BB:CC:DD:EE:FF Frame AA` line in the scan means BlueZ
   just dropped the stale cache entry — the glasses are *not* advertising.
5. **`connect()` gives up after 10 s.** `FrameBle.connect()` scans 10 s for the
   Frame service UUID and raises `No matching Frame device found`. A sleeping
   or low-battery Frame advertises rarely; run `utils/wait_for_frame.py` (scans
   up to 180 s) first, then connect.

6. **Pairing has to happen from the script, not from GNOME Settings.**
   After pairing in Settings the first connect from Python succeeded at the
   BLE level, then the glasses dropped the link and BlueZ cleared the bond
   (`Paired: no`). frame_ble then crashes with
   `AttributeError: 'NoneType' object has no attribute '_backend'` -- its
   disconnect handler sets `_client = None` mid-`connect()`. Pairing from
   Settings again gave `org.bluez.Error.AuthenticationCanceled`, and
   `bluetoothctl pair` with a `NoInputNoOutput` agent got no answer.
   What worked: `bluetoothctl remove AA:BB:CC:DD:EE:FF`, put the glasses in
   pairing mode, then connect with bleak's `BleakClient(..., pair=True)`.
7. **A half-done upload leaves `loading...` on the display.** `host_test.py`
   deletes `main.lua` before it writes the files. If a write fails (seen once:
   `GATT Protocol Error: Unlikely Error` on the first chunk), the glasses
   sit in a bare REPL with `loading...` on screen. Nothing is broken; run the
   upload again.

8. **The glasses drop the link on start, saying nothing: the watchdog.**
   The firmware's `require()` reads a file a byte at a time and grows its
   buffer by one byte a time with `realloc` (`lua_file_require` in
   `file.c`), unchecked, and no Lua runs meanwhile. The watchdog is fed
   only from Lua's hook, every call and 2000 instructions, and resets the
   glasses after 6 s (`watchdog.c`). The app's 19 KB of bytecode took 1 to
   3 s, longer the more broken up the heap, and sometimes past 6 s. So
   `main.lua` on the glasses is a loader (`app/glaz_boot.frame.lua`, which
   starts `app/glaz_boot.lua`): it replaces `require()` with one that reads
   512 bytes at a time through `frame.file` into `load()`, and loads the
   app, `glaz_app.lua`. Also:
   about 135 KB of heap is Lua's in all (measured: filled until 'not
   enough memory'); the app starts at about 89 KB.
9. **BlueZ keeps the link after a script is killed.** Once bonded, the link
   can stay up (`bluetoothctl info` says `Connected: yes`) after the Python
   process dies. A connected Frame does not advertise, so the next scan finds
   nothing. Run `bluetoothctl disconnect AA:BB:CC:DD:EE:FF` first.
10. **`GATT Protocol Error: Unlikely Error` on the reset signal** -- the
   glasses reboot before acknowledging the write. Just run the upload again.
11. **The app ran the glasses out of memory on start** ("not enough memory",
    or a reboot to "Frame is paired" right after Upload). Three causes,
    measured on a laptop with the same code:
    - `require()` holds the whole source while compiling it: the firmware
      reads the file into one buffer, a byte at a time, and frees it only
      after `luaL_loadbuffer` (`lua_file_require` in `file.c`).
      `glaz.lua` is 60 KB, two thirds comments.
    - Compiled code keeps debug information: `glaz.lua` loaded is
      66 KB, without it 19 KB.
    - All fifteen modules stayed loaded: 70 KB, more than the app.

    The Glaz app's Upload now minifies every file (comments and indentation
    out, line breaks kept: `flutter-glaz/lib/frame/lua_min.dart`), then has
    the glasses compile each one to bytecode without debug information while
    their memory is free (`glaz_compile` in `upload.dart`, since dropped:
    see below); and `glaz.lua` loads a module only while it is on screen or in the
    background (`load_module`). Start went from 168 KB to 105 KB. Bytecode
    built with the app (`tool/luac_frame.c`) drops only local variables'
    names: errors keep the file and line, `glaz.lua:1234: ...`, about
    3 KB more for main. `host_test.py` still sends source as it is.

    Then main.lua itself grew past what the glasses could compile in one
    go, even first thing after a reset ("not enough memory" at "Compiling
    main.lua"). Its larger, separable parts moved to `app/`: the services
    (`glaz_host.lua`, loaded at start but compiled on its own), and file
    browsing, the remote's photo and the splash (loaded only when used).
    Compiled with debug information main.lua went from 71 KB to 57 KB.

    In the end the glasses compile nothing. Every build of the phone app
    carries bytecode for every file (`tool/compile_lua.sh`: apk, linux-app,
    the Nix package, CI), and the app itself could no longer be compiled
    there anyway. A file without bytecode -- edited since the build --
    goes up as text, and glaz's `require()` loads it as text; the app
    alone must be bytecode, and Upload stops before it starts when it is
    not (`needBytecode` in `upload.dart`).

    Upload sends only what changed. The glasses hash each file they have
    (FNV-1a over what `read()` gives, `glaz_check` in `upload.dart`) and
    compare it with what the upload would write; files that match stay,
    main.lua included (moved aside as `glaz_prev.lua` while the upload
    runs). Text is compared as text, bytecode as bytecode.
12. **Many small `mono` sprites reboot the glasses.** Each
    `frame.display.text` glyph, `bitmap` or `mono` sprite is queued in the
    FPGA until `show()`. Measured with the first `mono` (a sprite a call),
    one-character calls: 100 a frame, three frames, fine; 150 a frame for
    three frames, or more, and the glasses rebooted (the next answer came
    from glasses a few seconds after boot). 150 in a single frame was fine,
    and `text`, 150 one-letter calls a frame for three frames, was fine
    too. 200 full rows with no `show()` rebooted them as well, 28 full rows
    then `show()`, ten times over, did not. The cause is not known; the
    watchdog is fed from Lua on every call, so a hang inside one C call
    is the likeliest. `mono` now sends a sprite a color, not a cell
    (`attrs`); call `show()` after every screen.

The working recipe used both workarounds: find Frame by address with a long
scan, and pair on connect. Both are monkey-patches around frame_ble 1.1.1, which
has no options for them:

```python
from bleak import BleakScanner
import bleak

_find = BleakScanner.find_device_by_filter
async def by_address(_f, timeout=10, **_kw):
    return await _find(lambda d, _a: d.address == "AA:BB:CC:DD:EE:FF", timeout=180)
BleakScanner.find_device_by_filter = staticmethod(by_address)

_init = bleak.BleakClient.__init__
def init(self, *a, **k):
    k.setdefault("pair", True)
    _init(self, *a, **k)
bleak.BleakClient.__init__ = init
# ...then run host_test.py / utils/connect.py as usual
```

If the glasses still do not show up with an RSSI: they are in deep sleep
(tapping does not wake it — put them on the charger and take them off),
connected to the phone app (one connection only), or flat.

---

## BLE specification (needed only to write your own client)

| What | UUID |
| --- | --- |
| Service | `7A230001-5475-A6A4-654C-8431F6AD49C4` |
| TX (host → glasses) | `7A230002-5475-A6A4-654C-8431F6AD49C4` |
| RX (glasses → host) | `7A230003-5475-A6A4-654C-8431F6AD49C4` |

Rules:

- A UTF-8 string on TX is Lua source, executed immediately.
- A leading `0x01` byte marks raw data, delivered to
  `frame.bluetooth.receive_callback()`.
- Packet limit is the MTU (27–251 bytes; 243 here); raw data gets 4 bytes less.
  Query it with `FrameBle.max_lua_payload()` or `frame.bluetooth.max_length()`.
- `0x03` aborts the running script. `0x04` resets.
- Firmware mode: `frame.update()`; the device then advertises as
  `Frame Update` and times out after 5 minutes.

---

## Lua API cheat sheet

### Display (640 × 400)

> ⚠️ **The published docs lag behind the firmware.** In `v25.080.0838` there is
> **no** `frame.display.clear()` — calling it fails with
> `attempt to call a nil value (field 'clear')`. The buffer resets itself after
> `show()`. The list below was obtained by introspecting the live device.

```lua
frame.display.text(str, x, y, {color='WHITE', spacing=4})
frame.display.mono(str, x, y, {size=24, bold=false, color='WHITE', bg=nil, attrs=nil})  -- ours, glaz/main
frame.display.bitmap(x, y, width, color_format, palette_offset, data)  -- format: 2|4|16
frame.display.show()            -- nothing appears without this
frame.display.assign_color(color, r, g, b)
frame.display.assign_color_ycbcr(color, y, cb, cr)
frame.display.set_brightness(b) -- -2 .. 2
frame.display.power_save(bool)
frame.display.write_register(addr, value)
```

Palette (16 colors): `VOID, WHITE, GREY, RED, PINK, DARKBROWN, BROWN, ORANGE,
YELLOW, DARKGREEN, GREEN, LIGHTGREEN, NIGHTBLUE, SEABLUE, SKYBLUE, CLOUDBLUE`.

**Cyrillic renders on our firmware** (`v26.292.2200-glaz-cyr` and later
builds from branch `glaz/main`, docs/FIRMWARE.md): `frame.display.text('Привет')`
draws it. The font has ASCII, Latin-1, Cyrillic U+0400..U+045F with the
extra letters of Kazakh, Tatar and others, and `«» ° № €`. Strings are
UTF-8, so `#s` counts bytes: use `utf8.len(s)` for characters. On the stock
firmware the font is ASCII only and Cyrillic stays blank. The source of a
Lua file must still be ASCII (see "Known gotchas"); write `'\xD0\x9F'` in
it, or send the text at run time.

### Camera

```lua
frame.camera.capture{resolution=512, quality='VERY_HIGH', pan=0}
frame.camera.image_ready()      -- poll for readiness
frame.camera.read(num_bytes); frame.camera.read_raw(num_bytes)
frame.camera.auto{metering='CENTER_WEIGHTED', exposure=0.1}
frame.camera.set_gain(v); frame.camera.set_shutter(v); frame.camera.set_white_balance(v)
frame.camera.power_save(bool); frame.camera.read_register(a); frame.camera.write_register(a, v)
```

> In `v25.080.0838` the method is `set_shutter`, not `set_exposure` as the docs
> claim.

### Microphone

```lua
frame.microphone.start{sample_rate=8000, bit_depth=8}
frame.microphone.read(num_bytes)
frame.microphone.stop()
```

### Motion sensor

```lua
frame.imu.direction()           -- roll, pitch, heading
frame.imu.tap_callback(handler) -- tap on the arm
frame.imu.raw()
```

**Two of the three axes work.** Measured on device:

| Axis | Head movement | State |
| --- | --- | --- |
| `pitch` | nod up / down | works — rests at ≈ −35°, swings −31…−46° |
| `roll` | tilt toward a shoulder | works — ±30° swing, ±4° noise |
| `heading` | turn left / right (yaw) | **dead — always `0.0`** |

`heading` is unusable because the magnetometer's Z axis is railed: `frame.imu.raw()`
returns a constant `8191` for `compass.z`, which is exactly `2^13 - 1`, the
maximum of a 14-bit signed value. X and Y vary normally.

This is not a firmware quirk that might be worked around. Roll and pitch are
derived from the gravity vector the accelerometer provides; yaw cannot be, which
is what a working three-axis magnetometer is for.

See [`PROTOCOL.md`](PROTOCOL.md) for how menu navigation is calibrated around
this.

### Bluetooth, glasses side

```lua
frame.bluetooth.send(data)
frame.bluetooth.receive_callback(handler)
frame.bluetooth.max_length()     -- 243 here
frame.bluetooth.address()
frame.bluetooth.is_connected()   -- present in firmware, absent from the docs
```

### Files

```lua
f = frame.file.open('data.txt', 'write')   -- 'read' | 'write' | 'append', full words only
f:write(data); f:read(n); f:close()
frame.file.remove(name); frame.file.rename(a, b)
frame.file.listdir(); frame.file.mkdir(name)
```

> Lua's standard `io` and `os` libraries are **not** present on Frame.

### System

```lua
frame.battery_level()     -- 1..100
frame.sleep(seconds)      -- or until tapped
frame.stay_awake(true)    -- development mode: do not sleep
frame.time.utc(ts); frame.time.zone('-7:00'); frame.time.date(ts)
frame.compression.decompress(data, block_size)   -- LZ4
frame.update()
frame.FIRMWARE_VERSION; frame.HARDWARE_VERSION; frame.GIT_TAG
```

`frame.time.utc()` counts monotonically from boot and works even when the clock
was never set — usable for timeouts.

---

## The menu app

A working in-glasses menu lives in [`glaz.lua`](../glaz.lua), driven by
the reference host [`host_test.py`](../host_test.py). The wire protocol and the
design rationale are in [`PROTOCOL.md`](PROTOCOL.md).

```bash
.venv/bin/python host_test.py
```

Tap the arm to summon the menu, tilt your head to scroll, tap to select. It
auto-hides after 10 seconds of inactivity.

---

## Apps on the glasses (`main.lua`)

`main.lua` runs on every power-on. Uploading is done either with
`FrameBle.upload_file()` or through the **Brilliant AR Studio** VS Code
extension; the file mapping lives in `studio/.brilliant/device-files.json`
(`/main.lua` ← `main.lua`).

To stop a running app and get the live REPL back, send the break signal
(`0x03`).

### Restart

An error the app does not catch ends it, and the link stays up: the phone
shows the glasses connected, but nothing answers taps, the remote or the
phone, and the firmware puts "Frame is paired" on screen (or the screen
stays dark). An error in a tap or Bluetooth callback does the same: the
firmware raises it again in whatever Lua was running, the app's main loop.

So the loader, `app/glaz_boot.lua`, starts the app again. The main loop
passes on every error but the break signal (`glaz.lua`, the end of
`app_loop`); the loader then drops the globals the app set and its tap
and Bluetooth callbacks, so the old app is freed before the new one
loads, prints the error (the phone's Log, Glasses, has it), keeps it in
`crash.txt` on the glasses (`<utc> <error>`, the last one only), shows
"restarted" for a second and starts the app. More than three restarts in
a minute and it stops there, as before: an app that fails on start would
only fail again. After a break signal there is no restart.

Restarting hides a bug; it does not fix it. Look for the error in the Log
or `crash.txt`.

---

## Known gotchas

- **The docs lag behind the firmware.** Before trusting the website, ask the
  device:

  ```python
  await frame.send_lua(
      "local t={} for k,v in pairs(frame.display) do t[#t+1]=k end "
      "table.sort(t) print(table.concat(t,' '))", await_print=True)
  ```

  (`pairs(frame)` at the top level does not work — `frame` is userdata; only
  submodules such as `frame.display` and `frame.camera` can be iterated.)

- **`frame.display.clear()` is gone.** Removed in `v25.080.0838`.
- **No Cyrillic in the stock font.** ASCII only; our firmware adds it
  (see "Display").
- **`frame.display.show()` is mandatory.** Draw text, forget `show()`, and you
  will spend half an hour hunting a Bluetooth bug that does not exist.
- **Lua errors come back as ordinary replies, not exceptions.** A string like
  `attempt to call a nil value` is returned by `send_lua()` as text — check the
  result, not just the absence of a traceback.
- **Lua files for upload must be ASCII.** `upload_file()` chunks by characters
  but checks the MTU in bytes, so non-ASCII comments break the upload with
  `payload length is too large`. A `frame_ble` bug; analysis in
  [`PROTOCOL.md`](PROTOCOL.md).
- **The Lua string length is capped by the MTU.** A long script will not fit in
  one send: split it, upload it as a file, or use `frame-msg`.
- **`await_print=True` without a `print(...)` in the Lua** hangs forever — the
  glasses never reply.
- **One connection at a time.** AR Studio in VS Code quietly takes the glasses.
- **Flat glasses behave like broken glasses** — the link drops for no apparent
  reason. Check the battery before you debug the code.

---

## Layout

```
glaz.lua           the application that runs on the glasses (glaz_app.lua)
glaz.frame.lua     its part for Frame: the screen (docs/DEVICES.md)
glaz.halo.lua      its part for Halo
app/               parts of glaz.lua in files of their own; glaz_boot's
                   part for the glasses is main.lua there
modules/           one Lua file per menu item, and its parts
host_test.py       reference host: uploads everything, then listens
check.sh           syntax, ASCII and unknown-global checks, no device needed
docs/              FRAME.md, PLATFORM.md, PROTOCOL.md
utils/             diagnostics, run individually as needed
  connect.py         smoke test: connect, report hardware, draw text
  wait_for_frame.py  keep scanning until the glasses start advertising
  calibrate.py       find the visible area of the display
  calibrate_roll.py  measure roll noise and gesture amplitude
```

---

## See also

- [`PLATFORM.md`](PLATFORM.md) — development model, chips and sensors, the
  single-bond connection model, camera bandwidth limits, and what can and
  cannot brick the device.
- [`PROTOCOL.md`](PROTOCOL.md) — the menu app's wire protocol and design notes.

---

## Sources

- [Frame SDK](https://docs.brilliant.xyz/frame/frame-sdk/)
- [Frame SDK for Python](https://docs.brilliant.xyz/frame/frame-sdk-python/)
- [Lua API Reference](https://docs.brilliant.xyz/frame/frame-sdk-lua/)
- [Talking to Frame Over Bluetooth](https://docs.brilliant.xyz/frame/frame-sdk-bluetooth-specs/)
- [frame-ble API docs](https://frame-ble-python.readthedocs.io/)
- [frame_examples_python](https://github.com/CitizenOneX/frame_examples_python)

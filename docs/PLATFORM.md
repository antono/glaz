# Frame platform notes

Background research on the development model, the hardware, the connection
model, the camera, firmware updates, and how much of this can be broken
permanently. Operational how-to lives in [`FRAME.md`](FRAME.md); the menu app's
own protocol is in [`PROTOCOL.md`](PROTOCOL.md).

Claims are marked where the documentation is silent and something is inferred
or measured rather than quoted.

---

## Plain-language summary

Frame has two chips inside. One is an ordinary little ARM processor that runs
Lua and talks Bluetooth — that is the one our code runs on. The other is an
FPGA, a chip whose circuitry is defined in software, and it drives the display
and the camera.

The important practical consequences: only **one** device can be paired at a
time; the camera sends photos over Bluetooth slowly, so resolution costs
seconds; and the FPGA cannot be reprogrammed from Lua at all, which means the
easy ways of experimenting cannot permanently break the glasses.

---

## Development model

The device runs a Lua interpreter. Two ways to work:

- **Live** — send Lua strings over BLE, executed immediately. A running app
  owns the interpreter, so the break signal (`0x03`) must come first.
- **Resident** — upload files to flash. Only **`main.lua`** auto-runs on
  power-on and after a reset; anything else has to be `require()`d.

Files persist in flash across power cycles. `require` works for uploaded
modules, which is what lets the menu split into one file per item.

Lua's standard `io` and `os` libraries are absent. There is no package manager
and no filesystem access from the host except through Lua calls — uploading is
literally a sequence of `f:write(...)` statements, which is why it is slow and
why a dropped connection leaves a half-written file.

---

## Hardware

| Part | Model | Notes |
| --- | --- | --- |
| MCU | Nordic **nRF52840** | 32-bit Cortex-M4F @ 64 MHz, 1 MB flash, 256 KB RAM, Bluetooth 5.3 |
| Co-processor | Lattice **Crosslink-NX LIFCL-17** FPGA | graphics acceleration and camera interface |
| Camera | **OV09734** | 720p |
| Microphone | TDK **ICS-41351** MEMS | dynamic range −35.5 dB to 129.5 dB |
| IMU | **MC6470** | 6-axis: accelerometer + e-compass |
| Power | **MAX77654** PMIC | 2 × 105 mAh cells = 210 mAh |
| Dock | "Mister Power" | 140 mAh, holds the pinhole reset button |

The nRF52 "is designed to handle the overall system operation, running Lua,
handling Bluetooth networking, AI tasks and power management"; the FPGA
"handles acceleration of the graphics and camera".

> ⚠️ From the hardware manual: "Do not try to remove the battery as the
> terminals can become shorted and result in the battery overheating or
> catching fire."

### Sensor reality check

The IMU is a 6-axis part — accelerometer plus magnetometer, **no gyroscope**.
That matters: roll and pitch come from the gravity vector, and yaw would have
to come from the magnetometer.

Measured on this unit (firmware `v25.080.0838`):

| Axis | Movement | State |
| --- | --- | --- |
| `pitch` | nod | works; rests near −35°, not 0 |
| `roll` | tilt to a shoulder | works; ±30° swing |
| `heading` | turn the head | **always `0.0`** |

`frame.imu.raw()` returns `compass.z` pinned at `8191` — exactly `2^13 - 1`,
the top of a 14-bit signed range, i.e. a railed axis. With the magnetometer
unusable there is no way to recover yaw, because gravity alone does not
constrain rotation about the vertical. **Two usable axes, not three.**

---

## Host connection

Frame "uses BLE bonding and must pair with a host device before any
communication can take place". The SDK triggers pairing automatically and the
OS prompts the user.

### Can two hosts connect at once?

**No, in practice — and the documentation does not even discuss it.** What the
docs do say points one way:

> "Frame must be reset using the pinhole button on the charging dock before it
> can be paired to a new host side device."
>
> "Host-side devices must also remove previous bonding before a new bonding can
> be accepted."

That is a single-bond model: switching hosts is a deliberate, physical act, not
a connection-time choice. *(Inferred, not stated: a connected Frame also stops
advertising, so a second host cannot even discover it. This matches repeatedly
observing the device vanish from scans while something else held it — the
single most confusing failure mode in practice, because it looks exactly like
the glasses being dead.)*

Consequence for a multi-client design: there is no sharing. A phone app and a
laptop script cannot both be live. Anything resembling multi-host has to be
built as one host that others talk to.

### MTU

"Common MTU lengths are from 27 to 251 bytes, depending on OS version, BT
version, and more." Measured here: **243**. Query at runtime with
`frame.bluetooth.max_length()` or `FrameBle.max_lua_payload()` — never assume.

### Firmware update mode

`frame.update()` reboots into the bootloader, which advertises as
**`Frame Update`** and times out after 5 minutes of inactivity.

---

## Camera

```lua
frame.camera.capture{resolution=512, quality='VERY_HIGH', pan=0}
```

- `resolution` — "may be any even number between 100 and 720"
- `quality` — `VERY_LOW`, `LOW`, `MEDIUM`, `HIGH`, `VERY_HIGH`
- `pan` — "any number between -140 and 140, where 0 represents a centered
  image"; selects which part of the sensor width is used

Capture is asynchronous: "following a capture, polling `image_ready()` will
return `false` while the image is being captured."

Reading back:

- `read(n)` — full JPEG including the header
- `read_raw(n)` — "skips the JPEG header data and only returns the image data"

Exposure control, automatic:

```lua
frame.camera.auto{metering='CENTER_WEIGHTED', exposure=0.1}
```

`metering` is `SPOT`, `CENTER_WEIGHTED` or `AVERAGE`; plus `exposure_speed`,
`white_balance_speed`, `shutter_limit`, `analog_gain_limit`, `rgb_gain_limit`.

Manual: `set_exposure(shutter)` 4–16383, `set_gain(gain)` 1–248,
`set_white_balance(r, g, b)` each 0–1023.

> On firmware `v25.080.0838` the Lua table exposes **`set_shutter`**, not
> `set_exposure` as the docs name it. Introspected from the live device.

### The real constraint is bandwidth

> "Transfers are limited by the Bluetooth bandwidth which is typically around
> 40 kBps under good signal conditions."

At 40 kB/s a 100 kB photo takes about 2.5 seconds of solid transfer, during
which the app loop is busy shuttling chunks. Resolution and quality are
therefore latency settings as much as image settings. `read_raw` exists to shave
the header off. `power_save(true)` shuts the camera down between uses.

---

## FPGA, firmware, and what can actually be bricked

This is the part worth getting right before experimenting.

### The FPGA cannot be reprogrammed from Lua

> "The FPGA does not expose a physical programming interface. Therefore the
> FPGA application is uploaded solely via SPI at boot-up."

And from the codebase: "The FPGA RTL is prebuilt and included in
`fpga_application.h` for convenience."

So the bitstream is **compiled into the nRF52 application** and pushed to the
FPGA over SPI on every boot. There is no FPGA flash to corrupt and no runtime
path to replace the bitstream.

### What `frame.fpga_read` / `frame.fpga_write` actually do

They poke FPGA **registers** at runtime — not the bitstream. The worst outcome
is a confused display or camera until the next reboot, because the bitstream is
re-uploaded from the nRF application at boot.

### The register map, and what Lua does not expose

From `docs/fpga-architecture.md`. Byte-addressed registers over SPI:

| Reg | Name | Reachable from Lua? |
| --- | --- | --- |
| `0x11` | `GRAPHICS_ASSIGN_COLOR` | yes — `frame.display.assign_color` |
| `0x12` | `GRAPHICS_DRAW_SPRITE` | yes — `frame.display.bitmap` |
| `0x13` | `GRAPHICS_DRAW_VECTOR` | **no** |
| `0x14` | `GRAPHICS_BUFFER_SHOW` | yes — `frame.display.show` |
| `0x18` | `GRAPHICS_BUFFER_STATUS` | **no** |
| `0x20` | `CAMERA_CAPTURE` | yes |
| `0x21` | `CAMERA_BYTES_AVAILABLE` | partly |
| `0x22` | `CAMERA_READ_BYTES` | yes — `camera.read` |
| `0x23` | `CAMERA_RESOLUTION` | yes |
| `0x25` | `CAMERA_READ_METERING` | partly — `RxMeteringData` |
| `0x26` | `CAMERA_QUALITY_FACTOR` | yes (`0x0`–`0x7`) |
| `0x28` | `CAMERA_DPHY_POWER_DOWN` | partly — `camera.power_save` |
| `0x30` | `CAMERA_IMAGE_READY` | yes |
| `0x31` | `CAMERA_BYTES_TOTAL` | partly |
| `0x32` | `CAMERA_GAMMA_BYPASS` | **no** |
| `0x40` | `PLL_CONTROL` | **no** |
| `0x41` | `PLL_STATUS` | **no** |
| `0xDB` | `GET_CHIP_ID` | **no** — returns `0x81` when alive |

**The vector engine is documented but not built.** `fpga-architecture.md`
describes `GRAPHICS_DRAW_VECTOR` in full, and `graphics.sv` declares

```systemverilog
parameter GRAPHICS_DRAW_VECTOR = 'h13;
```

— and then never references it again. Only `ASSIGN_COLOR`, `DRAW_SPRITE` and
`BUFFER_SHOW` are decoded, and `modules/graphics/` contains a `sprite_engine.sv`
with no vector counterpart. Writing to `0x13` draws nothing.

So the display cannot draw a line at all, at any level, without new RTL. Text
and sprites are the whole repertoire. Treat the opcode as reserved for a
feature that was specified ahead of implementation.

`GET_CHIP_ID` (`0xDB` → `0x81`) is the safe way to confirm register access works
before trying anything that draws.

#### Driving the vector engine — does not work, kept for reference

`frame.fpga_write(address, data)` takes an address `0x00..0xFF` and a raw byte
string, and hands it straight to `spi_write`. Register `0x13` wants:

```
x_start[15:0] y_start[15:0] x_end[15:0] y_end[15:0]
ctrl1_x[15:0] ctrl1_y[15:0] ctrl2_x[15:0] ctrl2_y[15:0] color[7:0]
```

Two details are not in the RTL document and have to come from the firmware
source (`lua_libraries/display.c`, where `draw_sprite` builds the same kind of
payload):

- **Big-endian.** It writes `x >> 8` then `x`.
- **Coordinates are 0-based.** `x_position--` is commented "remove Lua 1 based
  offset before sending", so the 1-based coordinates of `frame.display.text`
  are a Lua-level convention, not what the hardware uses.

Control points are relative to the start and end points respectively; zero them
for a straight line. Colour is a palette index `0..15`.

```lua
frame.fpga_write(0x13, string.pack('>I2I2I2I2I2I2I2I2B',
                                   80, 60, 560, 60, 0, 0, 0, 0, 1))
frame.display.show()
```

[`scripts/test_vector.py`](../scripts/test_vector.py) builds exactly this. It is
expected to draw **nothing**, because the RTL does not decode `0x13` — see
above. It is kept as the ready-made probe for the day the engine lands, and as
a way to disprove the reading of the RTL.

The byte-order and 0-based findings above still stand and apply to any register
payload, including sprites.

Other facts worth knowing from the same document:

- The display is **4 bits per pixel, 16 colours**, each palette index mapping to
  a configurable **YCbCr** value — hence `assign_color_ycbcr` existing alongside
  the RGB helper.
- **Palette index 0 is the transparent background, and it is configurable.**
- Sprites support 1-, 2- and 4-bit colour formats, and `palette_offset` exists
  precisely to recolour the same bitmap without duplicating it.
- Two **512 KB** frame buffers, double-buffered; `GRAPHICS_BUFFER_SHOW` swaps
  them. This is why `show()` leaves a clean buffer behind — it is a swap, not a
  blit.

---

## Ground truth: the API as the firmware registers it

The published docs have been wrong twice already (`display.clear` removed,
`set_exposure` renamed), so the authoritative list is the firmware source.
Checked out alongside this project:

```
../frame-codebase                 firmware + FPGA RTL -- the source of truth
../frame-docs                     source pages of docs.brilliant.xyz
../frame-sdk-python               official Python SDK
../frame-utilities-for-python     helper utilities
../frame-production               factory/production tooling
../frame-brilliant-sdk            all Brilliant SDKs, monorepo
../frame-ble-python               the BLE layer this project uses
../frame-msg-python               the message layer this project uses
../frame-examples-python          worked examples
```

Every library is registered unconditionally in
`source/application/luaport.c`, and the whole surface comes from
`source/application/lua_libraries/*.c`:

| Table | Functions |
| --- | --- |
| `frame` | `update` `sleep` `stay_awake` `battery_level` `fpga_read` `fpga_write` |
| `frame` | `HARDWARE_VERSION` `FIRMWARE_VERSION` `GIT_TAG` |
| `frame.bluetooth` | `is_connected` `address` `max_length` `send` `receive_callback` |
| `frame.display` | `assign_color` `assign_color_ycbcr` `bitmap` `text` `show` `power_save` `set_brightness` `write_register` |
| `frame.camera` | `capture` `image_ready` `read` `read_raw` `auto` `power_save` `set_shutter` `set_gain` `set_white_balance` `write_register` `read_register` |
| `frame.microphone` | `start` `stop` `read` |
| `frame.imu` | `direction` `raw` `tap_callback` |
| `frame.time` | `utc` `zone` `date` |
| `frame.led` | `set_color` |
| `frame.compression` | `decompress` `process_function` |
| `frame.file` | `open` `remove` `rename` `listdir` `mkdir` |

### What is missing from the documentation

- **`frame.led.set_color(r, g, b)`** — three channels, each `0..100`, driven by
  PWM. Absent from the docs entirely. The pins are named `FRAME_LITE_LED_*`, so
  whether a given unit has the LED fitted is a hardware question, but the
  function is registered on every build.
- **`frame.bluetooth.is_connected()`** — this project already relies on it to
  avoid deep-sleeping while a host is attached.
- **`frame.display.write_register`**, **`frame.camera.read_register` /
  `write_register`** — direct register access beside the normal API.
- **`frame.camera.auto`** returns much more than the docs suggest: `shutter`,
  `analog_gain`, `red_gain`, `green_gain`, `blue_gain`, and brightness as
  `spot`, `matrix`, `center_weighted_average` and `scene`, plus `error`.
- `frame.file.listdir` entries carry `name`, `size` and `type`.
- **`frame.display.clear` genuinely does not exist** — confirmed in source, not
  just by introspection.

### Startup, as the firmware performs it

```c
luaL_dostring(L, "frame.stay_awake(false); require('main')");
```

So `main.lua` is `require`d, not run as a file, and `stay_awake` is explicitly
turned off first. Uploading the app as `main.lua` is the supported path, not a
trick.

### ⚠️ Unpairing reformats the filesystem

```c
lua_open_file_library(L, !is_paired);   // the parameter is called `reformat`
```

```c
if (reformat || file_mount_error) { lfs_format(...); }
```

**Resetting the glasses with the pinhole button does not merely drop the BLE
bond — it wipes flash**, taking `main.lua` and every module with it. Anything
uploaded has to be uploaded again afterwards. The docs describe the pinhole
reset purely as an unpairing step and say nothing about data loss.

### Adding a function to the Lua engine

Four mechanical steps, no framework involved:

1. Write `source/application/lua_libraries/mine.c` exposing
   `void lua_open_mine_library(lua_State *L)`. Copy `led.c` — at 90 lines
   including the licence header it is the smallest complete example: it grabs
   the global `frame` table, makes a new table, `lua_pushcfunction` +
   `lua_setfield` per function, then `lua_setfield` the table onto `frame`.
2. Declare it in `lua_libraries/frame_lua_libraries.h`.
3. Call it from `lua_open_*_library` block in `source/application/luaport.c`.
4. Add `lua_libraries/mine.c` to the explicit source list in
   `source/application/Makefile` — the list is not a wildcard.

Argument checking is plain `luaL_checkinteger` / `luaL_checklstring` with
`luaL_error` for ranges, exactly as the existing libraries do.

Then `make release` and DFU the resulting `.zip`.

---

## Firmware currency

**This unit is behind.** Installed: `v25.080.0838` (day 80 — 21 March).
Latest: **`v25.278.1113`**, published **5 October 2026**.

The version scheme is `v25.<day-of-year>.<HHMM>`, so the gap is roughly seven
months of releases.

What the newer firmware brings, by the project's own notes:

- **A security fix that matters here.** `v25.278.1113` patches "a buffer
  overflow vulnerability in `lua_write_to_repl()` that could allow remote code
  execution via Bluetooth". Sending Lua over BLE is exactly what every host in
  this project does, all day.
- **Bluetooth throughput up to 65+ kB/s on iOS/macOS**, against the ~40 kB/s the
  camera documentation assumes. That directly shortens photo transfers.
- **Power-saving features**, relevant given the device never sleeps on its own
  while an app loop runs.
- Camera white balance and noise improvements.

Update paths: AR Studio updates automatically; manual OTA is possible with
nRF Connect and the release `.zip`. The Noa app did not carry this build at
release time. `frame.update()` puts the device into the bootloader, which
advertises as `Frame Update` and times out after five minutes.

> Updating firmware is a device-level action with its own risk window. It is
> listed here as a recommendation, not something to run unattended.

**Verdict: playing with these from Lua cannot brick the device.** It is a
power-cycle away from clean. *(This follows from the boot-time SPI upload; the
docs state no such guarantee explicitly.)*

### Custom firmware does NOT require opening the glasses

The hardware manual's line about "destructive disassembly" to reach the SWD
port describes debugging and bootloader work. It does **not** apply to
replacing the application, because the signed over-the-air path is open:

```make
nrfutil pkg generate \
    --hw-version 52 --application-version 0 \
    --application $(BUILD)/application.hex \
    --sd-req 0x0123 \
    --key-file source/bootloader/dfu_private_key.pem \
    $(BUILD)/frame-firmware-$(BUILD_VERSION).zip
```

**The DFU signing key ships in the repository.** `make release` produces a
properly signed `.zip` — the same artefact the official release notes tell
users to flash with nRF Connect. So a custom build installs over Bluetooth:
`frame.update()` to enter the bootloader, then DFU the `.zip`.

Signing here is an integrity check, not an authenticity barrier; anybody can
produce an image the bootloader accepts.

Every dependency is vendored under `libraries/` — nRF5 SDK, nrfx, SoftDevice,
Lua, littlefs, lz4, picolibc, CMSIS. Nothing has to be downloaded separately.
The host side needs an `arm-none-eabi` toolchain, `nrfutil`, and `mergehex`.

A J-Link is still needed for `flash-jlink`, for the bootloader, and for
recovering a device that will not enter DFU — that last case is the one that
needs the glasses opened.

Risk ladder, least to most severe:

1. **Lua mistakes** — break signal or reset recovers. No risk.
2. **A bad `main.lua`** — it auto-runs, but `FrameMsg.connect()` sends
   break → reset → break specifically to interrupt an auto-starting `main.lua`.
   Recoverable over BLE.
3. **A bad nRF52 application** — the bootloader survives, so DFU over BLE
   (`Frame Update` mode) can still reach it. Recoverable *if* the app still
   reaches `frame.update()` or the bootloader can be entered otherwise.
4. **A broken bootloader** — nothing on the BLE side can help. Recovery needs
   SWD, and SWD needs destructive disassembly. **This is the real brick.**

Practical rule: anything reachable from Lua or from a normal SDK upload is
recoverable. Only flashing the bootloader puts the device at risk, and that
already requires opening the glasses.

---

## Sources

- [Frame Hardware Manual](https://docs.brilliant.xyz/frame/hardware/)
- [Talking to Frame Over Bluetooth](https://docs.brilliant.xyz/frame/frame-sdk-bluetooth-specs/)
- [Lua API Reference](https://docs.brilliant.xyz/frame/frame-sdk-lua/)
- [Frame SDK for Python](https://docs.brilliant.xyz/frame/frame-sdk-python/)
- [frame-codebase (firmware + RTL)](https://github.com/brilliantlabsAR/frame-codebase)
- [frame_examples_python](https://github.com/CitizenOneX/frame_examples_python)

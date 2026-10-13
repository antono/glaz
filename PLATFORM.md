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

**The interesting gap is the vector engine.** The FPGA renders cubic Bézier
curves — start point, end point, two control points, with zeroed control points
giving straight lines — and the Lua API has no entry point for it at all. Lua
can draw text and blit sprites; it cannot draw a line. `frame.fpga_write(0x13, ...)`
is the only way to reach it without rebuilding firmware.

`GET_CHIP_ID` (`0xDB` → `0x81`) is the safe way to confirm register access works
before trying anything that draws.

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

### What genuinely carries risk

Changing the RTL means rebuilding the whole nRF52 application (the bitstream
lives inside it) and flashing it. The codebase builds with
`make release && make erase-jlink && make flash-jlink`, and **a J-Link debugger
is required**.

That is the dangerous path, for a reason specific to this device:

> Custom firmware requires "destructive disassembly" to access the physical ARM
> SWD debug port on the back PCB.

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

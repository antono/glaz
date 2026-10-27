# Brilliant Labs Halo

## Plain-language summary

Halo is Brilliant Labs' newer pair of glasses. Like Frame, it runs Lua and
talks over the same Bluetooth service, so the phone app already finds it.
Underneath, much is different:

- a different chip, running Zephyr;
- a small round colour screen that draws at once;
- a button, a speaker and two microphones;
- it loads only Lua source, not bytecode;
- firmware updates go over MCUmgr instead of Nordic DFU.

glaz is being built for Halo the way docs/DEVICES.md describes: each file
gets a Halo part next to its Frame one. The app's menu, top bar, taps and
sleep have one already, and so do a few simple modules. The phone finds
Halo, names it, and uploads to it the app and the apps that run there,
which are also all its Menu tab lists. It offers Halo no firmware, since
Frame's is never offered to Halo and the app has none for Halo yet. All
of it has been tried in Brilliant Labs' Halo emulator, none of it on a
Halo yet.

Sources, cited below by these short names:

- **FW:** [halo-firmware](https://github.com/brilliantlabsAR/halo-firmware)
  at 8415ce0 (firmware 0.8.22, 2026-10-26). `M:` stands for
  `modules/halo/src/` in it.
- **docs:** Brilliant's documentation (`lab-frame-docs/halo/`).
- **[mkt]:** the product page,
  [brilliant.xyz](https://brilliant.xyz/products/halo).

Nothing here has been measured from glaz yet.

## Telling Halo from Frame

Both advertise the Lua service `7a230001-5475-a6a4-654c-8431f6ad49c4`, so
the scan in `flutter-glaz/lib/frame/link.dart` finds both. The advertised
name tells them apart:

| Advertised name | Model |
| --- | --- |
| `Frame 4F` | Frame |
| `Frame Update` | Frame's bootloader (no Lua service, never found by the scan) |
| `Halo 3C` | Halo: `"Halo %02X"` of one byte of its address (`M:ble_connection.c:303`) |

`GlassesModel.fromName` (`flutter-glaz/lib/frame/model.dart`) reads the
name. A name that says neither is taken for Frame, as every pair was
before: none yet, or one given in the phone's Bluetooth settings. The Log's
`up:` line says which model came up.

Halo's GATT has characteristics Frame's does not have, which would tell the
two apart after connecting
([issue #6](https://github.com/antono/glaz/issues/6)); see Bluetooth below.

With Halo connected, the Glasses tab says that Halo support is new and
has been tried in the emulator only.

## Hardware

| | Halo | Source |
| --- | --- | --- |
| Chip | Alif Balletto B1: Cortex-M55, Ethos-U55 NPU, BLE 5.3 | FW `boards/arm/halo/halo_defconfig` |
| Memory | 1.5 MB internal SRAM and 7.5 MB external, both used by Lua | FW `applications/halo/LUA_RUNTIME.md` |
| Storage | MRAM: two 780 KB app slots; 128 KB LittleFS (`/lfs`) for files | FW `boards/arm/halo/halo.dts` |
| Display | Micro-OLED (GZOT VGA020); Lua draws a round 256x256, RGB888 | FW `halo.dts`; docs |
| Camera | PixArt PAG7982, global shutter, 640x480 | FW `halo.dts`; docs |
| Microphones | Two TDK T5838 (PDM), with wake on sound | FW `halo.dts` |
| Speaker | Bone conduction | docs |
| IMU | BMA580 accelerometer, with taps in hardware; QMC6308 compass; no gyroscope | FW `halo.dts` |
| Button | One, under the left arm | FW `halo.dts` |
| LED | One, white | FW `halo.dts` |
| Battery | 2 x 150 mAh; magnetic USB-C | docs |
| Battery life | "Up to 14 hours" | [mkt] |
| Weight | "Just over 40 g" | [mkt] |

The sources disagree on the panel. The firmware's binding says 320x240, the
docs say 640x480. Lua sees 256x256 either way.

## Bluetooth

The Lua service, from Halo's side (`M:../include/halo/ble_lua.h`,
`M:ble_lua.c`):

| UUID | | Use |
| --- | --- | --- |
| `7a230002-...` | write | Phone to Halo: REPL text, `0x01` + data, control bytes |
| `7a230003-...` | notify | Halo to phone: `print()` and `0x01` + data |
| `7a230004-...` | notify | Video. Unused, the docs say |
| `7a230005-...` | write | Phone to speaker: PCM or LC3 audio, past the Lua VM |
| `7a230006-...` | notify | Audio. Unused, the docs say; the microphone's data goes on `...0003` |

Frame has only `...0002` and `...0003`.

- **Encryption.** Every write and notify needs an encrypted link (Just
  Works bonding). Halo keeps 5 bonds and one connection at a time. Once
  bonded, it refuses new hosts unless its pairing window is open (5 s
  button hold).
- **MTU.** 23 until the host asks for more; the SDK asks for 517 on
  Android. `frame.bluetooth.max_length()` is the MTU less 1 (the `0x01`).
- **Control bytes.** `0x01` data, `0x02` reboot, `0x03` break, `0x04`
  reset (run `main.lua` again), `0x05` remove `main.lua` and reset, `0x06`
  leave the runtime, `0x07` remove every file.
- **REPL buffer.** A ring of 1 KB. A write that does not fit is refused
  (ATT error 0x11); a write without response is then lost without a word.
  While a script runs, REPL text is ignored, but `0x01` data still arrives.
- **Data buffer.** A ring of 4 KB, which `frame.bluetooth.receive_buffer_size()`
  can change.
- **Firmware updates.** SMP: service `8d53dc1d-1db7-4cd3-868b-8a527460aa84`,
  characteristic `da2e7828-fbce-4e01-ae9e-261174997c48`.

## Lua: what differs from Frame

Lua 5.4.6, with `halo` as another name for `frame`. Loaded libraries:
base, coroutine, table, string, math, utf8, debug. No io, os or package.

| | Frame | Halo |
| --- | --- | --- |
| `require` | firmware's reads a byte at a time; glaz uses its own (docs/FRAME.md) | reads `/lfs/<name>.lua`, **text only: bytecode is refused**; caches nothing (`M:lua_file.c:486`) |
| Watchdog | 6 s, fed by Lua's hook | 5 s, fed by a thread of its own: a long load does not trip it |
| File names | from `/` | relative, under `/lfs` |
| File modes | `'read'`, `'write'`, `'append'` | the same work: only the first letter is read (`'r'`, `'w'`, `'a'`) |
| `f:read()` | a line, at most 512 bytes, the line break dropped | a line; `f:read(n)` gives n bytes |
| `display.text(s, x, y, ...)` | options table `{ color = 'NAME' }` | a number `0xRRGGBB`; a table or a name is an error |
| Drawing | back buffer: `show()` flips it, and the next is zeroed | at once; `show()` does nothing; `clear([color])` |
| Font | proportional; ours adds Cyrillic and emoji | Dogica and Dogica Bold, `set_font(id, size, scale)`, size a multiple of 8; printable ASCII only |
| More drawing | `bitmap` | also `bitmap` (palette offset and 16 named colours, as Frame), `char`, `line`, `rect`, `circle`, `polygon`, `set_pixel` |
| Size | none to ask | `display.width()` and `height()`: 256 |
| Brightness | `set_brightness(-2..2)` | the same, kept; also `brightness(0..100)` |
| Taps | the callback fires once per tap; glaz counts them | the callback gets `'single'`, `'double'` or `'triple'` |
| Button | none | `frame.button.single(f)`, `double(f)`, `long(f)` |
| Sleep | `frame.sleep()`; a tap wakes (our firmware) | `sleep()` drops Bluetooth and wakes on the button only; `standby()` keeps Bluetooth and wakes on a tap, the button or sound |
| Microphone | 8 kHz | `start{encoder = 'pcm' or 'lc3', sample_rate = 8000 or 16000, ...}`; `read(n)` does not wait |
| Speaker | none | `frame.speaker.start/play/stop`; `frame.sound.play` for effects |
| Camera | `camera.min`, auto exposure | `frame.camera.capture{resolution = 640, quality = ...}`, `image_ready()`, `read(n)`; no exposure control |
| FPGA | `frame.fpga_read`, `fpga_write` | none |
| Which device | `frame.HARDWARE_VERSION`: `'Frame'` | `'halo'` (glaz does not ask: see below) |
| Notifications | none | `frame.ancs`: an iPhone's, on the glasses |

glaz never asks which glasses it is on: the parts on them say so
(docs/DEVICES.md).

## Firmware, updates and recovery

- **System.** Zephyr, on Alif's fork. The bootloader is MCUboot.
- **Updates.** MCUmgr (SMP) over Bluetooth, to a bonded host. The image
  (`zephyr.signed.bin`, about 600 KB) gets one test boot and goes back to the
  old one if it fails before confirming. Releases are on
  [GitHub](https://github.com/brilliantlabsAR/halo-firmware/releases).
- **Recovery.**
  - With no bootable image, MCUboot waits for an image over Bluetooth by
    itself.
  - It can be forced: hold the button while connecting the charger for 10
    s or more. The LED blinks once a second. This erases `/lfs`, files and
    bonds alike, so forget Halo on the phone before pairing again.
  - It leaves after 2 minutes idle.
  - FW `applications/halo/FLASHING.md`.
- **Restart.** Hold the button, connect the charger, and let go within 10 s.
- **Not known.** The bootloader's advertised name.

## glaz on Halo

What has a Halo part (docs/DEVICES.md):

- **`app/glaz_boot.halo.lua`**, Halo's `main.lua`. It loads files as text,
  under Halo's file names, and shows "restarted" on Halo's screen.
- **`glaz.halo.lua`**, the app's display. It has five rows of 16 px text,
  30 px apart, around the middle where the circle is widest. Each line is
  centred and cut to the circle's width at its height (`fit()`): 11
  characters on the top and bottom rows, 13 or 14 in the middle, so
  notifications wrap at 11. Above the rows go the clock and battery (8 px)
  and the breadcrumb; below them, Frame's icons as bitmaps. Palette names
  become the same colours as numbers. Text is folded to printable ASCII.
  Every screen starts from `clear()`, since Halo keeps what was drawn.
  Taps come whole from Halo's firmware, `'single'`, `'double'` or
  `'triple'`, and go to the same gestures as Frame's counted ones. Sleep is
  `standby()`, which keeps Bluetooth and wakes on a tap or the button;
  `sleep()` would wake on the button only.
- **Modules.** About, Battery, Bluetooth, Firmware, Uptime, Stopwatch,
  Weather and Notifications (Settings) use only what both pairs of glasses
  have, so each has an empty Halo part.
- **Upload.**
  - Text only: Halo's `require()` refuses bytecode.
  - The picture on the glasses while it runs is a line of text and the
    progress (`HaloPicture`): the eye does not fit the round panel.
  - There is no room check: Halo's firmware has no `frame.file.space()`.

## Trying it without a Halo

Brilliant Labs' Halo emulator, [`halo-emulator`](https://pypi.org/project/halo-emulator/)
(in [brilliant_sdk](https://github.com/brilliantlabsAR/brilliant_sdk),
`python/packages/halo_emulator`), runs Lua on a stand-in for Halo's
`frame.*` API. It has a 256x256 screen drawn with the firmware's fonts,
taps and the button to inject, and the Bluetooth sends to read back.

In the root devenv shell:

```sh
halo                              # pytest tests
HALO_SHOTS=/tmp/halo halo         # and keep the screens as PNG
```

`tests/halo_sandbox.py` lays out the files as the phone uploads them to
Halo, and `tests/test_halo.py` starts glaz from `main.lua` and checks four
things:

- it starts without errors;
- a double tap opens the menu;
- a single tap goes into Apps and the first app there, and a double tap
  comes back;
- a triple tap goes to standby, and a tap wakes it.

The emulator (2.3.0) follows firmware 0.8.12. Its `frame.file` is simpler
than the firmware's today (`lua_file.c`, 0.8.22):

- it takes only Python's file modes;
- it has no `read(n)`;
- `read()` keeps the line break;
- `listdir()` gives names only.

`halo_sandbox.py` gives it the firmware's `frame.file` instead. It has no
`frame.camera` either.

## Next steps

1. **Upload on a Halo.**
   - Whether uploadScript's writes fit Halo's REPL ring (1 KB). A full one
     refuses the write.
   - Whether `listdir('/')` lists `/lfs`. Upload clears old files with it,
     and the menu finds its modules with it.
   - Its firmware: the Firmware screen offers each pair of glasses only its
     own (`frame-firmware-*`, `halo-firmware-*` in assets/firmware/), and
     has none for Halo yet. Halo updates over MCUmgr, which the app does not
     do yet.
2. **Measure on a Halo.**
   - The MTU Android gets.
   - Whether `bitmap()` draws Frame's icons as they are.
   - The sign of `frame.imu.direction().roll`.
   - How Android reports a full REPL ring.
3. **The app on Halo**, in `glaz.lua` and its parts:
   - The button.
   - The eye before sleep (`glaz_blink`, Frame's only).
   - Module text is cut to the round rows; modules that draw for
     themselves need Halo parts.
4. **Modules, one by one.**
   - The camera first: Photo, Translate's photos, the remote's
     (`glaz_photo`, Frame's only).
   - Then Halo's own: firmware updates over SMP, answers spoken on its
     speaker.

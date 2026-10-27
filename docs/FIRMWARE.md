# Custom firmware: runtime tap tuning

## Plain-language summary

The glasses detect taps in a dedicated chip, not in software. That chip has
settings — how hard a knock counts, how long to stay deaf afterwards — and the
stock firmware fixes them at boot and never exposes them. This branch makes
them adjustable from Lua, so taps can be tuned while wearing the glasses
instead of by rebuilding firmware each time.

---

## Why

Tap handling has cost more debugging than anything else in this project:

- a single physical tap fired the callback **3 and even 7 times**, so the app
  carries a software bounce filter;
- multi-tap counting is done by hand in Lua, with a 0.75 s window, which
  **delays every single and double tap** by that much;
- taps and tilts share one accelerometer, so a tap throws roll by up to 56°.

The root cause turned out to be a register the stock firmware never writes.

### The MC6470 tap registers

From the datasheet, sections 9.6 to 9.8:

| Reg | Name | Contents |
| --- | --- | --- |
| `0x03` | `SR` | tap status, bits 0..5 `X+ X- Y+ Y- Z+ Z-`; **reading it clears and re-arms** |
| `0x06` | `INTEN` | per-axis interrupt enables |
| `0x07` | `MODE` | `IAH` `IPP` … `OPCON[1:0]` — `0xC0` standby, `0xC1` wake |
| `0x08` | `SRTFR` | `TAP_LATCH` \| `FLIP_*` \| `RATE[3:0]` |
| `0x09` | `TAPEN` | `TAP_EN` \| `THRDUR` \| per-axis enables |
| `0x0A`–`0x0C` | `TTTRX/Y/Z` | one per axis, X Y Z; **two registers in one**, selected by `THRDUR` |

That last row is the crux. With `THRDUR = 1` the address holds the **tap
threshold**; with `THRDUR = 0` the same address holds **`QUIET[7:4]`** and
**`DUR[3:0]`** — the silence enforced after a tap, and the minimum impulse
length.

Stock firmware sets `THRDUR = 1` and writes a threshold of `0x07`. It never
writes the other half, so `QUIET` and `DUR` stay at their power-on **zero**:
there is no enforced silence after a tap at all. The frame rings after a knock
and the chip faithfully reports each ring as another tap.

> `TAP_LATCH` is *not* a double-tap counter, despite the stock comment reading
> "ignore multiple taps". The datasheet defines it as: `0` multiple taps are
> detected and latched, `1` the first tap is latched and the rest ignored until
> register `0x03` is read. The MC6470 has no hardware double-tap feature — the
> software counting in `glaz.lua` is not redundant.

---

## What the branch changes

Branch `glaz/tap-tuning` in `../frame-codebase`, based on the current release
tag `v25.278.1113` (so it includes the `lua_write_to_repl()` buffer overflow
fix).

One file: `source/application/lua_libraries/imu.c`.

- The boot-time register sequence moves into `imu_apply_tap_settings()`, which
  wraps the writes in a **standby → configure → wake** cycle. The stock code
  did this once and documented the limitation as "IMU must be repowered after
  changing these settings"; performing the full cycle is what makes the
  settings changeable at runtime.
- Both halves of `0x0A`–`0x0C` are now written: first with `THRDUR = 0` for
  quiet and duration, then with `THRDUR = 1` for the threshold, each axis
  its own (`0x0A` X, `0x0B` Y, `0x0C` Z, datasheet table 23).
- A new Lua function is registered.
- The tap callback gets the status byte (see "Which side was tapped").

### `frame.imu.tap_config`

```lua
frame.imu.tap_config{
  threshold = 7,    -- 0..255  how hard a knock must be, all three axes
  quiet     = 0,    -- 0..15   silence enforced after a tap (anti-bounce)
  duration  = 0,    -- 0..15   minimum impulse length
  rate      = 256,  -- Hz: 1 2 4 8 16 32 64 128 256
  latch     = true, -- TAP_LATCH
  axes      = 0x08, -- TAPEN bits 5:0; 0x08 is -Y, as mounted
}
```

Every field is optional; omitted fields keep their current value. Called with
no arguments it **returns** the current settings as a table, so a calibration
app can display and round-trip them.

`threshold` also takes a table, one value per axis; axes it leaves out keep
their current value:

```lua
frame.imu.tap_config{threshold = {x = 137, z = 9}}  -- y unchanged
```

The table form takes only the keys `x`, `y` and `z`, and at least one of
them; a list such as `{137, 137, 137}` or `{X = 137}` is an error.

The returned table always has `thresholds = {x =, y =, z =}`, and
`threshold` as a plain integer only while the three are equal, as they are
by default (`0x07` each). The setter takes `thresholds` too, so passing the
returned table back restores every axis; when a table has both, `threshold`
is applied last and wins. A caller that only knows `threshold` reads and
writes it as before while the axes are equal. Once they differ it reads
`nil`, and writing `threshold` sets all three axes to that one value: Tap
tune then shows `thr ?`, and a tap on that row sets every axis to `3`.

---

## Calibrating

[`modules/taptune.lua`](../modules/taptune.lua) is a menu module for tuning in
place. Tilt moves the cursor over `threshold`, `quiet`, `duration`, `axes`
and `test`; a single tap on a setting steps it to its next value (the screen
says which) and reprograms the chip. On `test` a tap changes nothing. A hit
counter shows every hit since the last change, bounces included.

The counter is the actual measurement: on `test`, knock **once** and watch
whether it advances by one or by five. Raise `quiet` until one knock reads as
one tap.

The fourth setting, `axes`, switches between `0x08` (-Y, the default) and
`0x3F` (all six directions; the screen shows `08` and `3F`), and the last
row shows the last knock's status byte, from its first hit and not the
rebound, raw and decoded as `X+ X- Y+ Y- Z+ Z-` (bits 0..5, datasheet
table 17): knock the left arm, the right arm and the front with `axes`
at `0x3F` and note the bits. `axes` goes back when the module closes.

The module checks for `frame.imu.tap_config` and shows
`needs the glaz firmware` on stock firmware rather than failing.

Suggested order:

1. `quiet` first — it is the anti-bounce control and the one left at zero.
2. `threshold` next, only if taps still trigger from ordinary head movement.
3. `duration` last; it rejects very short spikes.

Once a setting works, move it into the `tap_settings` defaults in `imu.c` so it
survives a reboot — runtime changes are not persisted.

**Tap tune settings also decide how the glasses wake.** `frame.sleep()` leaves
the accelerometer powered, as it was last set, and its interrupt is the only
thing that wakes them. With a harder `threshold` or a long `duration` it took
many taps to wake them, or none did. So before `frame.sleep()` the app puts
back the stock settings (`WAKE_TAPS` in `glaz.lua`). That also clears a
latched tap, which would hold the wake-up line where no new tap can move it.
The boot after waking programs the `imu.c` defaults again.

**The firmware does this itself since `glaz/stable`.** Waking depended on
the Lua line above, and that line needs `frame.imu.tap_config`, which only
this branch has. Branch `pairing-once` (`v26.288.1712-pairing-once`) was cut
from upstream `main`, without the tap commits: the app skipped the reset, a
latched tap stayed on the wake-up line, and **the glasses never woke, by one
tap or two** (seen 16.10.2026, right after flashing it).

Branch `glaz/stable` merges both, and `shutdown()` in `main.c` now calls
`imu_prepare_wakeup()` (`imu.c`) on the way to System OFF: the boot tap
defaults back, the latch cleared, and cleared again 300 ms later, after the
frame has stopped ringing from the tap that sent it to sleep. So waking no
longer depends on what the Lua app remembers to do. Build
`v26.289.1613-stable`.

Rule: **every firmware of ours is built from a `glaz/` branch** in
`antono/frame-codebase`, and a fix goes in as a branch merged into it,
never as a branch off upstream `main` alone. `glaz/main` is `glaz/stable` with
`glaz/double-tap-wake` and `glaz/file-space` (`frame.file.space()`)
merged in; the other `glaz/*` branches stay as history (until 22.10.2026
they were `okulo/*`, and `glaz/main` was `glaz`). Builds carry the suffix
`-glaz`, the first one `v26.291.1045-glaz`.

Every feature is a branch `glaz/<topic>`, merged into `glaz/main`.
`glaz/stable` stays behind: it is moved up to `glaz/main`, a fast-forward
and never a merge, only when the maintainer says so. Nothing else
advances it.

**The phone app carries the build of `glaz/stable`**, every build of it:
the release (`.github/workflows/release.yml`, `FIRMWARE_REF`) and `apk`
alike. Locally, `firmware` in the root shell (`utils/build_firmware.sh`)
builds a branch's current commit in a worktree of its own, named by the
commit's time: `v26.299.1345-glaz` for `glaz/stable`,
`v26.298.1306-glaz-emoji` for `glaz/emoji`. The same commit always gets
the same name, so `flutter-glaz/tool/fetch_firmware.sh` can tell that a
zip is the current one, and fails when it is not there. While a feature
is being worked on, its build can go into the app as well:

```bash
firmware glaz/emoji                            # root shell
FIRMWARE_FEATURE=glaz/emoji apk                # flutter-glaz shell
```

`glaz/cyrillic-font`, merged into `glaz/main` on 20.10.2026, puts Cyrillic in
the system font: U+0400..U+045F and the extra letters of Kazakh, Tatar,
Bashkir, Yakut, Tajik and Uzbek. The glyphs are drawn by
`graphical_assets/cyrillic.py` from Play (SIL OFL), sized to the Latin,
then `system_font.h` is made from the PNGs as that folder's readme says.
First build `v26.292.2200-glaz-cyr`. Since then the phone sends Cyrillic as
it is, no longer transliterated (`flutter-glaz/lib/frame/glyphs.dart`).

`glaz/emoji`, merged into `glaz/main` on 25.10.2026, puts the 137 most used
emoji in the system font at their own codepoints: Unicode's emoji
frequency list, its first 137 that are a single codepoint. Two colors, 40
pixels tall, so they draw in the text's color; an emoji with U+FE0F after
it still draws, the selector is skipped. `graphical_assets/emoji.py` draws
them from Noto Emoji, the monochrome one (SIL OFL); the application grows
by 33 KB. The phone keeps these emoji and drops the others
(`glyphs.dart`); on older firmware they are blank.

`glaz/mono-font`, merged into `glaz/main` on 22.10.2026, adds
`frame.display.mono(text, x, y, {size, bold, color, bg, attrs})`, a
monospace font for the terminal: every character a cell of size/2 by size
pixels, sizes 20, 24, 28 and 32, normal and bold, printable ASCII only (any
other character leaves its cell blank). The glyphs are Terminus Font (SIL
OFL), written into `mono_font.h` by `graphical_assets/mono.py`. `attrs`
gives each cell its colors, a byte a cell: the text's palette index in the
low nibble (0: `color`), the background's in the high one (0: none). One
sprite goes to the FPGA for each color in the string, from its first cell
to its last, so a row of a terminal is a few sprites, not one a character.
It returns the x after the last cell. Measured on the glasses: 28 normal
is the smallest that reads well; in the visible 640x340 that is 45x12
cells. A full screen of it draws in 87 ms, 152 ms with a background on
every row. `utils/mono_test.py` shows every size and weight.

Also worth knowing: `frame.sleep()` with no argument is System OFF, and waking
from it is a **reset**. Nothing after `frame.sleep()` in Lua runs; the glasses
boot and `require('main')` again.

### Two taps to wake

One tap woke the glasses too often by accident: a bag, a table, putting
them on. Branch `glaz/double-tap-wake`, merged into `glaz/main`, asks
for two. The MC6470 cannot count taps, and an nRF in System OFF cannot run
code, so it is done in two steps:

1. Going to sleep with tap wakeup, `system_off()` (`main.c`) leaves the mark
   `0x5A` in `GPREGRET2`. That register survives System OFF; only power-on
   and brownout clear it. The bootloader reads `GPREGRET2` only for `0xA9`
   in its masked bits, which `0x5A` never matches.
2. The first tap wakes the nRF, which is a reset. Early in
   `hardware_setup()`, before the PMIC rails, FPGA, display or Bluetooth,
   the mark is read and cleared. If it was there and the glasses are not
   charging, `imu_wait_for_second_tap()` (`imu.c`) reads the accelerometer's
   status register `0x03` every 10 ms for 900 ms. Hits in the first 150 ms
   are the frame ringing from the first tap and do not count. No second
   tap: `system_off(true)`, straight back to sleep with the mark set again.

The bootloader skips its CRC check when waking from System OFF
(`NRF_BL_APP_CRC_CHECK_SKIPPED_ON_SYSTEMOFF_RESET`), so the wait starts soon
after the first tap. The bootloader also clears `RESETREAS.OFF` there, which
is why the mark is in `GPREGRET2` rather than read from the reset reason.

In the charging case the wait is skipped and the case logic decides, as
before. `frame.imu.woke_by_tap()` tells Lua that this boot was a two-tap
wake; the app then brings back the last module (or the menu) instead of
showing the banner.

Still to measure on the device: how long the first tap takes to reach
`imu_wait_for_second_tap()`. While the first tap is latched, a second one is
ignored (`TAP_LATCH`), so a very quick double tap, inside the boot time,
counts as one. If that happens, shorten `WAKE_TAP_MUTE_MS` or turn the latch
off before sleeping.

---

## Building and flashing

```bash
cd ../frame-codebase
git submodule update --init --recursive   # deps are submodules, NOT vendored
make application                          # or: make release
```

The build needs an `arm-none-eabi` toolchain. Without one installed system-wide:

```bash
nix shell nixpkgs#gcc-arm-embedded --command make application
```

Verified: builds clean, 561 888 bytes of text against the 824 KB application
partition.

### Packaging the DFU zip

`make release` also runs `mergehex`, which only exists to build the combined
`.hex` for J-Link flashing. For over-the-air updates that step is unnecessary —
the `.zip` comes from `nrfutil pkg generate` alone:

```bash
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure \
  --expr 'let p = import <nixpkgs> {
            config.allowUnfree = true;
            config.segger-jlink.acceptLicense = true;
          }; in [ p.nrfutil ]' \
  --command sh -c '
    nrfutil install nrf5sdk-tools
    nrfutil nrf5sdk-tools pkg generate \
      --hw-version 52 --application-version 0 \
      --application build/application.hex \
      --sd-req 0x0123 \
      --key-file source/bootloader/dfu_private_key.pem \
      build/frame-firmware-custom.zip'
```

Three things about this that cost time to work out:

- **nixpkgs ships nrfutil 8.2.0**, the Rust rewrite, not the Python tool the
  Makefile was written against. `pkg generate` is not built in: it arrives via
  `nrfutil install nrf5sdk-tools`, and the invocation gains a
  `nrf5sdk-tools` segment.
- **It pulls in SEGGER J-Link**, which nixpkgs requires a separate licence
  acknowledgement for. J-Link is never used on this path — it comes along as a
  packaging dependency of Nordic's tooling.
- **The old Python `nrfutil` is not a way around that.** Version 5.2.0 is the
  newest that installs on a modern Python and it is Python 2 code throughout:
  `c.encode('hex')`, `.iteritems()`, `basestring`, `xrange`, each surfacing
  only after the previous is patched. Version 6.1.7 would work but caps at
  Python 3.10.

- **On NixOS `nrf5sdk-tools` will not start** (`stub-ld`, exit code 127):
  it is a generic Linux binary that runs a second one inside. Run it in an
  FHS environment, with the version the hex was built with:

  ```bash
  V=$(TZ= date +v%y.%j.%H%M)-glaz     # suffix: anything after it is custom
  make application BUILD_VERSION=$V
  NIXPKGS_ALLOW_UNFREE=1 nix run --impure nixpkgs#steam-run -- \
    ~/.nrfutil/bin/nrfutil-nrf5sdk-tools pkg generate \
      --hw-version 52 --application-version 0 \
      --application build/application.hex --sd-req 0x0123 \
      --key-file source/bootloader/dfu_private_key.pem \
      build/frame-firmware-$V.zip
  ```

  `flutter-glaz/tool/fetch_firmware.sh` then copies the zip into the app,
  if it is the build of `glaz/stable` or of `FIRMWARE_FEATURE`. The root
  shell's `firmware` does all of this for a branch.

Verified output:

```
build/frame-firmware-<version>.zip
  application.bin   562944
  application.dat      141   init packet, signed
  manifest.json        147
```

This is the same shape of artefact the official releases ship, **signed with
the key in the repository** (`source/bootloader/dfu_private_key.pem`).

Flashing needs no debugger and no disassembly:

1. `frame.update()` — the device reboots into the bootloader and advertises as
   `Frame Update`, timing out after 3 minutes of inactivity
   (`NRF_BL_DFU_INACTIVITY_TIMEOUT_MS 180000` in the bootloader's
   `sdk_config.h`).
2. DFU the `.zip`.

### Step 2, in practice

**From the Glaz app** (Glasses > Firmware): pick a package, Install. It
offers the three newest official releases and our own build of
`glaz/stable` (plus a feature branch's, when one is being tried), the zips that
`flutter-glaz/tool/fetch_firmware.sh` puts in `flutter-glaz/assets/firmware/`.
A custom build is told apart by a suffix on its version, which the build
stamps into `frame.FIRMWARE_VERSION`:

```bash
make application BUILD_VERSION="v$(TZ= date +%y.%j.%H%M)-tap-tuning"
```

The app does what the Noa app does (`flutter-glaz/lib/frame/dfu.dart`):
break, `frame.update()`, find the bootloader by its DFU service `fe59` or
its name `Frame Update`, and hand the zip to `frame_ble`'s `BrilliantDfuDevice`. **The update wipes the
files on the glasses** -- `main.lua`, the modules, `settings.txt` -- although
DFU writes only the application partition (seen: the first Upload after it
found no `.lua` left to clear). So the app uploads the Lua again straight
after, in the same step, compiled by the new firmware's own Lua.

`frame.update()` goes as a write *with* response, and the phone waits for the
glasses to drop the link as they reset. Sent without response and
disconnected from at once, it could be lost: the glasses stayed in the app,
stopped, and the phone looked for a bootloader that was not there. No drop
within 10 s is now an error, not a silent search.

While in the bootloader the glasses look dead: dark, deaf to taps. That ends
by itself after 3 minutes, or with the dock (on and off the charger), but
only while a valid firmware is still there. An update whose old and new
builds together exceed the 824 KB application area (any two of ours, 600 to
660 KB each) erases the old one first (one bank), and if it then breaks off
the glasses stay in `Frame Update` until an image arrives: docs/RECOVERY.md,
section 6.

**From a computer**, Linux or macOS: `utils/dfu.py`, Nordic Secure DFU
over bleak, the same protocol the phone app speaks. It needs no pairing,
checks every 4 KB object by CRC32, resumes an update that broke off and
prints progress every 5 %:

```bash
python utils/dfu.py --enter build/frame-firmware-<version>.zip  # glasses running
python utils/dfu.py build/frame-firmware-<version>.zip          # already in Frame Update
```

About 2.5 KB/s from Linux, 4 to 5 minutes for a build. It replaces
nrf5-ota-dfu-python, which this section used to suggest: Python 2 code
driving the deprecated `gatttool`, which stalled for good on 25.10.2026
(docs/RECOVERY.md, section 6).

**nRF Connect on a phone** works too. Transfer the `.zip` to the phone,
connect to `Frame Update`, run DFU.

### Entering the bootloader

```bash
.venv/bin/python -c "
import asyncio
from frame_ble import FrameBle
async def main():
    f = FrameBle(); await f.connect()
    await f.send_break_signal(); await asyncio.sleep(0.6)
    try: await f.send_lua('frame.update()')
    except Exception: pass   # no reply is expected, it reboots
asyncio.run(main())"
```

Then scan for `Frame Update`. The window is **3 minutes**; letting it expire is
harmless, the glasses simply boot back into the app.

### Risk

Recoverable. A bad application still leaves the bootloader intact, and DFU can
be re-entered. Only a broken **bootloader** needs SWD, and SWD needs the
glasses physically opened. This branch touches neither the bootloader nor the
FPGA bitstream.

Reverting is re-flashing the official release `.zip`.

---

## Which side was tapped

Branch `tap-direction` (firmware and app). What the firmware does:

- `lua_imu_tap_callback_handler()` (`imu.c`) still reads status register
  `0x03` to clear the interrupt, and now passes the whole byte to the Lua
  callback: `frame.imu.tap_callback(function(status) ... end)`. A callback
  that takes no argument works as before.
- Per the datasheet (table 17) its bits are `0` X+, `1` X-, `2` Y+, `3` Y-,
  `4` Z+, `5` Z-, the same order as `INTEN` and `TAPEN`; bit 7 is
  `ACQ_INT` (a sample is ready) and can be set too, so mask with `0x3F`.
- `tap_config{threshold = {x =, y =, z =}}` sets a threshold per axis, so
  a direction that rings too easily can be made harder on its own.

Defaults are unchanged: `axes = 0x08` (-Y only), threshold `0x07` on every
axis, and `imu_prepare_wakeup()` restores them before sleep.

Still to measure on the glasses (none of this is confirmed yet):

- which bits a knock on the left arm, the right arm and the front sets,
  with `axes = 0x3F` in Tap tune; and whether the rebound sets the
  opposite sign;
- a threshold per axis that takes those knocks but not head movement;
- then widen the default `axes` beyond `0x08`, so the three sides become
  three different buttons, without counting taps.

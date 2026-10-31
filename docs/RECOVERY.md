# Disaster recovery

## Plain-language summary

Nothing we do to these glasses from a laptop is permanent. Lua code, the menu
app, even a whole custom firmware — all of it can be put back over Bluetooth.
There is exactly one way to truly break the device, and it requires physically
opening it, which we never do.

The flip side is that several failures **look** fatal and are not. The
glasses vanishing from Bluetooth is the usual one, and it has three ordinary
causes.

---

## Rule of thumb

| Layer | Broken by | Recovery | Needs |
| --- | --- | --- | --- |
| Lua app | bad `main.lua`, hung loop | break signal | host |
| Files | — | re-upload | host |
| Firmware app | bad custom build | DFU the official `.zip` | phone |
| Bootloader | flashing it wrong | SWD | **opening the glasses** |

We never touch the bootloader, and the FPGA bitstream cannot be written at all
from the normal path — it is compiled into the firmware and re-uploaded over
SPI at every boot. So every failure below sits in the top three rows.

---

## 1. The glasses are not in Bluetooth range

**By far the most common, and almost never a real fault.** In order of
likelihood:

1. **Another host holds them.** A connected BLE peripheral stops advertising,
   so the glasses become *completely invisible* — identical to being dead.
   The Noa app on a phone grabs them silently. Close it. AR Studio in VS Code
   does the same.
2. **In the charging case with the lid shut** — they are off.
3. **Flat battery.** Frame has no power switch and does not sleep on its own
   while an app loop runs; it just drains, rated about 4 hours.

**Charged, but stuck: wait for it to drain.** Hit in practice on
30.10.2026. The battery was not flat, yet the glasses would not wake, no
host could connect, and the reset button on the dock did nothing. A
computer saw no `Frame`, no `Frame Update` (`fe59`) and nothing new on USB
either: the dock's USB cable carries only power, so the glasses never show
up there. Charging changed nothing, however long they stayed on the dock.
What brought them back: leave them off the charger until the battery is
completely flat, then put them on the dock, let them charge and press
reset. Only after that full drain did the reset work. They came up as
before.

Confirm the radio is fine rather than guessing:

```bash
.venv/bin/python scripts/wait_for_frame.py
```

It scans for three minutes and prints how many other devices it sees. Plenty
of other devices and no Frame means the fault is on the glasses' side.

---

## 2. Connecting fails with `CBErrorDomain Code=15`

```
Failed to encrypt the connection, the connection has timed out unexpectedly.
```

Reproduces every attempt. **Hit in practice**: the glasses drained to 0%, reset
and lost their half of the BLE bond, while macOS kept its own and tried to
encrypt with a stale key.

```bash
system_profiler SPBluetoothDataType | grep -iA2 frame   # macOS still remembers it
open "x-apple.systempreferences:com.apple.Bluetooth-Settings.extension"
```

Forget `Frame AA` there — enable "Show all devices" if it is not listed, macOS
hides BLE-only hardware. Then reconnect and accept the pairing prompt.

> ⚠️ **The pinhole reset wipes flash.** Firmware calls
> `lua_open_file_library(L, !is_paired)` and that parameter is `reformat`, so
> unpairing reformats the filesystem — `main.lua` and every module go with it.
> Try forgetting the bond on the host first; reach for the pinhole (on the
> **charging dock**, not the frame) only if that fails, and expect to re-upload
> everything afterwards.

---

## 3. A Lua app is stuck, or the REPL will not answer

A running app owns the interpreter, so `send_lua()` times out with
`device didn't respond`. That is also how you *confirm* an app is running.

```python
await frame.send_break_signal()    # 0x03 -- abort the running script
await frame.send_reset_signal()    # 0x04 -- reinitialise Lua, run main.lua
```

`FrameMsg.connect()` already sends break → reset → break, the last one
specifically to interrupt an auto-starting `main.lua`. **So re-running the host
recovers a bad `main.lua` on its own** — there is no way to lock yourself out
with Lua.

Back to a known-good state:

```bash
.venv/bin/python scripts/host_test.py      # re-uploads modules and the app
```

---

## 4. The app is gone after a reset

Expected, not a fault. Only `main.lua` auto-runs — the firmware literally
executes `frame.stay_awake(false); require('main')`. The files survive in
flash; what is lost is the *running* chunk. Re-run the host.

If the files are genuinely gone, a pinhole reset happened — see the warning
above.

---

## 5. A custom firmware misbehaves

Our branch touches one file in the Lua layer. It cannot stop the device
booting, and tap settings are **not persisted**, so a power cycle restores the
compiled-in defaults even if `tap_config` was given something unusable.

To go back to stock:

1. Download the official release `.zip` from
   [frame-codebase/releases](https://github.com/brilliantlabsAR/frame-codebase/releases)
   (currently `v25.278.1113`).
2. `frame.update()` — reboots into the bootloader, advertises as
   `Frame Update`, times out after 3 minutes of inactivity.
3. DFU the `.zip`: `python scripts/dfu.py <zip>` from a computer (section 6),
   or nRF Connect on a phone.

If Lua is too broken to call `frame.update()`, send a break signal first; the
REPL comes back. `python scripts/dfu.py --enter <zip>` does both steps.

**Keep a known-good `.zip` on disk** so recovery never depends on having
network and a build toolchain at the same time.

---

## 6. Dark and deaf after an update: stuck in `Frame Update`

**Hit in practice on 25.10.2026.** A phone update to a larger build broke
off. Afterwards the glasses showed nothing, ignored taps, and the reset
button on the charger did nothing either. They were not dead: the
bootloader was running and waiting for an image, and it never draws.

Check before anything else. A computer sees the bootloader as `Frame
Update` with service `fe59`:

```bash
bluetoothctl --timeout 15 scan on | grep -i "frame update"
```

**Why it happens.** The bootloader updates in two banks when it can: the
new image goes next to the running one, and the old one is kept until the
new one is complete. When both do not fit in the application's 824 KB it
falls back to one bank (`NRF_DFU_SINGLE_BANK_APP_UPDATES 0` only means
"not forced"): it erases the running firmware first, then receives. If the
transfer breaks off after that, there is no firmware to go back to. Then
the 3 minute timeout does not apply, it starts only a valid application,
and the glasses stay in `Frame Update` until an image arrives. Our builds
are 600 to 660 KB, so any update between two of them is one-bank.

**The phone app cannot help here.** It sends the glasses to the
bootloader itself, from a connection to the running app, and has no way
to pick up glasses already sitting in it. A reset of the pairing does not
matter: the bootloader needs no bond.

**From a computer**, with the last build that worked:

```bash
python scripts/dfu.py flutter-glaz/assets/firmware/frame-firmware-<version>.zip
```

It finds `Frame Update`, sends the init packet and then the image in 4 KB
objects, each checked by CRC32 and sent again if it arrived wrong, and
prints its progress every 5 %. About 2.5 KB/s on Linux: 4 to 5 minutes
for 600 KB. If it stops, run it again: it resumes from what the glasses
hold. When it is done the glasses start the new firmware; the files on
them are gone, so upload the app again (phone app, or `upload`).

- **Keep them off the charger** while it runs: putting them on or taking
  them off the dock resets the bootloader. Before it starts, a dock cycle
  does no harm; it just comes back up as `Frame Update`.
- **Not nrf5-ota-dfu-python**, which this doc used to suggest: it is Python
  2 code with Python 3 syntax, drives the deprecated `gatttool`, and here
  it failed four ways before stalling for good at 3 KB.
- nRF Connect on a phone also works: copy the `.zip` to the phone,
  connect to `Frame Update`, DFU.

---

## 7. The device will not enter DFU at all

This is the only genuinely serious case. It means the bootloader is damaged,
which our workflow never writes — it would take a deliberate `flash-jlink` of
the bootloader.

Recovery needs SWD, and the SWD pads are inside: the hardware manual describes
"destructive disassembly" to reach them. The bootloader binary itself is in the
repo at `source/bootloader/frame-bootloader-v23.352.1005.hex`, so the software
side is covered; the obstacle is purely physical.

---

## Keeping a safety net

Stock firmware is already downloaded and verified, in `../frame-recovery/`:

| File | Use |
| --- | --- |
| `frame-firmware-v25.278.1113.zip` | **DFU over Bluetooth** — the one that matters |
| `frame-firmware-v25.278.1113.hex` | merged image for J-Link, needs the glasses opened |

See [`../../frame-recovery/README.md`](../../frame-recovery/README.md).

To check what is actually on the glasses:

```bash
.venv/bin/python scripts/connect.py        # prints firmware, battery, MTU
```

And the single most effective precaution, given how much time flat batteries
have cost here: **do not let the battery reach zero.** That is what broke the
pairing, and it is what makes the glasses look dead when they are not.

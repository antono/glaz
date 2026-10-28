# Battery drain investigation

## Plain-language summary

The glasses seemed to lose charge too fast. We measured it. Two findings:

1. **The battery percentage the glasses report is very noisy.** Two readings
   20 seconds apart can differ by 7–14 points. A single reading means almost
   nothing; only a trend over many readings does.
2. **While a laptop is connected, the glasses never go into deep sleep.** The
   app only parks itself in deep sleep when nobody is connected. During
   development a host script stays connected for hours, so the glasses stay
   fully awake the whole time. On top of that, the `Tilt` menu item kept the
   screen on until you closed it by hand. **Fixed:** it now closes itself
   after a minute without a tap.

Measured while connected: roughly **0.6 % per minute**, about **3 hours** from
full to empty. That is close to the rated ~4 hours, so nothing is obviously
broken. Instead, the power saving never gets a chance to kick in.

---

## Hardware

| Field | Value |
| --- | --- |
| Battery | 2 × 105 mAh = 210 mAh (see [`PLATFORM.md`](PLATFORM.md)) |
| Rated runtime with an app loop running | ~4 h (see [`PROTOCOL.md`](PROTOCOL.md)) |
| Firmware | `v25.080.0838` |

---

## Measurement 1: connected, REPL idle (2026-10-14)

**Setup.** Host connected over BLE, break signal sent (app stopped, REPL
idle), not on the dock, not worn, not tapped. `frame.battery_level()` polled
every 20 s for 6 minutes. Script: one `send_lua("print(frame.battery_level())")`
per sample.

| Time | +s | % | | Time | +s | % |
| --- | --- | --- | --- | --- | --- | --- |
| 00:14:29 | 0 | 84 | | 00:17:49 | 200 | 80 |
| 00:14:49 | 20 | 77 | | 00:18:09 | 220 | 78 |
| 00:15:09 | 40 | 83 | | 00:18:29 | 240 | 78 |
| 00:15:29 | 60 | 78 | | 00:18:49 | 261 | 75 |
| 00:15:49 | 80 | 81 | | 00:19:09 | 281 | 81 |
| 00:16:09 | 100 | 81 | | 00:19:29 | 301 | 79 |
| 00:16:29 | 120 | 80 | | 00:19:49 | 321 | 76 |
| 00:16:49 | 140 | 75 | | 00:20:09 | 341 | 79 |
| 00:17:09 | 160 | 83 | | 00:20:29 | 361 | 78 |
| 00:17:29 | 180 | 69 | | | | |

**Result.**

| Metric | Value |
| --- | --- |
| Samples | 19 |
| Range | 69–84 (spread 15 points) |
| Mean | 78.7 |
| Linear fit | **−0.57 % / min** (≈ 34 % / h, ≈ 3 h full to empty) |
| First 3 avg → last 3 avg | 81.3 → 77.7 |

**Caveat.** The noise (about ±4 points) is large next to six minutes of
drain. The slope's standard error is about ±0.45 %/min, so this number shows
the order of magnitude only. A longer run (30+ min), or averaging several
readings per sample, is needed for a firm figure.

### The reading is noisy

Earlier the same evening, two single readings about 2 minutes apart gave
85 and then 79. Inside the logged run, neighbouring samples jump by up to 14
points (83 → 69 → 80). The charge cannot physically move that fast. The
likely cause is that `battery_level()` is derived from cell voltage, which
sags while the radio transmits. This is an inference: the firmware docs do not
say how the value is computed.

**Rule:** never judge drain from one or two readings. Log a series and fit a
trend, or average several readings taken in a row.

---

## Verified on the device

| Check | Result |
| --- | --- |
| `frame.display.power_save` exists | yes, `pcall` returns `true` |
| `frame.camera.power_save` exists | yes, `pcall` returns `true` |
| `frame.bluetooth.is_connected` exists | yes; returns `true` while a host is attached |
| `frame.imu` has no power control | its keys are only `tap_callback`, `direction`, `raw` |

So the explicit power-down calls in `glaz.lua` really work. None of them
fails silently inside its `pcall`.

---

## Where the power goes (code review)

Ranked by likely impact.

### 1. Deep sleep is disabled whenever a host is connected

`glaz.lua:602`: deep sleep (`frame.sleep()` with no argument, line 622)
is used only when `not frame.bluetooth.is_connected()`. The reason is
deliberate: a host cannot reach an app parked in `frame.sleep()`.

The consequence: with `host_test.py` running, which is the normal development
setup and stays connected until Ctrl-C, the glasses **never** deep-sleep. They
sit in the `IDLE_PERIOD` loop (0.15 s, line 98) with the BLE link up
indefinitely. Any future host that keeps a permanent connection (a phone app)
will have the same problem.

### 2. `app`-mode modules never timed out — fixed

An `app` module (`Tilt` today) kept running until closed by hand. While it
runs:

- the display stays on,
- the loop runs at `ACTIVE_PERIOD = 0.01` (100 Hz, line 99),
- the IMU is read every `APP_TICK_PERIOD` (0.25 s).

In this session the last host event before the investigation was
`app START: 5`, which is Tilt. It was left running.

**Fix (applied).** `APP_TIMEOUT = 60` s in `glaz.lua`: an `app` module
closes itself after a minute with no tap, and a single tap restarts the
clock. Separately, the deep-sleep branch now closes any running module and the
menu before `frame.sleep()`. Rule: going to sleep closes whatever is open.

### 3. Brightness persists at whatever level was last chosen

`modules/brightness.lua` sets −2…2 (a picker), and the level stays until reboot. A
brighter panel costs more. Not measured.

### Already in place (working as intended)

- Display panel switched off when idle (`set_display`, line 212).
- Camera powered down and microphone stopped at boot and again after every
  module exits (`release_hardware`, line 283).
- IMU not polled while idle.
- Idle loop slowed from 0.05 s to 0.15 s.

---

## Not yet measured

- **Drain with the host disconnected**, where the app should deep-sleep after
  `SLEEP_AFTER = 30` s. This is the most important missing number. Method:
  read the battery, disconnect, leave the glasses untouched for 30+ minutes,
  reconnect and read again (several readings, averaged). Tapping wakes them.
- Whether the waking tap reaches `tap_callback`.
  [`scripts/test_deep_sleep.py`](../scripts/test_deep_sleep.py) exists for this,
  but no result is recorded yet.
- Drain with the menu or Tilt open (display on, 100 Hz loop).

---

## Possible fixes (not applied)

- Let deep sleep happen while connected, after a longer idle period, and have
  the host tolerate it. The host would need a tap, or a reconnect, to reach
  the app again.
- During development, stop `host_test.py` once you no longer need the event
  log. The app keeps running on the glasses.

---

## Doc drift found

[`PROTOCOL.md`](PROTOCOL.md) §"Power: nothing sleeps by itself" (line 460)
still shows `IDLE_PERIOD = 0.05` and says deep sleep is "available but not
used" (line 484). The code now uses 0.15 s and deep-sleeps when no host is
connected. §"The loop must not sleep long" (line 496) still talks about
`frame.sleep(0.001)` and `IMU_EVERY`, neither of which exists any more.

#!/usr/bin/env python3
"""Measure roll so the scroll threshold comes from data, not from taste.

Three phases: hold still (that is the noise floor), tilt right and back a few
times, tilt left and back a few times. Prints the spread of each phase and a
suggested threshold and dead zone.
"""
import asyncio
import statistics
import time

from frame_ble import FrameBle

PHASES = [
    ("still", 6, "HOLD STILL, look straight ahead"),
    ("right", 10, "TILT RIGHT toward your shoulder and back, a few times"),
    ("left", 10, "TILT LEFT toward your shoulder and back, a few times"),
]

READ = "local d=frame.imu.direction() print(string.format('%.1f', d.roll))"


async def sample(frame, seconds):
    out = []
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            out.append(float(await frame.send_lua(READ, await_print=True)))
        except (ValueError, TypeError):
            pass
    return out


async def main():
    frame = FrameBle()
    await frame.connect()
    await frame.send_break_signal()
    await asyncio.sleep(0.5)

    results = {}
    for name, seconds, prompt in PHASES:
        print(f"\n>>> {prompt}  ({seconds}s)")
        await asyncio.sleep(1.5)
        values = await sample(frame, seconds)
        results[name] = values
        rate = len(values) / seconds
        print(f"    {len(values)} samples, {rate:.0f} Hz")

    await frame.disconnect()

    print("\n--- measured ---")
    for name, values in results.items():
        if not values:
            print(f"{name}: no samples")
            continue
        print(f"{name:6} min={min(values):7.1f}  max={max(values):7.1f}  "
              f"median={statistics.median(values):7.1f}")

    still = results.get("still") or [0.0]
    base = statistics.median(still)
    noise = max(abs(v - base) for v in still)

    def reach(values):
        if not values:
            return 0.0
        return max(abs(v - base) for v in values)

    right_reach, left_reach = reach(results.get("right")), reach(results.get("left"))

    print(f"\nbaseline (median at rest): {base:.1f}")
    print(f"noise at rest (max deviation): {noise:.1f}")
    print(f"reach tilting right: {right_reach:.1f}")
    print(f"reach tilting left:  {left_reach:.1f}")

    usable = min(right_reach, left_reach)
    print(f"\nusable gesture amplitude (weaker side): {usable:.1f}")
    print("\nSuggestion: put the threshold about halfway between the noise")
    print("floor and the gesture amplitude, and the dead zone just above noise.")
    if usable > noise:
        print(f"  ROLL_THRESHOLD ~ {(noise + usable) / 2:.0f}")
        print(f"  DEADZONE       ~ {noise * 1.5:.0f}")
    else:
        print("  Gesture does not clear the noise floor -- retake the measurement.")


if __name__ == "__main__":
    asyncio.run(main())

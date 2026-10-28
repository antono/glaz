#!/usr/bin/env python3
"""Settle whether the tap that wakes Frame also reaches tap_callback.

frame.sleep() with no argument parks the device until a tap, and the docs say
"the tap gesture will always wake up Frame". That is by far the biggest power
saving available -- but it is only usable if the waking tap is ALSO delivered
to the callback. If the firmware swallows it, a triple tap arrives as two and
the menu becomes unreachable from the idle state.

Run it, then tap ONCE, promptly. The printed counter is the answer:
  1  -> the wake tap is delivered; deep sleep is safe to use
  0  -> the wake tap is swallowed; gesture counting would have to compensate
"""
import asyncio

from frame_ble import FrameBle


async def main():
    frame = FrameBle()
    await frame.connect()
    await frame.send_break_signal()
    await asyncio.sleep(0.5)

    await frame.send_lua(
        "taps=0;frame.imu.tap_callback(function() taps=taps+1 end);print(0)",
        await_print=True,
    )
    await frame.send_lua(
        "frame.display.text('sleeping - tap once', 60, 140);"
        "frame.display.show();print(0)",
        await_print=True,
    )

    print("Glasses are going to sleep. Tap ONCE, promptly.")
    try:
        answer = await frame.send_lua("frame.sleep();print(taps)", await_print=True)
    except Exception as exc:
        print(f"No reply: {exc}")
        print("Either the tap never arrived, or waking does not resume Lua.")
        await frame.disconnect()
        return

    print(f"\ntap_callback fired {answer} time(s) during the wake")
    if str(answer).strip() == "0":
        print("=> the wake tap is SWALLOWED. Deep sleep needs the gesture")
        print("   counter to treat the first tap after waking as consumed.")
    else:
        print("=> the wake tap IS delivered. Deep sleep can be used as-is.")

    await frame.send_lua(
        "frame.display.text('awake', 60, 140);frame.display.show();print(0)",
        await_print=True,
    )
    await frame.disconnect()


if __name__ == "__main__":
    asyncio.run(main())

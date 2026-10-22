#!/usr/bin/env python3
"""Try frame.display.mono, the monospace font of firmware branch
glaz/mono-font: every size and weight on one screen, then how fast a full
terminal screen redraws.

    python utils/mono_test.py              # show them, 30 s to look
    python utils/mono_test.py --look 60    # longer

Connects straight from the computer: the phone must let the glasses go
(turn Bluetooth off on it, or close Glaz). Stops the app on the glasses
with a break; reboot them, or Upload again, afterwards.
"""

import argparse
import asyncio
import time

from frame_ble import FrameBle

SAMPLE = "The quick brown fox {}[]|~ 0123 il1I"

# size, bold, color: two lines a size, normal and bold
ROWS = [
    (20, False, "WHITE"),
    (20, True, "WHITE"),
    (24, False, "LIGHTGREEN"),
    (24, True, "LIGHTGREEN"),
    (28, False, "YELLOW"),
    (28, True, "YELLOW"),
    (32, False, "CLOUDBLUE"),
    (32, True, "CLOUDBLUE"),
]


async def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--look", type=int, default=30, help="seconds to look")
    args = parser.parse_args()

    frame = FrameBle()
    print("Scanning for Frame... (wear or tap the glasses to wake them)")
    await frame.connect()
    await frame.send_break_signal()

    async def lua(code):
        return await frame.send_lua(code + ";print('ok')", await_print=True)

    print("Firmware:", await lua("print(frame.FIRMWARE_VERSION)"))
    if "nil" in await lua("print(frame.display.mono)"):
        print("No frame.display.mono: flash the glaz/mono-font build first.")
        await frame.disconnect()
        return

    await lua("M=frame.display.mono")
    await lua(f"S={SAMPLE!r}")
    y = 1
    for size, bold, color in ROWS:
        label = f"{size}{'b' if bold else 'n'} "
        await lua(
            f"M('{label}'..S,1,{y},{{size={size},bold={str(bold).lower()},color='{color}'}})"
        )
        y += size
    # a vim status line: text on a background
    await lua(
        f"M(' -- INSERT -- main.lua [+] ',1,{y + 4},"
        "{size=24,color='WHITE',bg='SEABLUE'})"
    )
    await lua("frame.display.show()")
    print(f"Look at the glasses: {args.look} s")
    await asyncio.sleep(args.look)

    # a 53x16 screen of 12x24 cells, redrawn whole, as a terminal would
    await lua(
        "function B(n) local L=string.rep('x',53) for k=1,n do "
        "for r=0,15 do M(L,1,r*24+1,{size=24}) end "
        "frame.display.show() end end"
    )
    for n in (1, 10):
        start = time.monotonic()
        await lua(f"B({n})")
        print(f"{n:2} full 53x16 redraws: {(time.monotonic() - start) * 1000:.0f} ms")

    await frame.disconnect()


if __name__ == "__main__":
    asyncio.run(main())

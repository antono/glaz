#!/usr/bin/env python3
"""Measure the actually-visible area of the display.

The docs say x is 1..640 and y is 1..400 with the origin at the upper-left,
and mention no safe area at all. In practice text at x=1 is clipped out of
the wearer's field of view, so the real bounds have to be measured.

Draws labelled markers at known coordinates; report which ones you can see.
"""
import asyncio

from frame_ble import FrameBle

# Markers along the left edge: digit N sits at x = LEFT_X_POSITIONS[N-1].
LEFT_X_POSITIONS = [1, 40, 80, 120, 160]
# Markers down the top edge: letter at y = TOP_Y_POSITIONS[i].
TOP_Y_POSITIONS = [1, 40, 80, 120, 160]


async def main():
    frame = FrameBle()
    await frame.connect()
    # main.lua owns the interpreter; take it back
    await frame.send_break_signal()
    await asyncio.sleep(0.5)

    parts = []

    # Horizontal ruler: digits 1..5 at increasing x, all on one mid-screen row.
    for i, x in enumerate(LEFT_X_POSITIONS, start=1):
        parts.append(f"frame.display.text('{i}',{x},200,{{color='WHITE'}})")

    # Vertical ruler: letters A..E at increasing y, well inside the left edge.
    for i, y in enumerate(TOP_Y_POSITIONS):
        letter = chr(ord("A") + i)
        parts.append(f"frame.display.text('{letter}',300,{y},{{color='GREEN'}})")

    # Far edges, to find where the visible area ends.
    parts.append("frame.display.text('R',600,200,{color='RED'})")
    parts.append("frame.display.text('B',300,370,{color='RED'})")

    # One draw call per message: the whole batch is ~600 bytes and the MTU is
    # 243, so it cannot go in a single send_lua.
    for part in parts:
        await frame.send_lua(f"{part};print(nil)", await_print=True)

    print("sent:", await frame.send_lua(
        "frame.display.show();print('ok')", await_print=True))
    print()
    print("Report what you can see:")
    print(f"  digits 1-5 sit at x = {LEFT_X_POSITIONS} (row y=200)")
    print(f"  letters A-E sit at y = {TOP_Y_POSITIONS} (column x=300)")
    print("  R is at x=600, B is at y=370")
    print()
    print("Leaving the markers up. Re-run host_test.py to restore the menu.")

    await frame.disconnect()


if __name__ == "__main__":
    asyncio.run(main())

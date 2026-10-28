#!/usr/bin/env python3
"""Drive the FPGA vector engine, which the Lua API does not expose.

The display hardware can draw cubic Beziers -- and with zeroed control points,
straight lines -- but frame.display has no entry point for it. The only way in
is frame.fpga_write() against register 0x13.

Payload, from frame-codebase/docs/fpga-architecture.md:

    x_start[15:0] y_start[15:0] x_end[15:0] y_end[15:0]
    ctrl1_x[15:0] ctrl1_y[15:0] ctrl2_x[15:0] ctrl2_y[15:0] color[7:0]

Byte order is big-endian and coordinates are 0-based. Both were taken from how
the firmware itself builds the sprite payload in lua_libraries/display.c, which
writes `x >> 8` then `x`, and comments its `x_position--` as "remove Lua 1
based offset before sending".

Control points are relative to the start and end points respectively.
Colour is a palette index, 0..15.

UNVERIFIED ON HARDWARE -- written from the RTL docs and firmware source.
"""
import asyncio

from frame_ble import FrameBle

DRAW_VECTOR = 0x13

PACK = "'>I2I2I2I2I2I2I2I2B'"


def vector(x0, y0, x1, y1, c1x=0, c1y=0, c2x=0, c2y=0, color=1):
    """One Lua statement writing a single vector to the FPGA."""
    args = f"{x0},{y0},{x1},{y1},{c1x},{c1y},{c2x},{c2y},{color}"
    return f"frame.fpga_write(0x{DRAW_VECTOR:02X}, string.pack({PACK},{args}))"


# Palette indices: 1 WHITE, 3 RED, 10 GREEN, 14 SKYBLUE
SHAPES = [
    ("straight line, white", vector(80, 60, 560, 60, color=1)),
    ("straight line, red", vector(80, 100, 560, 160, color=3)),
    ("curve, green", vector(80, 300, 560, 300, 0, -200, 0, -200, color=10)),
    ("curve, skyblue", vector(80, 200, 560, 200, 150, 120, -150, 120, color=14)),
]


async def main():
    frame = FrameBle()
    await frame.connect()
    await frame.send_break_signal()
    await asyncio.sleep(0.5)

    chip = await frame.send_lua(
        "print(string.byte(frame.fpga_read(0xDB, 1)))", await_print=True
    )
    print(f"FPGA chip id: {chip}  (0x81 = 129 means the FPGA is answering)")
    if str(chip).strip() != "129":
        print("Unexpected chip id -- register access is not working; stopping.")
        await frame.disconnect()
        return

    for label, statement in SHAPES:
        reply = await frame.send_lua(f"{statement};print(0)", await_print=True)
        print(f"  {label:24} -> {reply}")

    print(await frame.send_lua(
        "frame.display.show();print('shown')", await_print=True))
    print("\nLook at the glasses: two straight lines and two curves.")

    await frame.disconnect()


if __name__ == "__main__":
    asyncio.run(main())

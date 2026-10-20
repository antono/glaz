#!/usr/bin/env python3
"""Smoke test: connect to Frame, query the hardware, draw text."""
import asyncio

from frame_ble import FrameBle


async def main():
    frame = FrameBle()
    print("Scanning for Frame... (wear or tap the glasses to wake them)")
    await frame.connect()
    print("Connected.")

    async def ask(expr):
        return await frame.send_lua(f"print({expr})", await_print=True)

    print("Firmware:", await ask("frame.FIRMWARE_VERSION"))
    print("Battery :", await ask("frame.battery_level()"), "%")
    print("MTU     :", await ask("frame.bluetooth.max_length()"))

    # NB: frame.display.clear() was removed in v25.080.0838 -- the buffer
    # resets itself after show(). Our firmware's font has Cyrillic too.
    result = await frame.send_lua(
        "frame.display.text('Claude Code on air', 50, 137);"
        "frame.display.show();"
        "print('ok')",
        await_print=True,
    )
    print("Display :", result)

    await frame.disconnect()
    print("Disconnected.")


if __name__ == "__main__":
    asyncio.run(main())

#!/usr/bin/env python3
"""Reference host for the Frame menu. Exists only to exercise the protocol.

The real host may be anything (Flutter, etc.) -- all menu logic lives on the
glasses, and the menu items are Lua modules in modules/. This script uploads
them and then just listens. See frame_app.lua and PROTOCOL.md.
"""
import asyncio
from pathlib import Path

from frame_msg import FrameMsg

# Host -> Frame
MENU_SET = 0x20
MENU_HIDE = 0x21
MENU_SHOW = 0x22

# Frame -> Host
MENU_SELECT = 0x11
MENU_CURSOR = 0x12
MENU_OPEN = 0x13
MENU_CLOSE = 0x14
APP_START = 0x15
APP_STOP = 0x16

EVENTS = {
    MENU_SELECT: "SELECT",
    MENU_CURSOR: "cursor",
    MENU_OPEN: "menu opened",
    MENU_CLOSE: "menu hidden",
    APP_START: "app START",
    APP_STOP: "app stop",
}

MODULES_DIR = Path(__file__).parent / "modules"

# Deploy as main.lua so the menu is autonomous: the firmware auto-runs main.lua
# on power-on and after a reset, so the app survives disconnecting the host.
# Anything under another name (the default frame_app.lua) has to be require()d
# by a host every time, and stop_frame_app()'s reset signal leaves it stopped.
#
# This is safe to re-upload over: FrameMsg.connect() sends break/reset/break,
# and that last break exists precisely to interrupt an auto-starting main.lua.
FRAME_APP_NAME = "main"


async def main():
    frame = FrameMsg()
    await frame.connect()
    print("Connected.")

    # Not print_short_text(): that helper hardcodes (1, 1), which is in the
    # clipped corner. Measured usable area: see PROTOCOL.md.
    #
    # Drawn twice on purpose. The firmware paints its own "frame is paired"
    # banner shortly after the link comes up, and it lands on top of whatever
    # we drew -- show() does clear the buffer, but the firmware writes after
    # us. The second pass overwrites it.
    loading = ("frame.display.text('loading...', 60, 140);"
               "frame.display.show();print(0)")
    await frame.send_lua(loading, await_print=True)
    await asyncio.sleep(1.0)
    await frame.send_lua(loading, await_print=True)
    await frame.upload_stdlua_libs(lib_names=["data"])

    # One module per menu item. frame_app.lua requires them by bare name,
    # so each must land at /<name>.lua on the device.
    for path in sorted(MODULES_DIR.glob("*.lua")):
        await frame.upload_file(str(path), path.name)
        print(f"  module: {path.name}")

    await frame.upload_frame_app(
        local_filename="frame_app.lua",
        frame_filename=f"{FRAME_APP_NAME}.lua",
    )
    frame.attach_print_response_handler()
    await frame.start_frame_app(frame_app_name=FRAME_APP_NAME)
    print(f"Frame app started (deployed as {FRAME_APP_NAME}.lua).")

    def on_event(payload: bytes):
        code, index = payload[0], payload[1]
        print(f"  {EVENTS.get(code, hex(code))}: {index}")

    frame.register_data_response_handler(on_event, list(EVENTS), on_event)

    print("\nDouble tap  -- launch the app under the cursor / close it")
    print("Triple tap  -- open or hide the menu")
    print("Single tap  -- run the highlighted item (menu only)")
    print("Tilt        -- scroll the menu")
    print("'info' apps clear themselves after 5s; the menu hides after 10s.")
    print("Ctrl-C to quit.\n")

    try:
        while True:
            await asyncio.sleep(1)
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        frame.unregister_data_response_handler(on_event)
        frame.detach_print_response_handler()
        # break + reset. The reset boots main.lua, so the menu comes straight
        # back and keeps working on the glasses after the host goes away.
        await frame.stop_frame_app()
        await frame.disconnect()
        print("\nDisconnected. The menu keeps running on the glasses.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

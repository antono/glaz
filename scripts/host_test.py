#!/usr/bin/env python3
"""Reference host for the Frame menu. Exists only to exercise the protocol.

The real host may be anything (Flutter, etc.) -- all menu logic lives on the
glasses, and the menu items are Lua modules in modules/. This script uploads
them and then just listens. See glaz.lua and docs/PROTOCOL.md.
"""
import asyncio
import os
import struct
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

from frame_msg import FrameMsg, RxPhoto

# Host -> Frame
MENU_SET = 0x20
MENU_HIDE = 0x21
MENU_SHOW = 0x22
CLOCK_SET = 0x23
NOTIFY = 0x24
NET_RESPONSE = 0x25

# Frame -> Host
MENU_SELECT = 0x11
MENU_CURSOR = 0x12
MENU_OPEN = 0x13
MENU_CLOSE = 0x14
APP_START = 0x15
APP_STOP = 0x16
MENU_LEVEL = 0x17
APP_BACKGROUND = 0x18
NET_REQUEST = 0x19

EVENTS = {
    MENU_SELECT: "SELECT",
    MENU_CURSOR: "cursor",
    MENU_OPEN: "menu opened",
    MENU_CLOSE: "menu hidden",
    APP_START: "app START",
    APP_STOP: "app stop",
    MENU_LEVEL: "menu depth",
    APP_BACKGROUND: "app to background",
}

ROOT = Path(__file__).resolve().parent.parent
MODULES_DIR = ROOT / "modules"
SPRITES_DIR = ROOT / "sprites"
# glaz.lua and its parts in files of their own (glaz_host.lua and the
# rest): main.lua in one piece no longer fits the glasses' memory to compile.
APP_DIR = ROOT / "glaz"

# The Camera module (modules/photo.lua) streams each JPEG in chunks flagged
# 0x07 / 0x08 -- the frame_msg camera library's own codes. Saved here.
PHOTOS_DIR = ROOT / "photos"

# Internet for modules (_M.host.http, docs/PROTOCOL.md "Internet"). The phone
# asks the user per module; here the permission is a comma-separated list of
# module names, or '*' for all. Limits match the phone's.
NET_ALLOW = {m.strip() for m in os.environ.get("FRAME_NET_ALLOW", "*").split(",")}
NET_TIMEOUT = 15        # seconds; the glasses give up after 20
NET_BODY_MAX = 4096     # what fits next to the app in the glasses' memory

# Notifications (docs/PROTOCOL.md "Notifications"): the phone forwards its
# own; here, the desktop's. Off with FRAME_NOTIFY=0.
NOTIFY_ON = os.environ.get("FRAME_NOTIFY", "1") != "0"
NOTIFY_TEXT_MAX = 200

# Our firmware's font has ASCII, Latin-1 and Cyrillic (docs/FIRMWARE.md);
# the rest is dropped. The phone does it more carefully (glyphs.dart).
def for_glasses(text: str) -> str:
    return "".join(ch for ch in text
                   if " " <= ch <= "~" or "\u00a1" <= ch <= "\u00ff"
                   or "\u0400" <= ch <= "\u045f")

# Deployed as the phone does it (lib/frame/upload.dart): glaz.lua as
# glaz_app.lua, and main.lua is glaz_boot's part for Frame, which loads it.
# The firmware auto-runs main.lua on power-on and after a reset, so the app
# survives disconnecting the host.
#
# This is safe to re-upload over: FrameMsg.connect() sends break/reset/break,
# and that last break exists precisely to interrupt an auto-starting main.lua.
#
# Only Frame's parts go up (docs/DEVICES.md): name.lua is the same on all
# glasses, name.frame.lua is its part for Frame, and a module without one
# is not Frame's. This host speaks to Frame only (frame_msg).
DEVICE = "frame"
APP_NAME = "glaz_app"


def device_of(path: Path) -> str | None:
    """The glasses a part is for (reader.frame.lua -> 'frame'), or None."""
    parts = path.name.split(".")
    return parts[-2] if len(parts) >= 3 and parts[-2] in ("frame", "halo") else None


def ours(path: Path) -> bool:
    """A file for every pair of glasses, or Frame's part."""
    return device_of(path) in (None, DEVICE)


async def wait_for_repl(frame, attempts=6):
    """Wait until the Lua REPL answers after connect()'s break/reset/break.

    The reset re-runs main.lua, and the trailing break can go missing: the app
    loads each module inside pcall() so a broken one cannot take the menu
    down, and a break landing there is caught as a load error -- the app
    keeps running. Measured: anything from a 5.5 s delay (past send_lua()'s
    fixed 5 s timeout) to no effect at all. So ping with a unique token, and
    send the break again after every unanswered ping; most of the time the
    app sits in its main loop, where a break does stop it.

    Late replies to earlier pings, and the 'break signal' message, are skipped:
    frame_ble queues the first print after each request, whoever sent it.
    """
    ble = frame.ble
    for n in range(1, attempts + 1):
        token = f"ready{n}"
        try:
            reply = await frame.send_lua(f"print('{token}')", await_print=True)
            while reply != token:
                ble._awaiting_print_response = True
                reply = await asyncio.wait_for(ble._print_response.get(), 5)
            return
        except Exception:
            await ble.send_break_signal()   # the last one may have been eaten
    raise Exception("Frame REPL did not come back after reset")


def http_fetch(request: bytes) -> tuple[int, bytes]:
    """Run one module request, 'module\nMETHOD\nurl\nbody'. Blocking."""
    module, method, url, body = (request.decode("ascii", "replace")
                                 .split("\n", 3) + ["", "", ""])[:4]
    if "*" not in NET_ALLOW and module not in NET_ALLOW:
        return 403, b"not allowed: FRAME_NET_ALLOW"
    if method not in ("GET", "POST") or not url.startswith(("http://", "https://")):
        return 400, b"bad request"
    # curl's user agent: services like wttr.in answer it with plain text
    req = urllib.request.Request(
        url, data=body.encode() if method == "POST" else None, method=method,
        headers={"User-Agent": "curl/8"})
    try:
        with urllib.request.urlopen(req, timeout=NET_TIMEOUT) as resp:
            return resp.status, resp.read(NET_BODY_MAX)
    except urllib.error.HTTPError as e:
        return e.code, e.read(NET_BODY_MAX)
    except Exception as e:  # network error, timeout: status 0, body says why
        return 0, str(e).encode("ascii", "replace")[:NET_BODY_MAX]


async def watch_desktop_notifications(on_notify):
    """Call on_notify(app, title, text) for every desktop notification.

    GNOME Shell is the org.freedesktop.Notifications server; apps reach it
    with a Notify method call on the session bus. A monitor connection sees
    those calls without taking part. Linux only: returns quietly where there
    is no session bus.
    """
    try:
        from dbus_fast import BusType, Message, MessageType
        from dbus_fast.aio import MessageBus
        bus = await MessageBus(bus_type=BusType.SESSION).connect()
    except Exception as e:
        print(f"  notifications: off ({e})")
        return
    rule = ("type='method_call',interface='org.freedesktop.Notifications',"
            "member='Notify'")
    await bus.call(Message(
        destination="org.freedesktop.DBus", path="/org/freedesktop/DBus",
        interface="org.freedesktop.DBus.Monitoring", member="BecomeMonitor",
        signature="asu", body=[[rule], 0]))

    def on_message(msg):
        # Notify(app_name, replaces_id, app_icon, summary, body, ...). Only
        # calls to the well-known name: a proxy in between forwards each one
        # again to the shell's unique name, and that copy is skipped.
        if (msg.message_type == MessageType.METHOD_CALL and msg.member == "Notify"
                and msg.destination == "org.freedesktop.Notifications"):
            app, _, _, title, text = msg.body[:5]
            on_notify(app, title, text)
        # handled: a monitor must never reply to someone else's call
        return True

    bus.add_message_handler(on_message)
    print("  notifications: forwarding the desktop's")
    await bus.wait_for_disconnect()


async def start_app(frame, name, timeout=20):
    """require() the app and wait for its 'Frame app is running' line.

    Not frame.start_frame_app(): that waits a fixed 5 s for the first print,
    and loading every module plus packing the splash sprite takes longer.
    """
    ble = frame.ble
    await frame.send_lua(f"require('{name}')")
    # flag set after sending: send_lua(await_print=False) clears it, and the
    # app takes seconds before it prints anything
    ble._awaiting_print_response = True
    reply = await asyncio.wait_for(ble._print_response.get(), timeout)
    if reply != "Frame app is running":
        raise Exception(f"app did not start: {reply}")


async def main():
    frame = FrameMsg()
    # Not connect()'s own break/reset/break: the reset reboots main.lua, and
    # with the app installed the glasses then dropped the link a few seconds
    # later, every time (measured; cause not found). Instead: break the
    # running app, take main.lua out of the way, and only then reset -- into
    # a bare REPL with all memory free for the upload. The upload below
    # writes main.lua back.
    await frame.connect(initialize=False)
    print("Connected.")
    await wait_for_repl(frame)
    await frame.send_lua("pcall(frame.file.remove, 'main.lua');print('cleared')",
                         await_print=True)
    await frame.ble.send_reset_signal()
    await wait_for_repl(frame)

    # Not print_short_text(): that helper hardcodes (1, 1), which is in the
    # clipped corner. Measured usable area: see docs/PROTOCOL.md.
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
    # 'camera' is the frame_msg capture library, used by modules/photo.lua
    await frame.upload_stdlua_libs(lib_names=["data", "camera"])

    # One module per menu item. glaz.lua requires them by bare name,
    # so each must land at /<name>.lua on the device; glaz.lua and its
    # part go up as glaz_app, and glaz_boot's part as main.lua, last.
    for path in sorted(APP_DIR.glob("*.lua")):
        if (not ours(path) or path.name.startswith("glaz_boot.")
                or path.name.split(".")[0] == "glaz"):
            continue
        await frame.upload_file(str(path), path.name)
        print(f"  app part: {path.name}")

    modules = {p.name.split(".")[0] for p in MODULES_DIR.glob(f"*.{DEVICE}.lua")}
    for path in sorted(MODULES_DIR.glob("*.lua")):
        if not ours(path) or path.name.split(".")[0] not in modules:
            continue
        await frame.upload_file(str(path), path.name)
        print(f"  module: {path.name}")

    # Sprites (sprites/*.lua, the splash art) land at the root the same way.
    for path in sorted(SPRITES_DIR.glob("*.lua")):
        await frame.upload_file(str(path), path.name)
        print(f"  sprite: {path.name}")

    await frame.upload_file(str(APP_DIR / f"glaz.{DEVICE}.lua"),
                            f"{APP_NAME}.{DEVICE}.lua")
    await frame.upload_file(str(APP_DIR / "glaz.lua"), f"{APP_NAME}.lua")
    await frame.upload_frame_app(
        local_filename=str(APP_DIR / f"glaz_boot.{DEVICE}.lua"),
        frame_filename="main.lua",
    )
    frame.attach_print_response_handler()
    await start_app(frame, "main")
    print("Frame app started (main.lua loads glaz_app.lua).")

    def on_event(payload: bytes):
        code, index = payload[0], payload[1]
        print(f"  {EVENTS.get(code, hex(code))}: {index}")

    frame.register_data_response_handler(on_event, list(EVENTS), on_event)

    # A request arrives as [0x19, id, more, bytes...] packets, more = 0 on
    # the last; answered with one NET_RESPONSE: id, status, body.
    net_parts: dict[int, bytes] = {}
    net_tasks: set[asyncio.Task] = set()

    async def answer(req_id: int, request: bytes):
        status, body = await asyncio.to_thread(http_fetch, request)
        module, method, url = request.decode(errors="replace").split("\n")[:3]
        print(f"  net {module}: {method} {url} -> {status}")
        if not frame.ble.is_connected():
            print("  net: not answered, the glasses are gone")
            return
        await frame.send_message(NET_RESPONSE,
                                 struct.pack(">BH", req_id, status) + body)

    def on_net(payload: bytes):
        req_id, more = payload[1], payload[2]
        net_parts[req_id] = net_parts.get(req_id, b"") + payload[3:]
        if more:
            return
        task = asyncio.create_task(answer(req_id, net_parts.pop(req_id)))
        net_tasks.add(task)
        task.add_done_callback(net_tasks.discard)

    frame.register_data_response_handler(on_net, [NET_REQUEST], on_net)

    async def notify(app: str, title: str, text: str):
        # one line each: newlines inside a field would shift the fields
        app, title, text = (for_glasses(" ".join(f.split())) for f in (app, title, text))
        if not frame.ble.is_connected():
            # frame_ble would crash on the zero MTU of a dropped link
            print(f"  notify: not sent, the glasses are gone: {app}: {title}")
            return
        print(f"  notify: {app}: {title}")
        # cut in bytes, between characters
        text = text.encode()[:NOTIFY_TEXT_MAX].decode(errors="ignore")
        await frame.send_message(NOTIFY, f"{app}\n{title}\n{text}".encode())

    def on_notify(app, title, text):
        task = asyncio.create_task(notify(app, title, text))
        net_tasks.add(task)
        task.add_done_callback(net_tasks.discard)

    notify_watch = (asyncio.create_task(watch_desktop_notifications(on_notify))
                    if NOTIFY_ON else None)

    # The glasses have no idea what time it is: frame.time.utc() counts from
    # boot. Send unix time and the local UTC offset; the app keeps only the
    # difference, for the clock in the top bar. See docs/PROTOCOL.md.
    offset = datetime.now().astimezone().utcoffset()
    tz_minutes = int(offset.total_seconds() // 60) if offset else 0
    await frame.send_message(CLOCK_SET,
                             struct.pack(">Ih", int(time.time()), tz_minutes))

    # RxPhoto reassembles the chunks and turns the image upright (the sensor
    # is mounted rotated).
    rx_photo = RxPhoto()
    photo_queue = await rx_photo.attach(frame)

    async def save_photos():
        PHOTOS_DIR.mkdir(exist_ok=True)
        while True:
            jpeg = await photo_queue.get()
            # milliseconds too: two shots in one second must not collide
            ms = int(time.time() * 1000) % 1000
            path = PHOTOS_DIR / time.strftime(f"frame-%Y%m%d-%H%M%S-{ms:03d}.jpg")
            path.write_bytes(jpeg)
            print(f"  photo saved: photos/{path.name} ({len(jpeg) // 1024} KB)")

    photo_saver = asyncio.create_task(save_photos())

    print("\nSingle tap  -- select: run the item or enter the submenu;\n"
          "              on a blank screen, back to the last app")
    print("Double tap  -- back one level: app -> submenu -> root -> blank\n"
          "              (a background app keeps running)")
    print("Triple tap  -- open or hide the menu")
    print("Tilt        -- scroll the menu, or an app's own cursor")
    print("'info' apps clear themselves after 5s; the menu hides after 10s.")
    print("Ctrl-C to quit.\n")

    try:
        while True:
            await asyncio.sleep(1)
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        photo_saver.cancel()
        if notify_watch:
            notify_watch.cancel()
        rx_photo.detach(frame)
        frame.unregister_data_response_handler(on_event)
        frame.unregister_data_response_handler(on_net)
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

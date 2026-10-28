#!/usr/bin/env python3
"""Talk to the Flipper's Glaz app (flipper-glaz/) from a computer.

Connects to the glaz service, prints every press the Flipper sends, and
writes it a status, as glaz on the phone would: the Flipper then shows
glasses named "Frame 137". Pairs on the first run (confirm the PIN on
the Flipper). Open Apps > Bluetooth > Glaz on the Flipper first.

    python scripts/flipper_keys.py [--name "Frame 137"]

A connected Flipper does not advertise: if this does not find it, see
that nothing else holds it (bluetoothctl disconnect).
"""
import argparse
import asyncio
import struct

from bleak import BleakClient, BleakScanner

SERVICE = "a96fe95e-083f-402e-8be1-a9d5235813ca"
STATUS = "99a2eadd-2f24-4073-b412-56fc14ba5ecb"
KEYS = "fdf4c755-bc63-4750-9c39-e6ee8b8f55e9"

KEY_NAMES = {1: "Up", 2: "Down", 3: "Left", 4: "Right", 5: "OK", 6: "Back"}
PRESS_NAMES = {1: "short", 2: "long", 3: "repeat"}


def status(name, battery, disk, mem, app):
    """The status as Status::parse in flipper-glaz/src/main.rs reads it."""
    out = bytearray([1])
    for tag, text in ((1, name), (4, app)):
        b = text.encode("ascii", "replace")[:23]
        out += bytes([tag, len(b)]) + b
    for tag, n in ((2, disk), (3, mem)):
        out += bytes([tag, 4]) + struct.pack("<I", n)
    out += bytes([5, 1, battery])
    return bytes(out)


def on_keys(_char, data: bytearray):
    if len(data) != 3 or data[0] != 1:
        print("keys?", data.hex())
        return
    key = KEY_NAMES.get(data[1], f"key {data[1]}")
    press = PRESS_NAMES.get(data[2], f"press {data[2]}")
    print(key, press)


async def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--name", default="Frame 137", help="the glasses' name")
    args = p.parse_args()

    print("Looking for the Flipper's Glaz app...")
    device = await BleakScanner.find_device_by_filter(
        lambda _d, adv: SERVICE in adv.service_uuids, timeout=20
    )
    if device is None:
        print("Not found: is Glaz open on the Flipper?")
        return
    print("Found", device.name, device.address)
    async with BleakClient(device) as client:
        await client.pair()
        await client.start_notify(KEYS, on_keys)
        # The Flipper drops a status written in pieces.
        print("MTU", client.mtu_size)
        await client.write_gatt_char(
            STATUS, status(args.name, 37, 137 * 1024, 137 * 1024, "Menu"), response=True
        )
        print("Status written; press the Flipper's keys, Ctrl-C to stop.")
        while client.is_connected:
            await asyncio.sleep(1)
    print("Disconnected.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

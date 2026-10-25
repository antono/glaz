#!/usr/bin/env python3
"""Install a firmware .zip on the glasses over Bluetooth (Nordic Secure DFU).

The way back when the phone app cannot do it: the glasses sit in the
bootloader ("Frame Update", dark, deaf to taps and to the reset button)
after an update that broke off, or the phone is not paired any more. The
bootloader needs no pairing, so any computer with Bluetooth will do.

    python utils/dfu.py firmware.zip            # glasses already in Frame Update
    python utils/dfu.py --enter firmware.zip    # glasses running: send them there
    python utils/dfu.py --address E0:EF:CE:1C:08:16 firmware.zip

--address is the real MAC on Linux (bluetoothctl shows it); macOS gives a
CoreBluetooth UUID instead. Without it the first "Frame Update" found is
used.

The .zip is what `nrfutil pkg generate` makes (docs/FIRMWARE.md); the ones
the phone app ships are in flutter-glaz/assets/firmware/. Keep the glasses
off the charger while it runs: docking or undocking resets the bootloader.

Why not nrf5-ota-dfu-python, which docs/FIRMWARE.md used to point at: it is
Python 2 code under a Python 3 coat, drives the deprecated gatttool, and on
25.10.2026 it stalled for good after the first 3 KB. This speaks the same
protocol through bleak, one request at a time, and checks every object.

The protocol (nRF5 SDK 15, "DFU over BLE"): service fe59 has a control
point, written with response and answering by notification, and a data
point, written without response. The init packet (application.dat, the
signed description of the image) goes as one "command" object, the image
(application.bin) as "data" objects of at most 4096 bytes each. Every
object is created, filled, checked by CRC32 and executed; executing the
last one makes the bootloader check the signature, copy the image in place
and start it. An object that arrives wrong is sent again; an update that
broke off resumes where the glasses' own CRC says it is still good.
"""

import argparse
import asyncio
import json
import struct
import sys
import time
import zipfile
import zlib

from bleak import BleakClient, BleakScanner

DFU_SERVICE = "0000fe59-0000-1000-8000-00805f9b34fb"
CONTROL = "8ec90001-f315-4f60-9fb8-838830daea50"
PACKET = "8ec90002-f315-4f60-9fb8-838830daea50"
NAME = "Frame Update"

# control point opcodes
CREATE, SET_PRN, CALC_CRC, EXECUTE, SELECT = 0x01, 0x02, 0x03, 0x04, 0x06
RESPONSE = 0x60
COMMAND_OBJECT, DATA_OBJECT = 0x01, 0x02

RESULTS = {
    0x00: "invalid opcode",
    0x02: "opcode not supported",
    0x03: "invalid parameter",
    0x04: "insufficient resources",
    0x05: "invalid object",
    0x07: "unsupported type",
    0x08: "operation not permitted",
    0x0A: "operation failed",
}
# the extended error (result 0x0B) of nrf_dfu_req_handler.h
EXTENDED = {
    0x01: "wrong command format",
    0x02: "unknown command",
    0x03: "init command invalid",
    0x04: "firmware version too low",
    0x05: "hardware version mismatch",
    0x06: "SoftDevice version mismatch (--sd-req)",
    0x07: "signature missing",
    0x08: "wrong hash type",
    0x09: "hash failed",
    0x0A: "wrong signature type",
    0x0B: "verification failed: not signed with the repository's key",
    0x0C: "not enough space for the image",
}

TRIES = 3  # per object, before giving up


class DfuError(Exception):
    pass


def read_zip(path):
    """(init packet, image) of the application in a DFU .zip."""
    with zipfile.ZipFile(path) as z:
        manifest = json.loads(z.read("manifest.json"))["manifest"]
        if set(manifest) != {"application"}:
            # a SoftDevice or bootloader update is not ours to make: a broken
            # bootloader is the one thing that bricks the glasses
            sys.exit(f"{path}: has {', '.join(manifest)}, not only an application")
        app = manifest["application"]
        return z.read(app["dat_file"]), z.read(app["bin_file"])


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


class Dfu:
    def __init__(self, client):
        self.client = client
        self.answers = asyncio.Queue()
        # bluez says 23 until the MTU exchange is done; 244 is what the
        # glasses settle on (docs/PLATFORM.md), 20 is always safe
        self.chunk = max(20, min(client.mtu_size - 3, 244))

    async def start(self):
        await self.client.start_notify(CONTROL, lambda _, data: self.answers.put_nowait(bytes(data)))
        # no receipts while an object is sent: the CRC after it checks it all
        await self.request(SET_PRN, struct.pack("<H", 0))

    async def request(self, opcode, payload=b""):
        """Sends a request; its answer's payload, or DfuError."""
        await self.client.write_gatt_char(CONTROL, bytes([opcode]) + payload, response=True)
        try:
            answer = await asyncio.wait_for(self.answers.get(), 10)
        except asyncio.TimeoutError:
            raise DfuError(f"no answer to opcode {opcode:#04x}")
        if answer[0] != RESPONSE or answer[1] != opcode:
            raise DfuError(f"answer {answer.hex()} to opcode {opcode:#04x}")
        result = answer[2]
        if result == 0x0B:
            raise DfuError(EXTENDED.get(answer[3], f"extended error {answer[3]:#04x}"))
        if result != 0x01:
            raise DfuError(RESULTS.get(result, f"result {result:#04x}"))
        return answer[3:]

    async def select(self, kind):
        """(max object size, offset, crc) of what the glasses hold of kind."""
        return struct.unpack("<III", (await self.request(SELECT, bytes([kind])))[:12])

    async def check(self):
        """(offset, crc) of everything received so far."""
        return struct.unpack("<II", (await self.request(CALC_CRC))[:8])

    async def send_object(self, kind, data, start, end):
        """Creates an object for data[start:end], sends it and checks it."""
        for attempt in range(TRIES):
            await self.request(CREATE, bytes([kind]) + struct.pack("<I", end - start))
            for i in range(start, end, self.chunk):
                await self.client.write_gatt_char(PACKET, data[i:min(i + self.chunk, end)], response=False)
            offset, crc = await self.check()
            if offset == end and crc == crc32(data[:end]):
                return
            print(f"  object at {start} arrived wrong (offset {offset}), again")
        raise DfuError(f"object at {start} failed {TRIES} times")

    async def execute(self):
        await self.request(EXECUTE)

    async def send_init(self, init, image):
        """Sends the init packet; where in the image to start."""
        _, offset, crc = await self.select(COMMAND_OBJECT)
        if offset == len(init) and crc == crc32(init):
            # the same update broke off: resume it if what the glasses hold
            # of the image is good. Only a new init packet clears the image
            # received so far; a CREATE alone goes back one object at most.
            _, offset, crc = await self.select(DATA_OBJECT)
            if 0 < offset <= len(image) and crc == crc32(image[:offset]):
                try:
                    await self.execute()
                except DfuError:
                    pass  # executed before it broke off
                return offset
        await self.send_object(COMMAND_OBJECT, init, 0, len(init))
        # the bootloader checks the signature and the sizes here
        await self.execute()
        return 0

    async def send_image(self, image, offset, report):
        size, _, _ = await self.select(DATA_OBJECT)
        # carry on from the last whole object; one that is complete but not
        # executed yet is executed first
        start = offset - offset % size
        if start and start == offset:
            try:
                await self.execute()
            except DfuError:
                pass  # it was executed already
        if start:
            print(f"resuming at {start} of {len(image)} bytes")
        for begin in range(start, len(image), size):
            end = min(begin + size, len(image))
            await self.send_object(DATA_OBJECT, image, begin, end)
            if end == len(image):
                # the last execute starts the new firmware; the glasses may
                # reset before their answer comes
                try:
                    await self.execute()
                except Exception:
                    pass
            else:
                await self.execute()
            report(end)


async def enter_bootloader():
    """Sends running glasses into the bootloader, as the phone app does."""
    from frame_ble import FrameBle

    frame = FrameBle()
    print("Connecting to the glasses (tap them to wake them)...")
    await frame.connect()
    await frame.send_break_signal()
    await asyncio.sleep(0.6)
    try:
        await frame.send_lua("frame.update()")
    except Exception:
        pass  # no answer: they reset
    try:
        await frame.disconnect()
    except Exception:
        pass


async def find(address):
    print(f"Looking for {address or NAME}...")
    found = await BleakScanner.discover(timeout=10, return_adv=True)
    for device, adv in found.values():
        if address:
            if device.address.upper() == address.upper():
                return device
        elif adv.local_name == NAME or DFU_SERVICE in adv.service_uuids:
            return device
    sys.exit(f"{address or NAME} not found: are the glasses in the bootloader, near, off the charger?")


async def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("zip", help="the firmware .zip")
    parser.add_argument("--address", help="the bootloader's address, if more than one Frame is near")
    parser.add_argument("--enter", action="store_true", help="the glasses are running: send them into the bootloader first")
    args = parser.parse_args()

    init, image = read_zip(args.zip)
    print(f"{args.zip}: image {len(image)} bytes, CRC32 {crc32(image):08X}")

    if args.enter:
        await enter_bootloader()
        await asyncio.sleep(2)
    device = await find(args.address)
    print(f"Connecting to {device.address}...")

    async with BleakClient(device, timeout=20) as client:
        # bluez knows the MTU only once asked; without it writes are 20 bytes
        acquire = getattr(client._backend, "_acquire_mtu", None)
        if acquire:
            try:
                await acquire()
            except Exception:
                pass
        dfu = Dfu(client)
        await dfu.start()
        offset = await dfu.send_init(init, image)
        print(f"Init packet accepted; sending the image in {dfu.chunk} byte writes")

        began = time.monotonic()
        step = [-1]

        def report(done):
            # a line every 5 %, so a log shows it as well as a terminal
            percent = done * 100 // len(image)
            if percent // 5 > step[0] or done == len(image):
                step[0] = percent // 5
                took = time.monotonic() - began
                rate = done / took / 1024 if took else 0
                print(f"  {percent:3d}%  {done // 1024:4d} of {len(image) // 1024} KB  {rate:4.1f} KB/s", flush=True)

        await dfu.send_image(image, offset, report)

    took = time.monotonic() - began
    print(f"Done in {int(took // 60)} min {int(took % 60)} s: the glasses check the image and start it.")
    print("Then upload the app again: the update wipes the files on the glasses.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except DfuError as e:
        sys.exit(f"DFU failed: {e}. Run it again: it resumes.")

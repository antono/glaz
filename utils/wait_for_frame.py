#!/usr/bin/env python3
"""Wait until Frame starts advertising, then report it.

The default connect() timeout is 10s, which is easy to miss: a Frame on low
battery or deep idle advertises infrequently. This keeps scanning and prints
the moment it shows up, so there is no need to time the retry by hand.
"""
import asyncio
import sys

from bleak import BleakScanner

SERVICE = "7a230001-5475-a6a4-654c-8431f6ad49c4"
TOTAL_SECONDS = 180
SCAN_CHUNK = 10.0


def is_frame(device, adv) -> bool:
    name = device.name or adv.local_name or ""
    return "Frame" in name or SERVICE in [u.lower() for u in adv.service_uuids]


async def main() -> int:
    waited = 0
    while waited < TOTAL_SECONDS:
        found = await BleakScanner.discover(timeout=SCAN_CHUNK, return_adv=True)
        for addr, (device, adv) in found.items():
            if is_frame(device, adv):
                name = device.name or adv.local_name or "(unnamed)"
                print(f"FOUND after {waited + SCAN_CHUNK:.0f}s: "
                      f"{name} {addr} rssi={adv.rssi}")
                return 0
        waited += SCAN_CHUNK
        print(f"  {waited:.0f}s: not advertising ({len(found)} other devices)",
              flush=True)
    print(f"Gave up after {TOTAL_SECONDS}s. The glasses are not advertising.")
    return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

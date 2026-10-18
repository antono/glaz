#!/usr/bin/env python3
"""Run Lua on the glasses through the phone, without taking the link from it.

The Glaz app's Lua console (More > Lua console) runs Lua inside the app on
the glasses. With "Open to a computer" on, it also listens on the phone's
own 127.0.0.1:8137; this forwards that port over adb and talks to it.

    python utils/phone_lua.py 'frame.battery_level()'
    echo 'print(frame.file.space().free)' | python utils/phone_lua.py
    python utils/phone_lua.py --complete frame.disp
    python utils/phone_lua.py              # interactive, Tab completes

ADB_SERIAL picks the phone when more than one is attached. Exit status: 0
answered, 1 a Lua error, 2 no answer (no phone, console off, no glasses).
"""
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

PORT = 8137
BASE = f"http://127.0.0.1:{PORT}"


def forward():
    cmd = ["adb"]
    if os.environ.get("ADB_SERIAL"):
        cmd += ["-s", os.environ["ADB_SERIAL"]]
    subprocess.run(cmd + ["forward", f"tcp:{PORT}", f"tcp:{PORT}"],
                   check=True, stdout=subprocess.DEVNULL)


def call(req):
    """(status, text); status 0 when the phone did not answer at all."""
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except (urllib.error.URLError, ConnectionError) as e:
        return 0, f"no answer from the phone ({e}); is the Lua console " \
                  "open to a computer?"


def run(code):
    return call(urllib.request.Request(f"{BASE}/lua", data=code.encode(),
                                       method="POST"))


def complete(prefix):
    q = urllib.parse.quote(prefix)
    status, text = call(f"{BASE}/complete?q={q}")
    return text.splitlines() if status == 200 else []


def interactive():
    import readline

    found = []

    def completer(text, state):
        nonlocal found
        if state == 0:
            found = complete(text)
        return found[state] if state < len(found) else None

    readline.set_completer_delims(" \t\n()[]{},;=+-*/<>~\"'")
    readline.set_completer(completer)
    readline.parse_and_bind("tab: complete")
    while True:
        try:
            line = input("glaz> ")
        except EOFError:
            print()
            return
        if line.strip():
            status, text = run(line)
            print(text if status in (200, 422) else f"! {text}")


def main():
    forward()
    args = sys.argv[1:]
    if args[:1] == ["--complete"]:
        print("\n".join(complete(" ".join(args[1:]))))
        return 0
    if not args and sys.stdin.isatty():
        interactive()
        return 0
    code = " ".join(args) if args else sys.stdin.read()
    status, text = run(code)
    print(text)
    return {200: 0, 422: 1}.get(status, 2)


if __name__ == "__main__":
    sys.exit(main())

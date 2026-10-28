"""glaz on a pair of emulated glasses, for tests and screenshots
(docs/TESTING.md).

    g = Glasses('frame', tmp_path)      # or 'halo'
    g.start()                           # main.lua, until the app runs
    g.tap(2)                            # the menu
    g.open_app('stopwatch')             # as the phone's Menu tab does
    g.advance(3)                        # three seconds of the glasses' time
    assert 'Stopwatch' in g.screen_text()
    g.screenshot('stopwatch')           # PNG, when SHOTS is set
    g.stop()

The files go in as the phone uploads them (sandbox.py), and the app
starts as it does on the glasses: main.lua, the boot part, glaz_boot.lua,
the app. Frame runs in tests/frame_emulator, Halo in Brilliant Labs'
halo-emulator (halo_sandbox.py). Time is virtual on both (vclock.py): it
moves only with advance(), tap() and the like, so nothing here depends
on how fast the machine is.

What the phone says goes in as it does over Bluetooth (send(), with the
codes of docs/PROTOCOL.md), and what the glasses say back is in sent().
"""
from __future__ import annotations

import os
import struct
from pathlib import Path

from sandbox import modules, stage

SHOTS = os.environ.get("SHOTS") or os.environ.get("HALO_SHOTS")

# Host -> glasses (glaz.lua; docs/PROTOCOL.md)
MENU_SET, MENU_HIDE, MENU_SHOW = 0x20, 0x21, 0x22
CLOCK_SET, NOTIFY, NET_RESPONSE = 0x23, 0x24, 0x25
STATUS_GET, SETTINGS_SET, LOCATION = 0x26, 0x27, 0x28
FILES_GET, FILE_GET, INPUT = 0x29, 0x2A, 0x2B
PHOTO_TAKE, MODULE_CALL, HANDS_OFF = 0x2C, 0x2D, 0x2E
APP_OPEN, LUA_EVAL = 0x2F, 0x30

# Glasses -> host
LUA_RESULT = 0x09
MENU_SELECT, MENU_CURSOR, MENU_OPEN, MENU_CLOSE = 0x11, 0x12, 0x13, 0x14
APP_START, APP_STOP, MENU_LEVEL, APP_BACKGROUND = 0x15, 0x16, 0x17, 0x18
NET_REQUEST, STATUS, LOCATION_GET = 0x19, 0x1B, 0x1C
FILES, FILE_DATA = 0x1D, 0x1E

# A fixed time the phone sets: 2026-10-27 13:37 UTC, UTC+2
NOW = 1_793_108_220
ZONE_MINUTES = 120

TAP_GAP = 0.3      # between the taps of one gesture: past TAP_BOUNCE
TAP_SETTLE = 1.0   # after a gesture: past TAP_WINDOW, so it counts


class Glasses:
    """glaz running on emulated glasses of one kind, 'frame' or 'halo'."""

    def __init__(self, device: str, sandbox: Path, *, files=True):
        self.device = device
        self.sandbox = Path(sandbox)
        self.files = stage(self.sandbox, device) if files else []
        self.lines: list[str] = []
        if device == "frame":
            from frame_emulator import FrameEmulator
            self.emu = FrameEmulator(self.sandbox, self.lines.append)
        elif device == "halo":
            from halo_sandbox import emulator
            self.emu = emulator(self.sandbox, print_handler=self.lines.append)
        else:
            raise ValueError(device)
        self.clock = self.emu.clock
        self._shot = 0

    # ------------------------------------------------------------ running

    def start(self, wait_for: str | None = "Frame app is running",
              timeout: float = 20.0):
        """Starts main.lua and lets time pass until it printed wait_for."""
        self.emu.start("main.lua")
        if wait_for and not self.until(wait_for, timeout):
            raise AssertionError(
                f"{wait_for!r} not printed in {timeout}s: {self.lines[-20:]}")
        return self

    def stop(self):
        self.emu.stop()

    def running(self) -> bool:
        return self.emu.is_running()

    def advance(self, seconds: float):
        """Lets seconds of the glasses' time pass, in steps the app's loop
        sees as the glasses' would."""
        self.emu.advance(seconds)

    def until(self, text: str, timeout: float = 10.0, step: float = 0.1,
              since: int = 0) -> bool:
        """Advances time until a printed line has text (from line since)."""
        waited = 0.0
        while True:
            if any(text in l for l in self.lines[since:]):
                return True
            if waited >= timeout or not self.running():
                return False
            self.advance(step)
            waited += step

    def until_screen(self, text: str, timeout: float = 10.0,
                     step: float = 0.1) -> bool:
        """Advances time until text is on the screen."""
        waited = 0.0
        while text not in self.screen_text():
            if waited >= timeout or not self.running():
                return False
            self.advance(step)
            waited += step
        return True

    # ---------------------------------------------------- the wearer

    def tap(self, n: int = 1, settle: float = TAP_SETTLE):
        """n taps on the temple, as one gesture, then time for it to count.
        Frame's firmware calls once a tap; Halo's gives the gesture whole."""
        if self.device == "frame":
            for i in range(n):
                self.emu.tap()
                if i < n - 1:
                    self.advance(TAP_GAP)
        else:
            kinds = {1: "single", 2: "double", 3: "triple"}
            if n not in kinds:
                raise ValueError("Halo taps 1, 2 or 3 times")
            self.emu.inject_imu_tap(kinds[n])
            self.emu.settle()
        self.advance(settle)

    def tilt(self, step: int = 1, roll: float = 20.0):
        """The head tilted and brought back: the cursor a row down (step
        1, tilted right) or up (-1)."""
        set_roll = (self.emu.set_direction if self.device == "frame"
                    else lambda r: self.emu.set_imu_direction(0, r, 0))
        set_roll(-roll if step > 0 else roll)
        self.advance(0.4)
        set_roll(0.0)
        self.advance(0.4)

    def button(self, kind: str = "single"):
        """Halo's button: 'single', 'double' or 'long'."""
        getattr(self.emu, f"inject_button_{kind}")()
        self.emu.settle()
        self.advance(0.5)

    # ---------------------------------------------------- the phone

    def send(self, code: int, payload: bytes | str = b""):
        """A message from the phone, as frame_msg sends it: [code, size]
        and the payload, then [code] and more, in Bluetooth's writes."""
        if isinstance(payload, str):
            payload = payload.encode("utf-8")
        size = 200
        first = bytes([code, len(payload) >> 8, len(payload) & 0xFF])
        self._receive(first + payload[:size])
        for i in range(size, len(payload), size):
            self._receive(bytes([code]) + payload[i:i + size])
        self.advance(0.1)

    def _receive(self, data: bytes):
        if self.device == "frame":
            self.emu.receive(data)
        else:
            self.emu.inject_bluetooth_data(data)
            self.emu.settle()

    def set_clock(self, unix: int = NOW, zone_minutes: int = ZONE_MINUTES):
        self.send(CLOCK_SET, struct.pack(">Ih", unix, zone_minutes))

    def open_app(self, name: str, arg: str = "", settle: float = 0.5):
        """The phone puts a module on screen (APP_OPEN), as from its Menu
        tab: no menu to walk."""
        self.send(APP_OPEN, f"{name}\n{arg}")
        self.advance(settle)

    def remote(self, kind: int, value: int, settle: float = 0.3):
        """The phone's remote (INPUT): kind 1 that many taps, 2 a tilt (1
        next, 255 previous), 3 up and down."""
        self.send(INPUT, bytes([kind, value]))
        self.advance(settle)

    def call(self, module: str, arg: str = ""):
        """A module's remote(arg), as the phone calls it (MODULE_CALL)."""
        self.send(MODULE_CALL, f"{module}\n{arg}")

    def settings(self, lines: dict[str, str]):
        """Every module's settings, as the phone sends them (SETTINGS_SET)."""
        self.send(SETTINGS_SET,
                  "\n".join(f"{k}={v}" for k, v in lines.items()))

    def notify(self, app: str, title: str, text: str):
        self.send(NOTIFY, f"{app}\n{title}\n{text}")

    def sent(self, code: int | None = None) -> list[bytes]:
        """What the glasses sent the phone, each send whole; only those
        starting with code, when given."""
        out = (self.emu.sent if self.device == "frame"
               else self.emu.get_bluetooth_sent())
        return [m for m in out if code is None or m[:1] == bytes([code])]

    def clear_sent(self):
        if self.device == "frame":
            self.emu.sent.clear()
        else:
            self.emu.clear_bluetooth_sent()

    def joined(self, code: int) -> list[tuple[int, bytes]]:
        """Messages split over packets [code, id, more, bytes...] (a
        module's HTTP request, a folder listing, a file, Lua's result),
        put together: (id, bytes) each."""
        out, parts = [], {}
        for m in self.sent(code):
            if len(m) < 3:
                continue
            ident, more = m[1], m[2]
            parts.setdefault(ident, bytearray()).extend(m[3:])
            if more == 0:
                out.append((ident, bytes(parts.pop(ident))))
        return out

    # ---------------------------------------------------- what is shown

    def texts(self) -> list:
        """The strings on the screen now, each with where it was drawn."""
        if self.device == "frame":
            return self.emu.texts()
        return list(self.emu.texts)

    def screen_text(self) -> str:
        """The strings on the screen now, a line each, top to bottom."""
        return "\n".join(t.text for t in sorted(
            self.texts(), key=lambda t: (t.y, t.x)))

    def image(self):
        if self.device == "frame":
            return self.emu.image()
        return self.emu.get_framebuffer().convert("RGB")

    def lit(self) -> int:
        """Pixels on the screen that are not black."""
        return sum(1 for p in self.image().getdata() if sum(p) > 60)

    def screenshot(self, name: str, directory: str | Path | None = None):
        """The screen as a PNG, in directory, else $SHOTS/<device>/, else
        nowhere; returns the image."""
        img = self.image()
        where = directory or (Path(SHOTS) / self.device if SHOTS else None)
        if where:
            Path(where).mkdir(parents=True, exist_ok=True)
            img.save(Path(where) / f"{name}.png")
        return img

    # ---------------------------------------------------- what went wrong

    def errors(self) -> list[str]:
        """Printed lines that tell of an error, and the emulator's own."""
        quiet = ("emulator stopped", "emulator restart")
        # glaz.lua prints a module's error as '<label> err: <message>'
        out = [l for l in self.lines
               if ("error" in l.lower() or "traceback" in l.lower()
                   or " err: " in l)
               and not any(q in l for q in quiet)]
        err = (self.emu.error if self.device == "frame"
               else self.emu.get_error())
        if err is not None and not any(q in str(err) for q in quiet):
            out.append(f"emulator: {err}")
        return out

    def assert_ok(self):
        assert not self.errors(), "\n".join(self.errors() + self.lines[-30:])


def has_module(device: str, name: str) -> bool:
    return name in modules(device)

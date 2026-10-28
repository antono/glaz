"""Brilliant Labs' Halo emulator (halo-emulator) made to run glaz the way
Halo's firmware does today, with the time of tests/vclock.py
(tests/glasses.py, docs/HALO.md).

halo-emulator 2.3.0 (firmware 0.8.12) keeps frame.file simpler than
Halo's firmware does today (lua_file.c, 0.8.22): it takes only Python's
modes, has no file:read(n), keeps the line break read() should drop, and
listdir() gives bare names. glaz goes by the firmware, so the emulator
gets the firmware's file API here.

Its time is the machine's; here it is virtual, as for Frame's emulator:
utc() is the clock's, and sleep(), standby(), light_sleep() and yield()
wait on it. Every string drawn is kept, for tests to read the screen as
text, and the host's break comes as Halo raises it: "interrupted", once.
"""
import shutil
from dataclasses import dataclass
from pathlib import Path

from sandbox import stage as stage_for
from vclock import Stopped, VirtualClock, START

DEVICE = "halo"


def stage(sandbox: Path) -> list[str]:
    """Copies Halo's files into sandbox; returns their names there."""
    return stage_for(sandbox, DEVICE)


class FirmwareFile:
    """A file as Halo's firmware hands it to Lua."""

    def __init__(self, f):
        self._f = f

    def read(self, n=None):
        if isinstance(n, (int, float)):
            if n <= 0:
                return ""
            data = self._f.read(int(n))
            return data.decode("latin-1") if data else None
        line = bytearray()
        while True:  # a line, its line break dropped; nil at the end
            c = self._f.read(1)
            if not c:
                return line.decode("latin-1") if line else None
            if c == b"\n":
                return line.decode("latin-1")
            line += c

    def write(self, data):
        self._f.write(str(data).encode("latin-1"))

    def close(self):
        self._f.close()


class FirmwareFiles:
    """frame.file as Halo's firmware has it; names relative to the sandbox,
    as they are to /lfs on the glasses."""

    def __init__(self, root: Path):
        self._root = root.resolve()
        self._runtime = None  # set once the emulator has built its Lua

    def _path(self, name: str) -> Path:
        p = (self._root / name.lstrip("/")).resolve()
        if not str(p).startswith(str(self._root)):
            raise PermissionError(name)
        return p

    def open(self, name, mode="r"):
        flags = {"r": "rb", "w": "w+b", "a": "ab"}.get(str(mode)[:1])
        if flags is None:
            raise ValueError("mode must be 'r', 'w', or 'a'")
        try:
            return FirmwareFile(self._path(name).open(flags))
        except OSError as e:
            raise RuntimeError(f"cannot open file '{name}': {e.errno}")

    def remove(self, name):
        p = self._path(name)
        p.rmdir() if p.is_dir() else p.unlink()

    def remove_all(self):
        for p in self._root.iterdir():
            shutil.rmtree(p) if p.is_dir() else p.unlink()

    def rename(self, old, new):
        self._path(old).rename(self._path(new))

    def mkdir(self, path):
        self._path(path).mkdir(parents=True, exist_ok=True)

    def listdir(self, path=""):
        rt = self._runtime
        out = rt.table()
        for i, p in enumerate(sorted(self._path(path).iterdir()), 1):
            out[i] = rt.table_from({
                "name": p.name,
                "size": 0 if p.is_dir() else p.stat().st_size,
                "type": 2 if p.is_dir() else 1,
            })
        return out


@dataclass
class Text:
    """A string drawn, and where: what tests read the screen as."""
    text: str
    x: int
    y: int
    color: int = 0xFFFFFF


class ClockQueue:
    """The emulator's event queue, handing its events to the clock."""

    def __init__(self, clock: VirtualClock):
        self._clock = clock

    def put(self, event):
        self._clock.put(event)

    def drain(self):
        return []


# Run after the emulator's own frame.*: sleeps that report the host's break,
# a callback's error and the emulator's stop instead of raising Python's
# exceptions, which a pcall would take for the app's own.
WRAP = r"""
local function unwind(msg)
  debug.sethook(function() error(msg, 0) end, '', 1)
  error(msg, 0)
end
local function slept(r, msg)
  if r == 'break' then error('interrupted', 0) end   -- Halo: once
  if r == 'stop' then unwind('emulator stopped') end
  if r == 'restart' then unwind('emulator restart') end
  if r == 'error' then error(msg, 0) end
end
for _, name in ipairs({'sleep', 'standby', 'light_sleep', 'yield'}) do
  local f = frame[name]
  frame[name] = function(...) return slept(f(...)) end
end
"""


def emulator(sandbox: Path, print_handler=print):
    """A HaloEmulator on sandbox: the firmware's frame.file, virtual time,
    and the screen's strings kept (emu.texts)."""
    from halo_emulator import HaloEmulator

    emu = HaloEmulator(sandbox_dir=sandbox, print_handler=print_handler)
    clock = VirtualClock(start=START)
    emu.clock = clock
    emu._event_queue = ClockQueue(clock)
    emu._system._event_queue = emu._event_queue
    clock.watch(emu.is_running)
    files = FirmwareFiles(sandbox)
    emu._file = files
    emu.texts = []
    restart = {"pending": False}

    # ---- time
    utc_base = {"v": 0.0}

    def utc(timestamp=None):
        if timestamp is None:
            return clock.utc() + utc_base["v"]
        utc_base["v"] = float(timestamp) - clock.now
        return float(timestamp)

    emu._time.utc = utc

    wake_sources = {"ble": "ble", "button_single": "button",
                    "button_double": "button", "button_long": "button",
                    "imu_tap": "imu"}

    def run_events(seconds, asleep):
        state = {"error": None}

        def dispatch(event):
            if event.type in ("stop", "break"):
                return True
            if asleep:
                return event.type in wake_sources
            try:
                emu._dispatch_event(event)
            except Exception as e:   # a callback's Lua error
                state["error"] = str(e)
                return True
            return False

        try:
            ev = clock.wait(seconds, dispatch)
        except Stopped:
            return "stop"
        if ev is None:
            return None
        if ev.type == "stop":
            return "stop"
        if ev.type == "break":
            return "break"
        if state["error"] is not None:
            return "error", state["error"]
        emu._system._wakeup_src = wake_sources.get(ev.type, "timeout")
        return "woke"

    def sleep(seconds=None):
        if not seconds:
            return "stop"   # deep sleep: Bluetooth drops, as a shutdown
        r = run_events(float(seconds), asleep=False)
        return None if r == "woke" else r

    def standby(seconds=None):
        r = run_events(float(seconds) if seconds else None, asleep=True)
        return None if r == "woke" else r

    def light_sleep(seconds=None):
        r = run_events(float(seconds) if seconds else None, asleep=True)
        if r in (None, "woke"):
            restart["pending"] = True
            return "restart"
        return r

    def yield_():
        r = run_events(0, asleep=False)
        return None if r == "woke" else r

    emu._system.sleep = sleep
    emu._system.standby = standby
    emu._system.light_sleep = light_sleep
    emu._system.yield_ = yield_

    # ---- the screen as text
    display = emu._display
    draw_text, clear = display.text, display.clear

    def text(txt, x, y, color=0xFFFFFF):
        emu.texts.append(Text(str(txt), int(x), int(y), int(color)))
        return draw_text(txt, x, y, color)

    def cleared(color=0):
        emu.texts.clear()
        return clear(color)

    display.text, display.clear = text, cleared

    # ---- the runtime, with all of the above
    build = emu._build_runtime

    def build_with_files():
        build()
        files._runtime = emu._lua
        emu._lua.execute(WRAP)

    emu._build_runtime = build_with_files

    # ---- stop, break and restart
    from halo_emulator.event_queue import Event
    from halo_emulator.stubs.system import EmulatorRestartException

    def stop():
        clock.stop()
        if emu._lua_thread is not None:
            emu._lua_thread.join(timeout=5)

    def break_signal():
        clock.put(Event(type="break"))
        clock.settle()

    run_lua = emu._run_lua

    def run(script_name):
        # a restart unwinds Lua with an error; the emulator's loop wants
        # its exception, so main.lua runs again here
        while True:
            restart["pending"] = False
            run_lua(script_name)
            if not restart["pending"]:
                return
            emu.texts.clear()
            emu._lua_error = None
            emu._build_runtime()
            emu._running = True

    emu._run_lua = run
    emu.stop = stop
    emu.break_signal = break_signal
    emu.advance = clock.advance
    emu.settle = clock.settle
    return emu

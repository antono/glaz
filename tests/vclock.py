"""Virtual time for the glasses' emulators (tests/glasses.py).

On the glasses the app reads frame.time.utc() and paces itself with
frame.sleep(s). In the emulators that time is virtual: it moves only when
the test says so (advance()), and the Lua thread waits in sleep() until
it does. So a test of a minute's timeout takes a moment, and a tap lands
at the same point of the app's loop on every run: no test depends on how
busy the machine is.

The Lua thread calls wait(); the test's thread calls advance() and put().
Events put while the Lua thread waits are handed to dispatch at once, at
the current virtual instant, the way the firmware runs a callback between
two instructions.
"""
from __future__ import annotations

import queue
import threading
import time
from typing import Any, Callable

START = 1_761_955_200.0   # 2025-11-01 00:00 UTC: a fixed start, for clocks
REAL_TIMEOUT = 30.0       # seconds the test waits for Lua to get somewhere
UTC_STEP = 1e-4           # each utc() moves time on: busy waits end too


class Stopped(Exception):
    """The emulator was stopped: ends the Lua thread from inside sleep()."""


class VirtualClock:
    def __init__(self, start: float = START):
        self.now = start
        self._granted = start
        self._cond = threading.Condition()
        self._events: queue.Queue = queue.Queue()
        self._waiting = False
        self._stopped = False
        self._alive: Callable[[], bool] = lambda: True

    # ---- the Lua thread

    def utc(self) -> float:
        """Now, a step on. A stopped clock ends the Lua thread here too,
        so a loop that never sleeps but reads the time still ends."""
        with self._cond:
            if self._stopped:
                raise Stopped("emulator stopped")
            self.now += UTC_STEP
            self._granted = max(self._granted, self.now)
            return self.now

    def wait(self, seconds: float | None,
             dispatch: Callable[[Any], bool | None]) -> Any:
        """Lets seconds of virtual time pass (None: until an event wakes
        it). Each event goes to dispatch; one that dispatch returns true
        for ends the wait and is returned. None when the time ran out."""
        with self._cond:
            until = None if seconds is None else self.now + max(seconds, 0)
        while True:
            self._check()
            try:
                event = self._events.get_nowait()
            except queue.Empty:
                event = None
            if event is not None:
                if dispatch(event):
                    return event
                continue
            with self._cond:
                if until is not None and self._granted >= until:
                    self.now = max(self.now, until)
                    return None
                self.now = max(self.now, self._granted)
                if self._events.empty() and not self._stopped:
                    self._waiting = True
                    self._cond.notify_all()
                    self._cond.wait(0.5)
                    self._waiting = False

    def _check(self):
        if self._stopped:
            raise Stopped("emulator stopped")

    # ---- the test's thread

    def watch(self, alive: Callable[[], bool]):
        """alive(): whether the Lua thread still runs; advance() needs it."""
        self._alive = alive

    def put(self, event: Any):
        self._events.put(event)
        with self._cond:
            self._cond.notify_all()

    def advance(self, seconds: float):
        """Moves virtual time on by seconds, and returns once the Lua
        thread has caught up and waits for more (or has ended)."""
        with self._cond:
            self._granted = max(self._granted, self.now) + seconds
            target = self._granted
            self._cond.notify_all()
        self.settle(target)

    def settle(self, target: float | None = None):
        """Returns once the Lua thread waits with every event handled."""
        end = time.monotonic() + REAL_TIMEOUT
        with self._cond:
            if target is None:
                target = self.now
            while self._alive() and not (
                    self._waiting and self.now >= target
                    and self._events.empty()):
                if time.monotonic() > end:
                    raise TimeoutError(
                        f"Lua did not reach virtual time {target:.2f} "
                        f"(at {self.now:.2f}): busy, or stuck outside "
                        "frame.sleep()")
                self._cond.wait(0.05)

    def stop(self):
        with self._cond:
            self._stopped = True
            self._cond.notify_all()

    def restart(self):
        with self._cond:
            self._stopped = False

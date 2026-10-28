"""An emulator of Brilliant Labs Frame, for glaz's tests (tests/glasses.py,
docs/TESTING.md). There is none from Brilliant Labs; this one follows
their Halo emulator (halo-emulator) and Frame's firmware, glaz/main of
lab-frame-codebase (source/application/lua_libraries/*.c).

Lua 5.4 runs in lupa with the libraries Frame opens (no io, os or
package) and frame.* as the firmware has it:

- display: 640x400 in 16 palette colours, drawn to a back buffer that
  show() flips, with the firmware's fonts (display.py);
- file: littlefs as a directory, its modes, its 512-byte line reads,
  listdir()'s '.' and '..', space() in 4 KB blocks;
- imu: a tap callback called once a tap, with no argument (stock) or the
  accelerometer's status byte (glaz firmware), as the test taps;
  direction() as set by the test; tap_config(); woke_by_tap();
- sleep(s), and sleep() with no argument: deep sleep, which a tap ends
  with a reset (main.lua again, woke_by_tap() true) unless stay_awake;
  two taps with double_tap_wake, as firmware glaz/main wants;
- bluetooth: sends kept for the test, max_length() (243 on Android's MTU
  of 247) and its error, data from the phone to the receive callback;
- the host's break, raised once (luaport.c), and its reset;
- camera (a JPEG of a picture the test sets), microphone (bytes the test
  gives), fpga_read (zeros: no flip pending), battery, time.

Time is virtual (tests/vclock.py): it moves only when the test advances
it, so a test of a timeout takes no time and runs the same every time.
"""
from __future__ import annotations

import datetime
import io
import math
import os
import re
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

import lupa.lua54 as lupa
from PIL import Image, ImageDraw

from vclock import Stopped, VirtualClock
from frame_emulator.display import NAMES, FrameDisplay, LuaError

HARDWARE_VERSION = "Frame"
FIRMWARE_VERSION = "v25.080.0838"
BOOT_SECONDS = 2.0         # from power to main.lua: frame.time.utc() then
MTU = 247                  # what Android negotiates (BLE_PREFERRED_MAX_MTU)
# bluetooth.c: ble_negotiated_mtu is the MTU less ATT's 3 bytes, and
# max_length() that less the data flag: 243
PAYLOAD = MTU - 3
BLOCK, BLOCKS = 4096, 43   # littlefs on Frame: 172 KB (docs: flash space)
# The app goes up minified and compiled, and leaves about this much free
# (docs/FRAME.md); the emulator's files are source, far bigger, so what is
# in the sandbox when the emulator starts counts as that much used.
FREE_AFTER_UPLOAD = 8 * BLOCK
PIECE = 512                # LUAL_BUFFERSIZE on Frame: the most read() gives
ERR = "\0frame-error"      # a Python stub's error, raised in Lua by PRELUDE
# imu.c's tap_defaults: what a boot and every wake from deep sleep set
TAP_DEFAULTS = {"threshold": 7, "y": 7, "z": 7, "quiet": 0, "duration": 0,
                "axes": 0x08, "latch": True, "rate": 256}
TAP_AXIS = {"x": "threshold", "y": "y", "z": "z"}   # "threshold" is x
WAKE_TAP_MUTE, WAKE_TAP_WINDOW = 0.15, 0.9   # imu.c, in seconds


@dataclass
class Event:
    kind: str              # 'tap', 'ble', 'break', 'reset'
    data: Any = None


class Reboot(Exception):
    """The VM is to start again from main.lua: a reset or a wake."""


def integer(v, n: int, fn: str) -> int:
    """luaL_checkinteger: a float with a fraction is an error on Frame,
    not cut short: x / 2 where x // 2 was meant."""
    if isinstance(v, float) and not v.is_integer():
        raise LuaError(f"bad argument #{n} to '{fn}' "
                       "(number has no integer representation)")
    return int(v)


def luatype(v) -> str:
    """Lua's type() of a value that came into Python."""
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "boolean"
    if isinstance(v, (int, float)):
        return "number"
    if isinstance(v, (str, bytes)):
        return "string"
    return lupa.lua_type(v) or "userdata"


def lua_number(s: str):
    """Lua's string to number conversion (lua_stringtonumber): decimal or
    hex, spaces around allowed; None when it is not a number."""
    t = s.strip()
    try:
        return int(t, 10)
    except ValueError:
        pass
    body = t.lstrip("+-")
    if body[:2].lower() == "0x":
        try:
            return int(t, 16)
        except ValueError:
            return None
    try:
        return float(t) if t.lower().lstrip("+-") not in (
            "inf", "infinity", "nan") else None
    except ValueError:
        return None


def checkint(v, n: int, fn: str) -> int:
    """luaL_checkinteger: a number with an integer value, or a string
    that converts to one ('137' is 137, as lua_tointegerx makes it)."""
    if isinstance(v, str) and not isinstance(v, bool):
        num = lua_number(v)
        if num is not None:
            v = num
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        raise LuaError(f"bad argument #{n} to '{fn}' "
                       f"(number expected, got {luatype(v)})")
    return integer(v, n, fn)


def tolua_string(v: int | float) -> str:
    """Lua's tostring() of a number: '137', '1.5', '2.0', '1e+20'."""
    if isinstance(v, int):
        return str(v)
    s = f"{v:.14g}"
    return s if any(c in s for c in ".eninf") else s + ".0"


def checkstr(v, n: int, fn: str) -> str:
    """luaL_checklstring: a string, or a number made one."""
    if isinstance(v, str):
        return v
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return tolua_string(v)
    raise LuaError(f"bad argument #{n} to '{fn}' "
                   f"(string expected, got {luatype(v)})")


def lua_errors(fn):
    """A stub whose LuaError becomes a Lua error with the firmware's text."""
    def wrapped(*args):
        try:
            return fn(*args)
        except LuaError as e:
            return ERR, str(e)
    wrapped.__name__ = fn.__name__
    return wrapped


# Lua run before main.lua: frame.* from the stubs in _py, and the
# firmware's ways of raising what the stubs only report.
PRELUDE = r"""
local py, ERR = ...
local error, type, select, tostring, tonumber, load, pcall =
      error, type, select, tostring, tonumber, load, pcall
local setmetatable, getmetatable, ipairs =
      setmetatable, getmetatable, ipairs
local pack, unpack = table.pack, table.unpack

-- A stub's error raised as luaL_error raises it: at the line of Lua that
-- called the frame.* function. Never tail-called, so that level 3 is that
-- caller (a tail call would drop the frame.* function's own level).
local function raise(r, ...)
  if r == ERR then error((...), 3) end
  return r, ...
end
local function wrap(f)
  return function(...)
    local t = pack(f(...))
    if t[1] == ERR then error(t[2], 2) end
    return unpack(t, 1, t.n)
  end
end
-- the same, with the number of arguments first: lua_gettop() matters
local function wrapn(f)
  return function(...)
    local t = pack(f(select('#', ...), ...))
    if t[1] == ERR then error(t[2], 2) end
    return unpack(t, 1, t.n)
  end
end
local function opt(t, k) if type(t) == 'table' then return t[k] end end
-- luaL_checklstring: a string, or a number made one
local function checkstring(fn, n, given, v)
  local t = type(v)
  if t == 'number' then return tostring(v) end
  if t ~= 'string' then
    error(("bad argument #%d to '%s' (string expected, got %s)"):format(
      n, fn, given and t or 'no value'), 3)
  end
  return v
end

-- the emulator's stop: on every instruction from here until the chunk
-- unwinds, so that no pcall keeps a stopped emulator's Lua running
local function unwind(msg)
  debug.sethook(function() error(msg, 0) end, '', 1)
  error(msg, 0)
end
local function slept(r, msg)
  -- the host's break, once: luaport.c's break hook puts the watchdog's
  -- hook back (sethook_watchdog) before its luaL_error, so a pcall that
  -- catches it has stopped it
  if r == 'break' then error('break signal', 0) end
  if r == 'stop' then unwind('emulator stopped') end
  if r == 'error' then error(msg, 0) end
end

frame = {
  HARDWARE_VERSION = py.HARDWARE_VERSION,
  FIRMWARE_VERSION = py.FIRMWARE_VERSION,
  GIT_TAG = py.GIT_TAG,
  battery_level = wrap(py.battery_level),
  stay_awake = wrapn(py.stay_awake),
  fpga_read = wrap(py.fpga_read),
  fpga_write = wrap(py.fpga_write),
  update = function() slept(py.sleep(nil, 'update')) end,
}
-- luaL_checknumber: a number, or a string that converts to one
frame.sleep = function(...)
  if select('#', ...) == 0 then return slept(py.sleep(nil)) end
  local s = ...
  local n = tonumber(s)
  if n == nil or (type(s) ~= 'number' and type(s) ~= 'string') then
    error("bad argument #1 to 'sleep' (number expected, got " ..
          type(s) .. ")", 2)
  end
  return slept(py.sleep(n))
end

frame.time = {
  utc = wrapn(py.utc),
  zone = wrapn(py.zone),
  date = function(...)
    local t = {raise(py.date(select('#', ...), ...))}
    return {second = t[1], minute = t[2], hour = t[3], day = t[4],
            month = t[5], year = t[6], weekday = t[7],
            ['day of year'] = t[8], ['is daylight saving'] = false}
  end,
}

frame.display = {
  text = function(...)
    local s, x, y, o = ...
    s = checkstring('text', 1, select('#', ...) >= 1, s)
    raise(py.text(s, x, y, opt(o, 'color'), opt(o, 'spacing')))
  end,
  mono = function(...)
    local s, x, y, o = ...
    s = checkstring('mono', 1, select('#', ...) >= 1, s)
    local nx = raise(py.mono(s, x, y, opt(o, 'size'), opt(o, 'bold'),
                             opt(o, 'color'), opt(o, 'bg'), opt(o, 'attrs')))
    return nx
  end,
  bitmap = wrap(py.bitmap),
  show = wrap(py.show),
  assign_color = wrap(py.assign_color),
  assign_color_ycbcr = wrap(py.assign_color_ycbcr),
  set_brightness = wrap(py.set_brightness),
  power_save = wrap(py.power_save),
  write_register = wrap(py.display_write_register),
}

frame.bluetooth = {
  is_connected = wrap(py.is_connected),
  address = wrap(py.address),
  max_length = wrap(py.max_length),
  send = function(...)
    local s = checkstring('send', 1, select('#', ...) >= 1, (...))
    raise(py.send(s))
  end,
  -- lua_isnil() is false for no argument at all: that is the error too
  receive_callback = function(...)
    local f = ...
    if select('#', ...) == 0 or (f ~= nil and type(f) ~= 'function') then
      error('expected nil or function', 2)
    end
    py.set_callback('ble', f)
  end,
}

frame.imu = {
  tap_callback = function(...)
    local f = ...
    if select('#', ...) == 0 or (f ~= nil and type(f) ~= 'function') then
      error('expected nil or function', 2)
    end
    py.set_callback('tap', f)
  end,
  direction = function()
    local roll, pitch, heading = raise(py.direction())
    return {roll = roll, pitch = pitch, heading = heading}
  end,
  -- lua_pushnumber: floats, as the chip is still and level, 0.0 each
  raw = function()
    local cx, cy, cz, ax, ay, az = raise(py.raw())
    return {compass = {x = cx, y = cy, z = cz},
            accelerometer = {x = ax, y = ay, z = az}}
  end,
  woke_by_tap = wrap(py.woke_by_tap),
  -- no argument: what is set; "threshold" only while the axes agree.
  -- A table: sets what it names, and returns nothing (imu.c).
  tap_config = function(...)
    if select('#', ...) == 0 then
      local x, y, z, quiet, duration, axes, latch, rate =
        raise(py.tap_settings())
      local t = {thresholds = {x = x, y = y, z = z}, quiet = quiet,
                 duration = duration, axes = axes, latch = latch,
                 rate = rate}
      if x == y and y == z then t.threshold = x end
      return t
    end
    local o = ...
    if type(o) ~= 'table' then
      error("bad argument #1 to 'tap_config' (table expected, got " ..
            type(o) .. ")", 2)
    end
    raise(py.tap_config(o))
  end,
}

-- A file handle: its methods check that self is one, as luaL_checkudata
-- does, so f.read() without the colon is the firmware's error here too
local FILE, handles = {__name = 'FILE*'}, setmetatable({}, {__mode = 'k'})
FILE.__index = FILE
local function handle(fn, n, ...)
  local f = ...
  local h = n > 0 and type(f) == 'table' and handles[f]
  if not h then
    local mt = n > 0 and getmetatable(f)
    local got = n == 0 and 'no value'
                or (type(mt) == 'table' and type(mt.__name) == 'string'
                    and mt ~= FILE and mt.__name) or type(f)
    error(("bad argument #1 to '%s' (FILE* expected, got %s)"):format(
      fn, got), 3)
  end
  return h
end
function FILE.read(...)
  local s = raise(py.read(handle('read', select('#', ...), ...)))
  return s
end
-- file.c: closed, then read-only, then what is written
function FILE.write(...)
  local h = handle('write', select('#', ...), ...)
  raise(py.writable(h))
  local s = checkstring('write', 1, select('#', ...) >= 2, (select(2, ...)))
  raise(py.write(h, s))
end
function FILE.close(...)
  raise(py.close(handle('close', select('#', ...), ...)))
end

-- luaL_checkstring of the path first, then littlefs
local function path_fn(fn, f, n)
  return function(...)
    for i = 1, n do
      checkstring(fn, i, select('#', ...) >= i, (select(i, ...)))
    end
    local t = pack(f(...))
    if t[1] == ERR then error(t[2], 2) end
    return unpack(t, 1, t.n)
  end
end

frame.file = {
  open = function(...)
    local name = checkstring('open', 1, select('#', ...) >= 1, (...))
    local mode = select(2, ...)
    if mode == nil then mode = 'r' end
    mode = checkstring('open', 2, true, mode)
    local f = setmetatable({}, FILE)
    handles[f] = raise(py.open(name, mode))
    return f
  end,
  remove = path_fn('remove', py.remove, 1),
  rename = path_fn('rename', py.rename, 2),
  mkdir = path_fn('mkdir', py.mkdir, 1),
  listdir = function(...)
    local path = checkstring('listdir', 1, select('#', ...) >= 1, (...))
    local out = {}
    for i, e in ipairs({raise(py.listdir(path))}) do
      out[i] = {name = e[1], size = e[2], type = e[3]}
    end
    return out
  end,
  space = function()
    local total, used = raise(py.space())
    return {total = total, used = used, free = total - used}
  end,
}

-- capture() reads its options with lua_getfield(L, 1, ...): no table, and
-- it is Lua's own error; a string indexes as strings do, to nothing
frame.camera = {
  capture = function(...)
    raise(py.camera_check())
    local o = ...
    local t = type(o)
    if t ~= 'table' and t ~= 'string' then
      error('attempt to index a ' .. t .. ' value', 2)
    end
    raise(py.capture(opt(o, 'resolution'), opt(o, 'quality'),
                     opt(o, 'pan')))
  end,
  image_ready = wrap(py.image_ready),
  read = wrap(py.camera_read),
  read_raw = wrap(py.camera_read),
  power_save = wrap(py.camera_power_save),
  -- camera.c: nothing at all while the camera is asleep; its options
  -- checked; the metering of a grey scene, as the FPGA would give it
  auto = function(o)
    if not py.camera_awake() then return end
    if type(o) == 'table' then raise(py.camera_auto(o)) end
    local grey = {r = 0.5, g = 0.5, b = 0.5, average = 0.5}
    return {error = 0, shutter = 4096, analog_gain = 1, red_gain = 121,
            green_gain = 64, blue_gain = 140,
            brightness = {spot = grey,
                          matrix = {r = 0.5, g = 0.5, b = 0.5, average = 0.5},
                          center_weighted_average = 0.5, scene = 0.5}}
  end,
  set_shutter = wrap(py.camera_set_shutter),
  set_gain = wrap(py.camera_set_gain),
  set_white_balance = wrap(py.camera_set_white_balance),
  write_register = wrap(py.camera_write_register),
  read_register = wrap(py.camera_read_register),
}

frame.microphone = {
  start = function(o)
    raise(py.mic_start(opt(o, 'sample_rate'), opt(o, 'bit_depth')))
  end,
  stop = wrap(py.mic_stop),
  read = wrap(py.mic_read),
}

frame.led = { set_color = wrap(py.led_set_color) }

frame.compression = {
  process_function = function(...)
    local f = ...
    if select('#', ...) == 0 or (f ~= nil and type(f) ~= 'function') then
      error('expected nil or function', 2)
    end
  end,
  decompress = function() error('compression is not emulated', 2) end,
}

-- Frame opens base, coroutine, table, string, math, utf8 and debug, and
-- its own require() (file.c): name.lua and nothing else, run every time,
-- its errors as "exiting module"; it returns the last value the chunk
-- returned, or the file name when there is none
io, os, package, dofile, loadfile = nil, nil, nil, nil, nil
require = function(...)
  local name = checkstring('require', 1, select('#', ...) >= 1, (...))
  local file = name .. '.lua'
  local src = raise(py.require_source(file))
  local fn, err = load(src, file)
  local r = fn and pack(pcall(fn)) or {false, err, n = 2}
  if not r[1] then
    error(("exiting module '%s': %s"):format(name, tostring(r[2])), 2)
  end
  if r.n == 1 then return file end
  return r[r.n]
end
"""


class FrameFiles:
    """frame.file: littlefs as a directory, names from '/'."""

    def __init__(self, root: Path, free: int = FREE_AFTER_UPLOAD):
        self.root = root.resolve()
        self.handles: dict[int, tuple[Any, str]] = {}
        self.next_handle = 1
        # what the files there now take on the glasses: all but free
        self.uploaded = self.blocks()
        self.free = free

    def path(self, name: str) -> Path:
        p = (self.root / str(name).lstrip("/")).resolve()
        if p != self.root and self.root not in p.parents:
            raise LuaError(f"cannot open file {name}")
        return p

    def open(self, name, mode):
        # only the mode's first letter counts: 'read' is 'r' (file.c);
        # 'w' and 'a' are LFS_O_RDWR, read as well as written, and 'a'
        # reads from the start and writes at the end
        flags = {"r": "rb", "w": "w+b", "a": "a+b"}.get(str(mode)[:1])
        if flags is None:
            raise LuaError("mode must be 'r', 'w', or 'a'")
        p = self.path(name)
        try:
            if p.is_dir():
                raise OSError
            f = p.open(flags)
            f.seek(0)
        except OSError:
            raise LuaError(f"cannot open file {name}")
        h = self.next_handle
        self.next_handle += 1
        self.handles[h] = (f, flags[0])
        return h

    def file(self, h):
        if h not in self.handles:
            raise LuaError("attempt to use a closed file")
        return self.handles[h]

    def read(self, h, *_):
        """A line, its break dropped, of at most PIECE bytes; '' for an
        empty line, nil at the end (file.c)."""
        f, _mode = self.file(h)
        line = bytearray()
        for i in range(PIECE):
            c = f.read(1)
            if not c or c == b"\n":
                if i == 0:
                    return "" if c == b"\n" else None
                break
            line += c
        return line.decode("latin-1")

    def writable(self, h):
        _f, mode = self.file(h)
        if mode == "r":
            raise LuaError("file opened in read-only mode")

    def write(self, h, s):
        self.writable(h)
        f, mode = self.file(h)
        data = s.encode("latin-1")
        f.flush()
        size = os.fstat(f.fileno()).st_size
        end = size + len(data) if mode == "a" else \
            max(size, f.tell() + len(data))
        grows = max(1, -(-end // BLOCK)) - max(1, -(-size // BLOCK))
        if self.used() + grows * BLOCK > BLOCK * BLOCKS:
            raise LuaError("error writing to file")
        f.write(data)

    def close(self, h):
        f, _ = self.file(h)
        del self.handles[h]
        f.close()

    def remove(self, name):
        p = self.path(name)
        try:
            p.rmdir() if p.is_dir() else p.unlink()
        except OSError:
            raise LuaError("error deleting file/directory")

    def rename(self, old, new):
        try:
            self.path(old).rename(self.path(new))
        except OSError:
            raise LuaError("error renaming file/directory")

    def mkdir(self, path):
        """file.c makes every directory of the path in turn, 'a', then
        'a/b', and fails on any that is there already."""
        path = str(path)
        if len(path) > 0x100:
            raise LuaError("path too long")
        cuts = [i for i, c in enumerate(path) if c == "/" and i > 0]
        for part in [path[:i] for i in cuts] + [path]:
            try:
                self.path(part).mkdir()
            except (OSError, LuaError):
                raise LuaError("error creating directory")

    def listdir(self, path):
        p = self.path(path)
        if not p.is_dir():
            raise LuaError("directory not found")
        out = [(".", 0, 2), ("..", 0, 2)]
        for e in sorted(p.iterdir()):
            out.append((e.name, 0 if e.is_dir() else e.stat().st_size,
                        2 if e.is_dir() else 1))
        return out

    def blocks(self) -> int:
        blocks = 2   # the superblock pair
        for p in self.root.rglob("*"):
            blocks += 1 if p.is_dir() else max(1, -(-p.stat().st_size // BLOCK))
        return blocks

    def used(self) -> int:
        """Bytes used as the glasses would count them: the uploaded files
        as BLOCK * BLOCKS - free, the rest as they are."""
        extra = self.blocks() - self.uploaded
        return BLOCK * BLOCKS - self.free + extra * BLOCK

    def space(self):
        return BLOCK * BLOCKS, min(self.used(), BLOCK * BLOCKS)

    def close_all(self):
        for f, _ in self.handles.values():
            f.close()
        self.handles.clear()


def default_picture(size: int = 720) -> Image.Image:
    """What the emulator's camera sees unless the test sets a picture."""
    img = Image.new("RGB", (size, size), (40, 90, 160))
    d = ImageDraw.Draw(img)
    d.ellipse((size // 4, size // 4, 3 * size // 4, 3 * size // 4),
              fill=(230, 200, 60))
    d.text((size // 2 - 10, size // 2 - 5), "137", fill=(0, 0, 0))
    return img


class FrameEmulator:
    """Frame's firmware around a Lua VM, with time that moves on demand.

        emu = FrameEmulator(sandbox)     # the glasses' files
        emu.start()                      # main.lua, in a thread
        emu.advance(1.0)                 # a second of the glasses' time
        emu.tap(); emu.advance(1.0)
        emu.image().save('screen.png')
        emu.stop()
    """

    def __init__(self, sandbox: str | Path,
                 print_handler: Callable[[str], None] | None = print,
                 boot_seconds: float = BOOT_SECONDS):
        self.sandbox = Path(sandbox).resolve()
        self.sandbox.mkdir(parents=True, exist_ok=True)
        self.boot_seconds = boot_seconds
        self.print_handler = print_handler
        self.clock = VirtualClock(start=0.0)
        self.display = FrameDisplay()
        self.files = FrameFiles(self.sandbox)
        self.sent: list[bytes] = []
        self.connected = True
        self.address = "AA:BB:CC:DD:EE:FF"
        self.battery = 85
        self.roll = self.pitch = self.heading = 0.0
        self.picture = default_picture()
        self.led = (0, 0, 0)       # frame.led.set_color(): red, green, blue
        self.mic_data = bytearray()
        self.boots = 0
        self.asleep = False        # in deep sleep: frame.sleep() unargued
        self.error: Exception | None = None
        self._lua = None
        self._thread: threading.Thread | None = None
        self._running = False
        self._callbacks: dict[str, Any] = {}
        self._reboot: str | None = None
        self._woke_by_tap = False
        self._stay_awake = False
        # firmware glaz/main wakes on two taps (imu.c,
        # imu_wait_for_second_tap): a second one 0.15 to 0.9 s after the
        # first, else back to sleep. glaz/stable, and stock firmware, wake
        # on one, as here by default
        self.double_tap_wake = False
        self.updating = False      # frame.update() called: in the bootloader
        self._first_tap: float | None = None
        self._power_on()
        self.clock.watch(lambda: self._running)

    def _power_on(self):
        """The firmware's state in RAM, as a boot from power or a wake from
        deep sleep finds it: the clock from 0 in UTC, the tap defaults,
        the camera awake, the microphone off. A host's reset (0x04) only
        makes a new Lua state, and all this stays as it was."""
        # the RTC counts from 0, and the firmware's start (FPGA, panel,
        # Bluetooth) takes about this long before main.lua runs
        self._utc_base = self.boot_seconds - self.clock.now
        self._zone = (0, 0)
        # display_configuration.h: register 0x05 = 0xCB, set_brightness(1)
        self.display.brightness = 1
        self._camera_awake = True
        self._jpeg = b""
        self._jpeg_pos = 0
        self._mic_on = False
        self._mic_fmt = (8000, 8)
        self.mic_data.clear()
        self._tap = dict(TAP_DEFAULTS)

    # ------------------------------------------------------------ lifecycle

    def start(self, script: str = "main.lua"):
        self.clock.restart()
        self._running = True
        self._thread = threading.Thread(
            target=self._run, args=(script,), daemon=True, name="frame-lua")
        self._thread.start()

    def _build(self):
        self._callbacks = {}
        self.files.close_all()
        self._stay_awake = False     # run_lua(): "frame.stay_awake(false)"
        rt = lupa.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
        g = rt.globals()
        handler = self.print_handler
        tostring = g.tostring

        def lua_print(*args):
            if handler is not None:
                handler("\t".join(str(tostring(a)) for a in args))

        g.print = lua_print
        py = rt.table_from(self._stubs())
        rt.execute(PRELUDE, py, ERR)
        self._lua = rt

    def _run(self, script: str):
        # run_lua(): require('main'), so main.lua's errors are "exiting
        # module 'main': [string "main.lua"]:N: ..."
        module = script[:-4] if script.endswith(".lua") else script
        woke = False
        self._woke_by_tap = False
        try:
            while True:
                if woke:
                    self._power_on()
                    self._woke_by_tap = True
                # imu.c's imu_woke_by_tap is set at boot and nothing clears
                # it: a host's reset (0x04) after a wake still reads true
                self._build()
                woke = False
                self._reboot = None
                self.boots += 1
                try:
                    self._lua.globals().require(module)
                except lupa.LuaError as e:
                    if self._reboot is None:
                        if self.clock._stopped or self.updating:
                            break
                        raise
                except Stopped:
                    break
                if self._reboot is None:
                    break
                woke = self._reboot == "tap"
                self.display.powered = True
        except Exception as e:
            if not isinstance(e, Stopped):
                self.error = e
                if self.print_handler is not None:
                    self.print_handler(f"[frame-emulator] Lua error: {e}")
        finally:
            self._running = False
            self.files.close_all()

    def stop(self):
        self.clock.stop()
        if self._thread is not None:
            self._thread.join(timeout=5)

    def is_running(self) -> bool:
        return self._running

    # ---------------------------------------------------- the test's side

    def advance(self, seconds: float):
        """Lets seconds of the glasses' time pass, and their app with it."""
        self.clock.advance(seconds)

    def settle(self):
        self.clock.settle()

    def tap(self, status: int | None = None):
        """One tap on the temple: the tap callback, once. With no argument,
        as stock firmware calls it; firmware glaz passes the
        accelerometer's status byte (imu.c; 0x08 is Y-), given as status."""
        self.clock.put(Event("tap", status))
        self.settle()

    def receive(self, data: bytes):
        """Bytes from the phone, as one Bluetooth write; none arrive
        without a link."""
        if not self.connected:
            raise RuntimeError("no Bluetooth link: set connected first")
        self.clock.put(Event("ble", bytes(data)))
        self.settle()

    def break_signal(self):
        """The host's 0x03: 'break signal' raised in the running app."""
        self.clock.put(Event("break"))
        self.settle()

    def reset_signal(self):
        """The host's 0x04: the VM cleared, main.lua run again."""
        self.clock.put(Event("reset"))
        self.settle()

    def set_direction(self, roll=0.0, pitch=0.0, heading=0.0):
        self.roll, self.pitch, self.heading = roll, pitch, heading

    def utc(self) -> float:
        return self.clock.now + self._utc_base

    def image(self) -> Image.Image:
        return self.display.image()

    def texts(self):
        return self.display.texts()

    # ------------------------------------------------- the firmware's side

    def _dispatch(self, event: Event, asleep: bool = False) -> bool | str:
        """An event while Lua sleeps. True ends the sleep (a wake, a break,
        a reset); a callback's error is returned to be raised in Lua."""
        if asleep:
            # System OFF: Bluetooth is off, so no break, reset or data
            # gets there; a tap is all that wakes it
            return event.kind == "tap" and self._wakes()
        if event.kind in ("break", "reset"):
            return True
        fn = self._callbacks.get(event.kind)
        if fn is None:
            return False
        try:
            if event.kind == "tap":
                fn() if event.data is None else fn(int(event.data))
            else:
                fn(event.data.decode("latin-1"))
        except lupa.LuaError as e:
            # lua_tostring() of the error: the message, not lupa's
            # traceback after it
            self._callback_error = str(e).split("\nstack traceback:")[0]
            return True
        return False

    def _wakes(self) -> bool:
        """Whether a tap in deep sleep wakes the glasses."""
        if not self.double_tap_wake:
            return True
        now, first = self.clock.now, self._first_tap
        if first is not None and now - first <= WAKE_TAP_WINDOW:
            # the frame still ringing from the first tap does not count
            return now - first >= WAKE_TAP_MUTE
        self._first_tap = now      # one tap: awake to wait for a second
        return False

    def _sleep(self, seconds=None, why=None):
        self._callback_error = None
        if why == "update":
            # system.c: the 'Frame Update' screen, then a reset into the
            # bootloader: the app is over, without an error
            self.display.text("Frame Update", 200, 140)
            self.display.show()
            self.updating = True
            return "stop"
        deep = seconds is None
        if deep and self._stay_awake:
            return None
        if deep:
            self.display.powered = False
            self.asleep = True
            self._first_tap = None
        try:
            ev = self.clock.wait(
                None if deep else float(seconds),
                lambda e: self._dispatch(e, asleep=deep))
        except Stopped:
            return "stop"
        finally:
            self.asleep = False
        if ev is None:
            return None
        if self._callback_error is not None:
            return "error", self._callback_error
        if ev.kind == "break":
            return "break"
        self._reboot = "tap" if (deep and ev.kind == "tap") else "reset"
        return "stop"

    def _stubs(self) -> dict:
        emu = self

        def battery_level():
            # lua_pushnumber of a roundf(): a float, 85.0, from 0 to 100.
            # Not rounded here: a test may set 37.5 to make a reading fail
            return float(max(0, min(100, emu.battery)))

        def stay_awake(n, v=None, *_):
            if n > 1:
                raise LuaError("expected 0 or 1 arguments")
            if n == 0:
                return emu._stay_awake
            if not isinstance(v, bool):
                raise LuaError("bad argument #1 to 'stay_awake' "
                               f"(boolean expected, got {luatype(v)})")
            emu._stay_awake = v

        def fpga_read(address, n=None):
            address = checkint(address, 1, "fpga_read")
            if not 0 <= address <= 0xFF:
                raise LuaError("address must be between 0x00 and 0xFF")
            return "\0" * checkint(n, 2, "fpga_read")

        def fpga_write(address, data=None):
            address = checkint(address, 1, "fpga_write")
            if not 0 <= address <= 0xFF:
                raise LuaError("address must be between 0x00 and 0xFF")
            if isinstance(data, bool) or \
                    not isinstance(data, (str, int, float)):
                raise LuaError("bad argument #2 to 'fpga_write' "
                               f"(string expected, got {luatype(data)})")

        def now_ms():
            return math.floor((emu.clock.utc() + emu._utc_base) * 1000)

        # time.c: utc() the milliseconds since boot or since set, / 1000
        def utc(n, v=None):
            if n == 0:
                return now_ms() / 1000
            emu._utc_base = checkint(v, 1, "utc") - emu.clock.now

        # sscanf(s, "%d:%d"): '+02:00', '2:0' and '-05:30 more' all read
        def zone(n, v=None):
            if n == 0:
                h, m = emu._zone
                return f"{'+' if h >= 0 else '-'}{abs(h):02d}:{m:02d}"
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                v = str(v)
            if not isinstance(v, str):
                raise LuaError("bad argument #1 to 'zone' "
                               f"(string expected, got {luatype(v)})")
            found = re.match(r"\s*([+-]?\d+):\s*([+-]?\d+)", v)
            if not found:
                raise LuaError("must be '+hh:mm' or '-hh:mm'")
            h, m = int(found[1]), int(found[2])
            if not -12 <= h <= 14:
                raise LuaError("hour value must be between -12 and +14")
            if m not in (0, 30, 45):
                raise LuaError("minute value must be either 00, 30, or 45")
            if h in (-12, 14) and m != 0:
                raise LuaError("when hour is -12 or 14, minutes must be 0")
            emu._zone = (h, m)

        # time.c adds the zone to a timestamp given as well as to now, and
        # its minutes always forward: '-05:30' is five hours back and
        # thirty minutes on, -04:30
        def date(n, ts=None):
            h, m = emu._zone
            base = now_ms() // 1000 if n == 0 else checkint(ts, 1, "date")
            d = datetime.datetime.fromtimestamp(
                base + m * 60 + h * 3600, datetime.timezone.utc)
            return (d.second, d.minute, d.hour, d.day, d.month, d.year,
                    (d.weekday() + 1) % 7, d.timetuple().tm_yday - 1)

        # display.c, in its order: the string, x, y, then the options
        def text(s, x, y, color=None, spacing=None):
            x, y = checkint(x, 2, "text"), checkint(y, 3, "text")
            if color is not None:
                color = checkstr(color, -1, "text")
                if color not in NAMES[1:]:
                    raise LuaError("Invalid color name")
            emu.display.text(s, x, y, color,
                             4 if spacing is None
                             else checkint(spacing, -1, "text"))

        def mono(s, x, y, size=None, bold=None, color=None, bg=None,
                 attrs=None):
            x, y = checkint(x, 2, "mono"), checkint(y, 3, "mono")
            size = 24 if size is None else checkint(size, -1, "mono")
            for c in (color, bg):
                if c is not None and \
                        checkstr(c, -1, "mono") not in NAMES[1:]:
                    raise LuaError("Invalid color name")
            return emu.display.mono(
                s, x, y, size, bold is not None and bold is not False,
                None if color is None else checkstr(color, -1, "mono"),
                None if bg is None else checkstr(bg, -1, "mono"),
                None if attrs is None else checkstr(attrs, -1, "mono"))

        def bitmap(x=None, y=None, width=None, colors=None, offset=None,
                   data=None):
            data = checkstr(data, 6, "bitmap")
            emu.display.bitmap(
                checkint(x, 1, "bitmap"), checkint(y, 2, "bitmap"),
                checkint(width, 3, "bitmap"), checkint(colors, 4, "bitmap"),
                checkint(offset, 5, "bitmap"), data)

        def send(data):
            raw = data.encode("latin-1")
            if len(raw) + 1 > PAYLOAD:
                raise LuaError("string length is greater than max_length()")
            if not emu.connected:
                raise LuaError("bluetooth is busy")
            emu.sent.append(raw)

        def set_callback(kind, fn):
            if fn is None:
                emu._callbacks.pop(kind, None)
            else:
                emu._callbacks[kind] = fn

        def tap_threshold(v):
            v = checkint(v, -1, "tap_config")
            if not 0 <= v <= 255:
                raise LuaError("threshold must be between 0 and 255")
            return v

        def tap_axes(table):
            """{x =, y =, z =}: the axes it names; anything else an error,
            and nothing set unless all of it is right."""
            new = {}
            for k, v in table.items():
                if k not in ("x", "y", "z"):
                    raise LuaError("threshold table takes only x, y and z")
                new[TAP_AXIS[k]] = tap_threshold(v)
            if not new:
                raise LuaError(
                    "threshold table names no axis; use x, y or z")
            emu._tap.update(new)

        def tap_config(o):
            """imu.c, in its order: thresholds, then threshold (all three
            axes, or a table of some), quiet, duration, axes, latch, rate;
            what came before an error stays set."""
            t = emu._tap
            th = o["thresholds"]
            if th is not None:
                if luatype(th) != "table":
                    raise LuaError(
                        "thresholds must be a table {x =, y =, z =}")
                tap_axes(th)
            th = o["threshold"]
            if th is not None:
                if luatype(th) == "table":
                    tap_axes(th)
                else:
                    t["threshold"] = t["y"] = t["z"] = tap_threshold(th)
            for k in ("quiet", "duration"):
                if o[k] is not None:
                    v = checkint(o[k], -1, "tap_config")
                    if not 0 <= v <= 15:
                        raise LuaError(f"{k} must be between 0 and 15")
                    t[k] = v
            if o["axes"] is not None:
                v = checkint(o["axes"], -1, "tap_config")
                if not 1 <= v <= 0x3F:
                    raise LuaError("axes must be between 1 and 0x3F")
                t["axes"] = v
            if o["latch"] is not None:
                t["latch"] = o["latch"] is not False
            if o["rate"] is not None:
                v = checkint(o["rate"], -1, "tap_config")
                if v not in (1, 2, 4, 8, 16, 32, 64, 128, 256):
                    raise LuaError(
                        "rate must be 1, 2, 4, 8, 16, 32, 64, 128 or 256")
                t["rate"] = v

        def tap_settings():
            t = emu._tap
            return (t["threshold"], t["y"], t["z"], t["quiet"], t["duration"],
                    t["axes"], t["latch"], t["rate"])

        def listdir(path):
            return tuple(emu._lua.table(*e) for e in emu.files.listdir(path))

        def require_source(file):
            p = emu.files.path(file)
            if not p.is_file():
                raise LuaError(f"cannot open file: {file}")
            return p.read_text(encoding="latin-1")

        def camera_check():
            if not emu._camera_awake:
                raise LuaError("camera is asleep")

        def capture(resolution=None, quality=None, pan=None):
            res = 512
            if resolution is not None:
                res = checkint(resolution, -1, "capture")
                if not (100 <= res <= 720 and res % 2 == 0):
                    raise LuaError("resolution value must be a multiple of "
                                   "2 between 100 and 720")
            if pan is not None and \
                    not -280 <= checkint(pan, -1, "capture") * 2 <= 280:
                raise LuaError("pan value must be value between -140 and 140")
            q = 90
            if quality is not None:
                q = {"VERY_LOW": 10, "LOW": 25, "MEDIUM": 50, "HIGH": 75,
                     "VERY_HIGH": 90}.get(str(quality))
                if q is None:
                    raise LuaError("quality must be either VERY_HIGH, HIGH, "
                                   "MEDIUM, LOW or VERY_LOW")
            buf = io.BytesIO()
            emu.picture.resize((res, res)).convert("RGB").save(
                buf, "JPEG", quality=q)
            emu._jpeg, emu._jpeg_pos = buf.getvalue(), 0

        def image_ready():
            camera_check()
            return bool(emu._jpeg)

        def camera_read(n):
            n = checkint(n, 1, "read")
            if n <= 0:
                raise LuaError("bytes must be greater than 0")
            if emu._jpeg_pos >= len(emu._jpeg):
                emu._jpeg = b""
                return None
            chunk = emu._jpeg[emu._jpeg_pos:emu._jpeg_pos + n]
            emu._jpeg_pos += len(chunk)
            return chunk.decode("latin-1")

        def camera_power_save(on):
            if not isinstance(on, bool):
                raise LuaError("value must be true or false")
            emu._camera_awake = not on

        def checknumber(v, fn):
            """luaL_checknumber of an option (argument -1)."""
            if isinstance(v, str):
                num = lua_number(v)
                v = v if num is None else num
            if isinstance(v, bool) or not isinstance(v, (int, float)):
                raise LuaError(f"bad argument #-1 to '{fn}' "
                               f"(number expected, got {luatype(v)})")
            return v

        def camera_auto(o):
            """camera.c's checks of auto()'s options, in its order."""
            m = o["metering"]
            if m is not None:
                if not isinstance(m, (str, int, float)) or isinstance(m, bool):
                    raise LuaError("bad argument #-1 to 'auto' "
                                   f"(string expected, got {luatype(m)})")
                if str(m) not in ("SPOT", "CENTER_WEIGHTED", "AVERAGE"):
                    raise LuaError(
                        "metering must be SPOT, CENTER_WEIGHTED or AVERAGE")
            for k, lo, hi in (("exposure", 0, 1), ("exposure_speed", 0, 1),
                              ("shutter_limit", 4, 16383),
                              ("analog_gain_limit", 1, 248),
                              ("white_balance_speed", 0, 1),
                              ("rgb_gain_limit", 0, 1023)):
                if o[k] is not None and \
                        not lo <= checknumber(o[k], "auto") <= hi:
                    raise LuaError(f"{k} must be between {lo} and {hi}")

        def camera_set_shutter(v=None):
            camera_check()
            if not 4 <= checkint(v, 1, "set_shutter") <= 0x3FFF:
                raise LuaError("shutter must be between 4 and 16383")

        def camera_set_gain(v=None):
            camera_check()
            if not 1 <= checkint(v, 1, "set_gain") <= 0xF8:
                raise LuaError("gain must be between 1 and 248")

        def camera_set_white_balance(r=None, g=None, b=None):
            camera_check()
            gains = [checkint(v, i, "set_white_balance")
                     for i, v in enumerate((r, g, b), 1)]
            if not all(0 <= v <= 0x3FF for v in gains):
                raise LuaError("gains must be between 0 and 1023")

        def camera_write_register(address=None, value=None):
            camera_check()
            address = checkint(address, 1, "write_register")
            value = checkint(value, 2, "write_register")
            if not 0 <= address <= 0xFFFF:
                raise LuaError("address must be a 16 bit unsigned number")
            if not 0 <= value <= 0xFF:
                raise LuaError("value must be an 8 bit unsigned number")

        def camera_read_register(address=None):
            camera_check()
            if not 0 <= checkint(address, 1, "read_register") <= 0xFFFF:
                raise LuaError("address must be a 16 bit unsigned number")
            return 0

        def led_set_color(r=None, g=None, b=None):
            rgb = [checkint(v, i, "set_color")
                   for i, v in enumerate((r, g, b), 1)]
            if not all(0 <= v <= 100 for v in rgb):
                raise LuaError("led color must be between 0 and 100")
            emu.led = tuple(rgb)

        def display_write_register(address=None, value=None):
            address = checkint(address, 1, "write_register")
            value = checkint(value, 2, "write_register")
            if not 0 <= address <= 0xFF:
                raise LuaError("address must be a 8 bit unsigned number")
            if not 0 <= value <= 0xFF:
                raise LuaError("value must be a 8 bit unsigned number")

        def mic_start(rate=None, depth=None):
            if emu._mic_on:
                raise LuaError("already started")
            rate = 8000 if rate is None else checkint(rate, -1, "start")
            depth = 8 if depth is None else checkint(depth, -1, "start")
            if rate not in (8000, 16000):
                raise LuaError("sample rate must be 8000 or 16000")
            if depth not in (8, 16):
                raise LuaError("bit depth must be 8 or 16")
            emu._mic_fmt = (rate, depth)
            emu._mic_on = True
            emu.mic_data.clear()

        def mic_stop():
            emu._mic_on = False

        def mic_read(n):
            n = checkint(n, 1, "read")
            if n % 2:
                raise LuaError("bytes must be a multiple of 2")
            if not emu.mic_data:
                return "" if emu._mic_on else None
            chunk = bytes(emu.mic_data[:n])
            del emu.mic_data[:n]
            return chunk.decode("latin-1")

        f = emu.files
        d = emu.display
        stubs = {
            "HARDWARE_VERSION": HARDWARE_VERSION,
            "FIRMWARE_VERSION": FIRMWARE_VERSION,
            "GIT_TAG": "emulator",
            "battery_level": battery_level,
            "stay_awake": stay_awake,
            "fpga_read": fpga_read,
            "fpga_write": fpga_write,
            "sleep": emu._sleep,
            "utc": utc, "zone": zone, "date": date,
            "text": text, "mono": mono,
            "bitmap": bitmap, "show": d.show,
            # the name first, then the three numbers (display.c)
            "assign_color": lambda name, r, g, b: d.assign_color(
                d.palette_index(name), checkint(r, 2, "assign_color"),
                checkint(g, 3, "assign_color"),
                checkint(b, 4, "assign_color")),
            "assign_color_ycbcr": lambda name, y, cb, cr:
                d.assign_color_ycbcr(
                    d.palette_index(name),
                    checkint(y, 2, "assign_color_ycbcr"),
                    checkint(cb, 3, "assign_color_ycbcr"),
                    checkint(cr, 4, "assign_color_ycbcr")),
            "set_brightness": lambda lvl: d.set_brightness(
                checkint(lvl, 1, "set_brightness")),
            "power_save": d.power_save,
            "is_connected": lambda: emu.connected,
            "address": lambda: emu.address,
            "max_length": lambda: PAYLOAD - 1,
            "send": send,
            "set_callback": set_callback,
            "direction": lambda: (emu.roll, emu.pitch, emu.heading),
            "raw": lambda: (0.0,) * 6,
            "woke_by_tap": lambda: emu._woke_by_tap,
            "tap_config": tap_config, "tap_settings": tap_settings,
            "open": f.open, "read": f.read, "write": f.write,
            "writable": f.writable,
            "close": f.close, "remove": f.remove, "rename": f.rename,
            "mkdir": f.mkdir, "listdir": listdir, "space": f.space,
            "require_source": require_source,
            "camera_check": camera_check,
            "capture": capture, "image_ready": image_ready,
            "camera_read": camera_read,
            "camera_power_save": camera_power_save,
            "camera_awake": lambda: emu._camera_awake,
            "camera_auto": camera_auto,
            "camera_set_shutter": camera_set_shutter,
            "camera_set_gain": camera_set_gain,
            "camera_set_white_balance": camera_set_white_balance,
            "camera_write_register": camera_write_register,
            "camera_read_register": camera_read_register,
            "led_set_color": led_set_color,
            "display_write_register": display_write_register,
            "mic_start": mic_start, "mic_stop": mic_stop,
            "mic_read": mic_read,
        }
        return {k: lua_errors(v) if callable(v) and k != "sleep" else v
                for k, v in stubs.items()}

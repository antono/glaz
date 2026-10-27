"""The glasses' files as the phone uploads them to Halo, in a directory the
Halo emulator runs from (tests/test_halo.py, docs/DEVICES.md).

Mirrors luaFiles(..., model: halo) in flutter-glaz/lib/frame/upload.dart:
every file the same on all glasses, Halo's parts, a module only when it
has a Halo part, no empty parts; glaz.lua as glaz_app.lua, and glaz_boot's
Halo part as main.lua.
"""
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEVICE = "halo"
DEVICES = ("frame", "halo")


def device_of(path: Path) -> str | None:
    """The glasses a part is for (reader.halo.lua -> 'halo'), or None."""
    parts = path.name.split(".")
    return parts[-2] if len(parts) >= 3 and parts[-2] in DEVICES else None


def stem(path: Path) -> str:
    return path.name.split(".")[0]


def empty(path: Path) -> bool:
    """A part with nothing in it, which Upload leaves on the phone."""
    if device_of(path) is None:
        return False
    code = "".join(l for l in path.read_text().splitlines()
                   if not l.lstrip().startswith("--"))
    return re.sub(r"\s", "", code) in ("", "return{}")


def ours(path: Path) -> bool:
    return device_of(path) in (None, DEVICE) and not empty(path)


def stage(sandbox: Path) -> list[str]:
    """Copies Halo's files into sandbox; returns their names there."""
    sandbox.mkdir(parents=True, exist_ok=True)
    out = {}
    for p in sorted((ROOT / "flutter-glaz/assets/lua/lib").glob("*.lua")):
        out[p.name] = p
    for p in sorted((ROOT / "app").glob("*.lua")):
        if ours(p) and stem(p) != "glaz_boot" or p.name == "glaz_boot.lua":
            out[p.name] = p
    modules = {stem(p) for p in (ROOT / "modules").glob(f"*.{DEVICE}.lua")}
    for p in sorted((ROOT / "modules").glob("*.lua")):
        if stem(p) in modules and ours(p):
            out[p.name] = p
    if not empty(ROOT / f"glaz.{DEVICE}.lua"):
        out[f"glaz_app.{DEVICE}.lua"] = ROOT / f"glaz.{DEVICE}.lua"
    out["glaz_app.lua"] = ROOT / "glaz.lua"
    out["main.lua"] = ROOT / f"app/glaz_boot.{DEVICE}.lua"
    for name, src in out.items():
        shutil.copyfile(src, sandbox / name)
    return sorted(out)


# halo-emulator 2.3.0 (firmware 0.8.12) keeps frame.file simpler than
# Halo's firmware does today (lua_file.c, 0.8.22): it takes only Python's
# modes, has no file:read(n), keeps the line break read() should drop, and
# listdir() gives bare names. glaz goes by the firmware, so the emulator
# gets the firmware's file API here.

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


def emulator(sandbox: Path, print_handler=print):
    """A HaloEmulator on sandbox, with the firmware's frame.file."""
    from halo_emulator import HaloEmulator

    emu = HaloEmulator(sandbox_dir=sandbox, print_handler=print_handler)
    files = FirmwareFiles(sandbox)
    emu._file = files
    build = emu._build_runtime

    def build_with_files():
        build()
        files._runtime = emu._lua

    emu._build_runtime = build_with_files
    return emu

"""The glasses' files as the phone uploads them, in a directory an emulator
runs from (tests/glasses.py, docs/DEVICES.md).

Mirrors luaFiles(..., model:) in flutter-glaz/lib/frame/upload.dart:
every file the same on all glasses, the glasses' own parts, a module only
when it has a part for them, no empty parts; glaz.lua as glaz_app.lua,
its part as glaz_app.<device>.lua, and glaz_boot's part as main.lua.
Files go up as they are, not minified or compiled: the emulators load
text.
"""
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "glaz"                  # glaz.lua, its parts, the boot loader
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


def modules(device: str) -> list[str]:
    """The modules that go to these glasses: those with a part for them."""
    return sorted({stem(p) for p in (ROOT / "apps").glob(f"*/*.{device}.lua")})


def files(device: str) -> dict[str, Path]:
    """Name on the glasses -> file in the repository."""
    def ours(p: Path) -> bool:
        return device_of(p) in (None, device) and not empty(p)

    out = {}
    for p in sorted((ROOT / "flutter-glaz/assets/lua/lib").glob("*.lua")):
        out[p.name] = p
    for p in sorted(APP.glob("*.lua")):
        if stem(p) == "glaz":
            continue
        if ours(p) and stem(p) != "glaz_boot" or p.name == "glaz_boot.lua":
            out[p.name] = p
    mods = set(modules(device))
    for p in sorted((ROOT / "apps").glob("*/*.lua")):
        if stem(p) in mods and ours(p):
            out[p.name] = p
    if not empty(APP / f"glaz.{device}.lua"):
        out[f"glaz_app.{device}.lua"] = APP / f"glaz.{device}.lua"
    out["glaz_app.lua"] = APP / "glaz.lua"
    out["main.lua"] = APP / f"glaz_boot.{device}.lua"
    return out


def stage(sandbox: Path, device: str) -> list[str]:
    """Copies the glasses' files into sandbox; returns their names there."""
    sandbox.mkdir(parents=True, exist_ok=True)
    out = files(device)
    for name, src in out.items():
        shutil.copyfile(src, sandbox / name)
    return sorted(out)

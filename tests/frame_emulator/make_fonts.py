"""Frame's two fonts, taken from the firmware's sources into fonts.json.gz
for the emulator (tests/frame_emulator/display.py).

    python tests/frame_emulator/make_fonts.py [FRAME_CODEBASE]

FRAME_CODEBASE is the firmware's repository, ../lab-frame-codebase next to
this one by default, as for the phone app's build (AGENTS.md). Its two
headers:

- system_font.h, frame.display.text()'s proportional font: a glyph per
  code point, 2 colours, a bitstream of width * height pixels;
- mono_font.h, frame.display.mono()'s Terminus: 20 to 32 px, normal and
  bold, a row a uint16_t with the leftmost pixel in the top bit.

Run it again when the firmware's fonts change; the emulator never reads
the firmware's repository itself, so CI does without it.
"""
import base64
import gzip
import json
import os
import re
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ASSETS = "source/application/lua_libraries/graphical_assets"


def numbers(text: str) -> list[int]:
    return [int(n, 0) for n in re.findall(r"0x[0-9A-Fa-f]+|\b\d+\b", text)]


def system_font(src: str) -> dict:
    meta = re.search(r"sprite_metadata\[\] = \{(.*?)\};", src, re.S).group(1)
    glyphs = [
        [int(cp, 16), int(w), int(h), int(c), int(off, 16)]
        for cp, w, h, c, off in re.findall(
            r"\{0x([0-9A-Fa-f]+), (\d+), (\d+), SPRITE_(\d+)_COLORS, "
            r"0x([0-9A-Fa-f]+)\}", meta)
    ]
    body = re.search(r"sprite_data\[\] = \{(.*?)\};", src, re.S).group(1)
    data = bytes(int(b, 16) for b in re.findall(r"0x([0-9A-Fa-f]{2})", body))
    return {"glyphs": glyphs, "data": base64.b64encode(data).decode()}


def mono_font(src: str) -> list[dict]:
    arrays = {
        name: numbers(re.sub(r"//[^\n]*", "", body))
        for name, body in re.findall(
            r"static const uint16_t (\w+)\[\] = \{(.*?)\};", src, re.S)
    }
    table = re.search(r"mono_fonts\[\] = \{(.*?)\};", src, re.S).group(1)
    out = []
    for size, bold, width, height, name in re.findall(
            r"\{(\d+), (true|false), (\d+), (\d+), (\w+)\}", table):
        rows = arrays[name]
        out.append({
            "size": int(size), "bold": bold == "true",
            "width": int(width), "height": int(height),
            "rows": base64.b64encode(
                struct.pack(f"<{len(rows)}H", *rows)).decode(),
        })
    return out


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
        "FRAME_CODEBASE", HERE.parents[2] / "lab-frame-codebase"))
    assets = root / ASSETS
    fonts = {
        "system": system_font((assets / "system_font.h").read_text()),
        "mono": mono_font((assets / "mono_font.h").read_text()),
    }
    out = HERE / "fonts.json.gz"
    # mtime 0: the same fonts give the same bytes, and no diff
    with open(out, "wb") as raw, gzip.GzipFile(
            fileobj=raw, mode="wb", mtime=0) as f:
        f.write(json.dumps(fonts, separators=(",", ":")).encode())
    print(f"{out}: {len(fonts['system']['glyphs'])} glyphs, "
          f"{len(fonts['mono'])} mono fonts, {out.stat().st_size} bytes")


if __name__ == "__main__":
    main()

"""frame.display as Frame's firmware and FPGA have it (display.c,
glaz/main): 640x400, 16 palette colours, sprites drawn to a back buffer
that show() flips to the panel and zeroes.

Text is drawn with the firmware's own fonts (fonts.json.gz, from
make_fonts.py), so a screenshot is what the wearer sees, and every string
drawn is kept with where it went, for tests to read the screen as text.
"""
from __future__ import annotations

import base64
import gzip
import json
import math
import struct
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

WIDTH, HEIGHT = 640, 400

# display.c's colours: name, Y (4 bits), Cb and Cr (3 bits)
COLORS = [
    ("VOID", 0, 4, 4), ("WHITE", 15, 4, 4), ("GREY", 7, 4, 4),
    ("RED", 5, 3, 6), ("PINK", 9, 3, 5), ("DARKBROWN", 2, 2, 5),
    ("BROWN", 4, 2, 5), ("ORANGE", 9, 2, 5), ("YELLOW", 13, 2, 4),
    ("DARKGREEN", 4, 4, 3), ("GREEN", 6, 2, 3), ("LIGHTGREEN", 10, 1, 3),
    ("NIGHTBLUE", 1, 5, 2), ("SEABLUE", 4, 5, 2), ("SKYBLUE", 8, 5, 2),
    ("CLOUDBLUE", 13, 4, 3),
]
NAMES = [c[0] for c in COLORS]


class LuaError(Exception):
    """An error the firmware raises with luaL_error: Lua gets the text."""


def ycbcr(y: int, cb: int, cr: int) -> tuple[int, int, int]:
    """The FPGA's 4:3:3 bit YCbCr as RGB."""
    yy = y * 255 / 15
    cbb = (cb - 4) * 255 / 8
    crr = (cr - 4) * 255 / 8
    rgb = (yy + 1.402 * crr, yy - 0.344 * cbb - 0.714 * crr, yy + 1.772 * cbb)
    return tuple(max(0, min(255, round(v))) for v in rgb)


@dataclass
class Text:
    """A string drawn, and where: what tests read the screen as."""
    text: str
    x: int
    y: int
    color: str = "WHITE"
    mono: bool = False


class Fonts:
    _loaded: "Fonts | None" = None

    def __init__(self):
        raw = json.loads(gzip.decompress(
            (Path(__file__).parent / "fonts.json.gz").read_bytes()))
        system = raw["system"]
        self.data = base64.b64decode(system["data"])
        self.glyphs = {g[0]: tuple(g[1:]) for g in system["glyphs"]}
        self.mono = {}
        for m in raw["mono"]:
            rows = base64.b64decode(m["rows"])
            m["rows"] = struct.unpack(f"<{len(rows) // 2}H", rows)
            self.mono[(m["size"], m["bold"])] = m

    @classmethod
    def get(cls) -> "Fonts":
        if cls._loaded is None:
            cls._loaded = Fonts()
        return cls._loaded


def bits(data: bytes, n: int, depth: int):
    """n pixel values of depth bits each from a bitstream, high bits first."""
    per = 8 // depth
    mask = (1 << depth) - 1
    for i in range(n):
        byte = data[i // per] if i // per < len(data) else 0
        yield (byte >> (8 - depth * (i % per + 1))) & mask


def check_xy(x: int, y: int):
    if not 1 <= x <= WIDTH:
        raise LuaError("x_position must be between 1 and 640 pixels")
    if not 1 <= y <= HEIGHT:
        raise LuaError("y_position must be between 1 and 400 pixels")


class FrameDisplay:
    def __init__(self):
        self.fonts = Fonts.get()
        self.palette = [ycbcr(*c[1:]) for c in COLORS]
        self.back = bytearray(WIDTH * HEIGHT)    # palette indices
        self.front = bytearray(WIDTH * HEIGHT)
        self.back_texts: list[Text] = []
        self.front_texts: list[Text] = []
        self.powered = True
        self.brightness = 0
        self.shows = 0

    # ---- drawing (Lua)

    def sprite(self, x, y, width, colors, offset, data: bytes):
        """The FPGA's sprite engine: 1, 2 or 4 bits a pixel in one stream,
        0 transparent, any other value v drawn in palette v + offset."""
        check_xy(x, y)
        if not 1 <= width <= WIDTH:
            raise LuaError("width must be between 1 and 640 pixels")
        if colors not in (2, 4, 16):
            raise LuaError("total_colors must be either 2, 4 or 16")
        if not 0 <= offset <= 15:
            raise LuaError("palette_offset must be between 0 and 15")
        depth = {2: 1, 4: 2, 16: 4}[colors]
        n = len(data) * 8 // depth
        x0, y0 = x - 1, y - 1
        for i, v in enumerate(bits(data, n, depth)):
            if v == 0:
                continue
            px, py = x0 + i % width, y0 + i // width
            if px < WIDTH and py < HEIGHT:
                self.back[py * WIDTH + px] = (v + offset) % 16

    def bitmap(self, x, y, width, colors, offset, data):
        self.sprite(int(x), int(y), int(width), int(colors), int(offset),
                    data.encode("latin-1") if isinstance(data, str) else data)

    def text(self, s: str, x: int, y: int, color: str | None = None,
             spacing: int = 4):
        offset = 0
        if color is not None:
            if color not in NAMES[1:]:
                raise LuaError("Invalid color name")
            offset = NAMES.index(color) - 1
        # strlen(): a NUL byte ends the string
        raw = s.encode("latin-1").split(b"\0")[0]
        decoded = raw.decode("utf-8", errors="replace")
        self.back_texts.append(Text(decoded, x, y, color or "WHITE"))
        for ch in decoded:
            g = self.fonts.glyphs.get(ord(ch))
            if g is None:
                continue
            w, h, colors, off = g
            if x + w > WIDTH or y + h > HEIGHT:
                continue
            depth = {2: 1, 4: 2, 16: 4}[colors]
            length = -(-w * h * depth // 8)
            self.sprite(x, y, w, colors, offset, self.fonts.data[off:off + length])
            x += w + spacing

    def mono(self, s: str, x: int, y: int, size=24, bold=False,
             color: str | None = None, bg: str | None = None,
             attrs: str | None = None) -> int:
        # display.c's order: the colours, the font, then x and y
        fg_i = 1 if color is None else self._index(color)
        bg_i = 0 if bg is None else self._index(bg)
        font = self.fonts.mono.get((size, bool(bold)))
        if font is None:
            raise LuaError("size must be 20, 24, 28 or 32")
        check_xy(x, y)
        w, h = font["width"], font["height"]
        fit = (WIDTH - (x - 1)) // w
        raw = s.encode("latin-1")
        cells = [c for c in raw if c & 0xC0 != 0x80][:fit]
        attrs_b = attrs.encode("latin-1") if attrs else b""
        # nothing to draw, or a row that would run off the bottom: nothing
        # is drawn at all, and x comes back as it was
        if not cells or y - 1 + h > HEIGHT:
            return x
        self.back_texts.append(Text(
            bytes(cells).decode("latin-1"), x, y, color or "WHITE", mono=True))
        for i, c in enumerate(cells):
            fg, bgc = fg_i, bg_i
            if i < len(attrs_b):
                a = attrs_b[i]
                fg = a & 0x0F or fg_i
                bgc = a >> 4
            cx = x - 1 + i * w
            for row in range(h):
                py = y - 1 + row
                if py >= HEIGHT:
                    break
                bits_row = font["rows"][(c - 0x20) * h + row] \
                    if 0x20 <= c <= 0x7E else 0
                for col in range(w):
                    px = cx + col
                    on = bits_row & (0x8000 >> col)
                    if on:
                        self.back[py * WIDTH + px] = fg
                    elif bgc:
                        self.back[py * WIDTH + px] = bgc
        return x + len(cells) * w

    def _index(self, name: str) -> int:
        if name not in NAMES[1:]:
            raise LuaError("Invalid color name")
        return NAMES.index(name)

    def show(self):
        self.front, self.back = self.back, bytearray(WIDTH * HEIGHT)
        self.front_texts, self.back_texts = self.back_texts, []
        self.shows += 1

    def palette_index(self, name) -> int:
        """A palette entry by name, VOID too (assign_color's lookup)."""
        if name not in NAMES:
            raise LuaError("Invalid color name")
        return NAMES.index(name)

    def assign_color(self, name: str | int, r: int, g: int, b: int):
        """RGB as the firmware sends it to the FPGA: YCbCr in 4, 3 and 3
        bits, so the colour shown is the nearest of those."""
        i = name if isinstance(name, int) else self.palette_index(name)
        for v, what in ((r, "red"), (g, "green"), (b, "blue")):
            if not 0 <= v <= 255:
                raise LuaError(f"{what} component must be between 0 and 255")
        y = math.floor(0.299 * r + 0.587 * g + 0.114 * b)
        cb = math.floor(-0.169 * r - 0.331 * g + 0.5 * b + 128)
        cr = math.floor(0.5 * r - 0.419 * g - 0.081 * b + 128)
        self.palette[i] = ycbcr((y & 0xFF) >> 4, (cb & 0xFF) >> 5,
                                (cr & 0xFF) >> 5)

    def assign_color_ycbcr(self, name: str | int, y: int, cb: int, cr: int):
        i = name if isinstance(name, int) else self.palette_index(name)
        if not 0 <= y <= 15:
            raise LuaError("Y component must be between 0 and 15")
        if not 0 <= cb <= 7:
            raise LuaError("Cb component must be between 0 and 7")
        if not 0 <= cr <= 7:
            raise LuaError("Cr component must be between 0 and 7")
        self.palette[i] = ycbcr(y, cb, cr)

    def set_brightness(self, level: int):
        if level not in (-2, -1, 0, 1, 2):
            raise LuaError("level must be -2, -1, 0, 1, or 2")
        self.brightness = level

    def power_save(self, on):
        if not isinstance(on, bool):
            raise LuaError("value must be true or false")
        self.powered = not on

    # ---- what the panel shows (tests)

    def image(self) -> Image.Image:
        img = Image.new("RGB", (WIDTH, HEIGHT))
        if self.powered:
            pal = self.palette
            img.putdata([pal[i] for i in self.front])
        return img

    def texts(self) -> list[Text]:
        return list(self.front_texts) if self.powered else []

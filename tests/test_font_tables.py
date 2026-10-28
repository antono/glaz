"""The width tables of Frame's font kept outside the firmware: Reader's
(modules/reader.lua) and the phone's (flutter-glaz/lib/frame/font.dart),
both to fit text to the screen. Each must be the firmware's own widths
(fonts.json.gz, from system_font.h): one off, and every glyph after it
is placed a glyph's width wrong."""
import re

import pytest

from frame_emulator.display import Fonts
from sandbox import ROOT

RANGES = {"ascii": (32, 126), "latin1": (0xA0, 0xFF), "cyrillic": (0x400, 0x45F)}


def firmware(lo, hi):
    """Each code point's advance as the tables write it: 48 + px, '0'
    for none."""
    glyphs = Fonts.get().glyphs
    return "".join(chr(48 + glyphs[c][0]) if c in glyphs else "0"
                   for c in range(lo, hi + 1))


def lua_string(src, name):
    m = re.search(rf"local {name} = ((?:'[^']*'\s*(?:\.\.\s*)?)+)", src)
    return "".join(re.findall(r"'([^']*)'", m.group(1)))


@pytest.mark.parametrize("table", ["latin1", "cyrillic"])
def test_readers_table_is_the_firmwares(table):
    src = (ROOT / "modules/reader.lua").read_text()
    assert lua_string(src, table.upper()) == firmware(*RANGES[table])


@pytest.mark.parametrize("table", ["ascii", "latin1", "cyrillic"])
def test_the_phones_table_is_the_firmwares(table):
    src = (ROOT / "flutter-glaz/lib/frame/font.dart").read_text()
    m = re.search(rf"const _{table} =\s*'([^']*)'", src)
    assert m.group(1) == firmware(*RANGES[table])

"""The Frame emulator itself (tests/frame_emulator, tests/vclock.py): that
it does what Frame's firmware does, checked with small main.lua scripts
and no glaz. Every expectation here is from the firmware's sources,
lab-frame-codebase, source/application/lua_libraries/*.c and luaport.c
(branch glaz/main), named in the tests; a test of glaz on these glasses
is only as good as this.
"""
import datetime
import io
import textwrap
import threading
from pathlib import Path

import pytest
from PIL import Image

import vclock
from glasses import SHOTS
from frame_emulator import BLOCK, BOOT_SECONDS, FrameEmulator
from frame_emulator.display import COLORS, HEIGHT, WIDTH, ycbcr
from vclock import VirtualClock

# Lua for the scripts: an error as the script sees it, or 'ok'
# on the first line of main.lua, so a script's lines keep their numbers
TRY = ("function try(f, ...) local ok, e = pcall(f, ...) "
       "print(ok and 'ok' or tostring(e)) end")
WHERE = '[string "main.lua"]:'     # luaL_error's position in main.lua


@pytest.fixture
def boot(tmp_path):
    """boot(src, files): main.lua (with TRY) and other files on a new pair
    of emulated glasses, started; what it prints is in emu.lines."""
    started = []

    def boot(src, files=None, *, advance=0.0):
        sandbox = tmp_path / f"frame{len(started)}"
        sandbox.mkdir()
        if not src.startswith("\n"):
            src = "\n" + src
        files = dict(files or {}, **{"main.lua": TRY + textwrap.dedent(src)})
        for name, text in files.items():
            (sandbox / name).write_bytes(
                text if isinstance(text, bytes) else text.encode("latin-1"))
        lines = []
        # the clock from 0 at main.lua, for exact times below
        emu = FrameEmulator(sandbox, lines.append, boot_seconds=0)
        emu.lines = lines
        started.append(emu)
        emu.start()
        emu.advance(advance)
        return emu

    yield boot
    for emu in started:
        emu.stop()


def run(boot, src, files=None):
    """What a script that ends by itself printed."""
    emu = boot(src, files)
    assert not emu.is_running(), "the script should have ended"
    assert emu.error is None, emu.error
    return emu.lines


def screenshot(emu, name):
    """The panel as a PNG under $SHOTS/frame/, as Glasses.screenshot()."""
    img = emu.image()
    if SHOTS:
        where = Path(SHOTS) / "frame"
        where.mkdir(parents=True, exist_ok=True)
        img.save(where / f"{name}.png")
    return img


def pixel(emu, x, y):
    """The palette index on the panel at Lua's x and y (from 1)."""
    return emu.display.front[(y - 1) * WIDTH + (x - 1)]


def lit(emu):
    return sum(1 for p in emu.display.front if p)


def palette(name):
    return [c[0] for c in COLORS].index(name)


# ---------------------------------------------------------------- display

def test_text_goes_to_the_back_buffer_until_show(boot):
    emu = boot("""
        frame.display.text('137', 50, 60)
        frame.sleep(1)
        frame.display.show()
        frame.sleep(1)
        frame.display.show()
        frame.sleep(1)
    """)
    assert emu.texts() == [] and lit(emu) == 0  # drawn, not shown
    emu.advance(1)
    [t] = emu.texts()
    assert (t.text, t.x, t.y, t.color) == ("137", 50, 60, "WHITE")
    assert lit(emu) > 0
    left, top = emu.image().getbbox()[:2]
    assert left >= 49 and top >= 59              # x and y count from 1
    emu.advance(1)                               # show() empties the back
    assert emu.texts() == [] and lit(emu) == 0
    assert emu.display.shows == 2


def test_text_in_a_palette_colour(boot):
    emu = boot("""
        frame.display.text('1', 1, 1, {color = 'RED'})
        frame.display.show()
    """)
    assert emu.texts()[0].color == "RED"
    assert {p for p in emu.display.front if p} == {palette("RED")}


def test_text_spacing_moves_the_next_glyph(boot):
    widths = []
    for spacing in (0, 37):
        emu = boot(f"""
            frame.display.text('11', 1, 1, {{spacing = {spacing}}})
            frame.display.show()
        """)
        box = emu.image().getbbox()
        widths.append(box[2] - box[0])
    assert widths[1] - widths[0] == 37


def test_text_options_and_their_errors(boot):
    lines = run(boot, """
        try(function() frame.display.text('a', 1, 1, {color = 'VOID'}) end)
        try(function() frame.display.text('a', 1, 1, {color = 'PURPLE'}) end)
        try(function() frame.display.text('a', 60.5, 1) end)
        try(function() frame.display.text('a', 1, 2.5) end)
        try(function() frame.display.text('a', 1, 1, {spacing = 1.5}) end)
        try(function() frame.display.text('a', 0, 1) end)
        try(function() frame.display.text('a', 60.0, 1) end)
        try(function() frame.display.text(137, 1, 1) end)
        try(function() frame.display.text({}, 1, 1) end)
        try(function() frame.display.text('a', 1, 1, 'not a table') end)
    """)
    assert lines == [
        WHERE + "2: Invalid color name",             # VOID is not a colour
        WHERE + "3: Invalid color name",
        WHERE + "4: bad argument #2 to 'text' "
                "(number has no integer representation)",
        WHERE + "5: bad argument #3 to 'text' "
                "(number has no integer representation)",
        WHERE + "6: bad argument #-1 to 'text' "
                "(number has no integer representation)",
        WHERE + "7: x_position must be between 1 and 640 pixels",
        "ok",                                        # 60.0 is an integer
        "ok",                                        # a number is a string
        WHERE + "10: bad argument #1 to 'text' "
                "(string expected, got table)",
        "ok",                                        # options ignored
    ]


def test_an_error_has_no_position_when_pcall_calls_frame_directly(boot):
    # luaL_where(L, 1) is the caller: pcall, a C function, has no line
    lines = run(boot, "try(frame.display.text, 'a', 1.5, 1)")
    assert lines == ["bad argument #2 to 'text' "
                     "(number has no integer representation)"]


def test_a_glyph_that_does_not_fit_is_left_out(boot):
    lines = run(boot, """
        try(frame.display.text, '137', 630, 1)       -- past the right edge
        try(frame.display.text, '137', 1, 380)       -- past the bottom
        try(frame.display.text, '', 0, 0)            -- nothing to place
    """)
    assert lines == ["ok", "ok", "ok"]
    emu = boot("""
        frame.display.text('137', 630, 1)
        frame.display.show()
    """)
    assert lit(emu) == 0


def test_mono_returns_the_x_after_its_cells(boot):
    lines = run(boot, """
        print(frame.display.mono('137', 1, 1))
        print(frame.display.mono('137', 1, 1, {size = 20}))
        print(frame.display.mono('137', 1, 1, {size = 32, bold = true}))
        print(frame.display.mono('a\\xc3\\xa9b', 1, 1))  -- UTF-8: 3 cells
        print(frame.display.mono(string.rep('x', 137), 1, 1))
        print(frame.display.mono('', 137, 1))
        print(frame.display.mono('137', 1, 390))     -- off the bottom
    """)
    assert lines == ["37", "31", "49", "37",
                     str(1 + (640 // 12) * 12),      # cut at the right edge
                     "137", "1"]


def test_mono_draws_text_over_its_background(boot):
    emu = boot("""
        frame.display.mono('# #', 1, 1, {color = 'RED', bg = 'GREY'})
        frame.display.show()
    """)
    [t] = emu.texts()
    assert t.mono and t.text == "# #" and t.color == "RED"
    colours = {pixel(emu, x, y) for x in range(1, 37) for y in range(1, 25)}
    assert colours == {palette("RED"), palette("GREY")}
    assert pixel(emu, 37, 1) == 0                # nothing past three cells


def test_mono_attrs_colour_each_cell(boot):
    # a byte a cell: low nibble the text, high the background; 0 is the
    # option's colour, and cells past the end of attrs take the options
    emu = boot("""
        frame.display.mono('###', 1, 1,
          {color = 'GREEN', attrs = string.char(0x03, 0x20)})
        frame.display.show()
    """)

    def cell(i):
        return {pixel(emu, x, y) for x in range(1 + 12 * i, 13 + 12 * i)
                for y in range(1, 25)} - {0}

    assert cell(0) == {palette("RED")}
    assert cell(1) == {palette("GREEN"), palette("GREY")}
    assert cell(2) == {palette("GREEN")}


def test_mono_errors(boot):
    lines = run(boot, """
        try(function() frame.display.mono('a', 1, 1, {size = 25}) end)
        try(function() frame.display.mono('a', 1, 1, {color = 'VOID'}) end)
        try(function() frame.display.mono('a', 1, 1, {bg = 'NOPE'}) end)
        try(function() frame.display.mono('a', 641, 1) end)
        try(function() frame.display.mono('a', 1, 0) end)
        try(function() frame.display.mono('a', 1.5, 1) end)
        -- the colours are read before the size is looked at
        try(function() frame.display.mono('a', 1, 1, {size = 25, color = 'VOID'}) end)
    """)
    assert lines == [
        WHERE + "2: size must be 20, 24, 28 or 32",
        WHERE + "3: Invalid color name",
        WHERE + "4: Invalid color name",
        WHERE + "5: x_position must be between 1 and 640 pixels",
        WHERE + "6: y_position must be between 1 and 400 pixels",
        WHERE + "7: bad argument #2 to 'mono' "
                "(number has no integer representation)",
        WHERE + "9: Invalid color name",
    ]


def test_mono_off_the_bottom_draws_nothing(boot):
    emu = boot("""
        frame.display.mono('137', 1, 380)
        frame.display.show()
    """)
    assert lit(emu) == 0 and emu.texts() == []


def test_a_bitmap_of_two_colours_is_a_bit_a_pixel(boot):
    # 1 is palette 1 + offset, 0 is transparent; rows wrap at width
    emu = boot(r"""
        frame.display.bitmap(1, 1, 4, 16, 0, '\x22\x22\x22\x22')  -- GREY
        frame.display.bitmap(1, 1, 4, 2, 2, '\xA5')                  -- RED
        frame.display.show()
    """)
    row1 = [pixel(emu, x, 1) for x in range(1, 5)]
    row2 = [pixel(emu, x, 2) for x in range(1, 5)]
    red, grey = palette("RED"), palette("GREY")  # 1 + 2 is RED
    assert row1 == [red, grey, red, grey]          # 1010
    assert row2 == [grey, red, grey, red]          # 0101


def test_a_bitmap_of_four_and_sixteen_colours(boot):
    emu = boot(r"""
        frame.display.bitmap(137, 1, 4, 4, 0, '\x1B')        -- 00 01 10 11
        frame.display.bitmap(137, 2, 4, 16, 1, '\x01\x23')   -- 0 1 2 3
        frame.display.show()
    """)
    assert [pixel(emu, x, 1) for x in range(137, 141)] == [0, 1, 2, 3]
    assert [pixel(emu, x, 2) for x in range(137, 141)] == [0, 2, 3, 4]


def test_bitmap_errors(boot):
    lines = run(boot, r"""
        try(frame.display.bitmap, 1, 1, 8, 3, 0, '\xFF')
        try(frame.display.bitmap, 1, 1, 0, 2, 0, '\xFF')
        try(frame.display.bitmap, 1, 1, 8, 2, 16, '\xFF')
        try(frame.display.bitmap, 0, 1, 8, 2, 0, '\xFF')
        try(frame.display.bitmap, 1, 401, 8, 2, 0, '\xFF')
        try(frame.display.bitmap, 1.5, 1, 8, 2, 0, '\xFF')
        try(frame.display.bitmap, 1, 1, 8, 2, 0)
    """)
    assert lines == [
        "total_colors must be either 2, 4 or 16",
        "width must be between 1 and 640 pixels",
        "palette_offset must be between 0 and 15",
        "x_position must be between 1 and 640 pixels",
        "y_position must be between 1 and 400 pixels",
        "bad argument #1 to 'bitmap' (number has no integer representation)",
        "bad argument #6 to 'bitmap' (string expected, got nil)",
    ]


def test_assign_color_is_as_near_as_the_fpgas_bits(boot):
    # display.c: RGB to YCbCr, then 4, 3 and 3 bits: (255, 0, 0) is
    # Y 76 >> 4 = 4, Cb 84 >> 5 = 2, Cr 255 >> 5 = 7
    emu = boot("""
        frame.display.assign_color('WHITE', 255, 0, 0)
        frame.display.assign_color('GREY', 255, 255, 255)
        frame.display.assign_color_ycbcr('VOID', 5, 3, 6)
        frame.display.text('1', 1, 1)
        frame.display.show()
    """)
    pal = emu.display.palette
    assert pal[palette("WHITE")] == ycbcr(4, 2, 7) != (255, 0, 0)
    assert pal[palette("GREY")] == ycbcr(15, 4, 4)      # white, as at boot
    assert pal[palette("VOID")] == ycbcr(5, 3, 6)       # RED's own
    assert ycbcr(4, 2, 7) in set(emu.image().getdata())


def test_colour_and_brightness_errors(boot):
    lines = run(boot, """
        try(frame.display.assign_color, 'NOPE', 1, 2, 3)
        try(frame.display.assign_color, 'RED', 256, 0, 0)
        try(frame.display.assign_color, 'RED', 0, -1, 0)
        try(frame.display.assign_color, 'RED', 0, 0, 1.5)
        try(frame.display.assign_color_ycbcr, 'RED', 16, 0, 0)
        try(frame.display.assign_color_ycbcr, 'RED', 0, 8, 0)
        try(frame.display.set_brightness, 3)
        try(frame.display.set_brightness, -2)
        try(frame.display.power_save, 'yes')
    """)
    assert lines == [
        "Invalid color name",
        "red component must be between 0 and 255",
        "green component must be between 0 and 255",
        "bad argument #4 to 'assign_color' "
        "(number has no integer representation)",
        "Y component must be between 0 and 15",
        "Cb component must be between 0 and 7",
        "level must be -2, -1, 0, 1, or 2",
        "ok",
        "value must be true or false",
    ]


def test_power_save_turns_the_panel_off(boot):
    emu = boot("""
        frame.display.text('137', 1, 1)
        frame.display.show()
        frame.display.power_save(true)
        frame.sleep(1)
        frame.display.power_save(false)
        frame.sleep(1)
    """)
    assert emu.texts() == [] and emu.image().getbbox() is None
    emu.advance(1)
    assert emu.texts()[0].text == "137"


def test_text_options_are_checked_in_display_cs_order(boot):
    # luaL_checkstring of the colour, then luaL_checkinteger of spacing;
    # numbers stand for strings and numeric strings for integers
    lines = run(boot, """
        try(function() frame.display.text('a', 1, 1, {color = {}}) end)
        try(function() frame.display.text('a', 1, 1, {color = 137}) end)
        try(function()
          frame.display.text('a', 1, 1, {color = 'NOPE', spacing = 1.5}) end)
        try(function() frame.display.text('a', '137', ' 13 ') end)
        try(function() frame.display.text('a', '1.5', 1) end)
        try(function() frame.display.text('a', 'left', 1) end)
    """)
    assert lines == [
        WHERE + "2: bad argument #-1 to 'text' (string expected, got table)",
        WHERE + "3: Invalid color name",
        WHERE + "5: Invalid color name",
        "ok",
        WHERE + "7: bad argument #2 to 'text' "
                "(number has no integer representation)",
        WHERE + "8: bad argument #2 to 'text' (number expected, got string)",
    ]


def test_text_glyphs_fit_inside_640_by_400(boot):
    # display.c draws a glyph only while x + width <= 640 and
    # y + height <= 400; '1' is 16 by 48
    emu = boot("""
        frame.display.text('1', 624, 352)
        frame.display.show()
        frame.sleep(1)
        frame.display.text('1', 625, 1)
        frame.display.text('1', 1, 353)
        frame.display.show()
    """)
    right, bottom = emu.image().getbbox()[2:]
    assert right <= 640 and bottom <= 400 and lit(emu) > 0
    emu.advance(1)
    assert lit(emu) == 0


def test_text_reads_utf8_and_skips_what_the_font_lacks(boot):
    # utf8_decode(): e-acute is one glyph; a snowman has none and takes
    # no room, so 'a', snowman, 'b' is drawn as 'ab' is
    boxes = []
    for s in ("ab", "a\\u{2603}b", "\\u{e9}"):
        emu = boot(f"""
            frame.display.text('{s}', 1, 1)
            frame.display.show()
        """)
        boxes.append(emu.image().getbbox())
    assert boxes[0] == boxes[1]
    assert boxes[2] is not None
    assert emu.texts()[0].text == "é"


def test_text_ends_at_a_nul_byte(boot):
    # strlen() of luaL_checkstring's string
    emu = boot("""
        frame.display.text('13\\0' .. '7', 1, 1)
        frame.display.show()
    """)
    assert emu.texts()[0].text == "13"


def test_mono_takes_a_cell_for_a_character_it_cannot_draw(boot):
    # printable ASCII is drawn; a tab takes its cell, blank but for bg
    emu = boot("""
        print(frame.display.mono('a\\tb', 1, 1, {bg = 'GREY'}))
        frame.display.show()
    """)
    assert emu.lines == [str(1 + 3 * 12)]
    tab = {pixel(emu, x, y) for x in range(13, 25) for y in range(1, 25)}
    assert tab == {palette("GREY")}


def test_mono_bold_is_lua_truthiness(boot):
    # lua_toboolean: 0 is true, as any value but nil and false
    counts = []
    for bold in ("false", "0", "true"):
        emu = boot(f"""
            frame.display.mono('#', 1, 1, {{bold = {bold}}})
            frame.display.show()
        """)
        counts.append(lit(emu))
    assert counts[0] < counts[1] == counts[2]


def test_mono_option_types(boot):
    lines = run(boot, """
        try(frame.display.mono, '#', 1, 1, {attrs = {}})
        try(frame.display.mono, '#', 1, 1, {attrs = 3})    -- '3', 0x33
        try(frame.display.mono, '#', 1, 1, {bg = 137})
        try(frame.display.mono, '#', 1, 1, {size = '20'})
        try(frame.display.mono, '#', 1, 1, {size = 24.5})
    """)
    assert lines == [
        "bad argument #-1 to 'mono' (string expected, got table)",
        "ok",
        "Invalid color name",
        "ok",
        "bad argument #-1 to 'mono' (number has no integer representation)",
    ]


def test_a_bitmap_takes_a_number_for_its_data(boot):
    # luaL_checklstring: 1 is the string '1', 0x31, two pixels of 16 colours
    emu = boot("""
        frame.display.bitmap(1, 1, 2, 16, 0, 1)
        frame.display.show()
    """)
    assert [pixel(emu, x, 1) for x in (1, 2)] == [3, 1]


def test_brightness_and_display_registers(boot):
    lines = run(boot, """
        for _, level in ipairs({-2, -1, 0, 1, 2}) do
          frame.display.set_brightness(level)
        end
        try(frame.display.set_brightness, 1.5)
        try(frame.display.write_register, 0x100, 0)
        try(frame.display.write_register, 0, 256)
        try(frame.display.write_register, 0x05, 0xC8)
    """)
    assert lines == [
        "bad argument #1 to 'set_brightness' "
        "(number has no integer representation)",
        "address must be a 8 bit unsigned number",
        "value must be a 8 bit unsigned number",
        "ok",
    ]


def test_a_show_of_nothing_clears_the_panel(boot):
    emu = boot("""
        frame.display.text('137', 1, 1)
        frame.display.show()
        frame.sleep(1)
        frame.display.show()
    """)
    assert lit(emu) > 0
    emu.advance(1)
    assert lit(emu) == 0 and emu.texts() == []


def test_screenshots_of_what_the_display_draws(boot, tmp_path):
    # the emulator's panel, as docs/TESTING.md shows it: text in colour,
    # a mono row with attrs, and a bitmap
    emu = boot(r"""
        frame.display.text('Frame 137', 40, 40)
        frame.display.text('RED', 40, 110, {color = 'RED'})
        frame.display.text('SKYBLUE', 200, 110, {color = 'SKYBLUE'})
        frame.display.mono('mono 137 ', 40, 200,
          {size = 32, bold = true, color = 'YELLOW', bg = 'NIGHTBLUE'})
        frame.display.mono('attrs', 40, 260,
          {attrs = string.char(0x13, 0x24, 0x35, 0x46, 0x57)})
        frame.display.bitmap(480, 200, 64, 2, 9,
          string.rep(string.rep('\xAA', 8) .. string.rep('\x55', 8), 16))
        frame.display.show()
    """)
    img = screenshot(emu, "emulator_display")
    assert img.size == (WIDTH, HEIGHT)
    assert {t.text for t in emu.texts()} >= {"Frame 137", "RED", "attrs"}
    colours = set(img.getdata())
    for name in ("WHITE", "RED", "SKYBLUE", "YELLOW", "NIGHTBLUE"):
        assert emu.display.palette[palette(name)] in colours


# ---------------------------------------------------------------- files

def test_file_modes(boot):
    lines = run(boot, """
        local f = frame.file.open('a.txt', 'w')
        f:write('one\\n')
        f:write(137)                         -- a number is written as text
        f:close()
        f = frame.file.open('a.txt', 'a')    -- reads from the start
        print(f:read())
        f:write('\\nthree')                   -- and writes at the end
        f:close()
        f = frame.file.open('a.txt', 'read') -- only the first letter counts
        print(f:read(), f:read(), f:read(), f:read())
        try(f.write, f, 'x')
        f:close()
        f = frame.file.open('a.txt', 'w')    -- truncates
        f:close()
        print(frame.file.open('a.txt'):read())
    """)
    assert lines == ["one", "one\t137\tthree\tnil",
                     "file opened in read-only mode", "nil"]


def test_file_open_errors(boot):
    lines = run(boot, """
        try(function() frame.file.open('nope.txt') end)
        try(function() frame.file.open('a.txt', 'x') end)
        try(function() frame.file.open('a.txt', '') end)
        try(function() frame.file.open('no/such/dir.txt', 'w') end)
        try(function() frame.file.open() end)
        frame.file.mkdir('d')
        try(function() frame.file.open('d') end)
    """)
    assert lines == [
        WHERE + "2: cannot open file nope.txt",
        WHERE + "3: mode must be 'r', 'w', or 'a'",
        WHERE + "4: mode must be 'r', 'w', or 'a'",
        WHERE + "5: cannot open file no/such/dir.txt",
        WHERE + "6: bad argument #1 to 'open' (string expected, got no value)",
        WHERE + "8: cannot open file d",
    ]


def test_a_closed_file_is_an_error(boot):
    lines = run(boot, """
        local f = frame.file.open('a.txt', 'w')
        f:close()
        try(f.read, f)
        try(f.write, f, 'x')
        try(f.close, f)                      -- twice is an error too
    """)
    assert lines == ["attempt to use a closed file"] * 3


def test_a_file_method_wants_its_handle(boot):
    # luaL_checkudata(L, 1, LUA_FILEHANDLE): f.read() without the colon is
    # an error on the glasses
    lines = run(boot, """
        local f = frame.file.open('a.txt', 'w')
        try(function() f.read() end)
        try(function() f.write('x') end)
        try(function() f.close({}) end)
        f:close()
        local g = frame.file.open('a.txt', 'w')
        try(f.close, g)                      -- any open handle will do
    """)
    assert lines == [
        WHERE + "3: bad argument #1 to 'read' (FILE* expected, got no value)",
        WHERE + "4: bad argument #1 to 'write' (FILE* expected, got string)",
        WHERE + "5: bad argument #1 to 'close' (FILE* expected, got table)",
        "ok",
    ]


def test_write_checks_closed_then_read_only_then_the_string(boot):
    # file.c: check_if_file_closed, the mode, then luaL_checklstring
    lines = run(boot, """
        local f = frame.file.open('a.txt', 'w')
        try(f.write, f, {})
        try(f.write, f)
        f:close()
        try(f.write, f, {})
        f = frame.file.open('a.txt')
        try(f.write, f, {})
    """)
    assert lines == [
        "bad argument #1 to 'write' (string expected, got table)",
        "bad argument #1 to 'write' (string expected, got no value)",
        "attempt to use a closed file",
        "file opened in read-only mode",
    ]


def test_append_creates_a_file(boot):
    # file.c: 'a' is LFS_O_RDWR | LFS_O_APPEND | LFS_O_CREAT
    lines = run(boot, """
        local f = frame.file.open('new.txt', 'a')
        f:write('one\\ntwo')
        f:close()
        f = frame.file.open('new.txt')
        print(f:read(), f:read(), f:read())
        f:close()
    """)
    assert lines == ["one\ttwo\tnil"]


def test_file_functions_want_strings(boot):
    lines = run(boot, """
        try(frame.file.remove)
        try(frame.file.rename, 'a')
        try(frame.file.mkdir, {})
        try(frame.file.listdir)
        frame.file.mkdir(137)                -- a number is a name
        print(frame.file.listdir('/')[3].name)
        try(frame.file.mkdir, string.rep('d', 257))
    """)
    assert lines == [
        "bad argument #1 to 'remove' (string expected, got no value)",
        "bad argument #2 to 'rename' (string expected, got no value)",
        "bad argument #1 to 'mkdir' (string expected, got table)",
        "bad argument #1 to 'listdir' (string expected, got no value)",
        "137",
        "path too long",                     # name_max is 0x100
    ]


def test_read_gives_a_line_of_at_most_512_bytes(boot):
    # file.c: up to LUAL_BUFFERSIZE bytes, the line break dropped; '' for
    # an empty line, nil at the end; a 512-byte line leaves its break for
    # the next read, as ''
    text = ("one\n\n" + "x" * 600 + "\n" + "y" * 512 + "\nlast").encode()
    lines = run(boot, """
        local f = frame.file.open('t.txt')
        while true do
          local s = f:read()
          print(s == nil and 'nil' or #s .. ':' .. s:sub(1, 4))
          if s == nil then break end
        end
        print(frame.file.open('empty.txt'):read())
    """, {"t.txt": text, "empty.txt": b""})
    assert lines == ["3:one", "0:", "512:xxxx", "88:xxxx", "512:yyyy", "0:",
                     "4:last", "nil", "nil"]


def test_read_keeps_bytes_as_they_are(boot):
    lines = run(boot, """
        local s = frame.file.open('b.bin'):read()
        print(#s, s:byte(1, -1))
    """, {"b.bin": bytes([0, 137, 255, 13, 10])})
    assert lines == ["4\t0\t137\t255\t13"]


def test_listdir_has_dot_and_dot_dot_first(boot):
    lines = run(boot, """
        frame.file.mkdir('sub')
        local f = frame.file.open('sub/b.txt', 'w') f:write('137') f:close()
        for _, path in ipairs({'/', 'sub', '/sub'}) do
          for _, e in ipairs(frame.file.listdir(path)) do
            print(path, e.name, e.size, e.type)
          end
        end
        try(function() frame.file.listdir('nope') end)
        try(function() frame.file.listdir('sub/b.txt') end)
    """)
    root = [l for l in lines if l.startswith("/\t")]
    assert root[:2] == ["/\t.\t0\t2", "/\t..\t0\t2"]
    assert "/\tsub\t0\t2" in root
    assert lines[len(root):len(root) + 3] == [
        "sub\t.\t0\t2", "sub\t..\t0\t2", "sub\tb.txt\t3\t1"]
    assert lines[-2:] == [WHERE + "9: directory not found",
                          WHERE + "10: directory not found"]


def test_mkdir_makes_each_level_and_fails_on_one_there(boot):
    # file.c makes 'a', then 'a/b': any of them already there is an error
    lines = run(boot, """
        try(frame.file.mkdir, 'a/b')
        try(frame.file.mkdir, 'a')
        try(frame.file.mkdir, 'a/c')
        print(#frame.file.listdir('a/b'))
    """)
    assert lines == ["ok", "error creating directory",
                     "error creating directory", "2"]


def test_remove_and_rename(boot):
    lines = run(boot, """
        frame.file.mkdir('d')
        frame.file.open('d/x.txt', 'w'):close()
        try(frame.file.remove, 'd')          -- not empty
        try(frame.file.rename, 'd/x.txt', 'd/y.txt')
        try(frame.file.remove, 'd/x.txt')    -- gone
        try(frame.file.rename, 'nope', 'other')
        try(frame.file.remove, 'd/y.txt')
        try(frame.file.remove, 'd')
    """)
    assert lines == ["error deleting file/directory", "ok",
                     "error deleting file/directory",
                     "error renaming file/directory", "ok", "ok"]


def test_space_counts_4_kb_blocks_and_runs_out(boot):
    lines = run(boot, """
        local s = frame.file.space()
        print(s.total, s.used + s.free == s.total, s.free)
        local f = frame.file.open('big.txt', 'w')
        f:write(string.rep('x', 5000))
        f:close()
        print(s.free - frame.file.space().free)
        f = frame.file.open('fill.txt', 'w')
        local ok, e
        repeat ok, e = pcall(f.write, f, string.rep('y', 1370)) until not ok
        f:close()
        print(e, frame.file.space().free)
    """)
    assert lines[0] == f"{43 * BLOCK}\ttrue\t{8 * BLOCK}"   # 172 KB, 32 free
    assert lines[1] == str(2 * BLOCK)            # 5000 bytes, two blocks
    assert lines[2] == "error writing to file\t0"


def test_require_runs_name_dot_lua_every_time(boot):
    lines = run(boot, """
        print(require('m'), require('m'), n)
        print(require('empty'))              -- nothing returned: the name
        try(require, 'nope')
        try(require, 'bad')
        try(require, 'broken')
        print(io, os, package, dofile, loadfile)
    """, {
        "m.lua": "n = (n or 0) + 1\nreturn 137 + n\n",
        "empty.lua": "x = 1\n",
        "bad.lua": "local a = 1\nerror('boom 137')\n",
        "broken.lua": "return (\n",
    })
    assert lines[0] == "138\t139\t2"
    assert lines[1] == "empty.lua"
    assert lines[2] == "cannot open file: nope.lua"
    assert lines[3] == ("exiting module 'bad': "
                        '[string "bad.lua"]:2: boom 137')
    assert lines[4].startswith("exiting module 'broken': "
                               '[string "broken.lua"]:')
    assert lines[5] == "nil\tnil\tnil\tnil\tnil"


def test_an_error_in_main_lua_ends_it(boot):
    emu = boot("local x = 1\nerror('boom 137')\n")
    assert not emu.is_running()
    assert str(emu.error).startswith(
        "exiting module 'main': [string \"main.lua\"]:3: boom 137")
    assert any("[frame-emulator] Lua error" in l for l in emu.lines)


# ---------------------------------------------------------------- bluetooth

def test_send_up_to_max_length(boot):
    # bluetooth.c: Android's MTU of 247 less ATT's 3 bytes is 244, and
    # max_length() less the data flag
    emu = boot("""
        print(frame.bluetooth.max_length(), frame.bluetooth.is_connected(),
              frame.bluetooth.address())
        try(frame.bluetooth.send, string.rep('a', 243))
        try(frame.bluetooth.send, string.rep('b', 244))
        try(frame.bluetooth.send, 137)
        try(frame.bluetooth.send, '')
        try(frame.bluetooth.send, {})
        try(frame.bluetooth.send)
    """)
    assert emu.lines == [
        "243\ttrue\tAA:BB:CC:DD:EE:FF", "ok",
        "string length is greater than max_length()", "ok", "ok",
        "bad argument #1 to 'send' (string expected, got table)",
        "bad argument #1 to 'send' (string expected, got no value)",
    ]
    # the empty one goes too: a packet of the data flag alone
    assert emu.sent == [b"a" * 243, b"137", b""]


def test_send_without_a_link_is_busy(boot):
    emu = boot("""
        frame.sleep(1)
        print(frame.bluetooth.is_connected())
        try(frame.bluetooth.send, 'x')
    """)
    emu.connected = False
    emu.advance(1)
    assert emu.lines == ["false", "bluetooth is busy"]
    assert emu.sent == []
    with pytest.raises(RuntimeError):
        emu.receive(b"x")


def test_receive_callback_gets_each_write(boot):
    emu = boot("""
        frame.bluetooth.receive_callback(function(s)
          print(#s, s:byte(1, -1))
          if s == 'off' then frame.bluetooth.receive_callback(nil) end
        end)
        while true do frame.sleep(1) end
    """)
    emu.receive(bytes([1, 37, 0, 255]))
    emu.receive(b"off")
    emu.receive(b"unheard")
    emu.advance(1)
    assert emu.lines == ["4\t1\t37\t0\t255", "3\t111\t102\t102"]


def test_send_checks_the_length_before_the_link(boot):
    # bluetooth.c: max_length first, then bluetooth_send_data's busy
    emu = boot("""
        frame.sleep(1)
        try(frame.bluetooth.send, string.rep('x', 244))
        try(frame.bluetooth.send, 'x')
    """)
    emu.connected = False
    emu.advance(1)
    assert emu.lines == ["string length is greater than max_length()",
                         "bluetooth is busy"]


def test_a_new_receive_callback_replaces_the_old_one(boot):
    emu = boot("""
        frame.bluetooth.receive_callback(function(s) print('one', s) end)
        frame.sleep(1)
        frame.bluetooth.receive_callback(function(s) print('two', s) end)
        while true do frame.sleep(1) end
    """)
    emu.receive(b"137")
    emu.advance(1)
    emu.receive(b"137")
    assert emu.lines == ["one\t137", "two\t137"]


def test_data_with_no_callback_is_dropped(boot):
    emu = boot("""
        frame.sleep(1)
        frame.bluetooth.receive_callback(function(s) print('heard', s) end)
        while true do frame.sleep(1) end
    """)
    emu.receive(b"early")
    emu.advance(1)
    emu.receive(b"137")
    assert emu.lines == ["heard\t137"]


def test_a_callback_runs_inside_a_sleep_that_goes_on(boot):
    # the callback is a hook in the running code: frame.sleep() keeps
    # waiting for its time after it
    emu = boot("""
        frame.imu.tap_callback(function() print('tap', frame.time.utc() // 1) end)
        frame.bluetooth.receive_callback(function(s) print('ble', s) end)
        frame.sleep(10)
        print('woke', frame.time.utc() // 1)
    """)
    emu.advance(1)
    emu.tap()
    emu.advance(2)
    emu.receive(b"137")
    assert emu.lines == ["tap\t1.0", "ble\t137"]
    emu.advance(6.9)
    assert len(emu.lines) == 2
    emu.advance(0.1)
    assert emu.lines[-1] == "woke\t10.0"


def test_receive_callback_takes_a_function_or_nil(boot):
    lines = run(boot, """
        try(function() frame.bluetooth.receive_callback() end)
        try(function() frame.bluetooth.receive_callback(137) end)
        try(function() frame.bluetooth.receive_callback(nil) end)
        try(function() frame.imu.tap_callback() end)
        try(function() frame.imu.tap_callback('tap') end)
    """)
    assert lines == [WHERE + "2: expected nil or function",
                     WHERE + "3: expected nil or function", "ok",
                     WHERE + "5: expected nil or function",
                     WHERE + "6: expected nil or function"]


def test_an_error_in_a_callback_is_raised_where_lua_runs(boot):
    # bluetooth.c and imu.c raise a callback's error again in the code
    # that was running, here the sleep
    emu = boot("""
        frame.bluetooth.receive_callback(function(s) error('bad ' .. s, 0) end)
        while true do
          local ok, e = pcall(frame.sleep, 137)
          print(ok, e)
        end
    """)
    emu.receive(b"137")
    assert emu.lines == ["false\tbad 137"]
    assert emu.is_running()


# ---------------------------------------------------------------- imu

def test_the_tap_callback_is_called_once_a_tap(boot):
    emu = boot("""
        frame.imu.tap_callback(function(...)
          print('tap', select('#', ...), ...)
        end)
        while true do frame.sleep(1) end
    """)
    emu.tap()                                    # stock firmware: nothing
    emu.tap(0x08)                                # glaz: the status byte
    emu.tap()
    assert emu.lines == ["tap\t0", "tap\t1\t8", "tap\t0"]


def test_tap_config_reads_back_what_is_set(boot):
    lines = run(boot, """
        local function show(t)
          print(t.threshold, t.thresholds.x, t.thresholds.y, t.thresholds.z,
                t.quiet, t.duration, t.axes, t.latch, t.rate)
        end
        show(frame.imu.tap_config())                 -- imu.c's defaults
        print(select('#', frame.imu.tap_config{threshold = 37}))
        show(frame.imu.tap_config())                 -- all three axes
        frame.imu.tap_config{thresholds = {y = 13}, quiet = 3, duration = 7,
                             axes = 0x3F, latch = false, rate = 64}
        show(frame.imu.tap_config())                 -- no threshold now
        -- the getter's table back, threshold edited: threshold wins
        local t = frame.imu.tap_config()
        t.threshold = 137
        frame.imu.tap_config(t)
        show(frame.imu.tap_config())
        frame.imu.tap_config{threshold = {x = 1, z = 2}}
        show(frame.imu.tap_config())
    """)
    assert lines == [
        "7\t7\t7\t7\t0\t0\t8\ttrue\t256",
        "0",
        "37\t37\t37\t37\t0\t0\t8\ttrue\t256",
        "nil\t37\t13\t37\t3\t7\t63\tfalse\t64",
        "137\t137\t137\t137\t3\t7\t63\tfalse\t64",
        "nil\t1\t137\t2\t3\t7\t63\tfalse\t64",
    ]


def test_tap_config_errors(boot):
    lines = run(boot, """
        try(frame.imu.tap_config, {threshold = 256})
        try(frame.imu.tap_config, {thresholds = 5})
        try(frame.imu.tap_config, {threshold = {w = 1}})
        try(frame.imu.tap_config, {threshold = {}})
        try(frame.imu.tap_config, {quiet = 16})
        try(frame.imu.tap_config, {duration = -1})
        try(frame.imu.tap_config, {axes = 0})
        try(frame.imu.tap_config, {rate = 3})
        try(frame.imu.tap_config, 137)
        try(frame.imu.tap_config, nil)
        -- what came before the error is set
        try(frame.imu.tap_config, {threshold = 9, quiet = 99})
        print(frame.imu.tap_config().threshold)
    """)
    assert lines == [
        "threshold must be between 0 and 255",
        "thresholds must be a table {x =, y =, z =}",
        "threshold table takes only x, y and z",
        "threshold table names no axis; use x, y or z",
        "quiet must be between 0 and 15",
        "duration must be between 0 and 15",
        "axes must be between 1 and 0x3F",
        "rate must be 1, 2, 4, 8, 16, 32, 64, 128 or 256",
        "bad argument #1 to 'tap_config' (table expected, got number)",
        "bad argument #1 to 'tap_config' (table expected, got nil)",
        "quiet must be between 0 and 15",
        "9",
    ]


def test_direction_is_what_the_test_sets(boot):
    emu = boot("""
        frame.sleep(1)
        local d = frame.imu.direction()
        print(d.roll, d.pitch, d.heading)
    """)
    emu.set_direction(roll=-13.7, pitch=1.37)
    emu.advance(1)
    assert emu.lines == ["-13.7\t1.37\t0.0"]


def test_raw_is_floats_of_a_still_level_chip(boot):
    # imu.c pushes lua_pushnumber: floats
    lines = run(boot, """
        local r = frame.imu.raw()
        print(r.compass.x, r.compass.y, r.compass.z,
              r.accelerometer.x, r.accelerometer.y, r.accelerometer.z,
              math.type(r.accelerometer.z))
    """)
    assert lines == ["0.0\t0.0\t0.0\t0.0\t0.0\t0.0\tfloat"]


def test_a_tap_callback_set_to_nil_hears_nothing(boot):
    emu = boot("""
        frame.imu.tap_callback(function() print('tap') end)
        frame.sleep(1)
        frame.imu.tap_callback(nil)
        while true do frame.sleep(1) end
    """)
    emu.tap()
    emu.advance(1)
    emu.tap()
    assert emu.lines == ["tap"]


# ---------------------------------------------------------------- sleep

def test_sleep_waits_for_virtual_time(boot):
    emu = boot("""
        local t = frame.time.utc()
        frame.sleep(137)
        print(string.format('%.2f', frame.time.utc() - t))
        frame.sleep('0.5')                   -- luaL_checknumber takes it
        print('half')
    """)
    emu.advance(136)
    assert emu.lines == []
    emu.advance(1)
    assert emu.lines == ["137.00"]
    emu.advance(0.5)
    assert emu.lines[-1] == "half"


def test_sleep_of_nothing_or_less_returns_at_once(boot):
    # system.c: waits until utc() reaches now + seconds
    lines = run(boot, """
        local t = frame.time.utc()
        frame.sleep(0)
        frame.sleep(-137)
        print(frame.time.utc() - t < 0.01)
    """)
    assert lines == ["true"]


def test_deep_sleep_holds_until_a_tap_and_ignores_the_rest(boot):
    # shutdown(true): the panel and Bluetooth off; no callback runs, the
    # host's break and data cannot reach it, only a tap wakes
    emu = boot("""
        frame.imu.tap_callback(function() print('tap callback') end)
        if not frame.imu.woke_by_tap() then frame.sleep() end
        print('awake')
        while true do frame.sleep(1) end
    """)
    assert emu.asleep and emu.texts() == []
    emu.break_signal()
    emu.advance(137)
    assert emu.asleep and emu.lines == [] and emu.is_running()
    emu.tap()
    assert not emu.asleep and emu.lines == ["awake"]


def test_update_ends_the_app(boot):
    # system.c: frame.update() shows 'Frame Update' and reboots into the
    # bootloader; nothing after it runs, no error from the app
    emu = boot("""
        print('before')
        frame.update()
        print('after')
    """)
    assert emu.lines == ["before"]
    assert not emu.is_running() and emu.error is None and emu.updating
    [t] = emu.texts()
    assert (t.text, t.x, t.y) == ("Frame Update", 200, 140)


def test_sleep_wants_a_number(boot):
    lines = run(boot, """
        try(function() frame.sleep('soon') end)
        try(function() frame.sleep(nil) end)
        try(function() frame.sleep({}) end)
    """)
    assert lines == [
        WHERE + "2: bad argument #1 to 'sleep' (number expected, got string)",
        WHERE + "3: bad argument #1 to 'sleep' (number expected, got nil)",
        WHERE + "4: bad argument #1 to 'sleep' (number expected, got table)",
    ]


def test_deep_sleep_until_a_tap_then_main_lua_again(boot):
    emu = boot("""
        print('boot', frame.imu.woke_by_tap())
        frame.display.text('137', 1, 1)
        frame.display.show()
        frame.bluetooth.receive_callback(function() print('heard') end)
        if not frame.imu.woke_by_tap() then
          frame.sleep()
          print('never')
        end
        while true do frame.sleep(1) end
    """)
    assert emu.asleep and emu.boots == 1
    assert emu.image().getbbox() is None          # the panel is off
    emu.receive(b"x")                             # Bluetooth is off
    emu.advance(137)
    assert emu.asleep and emu.lines == ["boot\tfalse"]
    emu.tap()
    assert emu.boots == 2
    assert emu.lines == ["boot\tfalse", "boot\ttrue"]
    assert emu.display.powered


SLEEPER = """
    print('boot', frame.imu.woke_by_tap())
    if not frame.imu.woke_by_tap() then frame.sleep() end
    while true do frame.sleep(1) end
"""


def test_waking_takes_a_second_tap_with_double_tap_wake(boot):
    # firmware glaz/main (imu.c, imu_wait_for_second_tap): after the first
    # tap, a second one 150 to 900 ms later wakes; hits in the first 150 ms
    # are the frame still ringing; none, and it is back to System OFF
    emu = boot(SLEEPER)
    emu.double_tap_wake = True
    emu.tap()
    emu.advance(2)
    assert emu.asleep and emu.boots == 1         # one knock: asleep again
    emu.tap()
    emu.advance(1.37)
    emu.tap()                                    # too late: a first tap again
    assert emu.asleep and emu.boots == 1
    emu.advance(0.1)
    emu.tap()                                    # ringing: does not count
    assert emu.asleep and emu.boots == 1
    emu.advance(0.2)
    emu.tap()                                    # 0.3 s after the first
    assert not emu.asleep and emu.boots == 2
    assert emu.lines == ["boot\tfalse", "boot\ttrue"]


def test_one_tap_wakes_by_default(boot):
    # stock firmware and glaz/stable, which the phone app ships: one tap
    emu = boot(SLEEPER)
    assert not emu.double_tap_wake
    emu.tap()
    assert emu.boots == 2 and emu.lines == ["boot\tfalse", "boot\ttrue"]


def test_woke_by_tap_stays_true_through_a_hosts_reset(boot):
    # imu.c's imu_woke_by_tap is set in hardware_setup() and nothing clears
    # it; run_lua() again after 0x04 still reads true
    emu = boot(SLEEPER)
    emu.tap()
    emu.reset_signal()
    assert emu.boots == 3
    assert emu.lines == ["boot\tfalse", "boot\ttrue", "boot\ttrue"]


def test_stay_awake_keeps_deep_sleep_from_happening(boot):
    emu = boot("""
        print(frame.stay_awake())
        frame.stay_awake(true)
        frame.sleep()                        -- returns at once
        print('awake', frame.stay_awake())
        try(frame.stay_awake, 1)
        try(frame.stay_awake, true, true)
        while true do frame.sleep(1) end
    """)
    assert emu.lines == ["false", "awake\ttrue",
                         "bad argument #1 to 'stay_awake' "
                         "(boolean expected, got number)",
                         "expected 0 or 1 arguments"]
    assert not emu.asleep
    emu.reset_signal()                           # run_lua sets it false
    assert emu.lines[-4] == "false"


def test_a_pcall_catches_the_break_once(boot):
    # luaport.c, lua_break_signal_handler: sethook_watchdog() puts the
    # watchdog's hook back, then luaL_error: the break is raised once, and
    # an app that catches it must pass it on itself (glaz_break)
    emu = boot("""
        for i = 1, 2 do
          local ok, e = pcall(frame.sleep, 137)
          print('caught', e)
        end
        print('done')
    """)
    emu.break_signal()
    assert emu.lines == ["caught\tbreak signal"]
    assert emu.is_running()
    emu.advance(137)                             # the next sleep runs out
    assert emu.lines[-2:] == ["caught\tnil", "done"]
    assert not emu.is_running() and emu.error is None


def test_an_uncaught_break_ends_main_lua(boot):
    emu = boot("""
        frame.imu.tap_callback(function() print('tap') end)
        while true do frame.sleep(1) end
    """)
    emu.break_signal()
    assert not emu.is_running()
    assert "break signal" in str(emu.error)
    assert emu.lines == ["[frame-emulator] Lua error: " + str(emu.error)]
    emu.tap()                                    # nothing runs any more
    assert len(emu.lines) == 1


def test_stop_ends_a_script_that_catches_everything(boot):
    # the emulator's own stop unwinds through every pcall, unlike a break
    emu = boot("""
        while true do pcall(frame.sleep, 1) end
    """)
    emu.stop()
    assert not emu.is_running() and emu.error is None


def test_a_reset_runs_main_lua_again_with_the_clock_kept(boot):
    # 0x04 makes a new Lua state; the firmware's statics stay: the clock,
    # its zone, the tap settings
    emu = boot("""
        print('boot', frame.imu.woke_by_tap(), math.floor(frame.time.utc()),
              frame.time.zone(), frame.imu.tap_config().threshold)
        if frame.time.utc() < 1000 then
          frame.time.utc(1793108220)
          frame.time.zone('+02:00')
          frame.imu.tap_config{threshold = 37}
        end
        frame.bluetooth.receive_callback(function() print('heard') end)
        while true do frame.sleep(1) end
    """)
    emu.reset_signal()
    assert emu.boots == 2
    assert emu.lines == ["boot\tfalse\t0\t+00:00\t7",
                         "boot\tfalse\t1793108220\t+02:00\t37"]


def test_a_wake_from_deep_sleep_starts_from_power_on(boot):
    # a wake is a boot: the RAM is gone, the clock counts from 0 again in
    # UTC and the accelerometer has its defaults
    emu = boot("""
        print('boot', math.floor(frame.time.utc()), frame.time.zone(),
              frame.imu.tap_config().threshold)
        frame.time.utc(1793108220)
        frame.time.zone('+02:00')
        frame.imu.tap_config{threshold = 37}
        if not frame.imu.woke_by_tap() then frame.sleep() end
        while true do frame.sleep(1) end
    """)
    emu.advance(137)
    emu.tap()
    assert emu.lines == ["boot\t0\t+00:00\t7", "boot\t0\t+00:00\t7"]


# ---------------------------------------------------------------- time

def test_utc_is_set_and_moves_with_virtual_time(boot):
    emu = boot("""
        print(frame.time.utc())
        frame.time.utc(1793108220)
        frame.sleep(1.5)
        print(frame.time.utc())
        try(frame.time.utc, 1.5)
        try(frame.time.utc, nil)
    """)
    assert emu.lines == ["0.0"]
    emu.advance(1.5)
    assert emu.lines[1:] == [
        "1793108221.5",
        "bad argument #1 to 'utc' (number has no integer representation)",
        "bad argument #1 to 'utc' (number expected, got nil)",
    ]


def test_zone_and_date(boot):
    # NOW in glasses.py: 2026-10-27 13:37 UTC, a Tuesday, day 300 of 2026
    lines = run(boot, """
        frame.time.utc(1793108220)
        local function show(d)
          print(d.year, d.month, d.day, d.hour, d.minute, d.second,
                d.weekday, d['day of year'], d['is daylight saving'])
        end
        show(frame.time.date())
        frame.time.zone('+02:00')
        print(frame.time.zone())
        show(frame.time.date())
        show(frame.time.date(1793108220))    -- a stamp gets the zone too
        frame.time.zone('-05:30')            -- minutes always go forward
        print(frame.time.zone(), frame.time.date().hour,
              frame.time.date().minute)
        frame.time.zone(' 5:45 and more')    -- as sscanf reads it
        print(frame.time.zone())
    """)
    assert lines == [
        "2026\t10\t27\t13\t37\t0\t2\t299\tfalse",
        "+02:00",
        "2026\t10\t27\t15\t37\t0\t2\t299\tfalse",
        "2026\t10\t27\t15\t37\t0\t2\t299\tfalse",
        "-05:30\t9\t7",                          # 13:37 - 5:00 + 0:30
        "+05:45",
    ]
    assert datetime.datetime(2026, 10, 27).timetuple().tm_yday == 300


def test_date_fields_count_as_struct_tm_does(boot):
    # gmtime_r(): weekday 0 is Sunday, 'day of year' counts from 0
    lines = run(boot, """
        local function show(d)
          print(d.year, d.month, d.day, d.hour, d.weekday, d['day of year'])
        end
        show(frame.time.date(0))
        show(frame.time.date(1793108220 + 5 * 86400))
        show(frame.time.date('1793108220'))   -- a numeric string will do
        frame.time.zone('-00:30')             -- sscanf: hour 0, '+'
        print(frame.time.zone(), frame.time.date(0).minute)
        try(frame.time.date, 1.5)
        try(frame.time.date, nil)
    """)
    assert lines == [
        "1970\t1\t1\t0\t4\t0",                   # a Thursday
        "2026\t11\t1\t13\t0\t304",               # a Sunday
        "2026\t10\t27\t13\t2\t299",
        "+00:30\t30",
        "bad argument #1 to 'date' (number has no integer representation)",
        "bad argument #1 to 'date' (number expected, got nil)",
    ]


def test_zone_errors(boot):
    lines = run(boot, """
        try(frame.time.zone, '+15:00')
        try(frame.time.zone, '-13:00')
        try(frame.time.zone, '+02:15')
        try(frame.time.zone, '+14:30')
        try(frame.time.zone, '-12:45')
        try(frame.time.zone, 'UTC')
        try(frame.time.zone, {})
        try(frame.time.zone, '+14:00')
        print(frame.time.zone())
    """)
    assert lines == [
        "hour value must be between -12 and +14",
        "hour value must be between -12 and +14",
        "minute value must be either 00, 30, or 45",
        "when hour is -12 or 14, minutes must be 0",
        "when hour is -12 or 14, minutes must be 0",
        "must be '+hh:mm' or '-hh:mm'",
        "bad argument #1 to 'zone' (string expected, got table)",
        "ok",
        "+14:00",
    ]


def test_battery_and_fpga(boot):
    emu = boot("""
        print(frame.battery_level(), math.type(frame.battery_level()))
        frame.sleep(1)
        print(frame.battery_level())
        print(#frame.fpga_read(0x18, 1), frame.fpga_read(0x18, 1):byte())
        try(frame.fpga_read, 0x100, 1)
    """)
    emu.battery = 137                    # clamped, as roundf()'s result is
    emu.advance(1)
    assert emu.lines == [
        "85.0\tfloat", "100.0", "1\t0",
        "address must be between 0x00 and 0xFF",
    ]


def test_fpga_and_system_argument_errors(boot):
    emu = boot("""
        print(#frame.fpga_read(0x18, 137))
        try(frame.fpga_read, -1, 1)
        try(frame.fpga_read, 0x18)
        try(frame.fpga_write, 0x18, '\\0')
        try(frame.fpga_write, 0x100, '')
        try(frame.fpga_write, 0x18)
        frame.sleep(1)
        print(frame.battery_level())
    """)
    emu.battery = -13.7
    emu.advance(1)
    assert emu.lines == [
        "137",
        "address must be between 0x00 and 0xFF",
        "bad argument #2 to 'fpga_read' (number expected, got nil)",
        "ok",
        "address must be between 0x00 and 0xFF",
        "bad argument #2 to 'fpga_write' (string expected, got nil)",
        "0.0",
    ]


def test_versions_and_the_led(boot):
    emu = boot("""
        print(frame.HARDWARE_VERSION, type(frame.FIRMWARE_VERSION),
              type(frame.GIT_TAG))
        frame.led.set_color(100, 37, 0)
        try(frame.led.set_color, 101, 0, 0)
        try(frame.led.set_color, 0, -1, 0)
        try(frame.led.set_color, 0, 0)
        try(frame.compression.process_function, 137)
        try(frame.compression.process_function, nil)
    """)
    assert emu.lines == [
        "Frame\tstring\tstring", "led color must be between 0 and 100",
        "led color must be between 0 and 100",
        "bad argument #3 to 'set_color' (number expected, got nil)",
        "expected nil or function", "ok",
    ]
    assert emu.led == (100, 37, 0)


# ---------------------------------------------------------------- camera

def test_the_camera_takes_a_jpeg_of_the_picture(boot):
    emu = boot("""
        frame.camera.capture{resolution = 200, quality = 'LOW'}
        print(frame.camera.image_ready())
        local parts = {}
        while true do
          local s = frame.camera.read(137)
          if s == nil then break end
          parts[#parts + 1] = s
        end
        local jpeg = table.concat(parts)
        print(#parts > 1, #parts[1])
        local f = frame.file.open('photo.jpg', 'w')
        f:write(jpeg)
        f:close()
    """)
    assert emu.lines[0] == "true"
    assert emu.lines[1] == "true\t137"
    jpeg = (emu.sandbox / "photo.jpg").read_bytes()
    assert jpeg[:2] == b"\xff\xd8" and jpeg[-2:] == b"\xff\xd9"
    img = Image.open(io.BytesIO(jpeg))
    assert img.size == (200, 200)
    r, g, b = img.getpixel((5, 5))                # the default picture's blue
    assert b > r and b > g


def test_the_camera_takes_what_the_test_shows_it(boot):
    emu = boot("""
        frame.sleep(1)
        frame.camera.capture{}
        local s, parts = '', {}
        repeat s = frame.camera.read(1000) parts[#parts + 1] = s until not s
        local f = frame.file.open('photo.jpg', 'w')
        f:write(table.concat(parts))
        f:close()
    """)
    emu.picture = Image.new("RGB", (720, 720), (200, 30, 30))
    emu.advance(1)
    img = Image.open(emu.sandbox / "photo.jpg")
    assert img.size == (512, 512)                 # camera.c's default
    r, g, b = img.getpixel((256, 256))
    assert r > 150 and g < 80 and b < 80


def test_camera_errors(boot):
    lines = run(boot, """
        try(function() frame.camera.capture() end)
        try(frame.camera.capture, {resolution = 101})
        try(frame.camera.capture, {resolution = 722})
        try(frame.camera.capture, {resolution = 200.5})
        try(frame.camera.capture, {quality = 'BEST'})
        try(frame.camera.capture, {pan = 141})
        try(frame.camera.capture, {pan = -140})
        try(frame.camera.read, 0)
        frame.camera.power_save(true)
        try(frame.camera.capture, {})
        try(frame.camera.image_ready)
        try(frame.camera.power_save, 1)
        frame.camera.power_save(false)
        try(frame.camera.capture, {})
    """)
    assert lines == [
        WHERE + "2: attempt to index a nil value",
        "resolution value must be a multiple of 2 between 100 and 720",
        "resolution value must be a multiple of 2 between 100 and 720",
        "bad argument #-1 to 'capture' (number has no integer representation)",
        "quality must be either VERY_HIGH, HIGH, MEDIUM, LOW or VERY_LOW",
        "pan value must be value between -140 and 140",
        "ok",
        "bytes must be greater than 0",
        "camera is asleep",
        "camera is asleep",
        "value must be true or false",
        "ok",
    ]


def test_a_read_past_the_end_is_nil_and_the_image_gone(boot):
    # camera.c: read() gives nil once the image and its footer are out;
    # before any capture there is nothing to read either
    lines = run(boot, """
        print(frame.camera.image_ready(), frame.camera.read(137))
        frame.camera.capture{resolution = 100, quality = 'VERY_LOW'}
        local n = 0
        while frame.camera.read_raw(4096) do n = n + 1 end
        print(n > 0, frame.camera.read(137), frame.camera.image_ready())
    """)
    assert lines == ["false\tnil", "true\tnil\tfalse"]


def test_camera_auto_and_manual_exposure(boot):
    # camera.c: auto() gives its results while awake and nothing at all
    # asleep; the manual setters check their ranges, asleep first
    lines = run(boot, """
        local r = frame.camera.auto{metering = 'SPOT', exposure = 0.5}
        print(r.shutter, r.analog_gain, r.brightness.matrix.r,
              r.brightness.spot.average, r.brightness.scene)
        frame.camera.set_shutter(4096)
        frame.camera.set_gain(137)
        frame.camera.set_white_balance(1023, 0, 137)
        print(frame.camera.read_register(0x0100))
        frame.camera.write_register(0x0100, 1)
        try(frame.camera.auto, {metering = 'BRIGHT'})
        try(frame.camera.auto, {exposure = 1.5})
        try(frame.camera.auto, {shutter_limit = 3})
        try(frame.camera.auto, {analog_gain_limit = 249})
        try(frame.camera.auto, {rgb_gain_limit = 'lots'})
        try(frame.camera.set_shutter, 3)
        try(frame.camera.set_gain, 249)
        try(frame.camera.set_white_balance, 1024, 0, 0)
        try(frame.camera.write_register, 0x10000, 0)
        try(frame.camera.write_register, 0, 256)
        try(frame.camera.read_register, -1)
        frame.camera.power_save(true)
        print(select('#', frame.camera.auto()))
        try(frame.camera.set_shutter, 3)
        try(frame.camera.read_register, 0)
    """)
    assert lines == [
        "4096\t1\t0.5\t0.5\t0.5",
        "0",
        "metering must be SPOT, CENTER_WEIGHTED or AVERAGE",
        "exposure must be between 0 and 1",
        "shutter_limit must be between 4 and 16383",
        "analog_gain_limit must be between 1 and 248",
        "bad argument #-1 to 'auto' (number expected, got string)",
        "shutter must be between 4 and 16383",
        "gain must be between 1 and 248",
        "gains must be between 0 and 1023",
        "address must be a 16 bit unsigned number",
        "value must be an 8 bit unsigned number",
        "address must be a 16 bit unsigned number",
        "0",
        "camera is asleep",
        "camera is asleep",
    ]


def test_capture_takes_a_numeric_string_for_its_resolution(boot):
    # luaL_checkinteger converts '200', as lua_tointegerx does
    emu = boot("""
        frame.camera.capture{resolution = '200', pan = '-140'}
        local s, parts = '', {}
        repeat s = frame.camera.read('4096') parts[#parts + 1] = s until not s
        local f = frame.file.open('photo.jpg', 'w')
        f:write(table.concat(parts))
        f:close()
    """)
    assert emu.lines == [] and emu.error is None
    assert Image.open(emu.sandbox / "photo.jpg").size == (200, 200)


# ---------------------------------------------------------------- microphone

def test_the_microphone_gives_the_tests_bytes(boot):
    emu = boot("""
        print(frame.microphone.read(2))      -- not started: nil
        frame.microphone.start{sample_rate = 16000, bit_depth = 16}
        print(#frame.microphone.read(2))     -- started, nothing yet: ''
        frame.sleep(1)
        print(frame.microphone.read(4):byte(1, -1))
        frame.microphone.stop()
        print(frame.microphone.read(4):byte(1, -1))   -- what was left
        print(frame.microphone.read(4))
    """)
    assert emu.lines == ["nil", "0"]
    emu.mic_data.extend(bytes([1, 3, 7, 13, 37, 137]))
    emu.advance(1)
    assert emu.lines[2:] == ["1\t3\t7\t13", "37\t137", "nil"]


def test_starting_the_microphone_empties_its_fifo(boot):
    # microphone.c: start() sets fifo.head = fifo.tail = 0; stop() is
    # fine when it is not running
    emu = boot("""
        frame.microphone.stop()
        frame.sleep(1)
        frame.microphone.start()
        print(#frame.microphone.read(2))
        frame.sleep(1)
        print(frame.microphone.read('4'):byte(1, -1))
    """)
    emu.mic_data.extend(b"old")
    emu.advance(1)
    assert emu.lines == ["0"]
    emu.mic_data.extend(bytes([1, 37]))
    emu.advance(1)
    assert emu.lines == ["0", "1\t37"]


def test_microphone_errors(boot):
    lines = run(boot, """
        try(frame.microphone.start, {sample_rate = 44100})
        try(frame.microphone.start, {bit_depth = 12})
        try(frame.microphone.start, {sample_rate = 8000.5})
        try(frame.microphone.read, 3)
        frame.microphone.start()
        try(frame.microphone.start)
        frame.microphone.stop()
        try(frame.microphone.start, 'defaults')
    """)
    assert lines == [
        "sample rate must be 8000 or 16000",
        "bit depth must be 8 or 16",
        "bad argument #-1 to 'start' (number has no integer representation)",
        "bytes must be a multiple of 2",
        "already started",
        "ok",
    ]


# ---------------------------------------------------------------- the clock

def test_a_script_that_never_sleeps_times_out_and_still_stops(
        boot, monkeypatch):
    monkeypatch.setattr(vclock, "REAL_TIMEOUT", 0.3)
    emu = boot("frame.sleep(1)\nwhile true do local t = frame.time.utc() end")
    with pytest.raises(TimeoutError, match="stuck outside"):
        emu.advance(1)
    emu.stop()                           # utc() ends the busy loop
    assert not emu.is_running()


def test_virtual_time_moves_only_when_advanced():
    clock = VirtualClock(start=137.0)
    alive = {"v": True}
    clock.watch(lambda: alive["v"])
    seen, results = [], []

    def lua():
        results.append(clock.wait(10, lambda e: seen.append(e) or e == "end"))
        results.append(clock.wait(None, lambda e: seen.append(e) or e == "end"))
        alive["v"] = False

    t = threading.Thread(target=lua, daemon=True)
    t.start()
    clock.advance(9)
    assert clock.now == 146.0 and results == []
    clock.put("tap")                    # handed over at once, waiting on
    clock.settle()
    assert seen == ["tap"] and clock.now == 146.0
    clock.advance(1)
    assert results == [None] and clock.now == 147.0  # the 10 s ran out
    clock.advance(1000)
    assert len(results) == 1            # no time ends a wait for an event
    clock.put("end")
    t.join(5)
    assert results == [None, "end"] and clock.now == 1147.0


def test_the_screen_size_is_frames(boot):
    emu = boot("frame.display.show()")
    assert emu.image().size == (WIDTH, HEIGHT) == (640, 400)


def test_main_lua_starts_after_the_firmwares_boot(tmp_path):
    (tmp_path / "main.lua").write_text("print(frame.time.utc())")
    lines = []
    emu = FrameEmulator(tmp_path, lines.append)
    emu.start()
    emu.settle()
    emu.stop()
    assert lines == [str(float(BOOT_SECONDS))]

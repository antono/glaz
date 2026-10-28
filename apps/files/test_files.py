"""Files (apps/files/files.lua), Apps > Files on Frame: the files on the
glasses in a window of three around the cursor, a tilt to move it, a tap
to preview the file under it (name, size, first two lines), a tap or a
double tap back to the list, and a double tap from the list out of the
app. Halo has no Files: files.lua uses Frame's file API as it is.
"""
import pytest

from frame_emulator.display import LuaError
from glasses import APP_BACKGROUND, APP_START, APP_STOP, has_module

pytestmark = pytest.mark.module("files")

# Upper case sorts before the uploaded files' lower case names, 'zzz' after
FIRST = "A137.txt"
LAST = "zzz137.txt"


def put(g, name, data):
    """A file on the glasses, as if the phone had uploaded it."""
    path = g.sandbox / name
    if isinstance(data, str):
        data = data.encode("utf-8")
    path.write_bytes(data)
    return path


def body(g):
    """The module's lines on the screen, under the top bar."""
    lines = g.screen_text().split("\n")
    assert lines[0] == ".. > Files", lines
    return lines[3:]                     # under breadcrumb, clock, battery


def open_files(g, **files):
    for name, data in files.items():
        put(g, name, data)
    g.clear_sent()
    g.open_app("files")
    return body(g)


def leave(g):
    """Out of the app: a double tap per level, until the menu shows."""
    for _ in range(3):
        if "Files" not in g.screen_text():
            return
        g.tap(2)


@pytest.fixture
def listed(glasses):
    """Files open on three files of our own at the top of the list."""
    put(glasses, FIRST, "first line 137\nsecond line\nthird line\n")
    (glasses.sandbox / "Adir").mkdir()
    put(glasses, "B137.bin", b"x" * 1370)
    open_files(glasses)
    return glasses


# ---------------------------------------------------------------- devices

def test_files_goes_to_frame_only():
    assert has_module("frame", "files")
    assert not has_module("halo", "files")


def test_halo_ignores_the_phone_opening_files(halo):
    halo.clear_sent()
    halo.open_app("files")
    halo.advance(1)
    assert not halo.sent(APP_START)
    assert "Files" not in halo.screen_text()
    halo.assert_ok()


# ---------------------------------------------------------------- the list

def test_opens_on_the_list_sorted_by_name_with_sizes(listed):
    assert listed.sent(APP_START)
    assert body(listed) == ["> A137.txt  38 B", "  Adir/  ", "  B137.bin  1.3K"]
    listed.screenshot("files")
    listed.assert_ok()


def test_the_list_holds_the_uploaded_files_too(glasses):
    names = sorted(p.name for p in glasses.sandbox.iterdir())
    assert "files.lua" in names and "glaz_app.lua" in names
    open_files(glasses)
    assert body(glasses)[0].startswith(f"> {names[0]}  ")
    glasses.tilt(-1)                     # wraps round to the last
    assert body(glasses)[2].startswith(f"> {names[-1]}  ")
    glasses.assert_ok()


def test_sizes_in_bytes_then_kilobytes(glasses):
    rows = open_files(glasses, **{"A0": b"", "A1": b"x" * 1023,
                                  "A2": b"x" * 1024})
    assert rows == ["> A0  0 B", "  A1  1023 B", "  A2  1.0K"]


def test_a_tilt_moves_the_cursor_and_the_window_follows(listed):
    listed.tilt(1)
    assert body(listed) == ["  A137.txt  38 B", "> Adir/  ", "  B137.bin  1.3K"]
    listed.tilt(1)                       # the cursor stays in the middle
    rows = body(listed)
    assert rows[:2] == ["  Adir/  ", "> B137.bin  1.3K"]
    assert rows[2].startswith("  ") and not rows[2].startswith("  A")
    listed.tilt(-1)
    listed.tilt(-1)
    assert body(listed)[0] == "> A137.txt  38 B"
    listed.assert_ok()


def test_tilting_back_from_the_first_wraps_to_the_last(glasses):
    open_files(glasses, **{FIRST: "a", LAST: "z"})
    glasses.tilt(-1)
    rows = body(glasses)
    assert len(rows) == 3
    assert rows[2] == f"> {LAST}  1 B"         # at the end: the bottom row
    glasses.tilt(1)
    assert body(glasses)[0] == f"> {FIRST}  1 B"
    glasses.assert_ok()


def test_the_phones_remote_moves_the_cursor(listed):
    listed.remote(2, 1)
    assert body(listed)[1] == "> Adir/  "
    listed.remote(2, 255)
    assert body(listed)[0] == "> A137.txt  38 B"


def test_long_names_are_clipped(glasses):
    name = "A" + "long" * 10 + ".txt"
    rows = open_files(glasses, **{name: "137"})
    assert rows[0] == "> " + (name + "  3 B")[:24] + ".."


def test_the_list_is_read_once_when_the_app_opens(listed):
    put(listed, "A0new.txt", "137")
    listed.tilt(1)
    listed.tilt(-1)
    assert "A0new" not in listed.screen_text()
    leave(listed)
    listed.open_app("files")
    assert body(listed)[0] == "> A0new.txt  3 B"
    listed.assert_ok()


def test_reopened_it_starts_at_the_top_again(listed):
    listed.tilt(1)
    leave(listed)
    listed.open_app("files")
    assert body(listed)[0] == "> A137.txt  38 B"


# ---------------------------------------------------------------- preview

def test_a_tap_previews_name_size_and_first_two_lines(listed):
    listed.tap(1)
    assert body(listed) == ["A137.txt  38 B", "first line 137", "second line"]
    assert not listed.emu.files.handles          # the file closed again
    listed.screenshot("files-preview")
    listed.assert_ok()


def test_a_tap_in_the_preview_goes_back_to_the_list(listed):
    listed.tilt(1)
    listed.tilt(1)
    listed.tap(1)
    assert body(listed)[0] == "B137.bin  1.3K"
    listed.tap(1)
    assert body(listed)[1] == "> B137.bin  1.3K"  # the cursor where it was
    listed.assert_ok()


def test_a_double_tap_in_the_preview_goes_back_to_the_list(listed):
    listed.tap(1)
    listed.clear_sent()
    listed.tap(2)
    assert body(listed)[0] == "> A137.txt  38 B"
    assert not listed.sent(APP_STOP)
    listed.assert_ok()


def test_a_tilt_does_nothing_in_the_preview(listed):
    listed.tap(1)
    preview = body(listed)
    listed.tilt(1)
    listed.remote(2, 1)
    assert body(listed) == preview
    listed.tap(1)
    assert body(listed)[0] == "> A137.txt  38 B"


def test_the_phones_remote_taps_preview_too(listed):
    listed.remote(1, 1)
    assert body(listed)[0] == "A137.txt  38 B"
    listed.remote(1, 1)
    assert body(listed)[0] == "> A137.txt  38 B"


def test_a_directory_previews_as_a_directory(listed):
    listed.tilt(1)
    listed.tap(1)
    assert body(listed) == ["Adir/", "(directory)"]
    listed.assert_ok()


def test_long_lines_are_clipped_in_the_preview(listed):
    listed.tilt(1)
    listed.tilt(1)
    listed.tap(1)
    rows = body(listed)
    assert rows[1] == "x" * 24 + ".."
    assert rows[2] == "x" * 24 + ".."            # 512-byte reads, clipped
    listed.assert_ok()


def test_utf8_lines_are_clipped_by_characters(glasses):
    open_files(glasses, **{FIRST: "Привет мир " * 5 + "\n137\n"})
    glasses.tap(1)
    rows = body(glasses)
    assert rows[1] == ("Привет мир " * 5)[:24] + ".."
    assert rows[2] == "137"
    glasses.assert_ok()


def test_an_empty_file_previews_its_name_alone(glasses):
    open_files(glasses, **{FIRST: b""})
    glasses.tap(1)
    assert body(glasses) == [f"{FIRST}  0 B"]
    glasses.assert_ok()


def test_empty_lines_count_as_the_first_two(glasses):
    open_files(glasses, **{FIRST: "\n\n137\n"})
    glasses.tap(1)
    assert body(glasses) == [f"{FIRST}  6 B"]
    glasses.assert_ok()


def test_a_binary_file_previews_without_errors(glasses):
    open_files(glasses, **{FIRST: bytes(range(256))})
    glasses.tap(1)
    rows = body(glasses)
    assert rows[0] == f"{FIRST}  256 B"
    assert len(rows) > 1
    assert not glasses.emu.files.handles
    glasses.assert_ok()


def test_a_file_gone_since_the_list_cannot_be_opened(listed):
    (listed.sandbox / FIRST).unlink()
    listed.tap(1)
    assert body(listed) == ["A137.txt  38 B", "cannot open"]
    listed.tap(1)
    assert body(listed)[0] == "> A137.txt  38 B"
    listed.assert_ok()


# ---------------------------------------------------------------- no files

def test_without_a_listing_it_says_no_files(glasses):
    def fails(path):
        raise LuaError("directory not found")
    glasses.emu.files.listdir = fails
    assert open_files(glasses) == ["no files"]
    glasses.tap(1)
    glasses.tilt(1)
    assert body(glasses) == ["no files"]
    glasses.screenshot("files-empty")
    glasses.assert_ok()


def test_dot_entries_alone_are_no_files(glasses):
    glasses.emu.files.listdir = lambda path: [(".", 0, 2), ("..", 0, 2)]
    assert open_files(glasses) == ["no files"]
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


# ---------------------------------------------------------------- leaving

def test_a_double_tap_from_the_list_leaves_and_stops_it(listed):
    listed.clear_sent()
    listed.tap(2)
    assert listed.sent(APP_STOP)
    assert not listed.sent(APP_BACKGROUND)       # it never runs unseen
    assert "Files" not in listed.screen_text()
    assert not listed.emu.files.handles
    listed.assert_ok()


def test_left_alone_it_closes_after_a_minute(listed):
    listed.clear_sent()
    listed.advance(55)
    assert not listed.sent(APP_STOP)
    assert "A137.txt" in listed.screen_text()
    listed.advance(10)
    assert listed.sent(APP_STOP)
    assert "A137.txt" not in listed.screen_text()


def test_a_tilt_keeps_it_open(listed):
    listed.clear_sent()
    listed.advance(50)
    listed.tilt(1)
    listed.advance(50)
    assert not listed.sent(APP_STOP)
    assert body(listed)[1] == "> Adir/  "
    listed.assert_ok()


def test_left_in_the_preview_it_closes_too(listed):
    listed.tap(1)
    listed.clear_sent()
    listed.advance(65)
    assert listed.sent(APP_STOP)
    listed.open_app("files")
    assert body(listed)[0] == "> A137.txt  38 B"  # the list, not the preview
    listed.assert_ok()


# ---------------------------------------------------------------- the window

def only(g, *entries):
    """The glasses' listing, as littlefs gives it: '.' and '..' first,
    then (name, size, type) each, type 2 a directory."""
    g.emu.files.listdir = lambda path: [(".", 0, 2), ("..", 0, 2), *entries]


def names(g):
    return [row[2:].split()[0] for row in body(g)]


def test_kilobytes_keep_one_decimal(glasses):
    only(glasses, ("A", 137 * 1024, 1), ("B", 1536, 1),
         ("C", 1370 * 1024, 1))
    assert open_files(glasses) == ["> A  137.0K", "  B  1.5K", "  C  1370.0K"]
    glasses.assert_ok()


def test_one_file_alone_wraps_onto_itself(glasses):
    only(glasses, ("A137.txt", 137, 1))
    assert open_files(glasses) == ["> A137.txt  137 B"]
    glasses.tilt(1)
    assert body(glasses) == ["> A137.txt  137 B"]
    glasses.tilt(-1)
    assert body(glasses) == ["> A137.txt  137 B"]
    glasses.assert_ok()


def test_two_files_fill_two_rows(glasses):
    only(glasses, ("B", 2, 1), ("A", 1, 1))       # sorted on the glasses
    assert open_files(glasses) == ["> A  1 B", "  B  2 B"]
    glasses.tilt(1)
    assert body(glasses) == ["  A  1 B", "> B  2 B"]
    glasses.tilt(1)                               # wraps to the first
    assert body(glasses) == ["> A  1 B", "  B  2 B"]
    glasses.assert_ok()


def test_the_window_scrolls_one_row_at_a_time(glasses):
    only(glasses, *[(f"F{i}", 137, 1) for i in range(1, 6)])
    open_files(glasses)
    seen = []
    for _ in range(5):
        seen.append((names(glasses), body(glasses).index(
            next(r for r in body(glasses) if r.startswith(">")))))
        glasses.tilt(1)
    assert seen == [(["F1", "F2", "F3"], 0), (["F1", "F2", "F3"], 1),
                    (["F2", "F3", "F4"], 1), (["F3", "F4", "F5"], 1),
                    (["F3", "F4", "F5"], 2)]
    assert body(glasses)[0] == "> F1  137 B"     # wrapped round
    glasses.assert_ok()


def test_the_phones_up_and_down_move_the_cursor_too(listed):
    listed.remote(3, 1)                           # Down: next, as a tilt
    assert body(listed)[1] == "> Adir/  "
    listed.remote(3, 255)                         # Up: previous
    assert body(listed)[0] == "> A137.txt  38 B"
    listed.remote(3, 255)                         # wraps to the last
    assert body(listed)[2].startswith("> ")
    listed.assert_ok()


# ---------------------------------------------------------------- more previews

def test_a_file_of_one_line_previews_that_line(glasses):
    open_files(glasses, **{FIRST: "137"})          # no line break at the end
    glasses.tap(1)
    assert body(glasses) == [f"{FIRST}  3 B", "137"]
    assert not glasses.emu.files.handles
    glasses.assert_ok()


def test_the_last_file_previews_after_wrapping(glasses):
    open_files(glasses, **{FIRST: "a", LAST: "z 137\n"})
    glasses.tilt(-1)
    glasses.tap(1)
    assert body(glasses) == [f"{LAST}  6 B", "z 137"]
    glasses.tap(1)
    assert body(glasses)[2] == f"> {LAST}  6 B"
    glasses.assert_ok()


def test_a_long_directory_name_is_clipped(glasses):
    name = "A" + "dir" * 10
    (glasses.sandbox / name).mkdir()
    rows = open_files(glasses)
    assert rows[0] == "> " + (name + "/  ")[:24] + ".."
    glasses.tap(1)
    assert body(glasses) == [(name + "/")[:24] + "..", "(directory)"]
    glasses.assert_ok()


def test_a_long_name_in_the_preview_hides_the_size(glasses):
    name = "A" + "long" * 10 + ".txt"
    open_files(glasses, **{name: "137\n"})
    glasses.tap(1)
    assert body(glasses) == [name[:24] + "..", "137"]
    glasses.assert_ok()


def test_lines_that_are_not_utf8_are_clipped_by_bytes(glasses):
    open_files(glasses, **{FIRST: b"\xff" * 30 + b"\n137\n"})
    glasses.tap(1)
    rows = body(glasses)
    assert rows[0] == f"{FIRST}  35 B"
    assert rows[1].endswith("..") and len(rows[1]) < 30
    assert rows[2] == "137"
    assert not glasses.emu.files.handles
    glasses.assert_ok()


# ---------------------------------------------------------------- the phone

def test_the_phone_calling_files_changes_nothing(listed):
    listed.tilt(1)
    before = body(listed)
    listed.clear_sent()
    listed.call("files", "137")                   # Files has no remote()
    listed.advance(1)
    assert body(listed) == before
    assert not listed.sent(APP_STOP)
    listed.assert_ok()


def test_the_phone_cannot_start_files_unseen(frame):
    frame.clear_sent()
    frame.call("files", "137")                    # it sleeps: no background
    frame.advance(1)
    assert not frame.sent(APP_BACKGROUND)
    assert not frame.sent(APP_START)
    assert "Files" not in frame.screen_text()
    frame.assert_ok()


def test_opening_files_again_keeps_the_cursor(listed):
    listed.tilt(1)
    listed.clear_sent()
    listed.open_app("files", "137")               # already on screen
    assert body(listed)[1] == "> Adir/  "
    assert not listed.sent(APP_STOP)
    listed.assert_ok()


def test_an_argument_from_the_phone_still_opens_the_list(glasses):
    put(glasses, FIRST, "137")
    glasses.open_app("files", "137")
    assert body(glasses)[0] == f"> {FIRST}  3 B"
    glasses.assert_ok()


def test_another_app_from_the_phone_stops_files(listed):
    listed.tilt(1)
    listed.tap(1)
    listed.clear_sent()
    listed.open_app("stopwatch")
    assert listed.sent(APP_STOP)
    assert not listed.sent(APP_BACKGROUND)
    assert "Files" not in listed.screen_text()
    listed.open_app("files")
    assert body(listed)[0] == "> A137.txt  38 B"  # started afresh
    listed.assert_ok()


def test_a_notification_over_the_list_leaves_it_as_it_was(listed):
    listed.tilt(1)
    listed.notify("Chat", "Ann", "137 new files")
    assert "Ann" in listed.screen_text()
    listed.advance(20)
    assert "Ann" not in listed.screen_text()
    assert body(listed)[1] == "> Adir/  "
    listed.assert_ok()

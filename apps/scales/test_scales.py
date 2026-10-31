"""Scales (apps/scales/scales.lua, docs/SCALES.md): guitar scales on the
fretboard, Frame only. It opens on the instruments; a tap takes one, a
tilt moves the box along the neck, a tap or the remote's Up and Down ask
the phone for the next scale (SCALE_GET), the phone answers through
MODULE_CALL, and a double tap goes back to the instruments, then the menu.
The boards are bitmaps: the dots are checked by their colour on the panel.
"""
import pytest

from frame_emulator.display import NAMES
from glasses import APP_BACKGROUND, APP_START, APP_STOP, MENU_OPEN

pytestmark = pytest.mark.module("scales")

SCALE_GET = 0x02

DORIAN = "g2 14 dorian|dorian|023579a|9|m pent|0357a"
MAJOR = "g10 14 major|major|024579b|b|M pent|02479"

# The boards as scales.lua lays them out: x, column width, top string's y,
# from the top string to the bottom one
TOP = dict(x=192, col=64, y=130, h=70)        # two at once: the pentatonic
BOTTOM = dict(x=192, col=64, y=250, h=70)     # and the mode under it
SINGLE = dict(x=72, col=88, y=140, h=180)


def colour(g, board, string, column, strings=6):
    """The colour in the middle of a dot's place: string 1 the top one,
    column 0 the box's lowest fret. GREY is the bare string."""
    gap = board["h"] // (strings - 1)
    x = board["x"] + column * board["col"] + board["col"] // 2 - 1
    y = board["y"] + (string - 1) * gap - 1
    return NAMES[g.emu.display.front[y * 640 + x]]


def count(g, board, name, strings=6):
    """Pixels of a colour on a board, its whole box."""
    gap = board["h"] // (strings - 1)
    want = NAMES.index(name)
    front = g.emu.display.front
    rows = range(board["y"] - 12, board["y"] + gap * (strings - 1) + 13)
    cols = range(board["x"], board["x"] + board["col"] * 6 + 8)
    return sum(1 for y in rows for x in cols if front[y * 640 + x] == want)


def text_at(g, text):
    return next(t for t in g.texts() if t.text == text)


def scale_gets(g):
    return [m[1] for m in g.sent(SCALE_GET) if len(m) == 2]


def set_up(g, lines):
    """The phone's settings, a while before Scales is opened."""
    g.settings(lines)
    g.advance(1)


def fretboard(g, instrument=0):
    """Scales open, instrument (0 the guitar) taken."""
    g.open_app("scales")
    for _ in range(instrument):
        g.tilt(1)
    g.tap(1)


# ---------------------------------------------------------------- Halo

def test_only_frame_has_it(glasses):
    assert glasses.device == "frame"


def test_halo_has_no_scales(halo):
    halo.clear_sent()
    halo.open_app("scales")
    halo.advance(1)
    assert not halo.sent(APP_START)
    halo.assert_ok()


# ---------------------------------------------------------------- the list

def test_opens_on_the_instruments(frame):
    frame.clear_sent()
    frame.open_app("scales")
    assert frame.sent(APP_START)
    text = frame.screen_text()
    for name in ("> Guitar", "Bass", "Banjo", "Ukulele", "Balalaika"):
        assert name in text
    assert not frame.sent(SCALE_GET)             # nothing asked yet
    assert text_at(frame, "> Guitar").color == "WHITE"
    assert text_at(frame, "  Bass").color == "GREY"
    frame.screenshot("scales-instruments")
    frame.assert_ok()


def test_tilting_moves_through_the_instruments_and_wraps(frame):
    frame.open_app("scales")
    frame.tilt(1)
    assert "> Bass" in frame.screen_text()
    assert "> Guitar" not in frame.screen_text()
    frame.tilt(-1)
    frame.tilt(-1)
    assert "> Balalaika" in frame.screen_text()
    frame.tilt(1)
    assert "> Guitar" in frame.screen_text()
    frame.assert_ok()


def test_the_remote_moves_the_cursor_on_the_list(frame):
    frame.open_app("scales")
    frame.remote(2, 1)                           # Right
    assert "> Bass" in frame.screen_text()
    frame.remote(3, 1)                           # Down: a tilt here
    assert "> Banjo" in frame.screen_text()
    frame.remote(3, 255)                         # Up
    assert "> Bass" in frame.screen_text()
    assert not frame.sent(SCALE_GET)
    frame.assert_ok()


def test_a_double_tap_on_the_list_leaves_for_the_menu(frame):
    frame.open_app("scales")
    frame.clear_sent()
    frame.tap(2)
    assert frame.sent(APP_STOP)
    assert not frame.sent(APP_BACKGROUND)        # not a background app
    assert frame.sent(MENU_OPEN)
    assert "Glaz > Apps" in frame.screen_text()
    assert "Guitar" not in frame.screen_text()
    frame.assert_ok()


# ---------------------------------------------------------------- the board

def test_a_tap_takes_the_guitar_and_asks_for_the_first_scale(frame):
    frame.open_app("scales")
    frame.clear_sent()
    frame.tap(1)
    assert scale_gets(frame) == [0]
    text = frame.screen_text()
    assert "A minor pent" in text                # built in, no phone needed
    assert "fr 5" in text                        # A on the low E string
    assert "Guitar" not in text
    frame.screenshot("scales-minor-pent")
    frame.assert_ok()


def test_the_built_in_pentatonic_is_one_big_board(frame):
    fretboard(frame)
    # box at fret 5: the low E string (6th) A C D E G -- frets 5, 8 (C)
    assert colour(frame, SINGLE, 6, 0) == "RED"         # A, the root
    assert colour(frame, SINGLE, 6, 3) == "WHITE"       # C
    assert colour(frame, SINGLE, 6, 1) == "GREY"        # A#: bare string
    assert colour(frame, SINGLE, 1, 0) == "RED"         # high e, fret 5
    assert colour(frame, SINGLE, 4, 2) == "RED"         # D string, fret 7
    assert "m pent" not in frame.screen_text()   # no labels on one board


def test_the_phone_sends_a_mode_drawn_under_its_pentatonic(frame):
    fretboard(frame)
    frame.call("scales", DORIAN)
    text = frame.screen_text()
    assert "A dorian" in text
    assert "m pent" in text and "fr 5" in text
    # the Oye Como Va box of docs/SCALES.md: F#, Dorian's 6th, green
    assert colour(frame, BOTTOM, 2, 2) == "LIGHTGREEN"  # B string, fret 7
    assert colour(frame, BOTTOM, 5, 4) == "LIGHTGREEN"  # A string, fret 9
    assert colour(frame, BOTTOM, 6, 0) == "RED"
    assert colour(frame, BOTTOM, 6, 2) == "WHITE"       # B, fret 7
    # the pentatonic above has neither B nor F#
    assert colour(frame, TOP, 2, 2) == "GREY"
    assert colour(frame, TOP, 5, 4) == "GREY"
    assert colour(frame, TOP, 6, 0) == "RED"
    assert colour(frame, TOP, 6, 3) == "WHITE"          # C
    # the top row: key and mode white, the fret grey; a label on each board
    assert text_at(frame, "A dorian").color == "WHITE"
    assert text_at(frame, "fr 5").color == "GREY"
    assert text_at(frame, "m pent").y == TOP["y"] + 8
    assert text_at(frame, "dorian").y == BOTTOM["y"] + 8
    assert count(frame, TOP, "LIGHTGREEN") == 0          # no flavour there
    frame.screenshot("scales-dorian")
    frame.assert_ok()


def test_the_single_view_shows_the_mode_alone(frame):
    set_up(frame, {"scales.view": "single"})
    fretboard(frame)
    frame.call("scales", DORIAN)
    text = frame.screen_text()
    assert "A dorian" in text
    assert "m pent" not in text
    assert colour(frame, SINGLE, 2, 2) == "LIGHTGREEN"
    assert colour(frame, SINGLE, 6, 0) == "RED"
    frame.screenshot("scales-dorian-single")
    frame.assert_ok()


def test_the_key_comes_from_the_phones_settings(frame):
    set_up(frame, {"scales.key": "C"})
    fretboard(frame)
    text = frame.screen_text()
    assert "C minor pent" in text
    assert "fr 8" in text                        # C on the low E string
    assert colour(frame, SINGLE, 6, 0) == "RED"
    frame.assert_ok()


def test_settings_sent_just_before_opening_apply(frame):
    frame.settings({"scales.key": "C"})
    fretboard(frame)
    assert "C minor pent" in frame.screen_text()


def test_an_unknown_key_falls_back_to_a(frame):
    set_up(frame, {"scales.key": "H"})
    fretboard(frame)
    assert "A minor pent" in frame.screen_text()
    frame.assert_ok()


# ---------------------------------------------------------------- boxes

def test_tilting_moves_the_box_up_the_neck_and_wraps(frame):
    fretboard(frame)
    seen = []
    for _ in range(5):
        seen.append(next(t.text for t in frame.texts()
                         if t.text.startswith("fr ")))
        frame.tilt(1)
    assert seen == ["fr 5", "fr 8", "fr 10", "fr 12", "fr 15"]
    assert "fr 5" in frame.screen_text()         # round to the first
    frame.tilt(-1)
    assert "fr 15" in frame.screen_text()
    assert colour(frame, SINGLE, 6, 0) == "WHITE"   # G at fret 15
    assert colour(frame, SINGLE, 6, 2) == "RED"     # A at fret 17
    frame.assert_ok()


def test_the_remotes_left_and_right_move_the_box(frame):
    fretboard(frame)
    frame.remote(2, 1)
    assert "fr 8" in frame.screen_text()
    frame.remote(2, 255)
    assert "fr 5" in frame.screen_text()
    frame.assert_ok()


def test_a_major_scale_takes_the_major_pentatonics_boxes(frame):
    fretboard(frame)
    frame.call("scales", MAJOR)
    text = frame.screen_text()
    assert "A major" in text and "M pent" in text
    frame.tilt(1)
    assert "fr 7" in frame.screen_text()         # B: A major pent's 2nd
    frame.tilt(1)
    assert "fr 9" in frame.screen_text()
    frame.assert_ok()


def test_a_box_past_the_last_fret_moves_an_octave_down(frame):
    # ukulele in A, boxes from G: 2, 5, 7, 9, 12 -- 12..17 runs past 15
    fretboard(frame, instrument=3)
    assert "fr 2" in frame.screen_text()
    frame.tilt(-1)
    assert "fr 0" in frame.screen_text()
    frame.screenshot("scales-ukulele-open")
    frame.assert_ok()


def test_an_open_box_has_a_nut(frame):
    fretboard(frame, instrument=3)
    gap = SINGLE["h"] // 3
    y = SINGLE["y"] + gap // 2                   # between two strings
    px = SINGLE["x"] + SINGLE["col"] + 1         # 2 px right of the wire
    assert NAMES[frame.emu.display.front[y * 640 + px]] == "VOID"
    frame.tilt(-1)                               # fret 0
    assert NAMES[frame.emu.display.front[y * 640 + px]] == "GREY"
    frame.assert_ok()


@pytest.mark.parametrize("instrument, name, fret", [
    (1, "Bass", 5), (2, "Banjo", 7), (4, "Balalaika", 5)])
def test_each_instruments_first_box(frame, instrument, name, fret):
    frame.open_app("scales")
    for _ in range(instrument):
        frame.tilt(1)
    assert f"> {name}" in frame.screen_text()
    frame.tap(1)
    assert f"fr {fret}" in frame.screen_text()
    frame.assert_ok()


def test_the_banjos_short_string_starts_at_fret_5(frame):
    # D: the banjo's boxes start at fret 0 on its D string
    set_up(frame, {"scales.key": "D"})
    fretboard(frame, instrument=2)
    assert "fr 0" in frame.screen_text()
    # 5th string, g: open G and C at fret 5 drawn, the A at fret 2 is not
    assert colour(frame, SINGLE, 5, 0, strings=5) == "WHITE"
    assert colour(frame, SINGLE, 5, 2, strings=5) == "GREY"
    assert colour(frame, SINGLE, 5, 5, strings=5) == "WHITE"
    # the A at fret 2 of the full-length 3rd string, G, is drawn
    assert colour(frame, SINGLE, 3, 2, strings=5) == "WHITE"
    frame.screenshot("scales-banjo")
    frame.assert_ok()


# ---------------------------------------------------------------- scales

def test_without_the_phone_every_ask_is_for_the_first(frame):
    fretboard(frame)
    frame.clear_sent()
    frame.tap(1)
    frame.remote(3, 255)
    assert scale_gets(frame) == [0, 0]
    assert "A minor pent" in frame.screen_text()
    frame.assert_ok()


def test_a_tap_and_down_ask_for_the_next_up_for_the_previous(frame):
    fretboard(frame)
    frame.call("scales", DORIAN)
    frame.clear_sent()
    frame.tap(1)
    frame.remote(3, 1)                           # Down
    frame.remote(3, 255)                         # Up
    frame.remote(1, 1)                           # OK
    assert scale_gets(frame) == [3, 3, 1, 3]
    assert "A dorian" in frame.screen_text()     # until the phone answers
    frame.assert_ok()


def test_the_scales_wrap_round_the_phones_count(frame):
    fretboard(frame)
    frame.call("scales", "g13 14 phrygian dom|phr dom|14578a|4|m pent|0357a")
    frame.clear_sent()
    frame.tap(1)
    assert scale_gets(frame) == [0]
    frame.call("scales", "g0 14 minor pent|m pent|0357a|||")
    frame.clear_sent()
    frame.remote(3, 255)
    assert scale_gets(frame) == [13]
    frame.assert_ok()


def test_a_pentatonic_from_the_phone_is_drawn_alone(frame):
    fretboard(frame)
    frame.call("scales", DORIAN)
    frame.call("scales", "g0 14 minor pent|m pent|0357a|||")
    text = frame.screen_text()
    assert "A minor pent" in text
    assert "m pent" not in text.replace("minor pent", "")
    assert colour(frame, SINGLE, 6, 0) == "RED"
    frame.assert_ok()


def test_the_box_is_kept_for_the_next_scale(frame):
    fretboard(frame)
    frame.tilt(1)
    frame.tilt(1)
    frame.call("scales", DORIAN)
    assert "fr 10" in frame.screen_text()
    frame.assert_ok()


@pytest.mark.parametrize("arg", [
    "",
    "garbage",
    "g2 14 dorian",                              # fields missing
    "g2 14 dorian|dorian|02z579a|9|m pent|0357a",  # not hex
    "g2 14 dorian|dorian|023579a|99|m pent|0357a",  # two-digit flavour
    "gx 14 dorian|dorian|023579a|9|m pent|0357a",
    "g2 14 dorian|dorian|023579a|9|m pent|0357a|137",
])
def test_a_malformed_answer_changes_nothing(frame, arg):
    fretboard(frame)
    frame.call("scales", arg)
    text = frame.screen_text()
    assert "A minor pent" in text and "fr 5" in text
    frame.assert_ok()


def test_an_answer_on_the_list_shows_once_an_instrument_is_taken(frame):
    frame.open_app("scales")
    frame.call("scales", DORIAN)
    assert "> Guitar" in frame.screen_text()
    frame.clear_sent()
    frame.tap(1)
    assert scale_gets(frame) == [2]              # the one held, fresh
    assert "A dorian" in frame.screen_text()
    frame.assert_ok()


def test_not_running_it_takes_no_calls(frame):
    frame.clear_sent()
    frame.call("scales", DORIAN)
    frame.advance(1)
    assert not frame.sent(APP_START)
    assert not frame.sent(APP_BACKGROUND)
    frame.assert_ok()


# ---------------------------------------------------------------- leaving

def test_a_double_tap_goes_back_to_the_instruments_then_the_menu(frame):
    fretboard(frame, instrument=1)
    frame.clear_sent()
    frame.tap(2)
    assert "> Bass" in frame.screen_text()       # where it was
    assert not frame.sent(APP_STOP)
    frame.tap(2)
    assert frame.sent(APP_STOP)
    frame.assert_ok()


def test_the_remotes_back_does_the_same(frame):
    fretboard(frame)
    frame.remote(1, 2)
    assert "> Guitar" in frame.screen_text()
    frame.tap(1)
    assert "fr 5" in frame.screen_text()         # the first box again
    frame.assert_ok()


def test_opened_again_it_starts_afresh(frame):
    fretboard(frame)
    frame.call("scales", DORIAN)
    frame.tap(2)
    frame.tap(2)
    frame.open_app("scales")
    assert "> Guitar" in frame.screen_text()
    frame.tap(1)
    assert "A minor pent" in frame.screen_text()
    frame.assert_ok()


def test_it_stays_open_ten_minutes_without_input(frame):
    fretboard(frame)
    frame.clear_sent()
    frame.advance(590)                           # far past APP_TIMEOUT
    assert "fr 5" in frame.screen_text()
    assert not frame.sent(APP_STOP)
    frame.advance(80)                            # IDLE_MAX, then a minute
    assert frame.sent(APP_STOP)
    assert "fr 5" not in frame.screen_text()
    frame.assert_ok()


def test_a_tilt_keeps_it_open(frame):
    fretboard(frame)
    frame.clear_sent()
    frame.advance(500)
    frame.tilt(1)
    frame.advance(500)
    assert "fr 8" in frame.screen_text()
    assert not frame.sent(APP_STOP)
    frame.assert_ok()


def test_the_list_too_waits_ten_minutes(frame):
    frame.open_app("scales")
    frame.clear_sent()
    frame.advance(137 * 4)
    assert "> Guitar" in frame.screen_text()
    frame.advance(137)
    assert frame.sent(APP_STOP)
    frame.assert_ok()


def test_a_scale_without_notes_is_refused(frame):
    fretboard(frame)
    frame.call("scales", "g5 14 empty|empty||||")
    frame.tilt(1)
    text = frame.screen_text()
    assert "A minor pent" in text and "fr 8" in text
    frame.assert_ok()


def test_a_count_of_none_is_refused(frame):
    fretboard(frame)
    frame.call("scales", "g0 0 dorian|dorian|023579a|9|m pent|0357a")
    frame.clear_sent()
    frame.tap(1)
    assert scale_gets(frame) == [0]
    assert "A minor pent" in frame.screen_text()
    frame.assert_ok()


# ---------------------------------------------------------------- more

def test_its_state_is_never_shown_as_text(frame):
    # quiet: tick() returns the state only to say when to redraw
    fretboard(frame)
    frame.call("scales", DORIAN)
    frame.tilt(1)
    frame.advance(3)
    text = frame.screen_text()
    assert "true" not in text and "dorian 2" not in text
    frame.assert_ok()


def test_a_flat_key_is_named_and_its_last_box_moves_down(frame):
    # Eb on the low E: boxes 11, 14, 16, 18 and 21, which runs past 22
    set_up(frame, {"scales.key": "Eb"})
    fretboard(frame)
    assert "Eb minor pent" in frame.screen_text()
    assert "fr 11" in frame.screen_text()
    frame.tilt(-1)
    assert "fr 9" in frame.screen_text()
    assert colour(frame, SINGLE, 6, 0) == "WHITE"   # C# at fret 9
    assert colour(frame, SINGLE, 6, 2) == "RED"     # Eb at fret 11
    frame.assert_ok()


def test_a_sharp_key_is_named_too(frame):
    set_up(frame, {"scales.key": "C#"})
    fretboard(frame)
    assert "C# minor pent" in frame.screen_text()
    assert "fr 9" in frame.screen_text()
    frame.assert_ok()


def test_an_unknown_view_shows_two(frame):
    set_up(frame, {"scales.view": "137"})
    fretboard(frame)
    frame.call("scales", DORIAN)
    assert "m pent" in frame.screen_text()
    assert colour(frame, BOTTOM, 2, 2) == "LIGHTGREEN"
    frame.assert_ok()


def test_settings_changed_while_open_wait_for_the_next_start(frame):
    fretboard(frame)
    set_up(frame, {"scales.key": "C", "scales.view": "single"})
    frame.call("scales", DORIAN)
    assert "A dorian" in frame.screen_text()
    assert "m pent" in frame.screen_text()       # still two
    frame.tap(2)
    frame.tap(2)
    fretboard(frame)
    frame.call("scales", DORIAN)
    assert "C dorian" in frame.screen_text()
    assert "m pent" not in frame.screen_text()
    frame.assert_ok()


def test_the_majors_own_note_is_its_seventh(frame):
    fretboard(frame)
    frame.call("scales", MAJOR)
    # G#, A major's 7th, on the B string at fret 9: green, not in M pent
    assert colour(frame, BOTTOM, 2, 4) == "LIGHTGREEN"
    assert colour(frame, TOP, 2, 4) == "GREY"
    assert colour(frame, TOP, 2, 0) == "WHITE"      # E, fret 5
    assert colour(frame, TOP, 1, 4) == "WHITE"      # C#, fret 9: major 3rd
    assert colour(frame, BOTTOM, 6, 0) == "RED"
    assert text_at(frame, "M pent").y == TOP["y"] + 8
    frame.screenshot("scales-major")
    frame.assert_ok()


def test_a_scale_without_its_own_note_has_no_green(frame):
    fretboard(frame)
    frame.call("scales", "g4 14 minor|minor|023578a||m pent|0357a")
    assert "A minor" in frame.screen_text()
    assert count(frame, BOTTOM, "LIGHTGREEN") == 0
    assert colour(frame, BOTTOM, 2, 1) == "WHITE"   # F, fret 6: minor's 6th
    assert colour(frame, TOP, 2, 1) == "GREY"
    frame.assert_ok()


def test_two_boards_have_smaller_dots_than_one(frame):
    fretboard(frame)
    big = count(frame, SINGLE, "RED")
    frame.call("scales", DORIAN)
    small = count(frame, BOTTOM, "RED")
    assert 0 < small < big
    frame.assert_ok()


def test_the_bass_has_four_strings(frame):
    fretboard(frame, instrument=1)
    text = frame.screen_text()
    assert "A minor pent" in text and "fr 5" in text
    assert colour(frame, SINGLE, 1, 0, strings=4) == "WHITE"  # G string: C
    assert colour(frame, SINGLE, 1, 1, strings=4) == "GREY"   # C#
    assert colour(frame, SINGLE, 3, 0, strings=4) == "WHITE"  # A string: D
    assert colour(frame, SINGLE, 4, 0, strings=4) == "RED"    # E string: A
    assert colour(frame, SINGLE, 3, 2, strings=4) == "WHITE"  # E
    frame.screenshot("scales-bass")
    frame.assert_ok()


def test_the_balalaika_has_three_strings(frame):
    fretboard(frame, instrument=4)
    assert colour(frame, SINGLE, 1, 0, strings=3) == "WHITE"  # A string: D
    assert colour(frame, SINGLE, 1, 1, strings=3) == "GREY"   # D#
    assert colour(frame, SINGLE, 2, 0, strings=3) == "RED"    # E string: A
    assert colour(frame, SINGLE, 3, 0, strings=3) == "RED"
    frame.assert_ok()


def test_too_many_scales_are_refused(frame):
    # SCALE_GET asks with one byte: a count past 256 could not be asked for
    fretboard(frame)
    frame.call("scales", "g255 300 dorian|dorian|023579a|9|m pent|0357a")
    assert "A minor pent" in frame.screen_text()
    frame.clear_sent()
    frame.tap(1)
    assert scale_gets(frame) == [0]
    frame.assert_ok()


def test_the_last_of_256_scales_wraps_to_the_first(frame):
    fretboard(frame)
    frame.call("scales", "g255 256 dorian|dorian|023579a|9|m pent|0357a")
    frame.clear_sent()
    frame.tap(1)
    frame.remote(3, 255)
    assert scale_gets(frame) == [0, 254]
    frame.assert_ok()


def test_without_bluetooth_a_tap_still_works(frame):
    fretboard(frame)
    frame.emu.connected = False
    frame.clear_sent()
    frame.tap(1)
    frame.tilt(1)
    assert not frame.sent(SCALE_GET)
    text = frame.screen_text()
    assert "A minor pent" in text and "fr 8" in text
    frame.assert_ok()


def test_up_and_down_keep_it_open(frame):
    fretboard(frame)
    frame.clear_sent()
    frame.advance(500)
    frame.remote(3, 1)
    frame.advance(500)
    assert "fr 5" in frame.screen_text()
    assert not frame.sent(APP_STOP)
    frame.assert_ok()


def test_a_phone_answer_keeps_it_open(frame):
    fretboard(frame)
    frame.clear_sent()
    frame.advance(500)
    frame.call("scales", DORIAN)
    frame.advance(500)
    assert "A dorian" in frame.screen_text()
    assert not frame.sent(APP_STOP)
    frame.assert_ok()


def test_the_cursor_starts_on_the_guitar_again(frame):
    fretboard(frame, instrument=3)
    frame.tap(2)
    frame.tap(2)
    frame.open_app("scales")
    assert "> Guitar" in frame.screen_text()
    assert "> Ukulele" not in frame.screen_text()
    frame.assert_ok()


def test_the_box_starts_at_the_first_for_another_instrument(frame):
    fretboard(frame)
    frame.tilt(1)
    frame.tilt(1)                                # fr 10
    frame.tap(2)
    frame.tilt(1)
    frame.tap(1)                                 # the bass
    assert "fr 5" in frame.screen_text()
    frame.assert_ok()


# ---------------------------------------------------------------- edges

def test_a_scale_with_fewer_boxes_keeps_to_its_last(frame):
    # a seven-note scale without a pentatonic under it has seven boxes;
    # the next scale, with five, cannot start from the seventh
    fretboard(frame)
    frame.call("scales", "g0 2 seven|seven|0235789|||")
    for _ in range(6):
        frame.tilt(1)                            # its seventh box
    frame.call("scales", DORIAN)
    text = frame.screen_text()
    assert "A dorian" in text and "fr 15" in text   # m pent's fifth box
    assert colour(frame, BOTTOM, 6, 2) == "RED"     # A at fret 17
    frame.tilt(1)
    assert "fr 5" in frame.screen_text()         # and round to the first
    frame.assert_ok()


def test_a_box_ending_on_the_last_fret_stays_up_the_neck(frame):
    # B on the low E: boxes 7, 10, 12, 14 and 17, whose 17..22 just fits
    set_up(frame, {"scales.key": "B"})
    fretboard(frame)
    assert "fr 7" in frame.screen_text()
    frame.tilt(-1)
    assert "fr 17" in frame.screen_text()
    assert colour(frame, SINGLE, 6, 2) == "RED"     # B at fret 19
    frame.assert_ok()


def test_in_e_the_first_box_is_open_and_the_last_at_ten(frame):
    set_up(frame, {"scales.key": "E"})
    fretboard(frame)
    text = frame.screen_text()
    assert "E minor pent" in text and "fr 0" in text
    assert colour(frame, SINGLE, 6, 0) == "RED"     # the open low E
    assert colour(frame, SINGLE, 1, 0) == "RED"     # and the high one
    frame.tilt(-1)
    assert "fr 10" in frame.screen_text()
    frame.assert_ok()


def test_one_scale_on_the_phone_asks_for_itself(frame):
    fretboard(frame)
    frame.call("scales", "g0 1 minor pent|m pent|0357a|||")
    frame.clear_sent()
    frame.tap(1)
    frame.remote(3, 1)
    frame.remote(3, 255)
    assert scale_gets(frame) == [0, 0, 0]
    frame.assert_ok()


def test_a_number_past_the_count_still_asks_within_it(frame):
    fretboard(frame)
    frame.call("scales", "g137 14 dorian|dorian|023579a|9|m pent|0357a")
    assert "A dorian" in frame.screen_text()
    frame.clear_sent()
    frame.tap(1)
    frame.remote(3, 255)
    assert scale_gets(frame) == [138 % 14, 136 % 14]
    frame.assert_ok()


def test_the_same_answer_twice_changes_nothing(frame):
    fretboard(frame)
    frame.call("scales", DORIAN)
    frame.tilt(1)
    before = frame.image().tobytes()
    frame.call("scales", DORIAN)
    assert frame.image().tobytes() == before
    assert "fr 8" in frame.screen_text()
    frame.assert_ok()


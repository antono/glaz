"""Gemini (apps/gemini/gemini.lua), the Gemini browser whose pages the phone
fetches: asking for lines (GEM_GET) and showing the phone's answer
(MODULE_CALL 'p:...'), the cursor on links and scrolling by tilt and tap,
opening a link, going back, the notes for no phone and no answer, and the
page kept between visits. Frame only (gemini.lua uses Frame's API; it has
no Halo part, docs/DEVICES.md)."""
import struct

import pytest

from glasses import APP_BACKGROUND, APP_STOP, MENU_OPEN, has_module

pytestmark = pytest.mark.module("gemini")

GEM_GET = 0x0D
OPEN, LINES = 1, 2

HOME = [("H", "Bookmarks"), ("L1", "Gemini project"), ("L2", "Antenna")]

# A page of 14 lines: '< back', text, a link, a link over two lines, a
# quote, preformatted text, then '< back' and 'home'
STATION = [
    ("L0", "< back"), ("H", "Station"),
    ("T", "text a"), ("T", "text b"), ("T", "text c"), ("T", "text d"),
    ("L1", "First link"), ("L2", "A link that runs"), ("L2", "over two lines"),
    ("T", "text e"), ("Q", "a quote"), ("P", "pre text"),
    ("L0", "< back"), ("L65535", "home"),
]


def answer(page, lines, start=0, total=None, top=0, back=None):
    """The phone's answer: 'p:<page>:<from>:<total>:<top>:<back>' and a
    line each; back None for an older phone's header without it."""
    head = f"p:{page}:{start}:{len(lines) if total is None else total}:{top}"
    if back is not None:
        head += f":{back}"
    return head + "".join(f"\n{k}|{t}" for k, t in lines)


def asks(g):
    """GEM_GET requests sent: (op, page, n, top) each."""
    return [struct.unpack(">BBHH", m[1:])
            for m in g.sent(GEM_GET)]


def color(g, text):
    return next(t.color for t in g.texts() if t.text == text)


def cursor_row(g):
    """The text on the cursor's row, or None."""
    marks = [t for t in g.texts() if t.text == ">" and t.color == "YELLOW"]
    if not marks:
        return None
    return next(t.text for t in g.texts()
                if t.y == marks[0].y and t.x > marks[0].x)


def opened(g, page=1, lines=HOME, back=0, top=0, total=None):
    """Gemini on screen with a page from the phone."""
    g.open_app("gemini")
    g.call("gemini", answer(page, lines, total=total, top=top, back=back))
    g.advance(0.3)


def test_only_frame_has_it():
    assert has_module("frame", "gemini")
    assert not has_module("halo", "gemini")


def test_opens_asking_for_lines_and_shows_loading(glasses):
    glasses.clear_sent()
    glasses.open_app("gemini")
    glasses.advance(0.5)
    assert asks(glasses) == [(LINES, 0, 0, 0)]
    assert "loading.." in glasses.screen_text()
    assert "Gemini" in glasses.screen_text()
    glasses.screenshot("gemini-loading")
    glasses.assert_ok()


def test_shows_the_home_page_with_the_cursor_on_its_first_link(glasses):
    opened(glasses)
    text = glasses.screen_text()
    assert "Bookmarks" in text and "Antenna" in text
    assert "loading.." not in text
    assert cursor_row(glasses) == "Gemini project"
    assert color(glasses, "Bookmarks") == "ORANGE"
    assert color(glasses, "Gemini project") == "YELLOW"
    assert color(glasses, "Antenna") == "SKYBLUE"
    glasses.screenshot("gemini-home")
    glasses.assert_ok()


def test_each_kind_of_line_has_its_colour(glasses):
    lines = [("T", "plain"), ("H", "heading"), ("L1", "link"),
             ("Q", "quote"), ("P", "pre")]
    opened(glasses, lines=lines)
    assert color(glasses, "plain") == "WHITE"
    assert color(glasses, "heading") == "ORANGE"
    assert color(glasses, "quote") == "GREY"
    assert color(glasses, "pre") == "LIGHTGREEN"
    glasses.assert_ok()


def test_utf8_text_is_shown_as_it_comes(glasses):
    opened(glasses, lines=[("T", "Привет, мир"), ("L1", "Ссылка 137")])
    assert "Привет, мир" in glasses.screen_text()
    assert cursor_row(glasses) == "Ссылка 137"
    glasses.assert_ok()


def test_a_tilt_moves_the_cursor_between_links(glasses):
    opened(glasses)
    glasses.tilt(1)
    assert cursor_row(glasses) == "Antenna"
    assert color(glasses, "Gemini project") == "SKYBLUE"
    glasses.tilt(1)                      # past the last, at the page's end
    assert cursor_row(glasses) == "Antenna"
    glasses.tilt(-1)
    assert cursor_row(glasses) == "Gemini project"
    glasses.tilt(-1)                     # past the first, at the top
    assert cursor_row(glasses) == "Gemini project"
    glasses.assert_ok()


def test_the_remote_moves_the_cursor_too(glasses):
    opened(glasses)
    glasses.remote(2, 1)
    assert cursor_row(glasses) == "Antenna"
    glasses.remote(2, 255)
    assert cursor_row(glasses) == "Gemini project"
    glasses.assert_ok()


def test_tilting_past_the_last_link_on_screen_scrolls_down(glasses):
    opened(glasses, page=2, lines=STATION, back=1)
    assert cursor_row(glasses) == "< back"
    glasses.tilt(1)                      # no link in rows 1..4: a screen down
    text = glasses.screen_text()
    assert "Station" not in text and "text c" in text
    assert cursor_row(glasses) == "First link"
    glasses.tilt(1)
    assert cursor_row(glasses) == "A link that runs"
    # the link under the cursor is yellow on both its lines
    assert color(glasses, "over two lines") == "YELLOW"
    assert color(glasses, "First link") == "SKYBLUE"
    glasses.screenshot("gemini-page")
    glasses.tilt(1)                      # its second line is not a stop
    assert cursor_row(glasses) == "< back"
    assert "pre text" in glasses.screen_text()
    glasses.tilt(1)
    assert cursor_row(glasses) == "home"
    glasses.tilt(1)                      # the end of the page
    assert cursor_row(glasses) == "home"
    glasses.tilt(-1)
    assert cursor_row(glasses) == "< back"
    glasses.assert_ok()


def test_tilting_up_past_the_first_link_scrolls_up(glasses):
    opened(glasses, page=2, lines=STATION, back=1, top=9)
    assert "text e" in glasses.screen_text()
    assert cursor_row(glasses) == "< back"
    glasses.tilt(-1)                     # no link above on screen
    assert "text e" in glasses.screen_text()
    assert cursor_row(glasses) == "A link that runs"
    glasses.tilt(-1)
    assert cursor_row(glasses) == "First link"
    glasses.tilt(-1)                     # a screen up: rows 1..5, no link
    assert "Station" in glasses.screen_text()
    assert cursor_row(glasses) is None
    glasses.tilt(-1)                     # the first row
    assert cursor_row(glasses) == "< back"
    glasses.tilt(-1)                     # the top of the page
    assert cursor_row(glasses) == "< back"
    glasses.assert_ok()


def test_the_phones_top_shows_the_page_where_it_was_left(glasses):
    opened(glasses, page=2, lines=STATION, back=1, top=9)
    text = glasses.screen_text()
    assert "Station" not in text
    assert "text e" in text and "home" in text
    glasses.assert_ok()


def test_a_tap_opens_the_link_under_the_cursor(glasses):
    opened(glasses)
    glasses.tilt(1)                      # Antenna, link 2
    glasses.clear_sent()
    glasses.tap(1)
    assert asks(glasses) == [(OPEN, 1, 2, 0)]
    assert "opening.." in glasses.screen_text()
    assert cursor_row(glasses) is None
    glasses.screenshot("gemini-opening")
    glasses.call("gemini", answer(2, STATION, back=1))
    glasses.advance(0.3)
    assert "Station" in glasses.screen_text()
    assert cursor_row(glasses) == "< back"
    glasses.assert_ok()


def test_while_a_page_opens_tilts_and_taps_do_nothing(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.clear_sent()
    glasses.tilt(1)
    glasses.tap(1)
    assert not glasses.sent(GEM_GET)
    assert "opening.." in glasses.screen_text()
    glasses.assert_ok()


def test_a_tap_with_no_link_on_screen_scrolls_down(glasses):
    lines = [("T", f"line {i}") for i in range(12)]
    opened(glasses, page=3, lines=lines)
    assert cursor_row(glasses) is None
    glasses.clear_sent()
    glasses.tap(1)
    text = glasses.screen_text()
    assert "line 3" not in text and "line 4" in text and "line 8" in text
    assert not glasses.sent(GEM_GET)
    glasses.tap(1)                       # no further than the last screen
    text = glasses.screen_text()
    assert "line 6" not in text and "line 7" in text and "line 11" in text
    glasses.tap(1)                       # the end of the page
    assert glasses.screen_text() == text
    assert not glasses.sent(GEM_GET)
    glasses.assert_ok()


def test_scrolling_past_the_lines_held_asks_for_more(glasses):
    # 137 lines, the phone sends the first 12
    lines = [("T", f"line {i}") for i in range(137)]
    opened(glasses, page=3, lines=lines[:12], total=137)
    glasses.tap(1)
    glasses.tap(1)                       # top 8: lines 8..12, 12 missing
    assert "loading.." in glasses.screen_text()
    assert asks(glasses)[-1] == (LINES, 3, 0, 8)     # from top - 8
    glasses.call("gemini", answer(3, lines[0:40], total=137))
    glasses.advance(0.3)
    text = glasses.screen_text()
    assert "line 8" in text and "line 12" in text
    glasses.tap(1)
    glasses.tap(1)
    glasses.tap(1)
    glasses.tap(1)
    glasses.tap(1)
    glasses.tap(1)
    glasses.tap(1)                       # top 36: lines 36..40, 40 missing
    assert asks(glasses)[-1] == (LINES, 3, 28, 36)
    glasses.call("gemini", answer(3, lines[28:68], start=28, total=137))
    glasses.advance(0.3)
    assert "line 40" in glasses.screen_text()
    assert "line 35" not in glasses.screen_text()
    glasses.assert_ok()


def test_an_answer_to_an_older_request_is_dropped(glasses):
    lines = [("T", f"line {i}") for i in range(137)]
    opened(glasses, page=3, lines=lines[:40], total=137)
    for _ in range(9):
        glasses.tap(1)                   # top 36: lines 36..40, 40 missing
    assert asks(glasses)[-1] == (LINES, 3, 28, 36)
    # lines from 0 of the same page: not what was asked for now
    glasses.call("gemini", answer(3, lines[0:40], total=137))
    glasses.advance(0.3)
    assert "loading.." in glasses.screen_text()
    glasses.advance(5)                   # RETRY: asked again
    assert asks(glasses)[-1] == (LINES, 3, 28, 36)
    glasses.assert_ok()


def test_without_an_answer_it_asks_again(glasses):
    glasses.clear_sent()
    glasses.open_app("gemini")
    glasses.advance(1)
    assert len(asks(glasses)) == 1
    glasses.advance(5)                   # RETRY
    assert len(asks(glasses)) == 2
    assert asks(glasses)[-1] == (LINES, 0, 0, 0)
    assert "loading.." in glasses.screen_text()
    glasses.assert_ok()


def test_a_page_that_never_comes_says_so_and_a_tap_goes_on(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.advance(26)                  # past OPEN_WAIT
    assert "no answer, tap to retry" in glasses.screen_text()
    glasses.screenshot("gemini-no-answer")
    glasses.clear_sent()
    glasses.advance(10)
    assert not glasses.sent(GEM_GET)     # it waits for the tap
    glasses.tap(1)
    # the page held is still whole: shown again, nothing to ask for
    assert "Bookmarks" in glasses.screen_text()
    assert not glasses.sent(GEM_GET)
    glasses.tilt(1)                      # the cursor comes back
    assert cursor_row(glasses) == "Gemini project"
    glasses.assert_ok()


def test_lines_that_never_come_are_asked_for_after_a_tap(glasses):
    lines = [("T", f"line {i}") for i in range(137)]
    opened(glasses, page=3, lines=lines[:12], total=137)
    glasses.tap(1)
    glasses.tap(1)                       # lines 8..12 wanted
    glasses.clear_sent()
    glasses.advance(30)
    assert len(asks(glasses)) >= 5       # every RETRY seconds
    assert set(asks(glasses)) == {(LINES, 3, 0, 8)}
    glasses.assert_ok()


def test_a_late_page_after_no_answer_is_shown(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.advance(26)
    glasses.call("gemini", answer(2, STATION, back=1))
    glasses.advance(0.3)
    assert "Station" in glasses.screen_text()
    assert "no answer" not in glasses.screen_text()
    glasses.assert_ok()


def test_without_a_phone_it_says_so_and_asks_once_it_is_back(frame):
    lines = [("T", f"line {i}") for i in range(137)]
    opened(frame, page=3, lines=lines[:12], total=137)
    frame.emu.connected = False
    frame.clear_sent()
    frame.tap(1)
    frame.tap(1)                         # lines 8..12 wanted
    assert "no phone" in frame.screen_text()
    assert "tap to retry" not in frame.screen_text()
    assert not frame.sent(GEM_GET)
    frame.screenshot("gemini-no-phone")
    frame.emu.connected = True
    frame.advance(1)
    assert asks(frame) == [(LINES, 3, 0, 8)]
    assert "loading.." in frame.screen_text()
    frame.assert_ok()


def test_a_link_without_a_phone_is_not_opened(frame):
    opened(frame)
    frame.emu.connected = False
    frame.clear_sent()
    frame.tap(1)
    assert not frame.sent(GEM_GET)
    assert "no phone" in frame.screen_text()
    frame.assert_ok()


def test_a_double_tap_goes_back_a_page(glasses):
    opened(glasses, page=2, lines=STATION, back=1)
    glasses.clear_sent()
    glasses.tap(2)
    assert asks(glasses) == [(OPEN, 2, 0, 0)]       # link 0, '< back'
    assert "opening.." in glasses.screen_text()
    assert not glasses.sent(APP_STOP)
    glasses.call("gemini", answer(3, HOME, back=0))
    glasses.advance(0.3)
    assert "Bookmarks" in glasses.screen_text()
    glasses.assert_ok()


def test_a_double_tap_on_the_home_page_leaves(glasses):
    opened(glasses, back=0)
    glasses.clear_sent()
    glasses.tap(2)
    assert not glasses.sent(GEM_GET)
    assert glasses.sent(MENU_OPEN)
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)
    assert "Apps" in glasses.screen_text()
    glasses.assert_ok()


def test_an_older_phones_header_without_back_reads_as_home(glasses):
    opened(glasses, page=2, lines=STATION, back=None)
    assert "Station" in glasses.screen_text()
    glasses.clear_sent()
    glasses.tap(2)
    assert not glasses.sent(GEM_GET)
    assert glasses.sent(MENU_OPEN)
    glasses.assert_ok()


def test_a_double_tap_while_a_page_opens_leaves(glasses):
    opened(glasses, page=2, lines=STATION, back=1)
    glasses.tap(1)                       # '< back' under the cursor
    glasses.clear_sent()
    glasses.tap(2)
    assert not glasses.sent(GEM_GET)
    assert glasses.sent(MENU_OPEN)
    glasses.assert_ok()


def test_a_double_tap_without_a_phone_leaves(frame):
    opened(frame, page=2, lines=STATION, back=1)
    frame.emu.connected = False
    frame.clear_sent()
    frame.tap(2)
    assert not frame.sent(GEM_GET)
    assert "Apps" in frame.screen_text()     # the menu
    frame.assert_ok()


def test_the_page_comes_back_from_the_phone_on_the_next_visit(glasses):
    # Frame's require() caches nothing: left, the module is loaded afresh
    # and holds no page. The phone keeps it, and the place on it, and
    # answers page 0 with the page it has open (gemini.dart).
    lines = [("T", f"line {i}") for i in range(40)]
    opened(glasses, page=5, lines=lines, back=0, top=20)
    glasses.tap(2)                       # home page: leaves
    glasses.clear_sent()
    glasses.open_app("gemini")
    glasses.advance(0.5)
    assert asks(glasses) == [(LINES, 0, 0, 0)]
    glasses.call("gemini", answer(5, lines[12:40], start=12, total=40,
                                  top=20, back=0))
    glasses.advance(0.3)
    text = glasses.screen_text()
    assert "line 19" not in text and "line 20" in text
    glasses.assert_ok()


def test_an_answer_after_leaving_does_not_start_it(glasses):
    opened(glasses)
    glasses.tap(2)                       # leaves
    glasses.clear_sent()
    glasses.call("gemini", answer(2, STATION, back=1))
    glasses.advance(1)
    assert not glasses.sent(APP_BACKGROUND)
    assert "Station" not in glasses.screen_text()
    glasses.assert_ok()


def test_a_new_page_from_the_phone_replaces_the_one_held(glasses):
    lines = [("T", f"line {i}") for i in range(137)]
    opened(glasses, page=3, lines=lines[:12], top=0)
    glasses.call("gemini", answer(3, lines[:12], total=137))
    glasses.advance(0.3)
    glasses.tap(1)
    glasses.tap(1)                       # asks for lines of page 3
    # the phone restarted: it answers with the page it has
    glasses.call("gemini", answer(1, HOME, back=0))
    glasses.advance(0.3)
    assert "Bookmarks" in glasses.screen_text()
    assert cursor_row(glasses) == "Gemini project"
    glasses.assert_ok()


@pytest.mark.parametrize("arg", [
    "", "hello", "p:1", "p:x:0:3:0\nT|nope", "q:1:0:3:0\nT|nope",
])
def test_malformed_answers_are_ignored(glasses, arg):
    opened(glasses)
    before = glasses.screen_text()
    glasses.call("gemini", arg)
    glasses.advance(0.5)
    assert glasses.screen_text() == before
    glasses.assert_ok()


def test_left_alone_it_closes_after_a_minute(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.advance(61)                  # APP_TIMEOUT
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)
    assert "Bookmarks" not in glasses.screen_text()
    glasses.assert_ok()


class Busy:
    """emu.connected for a link the firmware calls busy: is_connected()
    gives Lua a value that is true, send() raises 'bluetooth is busy'
    (bluetooth.c, lua_bluetooth_send), as when the radio's queue is full."""

    def __bool__(self):
        return False


def test_the_phones_remote_taps_and_tilts_as_the_wearer(glasses):
    opened(glasses, page=2, lines=STATION, back=1)
    glasses.remote(3, 1)                 # Down: no on_up_down, so a tilt
    assert cursor_row(glasses) == "First link"
    glasses.remote(3, 255)               # Up
    assert cursor_row(glasses) == "< back"
    glasses.remote(2, 1)
    glasses.clear_sent()
    glasses.remote(1, 1)                 # a tap: opens 'First link'
    assert asks(glasses) == [(OPEN, 2, 1, 4)]
    assert "opening.." in glasses.screen_text()
    glasses.call("gemini", answer(3, STATION, back=1))
    glasses.advance(0.3)
    glasses.clear_sent()
    glasses.remote(1, 2)                 # a double tap: back
    assert asks(glasses) == [(OPEN, 3, 0, 0)]
    assert not glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_requests_carry_the_page_and_the_line_on_the_first_row(glasses):
    opened(glasses, page=7, lines=STATION, back=1)
    glasses.tilt(1)                      # a screen down: top 4
    glasses.clear_sent()
    glasses.tap(1)                       # 'First link'
    assert asks(glasses) == [(OPEN, 7, 1, 4)]
    glasses.call("gemini", answer(8, STATION, back=1, top=9))
    glasses.advance(0.3)
    glasses.clear_sent()
    glasses.tap(2)                       # back, from top 9
    assert asks(glasses) == [(OPEN, 8, 0, 9)]
    glasses.assert_ok()


def test_a_new_page_whose_top_is_not_held_asks_for_its_lines(glasses):
    lines = [("T", f"line {i}") for i in range(137)]
    glasses.open_app("gemini")
    glasses.clear_sent()
    # the phone sends from 0, but the page is to show from line 20
    glasses.call("gemini", answer(4, lines[:12], total=137, top=20, back=1))
    glasses.advance(0.5)
    assert "loading.." in glasses.screen_text()
    assert asks(glasses) == [(LINES, 4, 12, 20)]
    glasses.call("gemini", answer(4, lines[12:52], start=12, total=137,
                                  top=20, back=1))
    glasses.advance(0.3)
    text = glasses.screen_text()
    assert "line 19" not in text
    assert "line 20" in text and "line 24" in text
    assert "line 25" not in text
    glasses.assert_ok()


def test_a_link_begun_above_the_lines_held_gets_the_cursor(glasses):
    # lines from 12: line 12 is the second line of link 5, which began on
    # line 11, not held; it is the first line of that link the glasses have
    glasses.open_app("gemini")
    glasses.call("gemini", "p:4:12:16:12:1\nL5|second half\nT|after"
                           "\nL6|next link\nT|end")
    glasses.advance(0.3)
    assert cursor_row(glasses) == "second half"
    glasses.tilt(1)
    assert cursor_row(glasses) == "next link"
    glasses.assert_ok()


def test_an_answer_without_the_line_under_the_cursor_drops_the_cursor(glasses):
    # 137 lines, the phone sends 0..9: the screen at top 8 shows lines 8..9
    # held, the link on line 9 under the cursor, the rest asked for
    lines = [("T", f"line {i}") for i in range(137)]
    lines[9] = ("L3", "a link")
    glasses.open_app("gemini")
    glasses.call("gemini", answer(4, lines[:10], total=137, top=8))
    glasses.advance(0.5)
    assert "loading.." in glasses.screen_text()
    assert asks(glasses)[-1] == (LINES, 4, 0, 8)
    # the phone answers with fewer lines than wanted: 0..8, not line 9
    glasses.call("gemini", answer(4, lines[:9], total=137, top=8))
    glasses.advance(0.3)
    glasses.call("gemini", answer(4, lines[0:40], total=137, top=8))
    glasses.advance(0.3)
    text = glasses.screen_text()
    assert "a link" in text and "line 12" in text
    assert cursor_row(glasses) is None   # dropped, not put back
    glasses.tilt(1)
    assert cursor_row(glasses) == "a link"
    glasses.assert_ok()


def test_odd_lines_empty_unknown_kind_and_a_bar_in_the_text(glasses):
    lines = [("T", "above"), ("T", ""), ("X", "unknown kind"),
             ("T", "a | b"), ("L1", "x|y")]
    opened(glasses, lines=lines)
    texts = sorted(glasses.texts(), key=lambda t: t.y)
    shown = [t.text for t in texts if t.y >= 65 and t.x > 80]   # TOP_Y, TEXT_X
    assert shown == ["above", "unknown kind", "a | b", "x|y"]
    # the empty line keeps its row: the rows are ROW_H (55) apart
    ys = {t.text: t.y for t in texts}
    assert ys["unknown kind"] - ys["above"] == 2 * 55
    assert color(glasses, "unknown kind") == "WHITE"
    assert cursor_row(glasses) == "x|y"
    glasses.assert_ok()


def test_an_empty_page_shows_nothing_and_a_double_tap_goes_back(glasses):
    opened(glasses, page=4, lines=[], back=1)
    text = glasses.screen_text()
    assert "loading.." not in text and "opening.." not in text
    glasses.clear_sent()
    glasses.tilt(1)
    glasses.tap(1)
    assert not glasses.sent(GEM_GET)
    glasses.tap(2)
    assert asks(glasses) == [(OPEN, 4, 0, 0)]
    glasses.assert_ok()


def test_while_loading_tilts_and_taps_do_nothing(glasses):
    glasses.open_app("gemini")
    glasses.advance(1)
    glasses.clear_sent()
    glasses.tilt(1)
    glasses.tap(1)
    assert not glasses.sent(GEM_GET)
    assert "loading.." in glasses.screen_text()
    glasses.assert_ok()


def test_lines_are_asked_again_after_exactly_retry_seconds(glasses):
    glasses.clear_sent()
    glasses.open_app("gemini")           # asked at once
    glasses.advance(4.5)
    assert len(asks(glasses)) == 1       # not before RETRY
    glasses.advance(1)
    assert len(asks(glasses)) == 2
    glasses.assert_ok()


def test_a_page_is_waited_for_open_wait_seconds(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.advance(24)
    assert "opening.." in glasses.screen_text()
    glasses.advance(2)
    assert "no answer, tap to retry" in glasses.screen_text()
    glasses.assert_ok()


def test_a_stale_answer_for_the_page_held_is_dropped_while_opening(glasses):
    opened(glasses, page=2, lines=STATION, back=1)
    glasses.tap(1)                       # '< back'
    glasses.call("gemini", answer(2, STATION, back=1, top=9))
    glasses.advance(0.3)
    assert "opening.." in glasses.screen_text()
    glasses.call("gemini", answer(3, HOME, back=0))
    glasses.advance(0.3)
    assert "Bookmarks" in glasses.screen_text()
    glasses.assert_ok()


def test_after_no_answer_a_double_tap_goes_back(glasses):
    opened(glasses, page=2, lines=STATION, back=1)
    glasses.tilt(1)
    glasses.tap(1)                       # 'First link'
    glasses.advance(26)
    assert "no answer" in glasses.screen_text()
    glasses.clear_sent()
    glasses.tap(2)
    assert asks(glasses) == [(OPEN, 2, 0, 4)]
    assert "opening.." in glasses.screen_text()
    glasses.assert_ok()


def test_no_phone_while_the_first_page_loads(frame):
    frame.open_app("gemini")
    frame.emu.connected = False
    frame.clear_sent()
    frame.advance(5.5)                   # RETRY: asks again, and cannot
    assert "no phone" in frame.screen_text()
    assert "loading.." not in frame.screen_text()
    assert not frame.sent(GEM_GET)
    frame.tap(1)                         # clears the note: still no phone
    frame.advance(0.5)
    assert "no phone" in frame.screen_text()
    assert not frame.sent(GEM_GET)
    frame.emu.connected = True
    frame.advance(0.5)
    assert asks(frame) == [(LINES, 0, 0, 0)]
    frame.assert_ok()


def test_a_link_opens_once_the_phone_is_back(frame):
    opened(frame)
    frame.emu.connected = False
    frame.tap(1)
    assert "no phone" in frame.screen_text()
    frame.emu.connected = True
    frame.advance(0.5)
    # the note goes, the page and its cursor are as they were
    assert "no phone" not in frame.screen_text()
    assert cursor_row(frame) == "Gemini project"
    frame.clear_sent()
    frame.tap(1)
    assert asks(frame) == [(OPEN, 1, 1, 0)]
    frame.assert_ok()


def test_a_busy_link_does_not_leave_it_opening(frame):
    opened(frame)
    frame.clear_sent()
    frame.emu.connected = Busy()
    frame.tap(1)                         # 20 tries, all refused
    frame.emu.connected = True
    assert not frame.sent(GEM_GET)
    assert "opening.." not in frame.screen_text()
    assert cursor_row(frame) == "Gemini project"
    frame.tap(1)                         # the link is there to open again
    assert asks(frame) == [(OPEN, 1, 1, 0)]
    frame.assert_ok()


def test_a_page_in_cyrillic(glasses):
    lines = [("L0", "< back"), ("H", "Станция 137"),
             ("T", "Короткий текст"), ("L1", "Первая ссылка"),
             ("Q", "цитата")]
    opened(glasses, page=2, lines=lines, back=1)
    glasses.tilt(1)
    assert cursor_row(glasses) == "Первая ссылка"
    assert color(glasses, "Станция 137") == "ORANGE"
    assert color(glasses, "цитата") == "GREY"
    glasses.screenshot("gemini-cyrillic")
    glasses.assert_ok()

"""Notifications (modules/notifications.lua), Apps > Notifications: the
phone's notifications, newest first. The glasses ask for a window of the
list with NOTICES_GET (0x0E, '>BBI4': op 1 the list from a number, op 2 one
by id) and the phone answers through MODULE_CALL ('l:<from>:<total>' and a
'<id>|<line>' each, or 'f:<id>' and its lines; docs/PROTOCOL.md,
"Notifications"). Tilts move the cursor or page an open one, a tap opens
and closes one, a double tap goes back. Frame only (docs/DEVICES.md).
"""
import struct

import pytest

from glasses import APP_BACKGROUND, APP_STOP, has_module

pytestmark = pytest.mark.module("notifications")

NOTICES_GET = 0x0E
LIST, ONE = 1, 2


def asked(g):
    """What the glasses asked the phone for: (op, n) each."""
    return [struct.unpack(">BI", m[1:]) for m in g.sent(NOTICES_GET)]


def listing(start, total, ids):
    """The phone's answer to op 1: the notifications from number start."""
    return f"l:{start}:{total}" + "".join(
        f"\n{i}|App: title {i}" for i in ids)


def opened(g, total=3):
    """Notifications on screen with the phone's list of total, newest
    (the highest id) first, ten of them sent."""
    g.clear_sent()
    g.open_app("notifications")
    assert asked(g) == [(LIST, 0)]
    ids = [137 - n for n in range(min(10, total))]
    g.call("notifications", listing(0, total, ids))
    return ids


def ok(g):
    """No error: the harness's, and a module's own, which the app prints
    as '<label> err: <message>' (tests/glasses.py errors() looks only for
    'error')."""
    g.assert_ok()
    assert not [l for l in g.lines if " err: " in l], g.lines[-10:]


def rows(g):
    """The module's rows: the screen under the top bar (its crumbs, the
    clock and the battery)."""
    return g.screen_text().split("\n")[3:]


# ---------------------------------------------------------------- the list

def test_opens_loading_and_asks_for_the_newest(glasses):
    glasses.clear_sent()
    glasses.open_app("notifications")
    assert "Notifications" in glasses.screen_text()
    assert rows(glasses) == ["loading.."]
    # [0x0E, op 1, from 0]: the list from the newest
    assert glasses.sent(NOTICES_GET) == [b"\x0e\x01\x00\x00\x00\x00"]
    glasses.screenshot("notifications-loading")
    ok(glasses)


def test_shows_the_list_with_the_cursor_on_the_newest(glasses):
    opened(glasses)
    assert rows(glasses) == ["> App: title 137", "  App: title 136",
                             "  App: title 135"]
    glasses.screenshot("notifications")
    ok(glasses)


def test_an_empty_list_says_so(glasses):
    glasses.open_app("notifications")
    glasses.call("notifications", "l:0:0")
    assert rows(glasses) == ["no notifications"]
    glasses.clear_sent()
    glasses.tilt(1)
    glasses.tap(1)
    assert rows(glasses) == ["no notifications"]
    assert not glasses.sent(NOTICES_GET)
    ok(glasses)


def test_tilts_move_the_cursor_and_stop_at_the_ends(glasses):
    opened(glasses)
    glasses.tilt(-1)                             # above the newest: stays
    assert rows(glasses)[0] == "> App: title 137"
    glasses.tilt(1)
    assert rows(glasses)[1] == "> App: title 136"
    for _ in range(3):
        glasses.tilt(1)
    assert rows(glasses) == ["  App: title 137", "  App: title 136",
                             "> App: title 135"]
    glasses.tilt(-1)
    assert rows(glasses)[1] == "> App: title 136"
    ok(glasses)


def test_the_phones_remote_moves_the_cursor(glasses):
    opened(glasses)
    glasses.remote(2, 1)                         # a tilt: next
    assert rows(glasses)[1] == "> App: title 136"
    glasses.remote(2, 255)                       # previous
    assert rows(glasses)[0] == "> App: title 137"
    ok(glasses)


def test_five_rows_scroll_with_the_cursor(glasses):
    ids = opened(glasses, total=137)
    assert len(rows(glasses)) == 5
    for _ in range(5):
        glasses.tilt(1)
    # the cursor on the sixth, the first gone up
    assert rows(glasses) == [f"  App: title {i}" for i in ids[1:5]] + \
        [f"> App: title {ids[5]}"]
    glasses.tilt(-1)
    glasses.tilt(-1)
    glasses.tilt(-1)
    glasses.tilt(-1)
    glasses.tilt(-1)
    assert rows(glasses)[0] == f"> App: title {ids[0]}"
    ok(glasses)


def test_past_the_window_it_asks_for_more(glasses):
    opened(glasses, total=137)                   # numbers 0..9 held
    glasses.clear_sent()
    for _ in range(9):
        glasses.tilt(1)
    assert not asked(glasses)                    # 9 is still held
    glasses.tilt(1)                              # 10: rows 6..10
    # from two above the first row, so a tilt back needs no asking
    assert asked(glasses) == [(LIST, 4)]
    assert rows(glasses)[-1] == "> .."           # not here yet
    glasses.call("notifications",
                 listing(4, 137, [137 - n for n in range(4, 14)]))
    assert rows(glasses) == [f"  App: title {137 - n}" for n in range(6, 10)] \
        + ["> App: title 127"]
    glasses.screenshot("notifications-scrolled")
    ok(glasses)


def test_a_tap_on_a_row_not_here_yet_does_nothing(glasses):
    opened(glasses, total=137)
    for _ in range(10):
        glasses.tilt(1)
    glasses.clear_sent()
    glasses.tap(1)
    assert rows(glasses)[-1] == "> .."
    assert not [a for a in asked(glasses) if a[0] == ONE]
    ok(glasses)


def test_asks_again_after_five_seconds_without_an_answer(glasses):
    glasses.clear_sent()
    glasses.open_app("notifications")
    assert asked(glasses) == [(LIST, 0)]
    glasses.advance(4)
    assert asked(glasses) == [(LIST, 0)]         # not yet
    glasses.advance(2)
    assert asked(glasses) == [(LIST, 0), (LIST, 0)]
    assert rows(glasses) == ["loading.."]
    ok(glasses)


def test_an_answer_to_another_request_is_ignored(glasses):
    glasses.open_app("notifications")
    glasses.call("notifications", listing(5, 137, [132]))   # asked from 0
    assert rows(glasses) == ["loading.."]
    glasses.call("notifications", "f:137\nnot asked for")
    assert rows(glasses) == ["loading.."]
    glasses.call("notifications", listing(0, 1, [137]))
    assert rows(glasses) == ["> App: title 137"]
    ok(glasses)


@pytest.mark.parametrize("payload", [
    "", "garbage", "l:", "l:x:3", "x:0:3\n137|App", "l:0\n137|App",
    "l:0:\n137|App", "f:\nno id", "l:-1:3\n137|App",
])
def test_a_malformed_answer_changes_nothing(glasses, payload):
    glasses.open_app("notifications")
    glasses.call("notifications", payload)
    glasses.advance(1)
    assert rows(glasses) == ["loading.."]
    ok(glasses)


def test_a_shorter_list_keeps_the_cursor_on_it(glasses):
    opened(glasses, total=137)
    for _ in range(10):
        glasses.tilt(1)
    # meanwhile the phone dropped all but six
    glasses.call("notifications",
                 listing(4, 6, [133, 132]))
    assert rows(glasses) == ["> App: title 132"]   # the last one, number 5
    glasses.tilt(-1)
    assert rows(glasses) == ["> App: title 133", "  App: title 132"]
    ok(glasses)


def test_a_malformed_answer_is_not_taken_for_the_list(glasses):
    glasses.open_app("notifications")
    glasses.call("notifications", "l:0\n137|App: no total")
    glasses.call("notifications", listing(0, 2, [137, 136]))
    assert rows(glasses) == ["> App: title 137", "  App: title 136"]
    ok(glasses)


def test_the_empty_list_screen(glasses):
    glasses.open_app("notifications")
    glasses.call("notifications", "l:0:0")
    glasses.screenshot("notifications-empty")
    glasses.clear_sent()
    glasses.advance(10)
    assert not glasses.sent(NOTICES_GET)         # an answer: nothing more
    ok(glasses)


def test_the_list_is_not_asked_again_while_held(glasses):
    opened(glasses, total=137)
    glasses.clear_sent()
    glasses.advance(20)
    for _ in range(4):
        glasses.tilt(1)
    assert not glasses.sent(NOTICES_GET)
    ok(glasses)


def test_a_scroll_request_is_asked_again_after_five_seconds(glasses):
    opened(glasses, total=137)
    for _ in range(10):
        glasses.tilt(1)
    glasses.clear_sent()
    glasses.advance(5.5)
    assert asked(glasses) == [(LIST, 4)]
    assert rows(glasses)[-1] == "> .."
    ok(glasses)


def scroll(g, n, total=137):
    """n tilts down, the phone answering every ask for more as it comes,
    ten from where asked (the highest id the newest, 137 down)."""
    for _ in range(n):
        g.clear_sent()
        g.tilt(1)
        for op, start in asked(g):
            ids = [137 - k for k in range(start, min(start + 10, total))]
            g.call("notifications", listing(start, total, ids))


def test_back_above_the_window_it_asks_from_two_above(glasses):
    opened(glasses, total=137)
    scroll(glasses, 20)                          # number 20, rows 16..20
    assert rows(glasses)[-1] == "> App: title 117"
    glasses.clear_sent()
    while rows(glasses)[0] != "> ..":            # up to the first not held
        glasses.tilt(-1)
    (op, start), = asked(glasses)
    assert op == LIST
    assert rows(glasses)[0] == "> .."
    # the one under the cursor is two below where it asked from
    glasses.call("notifications",
                 listing(start, 137, [137 - n for n in range(start,
                                                            start + 10)]))
    assert rows(glasses)[0] == f"> App: title {137 - start - 2}"
    ok(glasses)


def test_the_end_of_a_long_list(glasses):
    opened(glasses, total=12)                    # 0..9 held of 12
    scroll(glasses, 11, total=12)
    glasses.tilt(1)                              # the oldest: stays
    assert rows(glasses) == [f"  App: title {137 - n}" for n in range(7, 11)] \
        + ["> App: title 126"]
    ok(glasses)


def test_a_list_with_more_than_its_total_shows_the_total(glasses):
    glasses.open_app("notifications")
    glasses.call("notifications", listing(0, 2, [137, 136, 135]))
    assert rows(glasses) == ["> App: title 137", "  App: title 136"]
    for _ in range(3):
        glasses.tilt(1)
    assert rows(glasses) == ["  App: title 137", "> App: title 136"]
    ok(glasses)


def test_a_notification_coming_in_covers_the_list_for_a_while(glasses):
    opened(glasses)
    glasses.notify("Mail", "From 137", "hello")
    assert "From 137" in glasses.screen_text()
    glasses.advance(6)
    assert rows(glasses)[0] == "> App: title 137"
    ok(glasses)


# ---------------------------------------------------------------- one open

def test_a_tap_opens_one_and_shows_it_all(glasses):
    opened(glasses)
    glasses.tilt(1)
    glasses.clear_sent()
    glasses.tap(1)
    assert rows(glasses) == ["loading.."]
    assert asked(glasses) == [(ONE, 136)]
    glasses.call("notifications",
                 "f:136\n15:30 App\nTitle 136\nfirst line\n\nsecond line")
    # empty lines are left out
    assert rows(glasses) == ["15:30 App", "Title 136", "first line",
                             "second line"]
    glasses.screenshot("notifications-open")
    ok(glasses)


def test_an_open_one_without_lines_says_empty(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.call("notifications", "f:137")
    assert rows(glasses) == ["(empty)"]
    ok(glasses)


def test_one_the_phone_no_longer_keeps_says_gone(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.call("notifications", "f:137\n(gone)")
    assert rows(glasses) == ["(gone)"]
    ok(glasses)


def test_an_answer_for_another_one_is_ignored(glasses):
    opened(glasses)
    glasses.tap(1)                               # 137
    glasses.call("notifications", "f:136\nnot this one")
    assert rows(glasses) == ["loading.."]
    glasses.call("notifications", listing(0, 3, [1, 2, 3]))   # not asked
    assert rows(glasses) == ["loading.."]
    ok(glasses)


def test_opening_asks_again_after_five_seconds(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.tap(1)                               # asked 0..1 s after it
    assert asked(glasses) == [(ONE, 137)]
    glasses.advance(3.5)
    assert asked(glasses) == [(ONE, 137)]
    glasses.advance(2)
    assert asked(glasses) == [(ONE, 137), (ONE, 137)]
    ok(glasses)


def test_tilts_page_a_long_one_by_four_lines(glasses):
    opened(glasses)
    glasses.tap(1)
    lines = [f"line {n}" for n in range(1, 14)]   # 13 lines
    glasses.call("notifications", "f:137\n" + "\n".join(lines))
    assert rows(glasses) == lines[0:5]
    glasses.tilt(1)
    assert rows(glasses) == lines[4:9]           # the last row stays on top
    glasses.tilt(1)
    assert rows(glasses) == lines[8:13]
    glasses.tilt(1)
    assert rows(glasses) == lines[8:13]          # the end
    glasses.tilt(-1)
    assert rows(glasses) == lines[4:9]
    glasses.tilt(-1)
    glasses.tilt(-1)
    assert rows(glasses) == lines[0:5]           # the start
    ok(glasses)


def test_tilts_do_nothing_while_it_loads(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.tilt(1)
    assert rows(glasses) == ["loading.."]
    glasses.call("notifications", "f:137\nall of it")
    assert rows(glasses) == ["all of it"]
    ok(glasses)


def test_a_tap_closes_it_with_the_cursor_where_it_was(glasses):
    opened(glasses)
    glasses.tilt(1)
    glasses.tilt(1)
    glasses.tap(1)
    glasses.call("notifications", "f:135\nthe third")
    glasses.clear_sent()
    glasses.tap(1)
    assert rows(glasses)[2] == "> App: title 135"
    assert not glasses.sent(NOTICES_GET)         # the list is still held
    ok(glasses)


def test_a_double_tap_closes_it_too(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.call("notifications", "f:137\nthe newest")
    glasses.clear_sent()
    glasses.tap(2)
    assert rows(glasses)[0] == "> App: title 137"
    assert not glasses.sent(APP_STOP)            # still in Notifications
    ok(glasses)


def test_closed_while_loading_a_late_answer_is_ignored(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.tap(1)                               # back before the answer
    glasses.call("notifications", "f:137\ntoo late")
    assert rows(glasses)[0] == "> App: title 137"
    ok(glasses)


def test_a_short_one_does_not_page(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.call("notifications", "f:137\none\ntwo\nthree")
    glasses.tilt(1)
    assert rows(glasses) == ["one", "two", "three"]
    glasses.tilt(-1)
    assert rows(glasses) == ["one", "two", "three"]
    ok(glasses)


def test_reopened_it_starts_from_the_top(glasses):
    opened(glasses)
    glasses.tap(1)
    lines = [f"line {n}" for n in range(1, 14)]
    glasses.call("notifications", "f:137\n" + "\n".join(lines))
    glasses.tilt(1)
    glasses.tap(1)                               # back to the list
    glasses.clear_sent()
    glasses.tap(1)                               # the same one again
    assert rows(glasses) == ["loading.."]
    assert asked(glasses) == [(ONE, 137)]        # not kept: asked anew
    glasses.call("notifications", "f:137\n" + "\n".join(lines))
    assert rows(glasses) == lines[0:5]
    ok(glasses)


def test_opened_while_the_list_was_asked_for_more(glasses):
    opened(glasses, total=137)
    for _ in range(10):
        glasses.tilt(1)                          # asks from 4
    glasses.tilt(-1)                             # 9, held
    glasses.clear_sent()
    glasses.tap(1)
    assert asked(glasses) == [(ONE, 128)]
    # the list's answer, late: no longer asked for
    glasses.call("notifications",
                 listing(4, 137, [137 - n for n in range(4, 14)]))
    assert rows(glasses) == ["loading.."]
    glasses.call("notifications", "f:128\nthe tenth")
    assert rows(glasses) == ["the tenth"]
    glasses.clear_sent()
    glasses.tap(1)                               # back: the rows still asked
    assert asked(glasses) == [(LIST, 4)]
    assert rows(glasses)[3] == "> App: title 128"
    ok(glasses)


# ---------------------------------------------------------------- leaving

def test_a_double_tap_in_the_list_leaves_to_the_menu(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)      # nothing left running
    assert "Apps" in glasses.screen_text()
    assert "App: title 137" not in glasses.screen_text()
    ok(glasses)


def test_an_answer_after_leaving_is_dropped(glasses):
    glasses.open_app("notifications")
    glasses.tap(2)                               # left before the answer
    menu = glasses.screen_text()
    glasses.clear_sent()
    glasses.call("notifications", listing(0, 3, [137, 136, 135]))
    glasses.advance(1)
    assert glasses.screen_text() == menu
    assert not glasses.sent(APP_BACKGROUND)
    ok(glasses)


def test_opened_again_it_asks_afresh(glasses):
    opened(glasses)
    glasses.tilt(1)
    glasses.tap(2)
    ids = opened(glasses)                        # asks from 0 again
    assert rows(glasses)[0] == f"> App: title {ids[0]}"
    ok(glasses)


def test_left_alone_for_a_minute_it_closes(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.advance(55)
    assert not glasses.sent(APP_STOP)
    glasses.advance(10)
    assert glasses.sent(APP_STOP)
    assert "App: title 137" not in glasses.screen_text()
    ok(glasses)


# ---------------------------------------------------------------- no phone

def phone_gone(g):
    """Notifications opened, then the phone gone before it answered: the
    next ask, five seconds on, finds no link. Nothing comes from the phone
    without one, so no APP_OPEN either."""
    g.open_app("notifications")
    g.emu.connected = False
    g.clear_sent()
    g.advance(5.5)


def test_without_the_phone_it_says_no_phone(frame):
    phone_gone(frame)
    assert rows(frame) == ["no phone"]
    assert not frame.sent(NOTICES_GET)
    frame.screenshot("notifications-no-phone")
    ok(frame)


def test_a_tap_on_no_phone_tries_again_and_finds_none(frame):
    phone_gone(frame)
    frame.tap(1)
    frame.tilt(1)
    assert rows(frame) == ["no phone"]
    assert not frame.sent(NOTICES_GET)
    ok(frame)


def test_with_the_phone_back_it_asks(frame):
    phone_gone(frame)
    frame.emu.connected = True
    frame.advance(1.5)
    assert asked(frame) == [(LIST, 0)]
    frame.call("notifications", listing(0, 1, [137]))
    assert rows(frame) == ["> App: title 137"]
    ok(frame)


def test_with_the_phone_back_no_phone_goes_at_once(frame):
    """Once asked again, the screen says it is loading, not that there is
    no phone."""
    phone_gone(frame)
    frame.emu.connected = True
    frame.advance(1.5)
    assert asked(frame) == [(LIST, 0)]
    assert rows(frame) == ["loading.."]
    ok(frame)


def test_one_opened_without_the_phone_comes_when_it_is_back(frame):
    opened(frame)
    frame.emu.connected = False
    frame.clear_sent()
    frame.tap(1)
    frame.advance(6)
    assert rows(frame) == ["loading.."]
    assert not frame.sent(NOTICES_GET)
    frame.emu.connected = True
    frame.advance(1)
    assert asked(frame) == [(ONE, 137)]
    frame.call("notifications", "f:137\nhere at last")
    assert rows(frame) == ["here at last"]
    ok(frame)


def test_with_the_list_held_a_lost_phone_takes_no_tap(frame):
    """The list was there, the phone went while asking for more and came
    back: the first tap on a row opens it."""
    opened(frame, total=137)
    frame.emu.connected = False
    for _ in range(10):
        frame.tilt(1)                            # asks: no phone
    frame.advance(1)
    assert rows(frame)[-1] == "> .."
    for _ in range(5):
        frame.tilt(-1)                           # 5..9, all held
    frame.emu.connected = True
    frame.advance(1)
    frame.clear_sent()
    frame.tap(1)
    assert asked(frame) == [(ONE, 132)]
    assert rows(frame) == ["loading.."]
    ok(frame)


def test_frame_only():
    assert has_module("frame", "notifications")
    assert not has_module("halo", "notifications")

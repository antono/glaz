"""Terminal (apps/term/term.lua) on the glasses that have it, Frame only: the
phone holds the SSH session and sends the rows that changed, one frame at
a time; the glasses draw them with frame.display.mono, ask for the
terminal when it opens, say each frame was taken, and close it when it is
left, or left alone (docs/PROTOCOL.md)."""
import struct

import pytest

from glasses import (APP_OPEN, APP_START, LUA_EVAL, MENU_OPEN, MODULE_CALL,
                     has_module)

pytestmark = pytest.mark.module("term")

TERM = 0x0C                       # glasses -> phone, term.lua
WANT = bytes([TERM, 1, 45, 12])   # start the terminal, 45x12
DONE = bytes([TERM, 0])           # stop it
SIZE = 28                         # mono's cell height
X, Y = 6, 3                       # the first cell, 1-based


def frame_msg(seq, rows, typed=False):
    """A frame as the phone sends it: rows is {row: text} or
    {row: (text, attrs)}, rows 1..12."""
    mask, body = 0, b""
    for r in sorted(rows):
        mask |= 0x8000 >> (r - 1)
        cell = rows[r]
        text, attrs = cell if isinstance(cell, tuple) else (cell, None)
        text = text.encode("latin-1")
        attrs = attrs if attrs is not None else bytes(len(text))
        body += bytes([len(text)]) + text + attrs
    return b"f" + struct.pack(">BBH", seq, 1 if typed else 0, mask) + body


def call(g, arg: bytes):
    """MODULE_CALL 'term' with bytes as they are, not UTF-8 encoded."""
    g.send(MODULE_CALL, b"term\n" + arg)


def term_sent(g):
    return g.sent(TERM)


def mono_rows(g):
    """The rows mono drew: {y: text}."""
    return {t.y: t.text for t in g.texts() if getattr(t, "mono", False)}


def opened(g):
    g.clear_sent()
    g.open_app("term")
    return g


# ---------------------------------------------------------------- devices

def test_only_frame_has_it():
    assert has_module("frame", "term")
    assert not has_module("halo", "term")


def test_halo_does_not_open_it(halo):
    halo.clear_sent()
    halo.send(APP_OPEN, "term\n")
    halo.advance(1)
    call(halo, frame_msg(1, {1: "$"}))
    assert not halo.sent(APP_START)
    assert not term_sent(halo)
    halo.assert_ok()


# ---------------------------------------------------------------- opening

def test_opens_waiting_for_the_phone_and_asks_for_the_terminal(glasses):
    opened(glasses)
    assert glasses.sent(APP_START)
    assert term_sent(glasses) == [WANT]
    text = glasses.screen_text()
    assert "waiting for the phone" in text
    assert "Terminal" not in text                 # fullscreen: no top bar
    glasses.screenshot("term-waiting")
    glasses.assert_ok()


def test_asks_again_until_the_phone_answers(glasses):
    opened(glasses)
    glasses.advance(10)
    asks = term_sent(glasses)
    assert len(asks) >= 3 and set(asks) == {WANT}
    call(glasses, frame_msg(1, {1: "$"}))
    glasses.clear_sent()
    glasses.advance(10)
    assert WANT not in term_sent(glasses)
    glasses.assert_ok()


def test_asks_every_three_seconds(glasses):
    opened(glasses)
    assert term_sent(glasses) == [WANT]
    glasses.advance(2)                            # not yet ASK_AGAIN
    assert term_sent(glasses) == [WANT]
    glasses.advance(2)
    assert term_sent(glasses) == [WANT, WANT]
    glasses.assert_ok()


def test_a_status_is_an_answer_too(glasses):
    opened(glasses)
    call(glasses, b"sconnecting to 10.0.0.137")
    glasses.clear_sent()
    glasses.advance(10)
    assert not term_sent(glasses)                 # no more asking
    assert "connecting to 10.0.0.137" in glasses.screen_text()
    glasses.assert_ok()


# ---------------------------------------------------------------- frames

def test_a_frame_is_drawn_row_by_row_and_taken(glasses):
    opened(glasses)
    call(glasses, frame_msg(137, {1: "user@host:~$ ls", 3: "notes.txt"}))
    rows = mono_rows(glasses)
    assert rows[Y] == "user@host:~$ ls"
    assert rows[Y + 2 * SIZE] == "notes.txt"
    assert len(rows) == 2
    assert all(t.x == X for t in glasses.texts() if t.mono)
    assert "waiting for the phone" not in glasses.screen_text()
    assert bytes([TERM, 2, 137]) in term_sent(glasses)
    glasses.screenshot("term")
    glasses.assert_ok()


def test_only_the_rows_sent_change(glasses):
    opened(glasses)
    call(glasses, frame_msg(1, {1: "top", 2: "middle", 12: "bottom"}))
    call(glasses, frame_msg(2, {2: "changed"}))
    rows = mono_rows(glasses)
    assert rows == {Y: "top", Y + SIZE: "changed", Y + 11 * SIZE: "bottom"}
    assert bytes([TERM, 2, 2]) in term_sent(glasses)
    glasses.assert_ok()


def test_a_blank_row_is_cleared(glasses):
    opened(glasses)
    call(glasses, frame_msg(1, {1: "one", 2: "two"}))
    call(glasses, frame_msg(2, {2: " " * 45}))
    assert mono_rows(glasses) == {Y: "one"}
    glasses.assert_ok()


def test_a_whole_screen_in_one_frame(glasses):
    # 12 rows of 45 cells: over a kilobyte, in several Bluetooth writes
    rows = {r: chr(ord("A") + r - 1) * 45 for r in range(1, 13)}
    opened(glasses)
    call(glasses, frame_msg(137, rows))
    drawn = mono_rows(glasses)
    assert drawn == {Y + (r - 1) * SIZE: rows[r] for r in rows}
    assert bytes([TERM, 2, 137]) in term_sent(glasses)
    # the last cell of the last row is still inside the 640x340
    last = max(t.y for t in glasses.texts() if t.mono)
    assert last + SIZE - 1 <= 340 and X - 1 + 45 * SIZE // 2 <= 640
    glasses.screenshot("term-full")
    glasses.assert_ok()


def test_a_dim_attribute_on_spaces_still_clears(glasses):
    # attrs below 0x10 are foreground only: spaces show nothing
    opened(glasses)
    call(glasses, frame_msg(1, {1: "x", 2: ("  ", b"\x0f\x0f")}))
    assert mono_rows(glasses) == {Y: "x"}
    call(glasses, frame_msg(2, {2: ("  ", b"\x0f\x10")}))
    assert mono_rows(glasses) == {Y: "x", Y + SIZE: "  "}
    glasses.assert_ok()


def test_a_blank_row_with_a_background_is_kept(glasses):
    opened(glasses)
    call(glasses, frame_msg(1, {5: ("   ", b"\x20\x20\x20")}))
    assert mono_rows(glasses) == {Y + 4 * SIZE: "   "}
    assert glasses.lit() > 0                      # the background shows
    glasses.assert_ok()


def test_attributes_colour_the_cells(glasses):
    opened(glasses)
    call(glasses, frame_msg(1, {1: "AB"}))
    plain = glasses.image().crop((X - 1, Y - 1, X - 1 + 28, Y - 1 + SIZE))
    call(glasses, frame_msg(2, {1: ("AB", b"\x02\x02")}))
    coloured = glasses.image().crop((X - 1, Y - 1, X - 1 + 28, Y - 1 + SIZE))
    assert mono_rows(glasses) == {Y: "AB"}
    assert set(plain.getdata()) != set(coloured.getdata())
    glasses.assert_ok()


def test_a_frame_without_rows_is_still_taken(glasses):
    opened(glasses)
    call(glasses, frame_msg(1, {1: "kept"}))
    call(glasses, frame_msg(7, {}))
    assert mono_rows(glasses) == {Y: "kept"}
    assert bytes([TERM, 2, 7]) in term_sent(glasses)
    glasses.assert_ok()


def test_a_short_frame_is_ignored(glasses):
    opened(glasses)
    glasses.clear_sent()
    call(glasses, b"f\x01\x00")
    assert not term_sent(glasses)
    assert not mono_rows(glasses)
    glasses.assert_ok()


def test_a_truncated_frame_does_not_break_it(glasses):
    opened(glasses)
    # rows 1 and 2 in the mask, but only row 1 and half of row 2 sent
    msg = frame_msg(9, {1: "whole", 2: "cut short"})[:-10]
    call(glasses, msg)
    assert mono_rows(glasses)[Y] == "whole"
    assert bytes([TERM, 2, 9]) in term_sent(glasses)
    glasses.assert_ok()


def test_a_status_from_the_phone_replaces_the_screen(glasses):
    opened(glasses)
    call(glasses, frame_msg(1, {1: "$ ssh"}))
    call(glasses, b"sconnection refused")
    assert not mono_rows(glasses)
    assert "connection refused" in glasses.screen_text()
    glasses.screenshot("term-status")
    # and a frame brings the terminal back
    call(glasses, frame_msg(2, {1: "$"}))
    assert mono_rows(glasses) == {Y: "$"}
    assert "connection refused" not in glasses.screen_text()
    glasses.assert_ok()


def test_a_status_stays_until_the_next_frame(glasses):
    opened(glasses)
    call(glasses, b"shost unreachable")
    glasses.advance(30)
    assert "host unreachable" in glasses.screen_text()
    assert not mono_rows(glasses)
    glasses.assert_ok()


def test_an_unknown_call_changes_nothing(glasses):
    opened(glasses)
    call(glasses, frame_msg(1, {1: "$"}))
    call(glasses, b"x137")
    assert mono_rows(glasses) == {Y: "$"}
    glasses.assert_ok()


# ---------------------------------------------------------------- leaving

def test_a_double_tap_leaves_and_tells_the_phone(glasses):
    opened(glasses)
    call(glasses, frame_msg(1, {1: "$"}))
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(MENU_OPEN)
    assert DONE in term_sent(glasses)
    assert not mono_rows(glasses)
    glasses.assert_ok()


def test_a_frame_after_it_closed_starts_nothing(glasses):
    opened(glasses)
    glasses.tap(2)
    glasses.clear_sent()
    call(glasses, frame_msg(1, {1: "late"}))
    glasses.advance(5)
    assert not term_sent(glasses)
    assert not mono_rows(glasses)
    glasses.assert_ok()


def test_opened_again_it_starts_afresh(glasses):
    opened(glasses)
    call(glasses, frame_msg(1, {1: "old"}))
    glasses.tap(2)
    opened(glasses)
    assert term_sent(glasses) == [WANT]
    assert not mono_rows(glasses)
    assert "waiting for the phone" in glasses.screen_text()
    glasses.assert_ok()


def test_opened_again_after_a_status_it_waits_again(glasses):
    opened(glasses)
    call(glasses, b"sauth failed")
    glasses.tap(2)
    opened(glasses)
    text = glasses.screen_text()
    assert "auth failed" not in text
    assert "waiting for the phone" in text
    glasses.assert_ok()


def test_a_tilt_does_not_leave_or_change_it(glasses):
    opened(glasses)
    call(glasses, frame_msg(1, {1: "$ uptime"}))
    glasses.clear_sent()
    glasses.tilt(+1)
    glasses.tilt(-1)
    assert mono_rows(glasses) == {Y: "$ uptime"}
    assert DONE not in term_sent(glasses)
    assert not glasses.sent(MENU_OPEN)
    glasses.assert_ok()


def test_without_the_phone_it_closes_after_a_minute(glasses):
    opened(glasses)
    glasses.advance(55)
    assert "waiting for the phone" in glasses.screen_text()
    glasses.advance(10)                           # past APP_TIMEOUT
    assert "waiting for the phone" not in glasses.screen_text()
    assert DONE in term_sent(glasses)
    glasses.assert_ok()


def test_frames_alone_keep_it_open_for_ten_minutes_not_more(glasses):
    opened(glasses)
    for seq in range(1, 30):                      # top, redrawing itself
        call(glasses, frame_msg(seq, {1: f"load {seq}"}))
        glasses.advance(30)
        if seq * 30 < 590:
            assert mono_rows(glasses), seq
    assert "load" not in glasses.screen_text()
    assert DONE in term_sent(glasses)
    assert glasses.sent(MENU_OPEN)                # back in the menu
    glasses.assert_ok()


def test_typing_keeps_it_open(glasses):
    opened(glasses)
    for seq in range(1, 30):
        call(glasses, frame_msg(seq, {1: f"typed {seq}"}, typed=True))
        glasses.advance(30)
    assert mono_rows(glasses) == {Y: "typed 29"}
    glasses.assert_ok()


def test_typing_restarts_the_ten_minutes(glasses):
    opened(glasses)
    t = 0
    for seq in range(1, 40):                      # a frame every 30 s
        call(glasses, frame_msg(seq, {1: f"line {seq}"}, typed=(seq == 10)))
        glasses.advance(30)
        t += 30
        if t < 270 + 590:                         # typed at 270 s
            assert mono_rows(glasses), t
    assert not mono_rows(glasses)
    assert DONE in term_sent(glasses)
    glasses.assert_ok()


def test_taps_keep_it_open(glasses):
    opened(glasses)
    for seq in range(1, 30):
        call(glasses, frame_msg(seq, {1: f"tapped {seq}"}))
        glasses.tap(1, settle=0)
        glasses.advance(30)
    assert mono_rows(glasses) == {Y: "tapped 29"}
    glasses.assert_ok()


def test_the_phones_remote_tap_keeps_it_open(glasses):
    opened(glasses)
    for seq in range(1, 30):
        call(glasses, frame_msg(seq, {1: f"remote {seq}"}))
        glasses.remote(1, 1)                      # one tap, from the phone
        glasses.advance(30)
    assert mono_rows(glasses) == {Y: "remote 29"}
    glasses.assert_ok()


# ---------------------------------------------------------------- the link

def test_without_a_link_it_says_so_and_asks_again_when_back(frame):
    opened(frame)
    call(frame, frame_msg(1, {1: "$"}))
    frame.emu.connected = False
    frame.advance(2)
    assert "no phone" in frame.screen_text()
    assert not mono_rows(frame)
    frame.screenshot("term-no-phone")
    frame.emu.connected = True
    frame.clear_sent()
    frame.advance(2)
    assert term_sent(frame) == [WANT]
    assert "waiting for the phone" in frame.screen_text()
    frame.assert_ok()


def test_without_glaz_firmware_it_says_so(frame):
    frame.send(LUA_EVAL, b"\x01frame.display.mono = nil")
    opened(frame)
    assert "needs the glaz" in frame.screen_text()
    assert "firmware" in frame.screen_text()
    assert not term_sent(frame)
    frame.screenshot("term-no-firmware")
    call(frame, frame_msg(1, {1: "$"}))          # nothing to draw it with
    frame.advance(2)
    assert not mono_rows(frame)
    assert "needs the glaz" in frame.screen_text()
    frame.clear_sent()
    frame.tap(2)
    assert DONE not in term_sent(frame)           # it never asked
    frame.assert_ok()

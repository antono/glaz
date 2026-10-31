"""Flipper (apps/flipper/flipper.lua): a Flipper Zero's screen, as the phone
passes it on (docs/FLIPPER.md). The module asks the phone for the screen
(FLIPPER [1]), asks again while the phone is silent, draws the rows of
each frame four times the size in orange inside a brown frame, answers
every frame with its seq (FLIPPER [2, seq]), shows the phone's words
instead of a picture, and says it is done (FLIPPER [0]) when it closes:
by a double tap, after a minute without input, or after five minutes
without a tap however many frames come. Frame only: it has no Halo part.
"""
import pytest

from glasses import APP_START, MODULE_CALL, MENU_OPEN

pytestmark = pytest.mark.module("flipper")

FLIPPER = 0x0B
WANT, DONE = bytes([FLIPPER, 1]), bytes([FLIPPER, 0])

X, Y, SCALE = 65, 43, 4                 # the picture, 1-based, 512x256
ORANGE, BROWN = 7, 6                    # palette indices
BOX_X, BOX_Y = X - 14, Y - 14           # the frame round it, 2 px thick


def frame_msg(seq: int, rows: dict[int, bytes]) -> bytes:
    """'f' seq mask rows: a bit a row in the mask, row 0 the high bit of
    the first byte, then 32 nibble bytes for each row whose bit is set."""
    mask = bytearray(8)
    body = b""
    for r in sorted(rows):
        mask[r >> 3] |= 0x80 >> (r & 7)
        body += rows[r]
    return b"f" + bytes([seq]) + bytes(mask) + body


def nibbles(pixels: str) -> bytes:
    """A row of 128 pixels, '#' set and anything else clear, as nibbles."""
    pixels = pixels.ljust(128, ".")
    return bytes(
        sum(8 >> b for b in range(4) if pixels[4 * i + b] == "#")
        for i in range(32))


FULL = bytes([15] * 32)                 # a row all set
BLANK = bytes(32)


def flipper(glasses, payload: bytes):
    """The phone calls the module (MODULE_CALL 'flipper'), binary and all."""
    glasses.send(MODULE_CALL, b"flipper\n" + payload)
    glasses.advance(0.2)


def pixel(glasses, x: int, y: int) -> int:
    """The palette index shown at 1-based (x, y)."""
    return glasses.emu.display.front[(y - 1) * 640 + (x - 1)]


def flipper_pixel(glasses, col: int, row: int) -> int:
    """The palette index of the Flipper's pixel (col, row), its first
    screen pixel of the 4x4 it is drawn as."""
    return pixel(glasses, X + SCALE * col, Y + SCALE * row)


def orange(glasses) -> int:
    return glasses.emu.display.front.count(ORANGE)


def opened(glasses):
    glasses.clear_sent()
    glasses.open_app("flipper")
    return glasses


# ---------------------------------------------------------------- devices

def test_only_frame_has_it(tmp_path):
    from sandbox import modules
    assert "flipper" in modules("frame")
    assert "flipper" not in modules("halo")


# ---------------------------------------------------------------- opening

def test_opens_full_screen_and_asks_the_phone(glasses):
    opened(glasses)
    assert glasses.sent(APP_START)
    assert glasses.sent(FLIPPER) == [WANT]
    text = glasses.screen_text()
    assert "waiting for the phone" in text
    assert "Flipper" not in text                 # no top bar, no crumbs
    glasses.screenshot("flipper-waiting")
    glasses.assert_ok()


def test_draws_the_brown_frame_before_any_picture(glasses):
    opened(glasses)
    assert orange(glasses) == 0
    # the corners and the middle of each side
    for x, y in ((BOX_X, BOX_Y), (BOX_X + 539, BOX_Y),
                 (BOX_X, BOX_Y + 283), (BOX_X + 539, BOX_Y + 283),
                 (BOX_X + 270, BOX_Y + 1), (BOX_X + 1, BOX_Y + 140)):
        assert pixel(glasses, x, y) == BROWN, (x, y)
    # two pixels thick, and nothing just inside or outside it
    assert pixel(glasses, BOX_X + 270, BOX_Y + 2) != BROWN
    assert pixel(glasses, BOX_X + 2, BOX_Y + 140) != BROWN
    assert pixel(glasses, BOX_X - 1, BOX_Y + 140) != BROWN
    assert pixel(glasses, BOX_X + 540, BOX_Y + 140) != BROWN
    glasses.assert_ok()


def test_asks_again_every_few_seconds_while_the_phone_is_silent(glasses):
    opened(glasses)
    glasses.advance(10)
    wants = glasses.sent(FLIPPER)
    assert wants.count(WANT) >= 3                # at 0, then about every 3 s
    assert set(wants) == {WANT}
    glasses.assert_ok()


def test_asks_again_only_after_three_seconds(glasses):
    opened(glasses)
    assert glasses.sent(FLIPPER) == [WANT]
    glasses.advance(2.5)
    assert glasses.sent(FLIPPER) == [WANT]       # not yet
    glasses.advance(1.5)                         # past 3 s since the first
    assert glasses.sent(FLIPPER) == [WANT, WANT]
    glasses.assert_ok()


def test_a_frame_stops_the_asking_too(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL}))
    glasses.clear_sent()
    glasses.advance(10)
    assert glasses.sent(FLIPPER) == []
    assert flipper_pixel(glasses, 0, 0) == ORANGE  # and the picture stays
    glasses.assert_ok()


def test_stops_asking_once_the_phone_answers(glasses):
    opened(glasses)
    flipper(glasses, b"spair the Flipper")
    glasses.clear_sent()
    glasses.advance(10)
    assert WANT not in glasses.sent(FLIPPER)
    glasses.assert_ok()


# ---------------------------------------------------------------- frames

def test_a_frame_is_drawn_four_times_the_size(glasses):
    opened(glasses)
    # a dot at (0, 0), a bar on row 37, the last pixel of the last row
    flipper(glasses, frame_msg(1, {
        0: nibbles("#"),
        37: nibbles("." * 13 + "#" * 7),
        63: nibbles("." * 127 + "#"),
    }))
    assert flipper_pixel(glasses, 0, 0) == ORANGE
    assert pixel(glasses, X + 3, Y + 3) == ORANGE          # all of its 4x4
    assert pixel(glasses, X + 4, Y) != ORANGE              # not its neighbour
    assert pixel(glasses, X, Y + 4) != ORANGE
    for col in range(13, 20):
        assert flipper_pixel(glasses, col, 37) == ORANGE
    assert flipper_pixel(glasses, 12, 37) != ORANGE
    assert flipper_pixel(glasses, 20, 37) != ORANGE
    assert pixel(glasses, X + 511, Y + 255) == ORANGE      # 576, 298
    # 1 + 7 + 1 Flipper pixels, 16 screen pixels each
    assert orange(glasses) == 9 * 16
    assert glasses.screen_text() == ""           # the picture, no words
    glasses.assert_ok()


def test_a_frame_is_answered_with_its_seq(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(137, {5: FULL}))
    assert bytes([FLIPPER, 2, 137]) in glasses.sent(FLIPPER)
    flipper(glasses, frame_msg(0, {}))
    assert glasses.sent(FLIPPER)[-1] == bytes([FLIPPER, 2, 0])
    flipper(glasses, frame_msg(255, {}))
    assert glasses.sent(FLIPPER)[-1] == bytes([FLIPPER, 2, 255])
    # an empty frame changes no row
    assert flipper_pixel(glasses, 0, 5) == ORANGE
    glasses.assert_ok()


def test_a_whole_screen_in_one_frame(glasses):
    opened(glasses)
    # a checkerboard of 4x4 squares, every row sent
    rows = {r: nibbles(("####...." if r // 4 % 2 else "....####") * 16)
            for r in range(64)}
    flipper(glasses, frame_msg(7, rows))
    assert bytes([FLIPPER, 2, 7]) in glasses.sent(FLIPPER)
    assert orange(glasses) == 128 * 64 // 2 * 16
    assert flipper_pixel(glasses, 4, 0) == ORANGE
    assert flipper_pixel(glasses, 0, 0) != ORANGE
    assert flipper_pixel(glasses, 0, 4) == ORANGE
    glasses.screenshot("flipper")
    glasses.assert_ok()


def test_a_frame_changes_only_the_rows_it_sends(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {10: FULL, 20: FULL}))
    assert orange(glasses) == 2 * 128 * 16
    # row 10 cleared, row 30 drawn, row 20 left as it was
    flipper(glasses, frame_msg(2, {10: BLANK, 30: nibbles("#")}))
    assert flipper_pixel(glasses, 0, 10) != ORANGE
    assert flipper_pixel(glasses, 127, 20) == ORANGE
    assert flipper_pixel(glasses, 0, 30) == ORANGE
    assert orange(glasses) == (128 + 1) * 16
    glasses.assert_ok()


def test_a_short_frame_is_ignored(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {3: FULL}))
    glasses.clear_sent()
    flipper(glasses, b"f\x02\x00\x00")           # no whole mask
    assert glasses.sent(FLIPPER) == []           # not taken
    assert flipper_pixel(glasses, 0, 3) == ORANGE
    glasses.assert_ok()


def test_a_short_frame_before_any_picture_keeps_the_words(glasses):
    opened(glasses)
    flipper(glasses, b"f\x01")
    assert glasses.sent(FLIPPER) == [WANT]       # no answer
    assert "waiting for the phone" in glasses.screen_text()
    assert orange(glasses) == 0
    glasses.assert_ok()


def test_a_cut_off_row_is_left_blank(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {2: FULL, 3: FULL}))
    # rows 2 and 3 in the mask, but only 32 + 13 bytes after it
    msg = frame_msg(2, {2: nibbles("#"), 3: FULL})[:10 + 32 + 13]
    flipper(glasses, msg)
    assert bytes([FLIPPER, 2, 2]) in glasses.sent(FLIPPER)
    assert flipper_pixel(glasses, 0, 2) == ORANGE
    assert flipper_pixel(glasses, 1, 2) != ORANGE
    assert all(flipper_pixel(glasses, c, 3) != ORANGE for c in range(128))
    glasses.assert_ok()


def test_a_bad_nibble_draws_the_row_short_and_no_further(glasses):
    opened(glasses)
    # a byte above 15 is not in the widening table, so string.gsub keeps
    # it as it is: one byte, eight pixels, where 64 were due. The row's
    # four copies come out shorter, all inside the row's four pixel rows.
    row = bytes([15] * 31 + [0x37])              # 0x37: five bits set
    flipper(glasses, frame_msg(1, {20: row}))
    assert bytes([FLIPPER, 2, 1]) in glasses.sent(FLIPPER)
    assert orange(glasses) == 31 * 4 * 16 + 5 * SCALE
    top, bottom = Y + SCALE * 20, Y + SCALE * 21
    front = glasses.emu.display.front
    lit_rows = {i // 640 + 1 for i, v in enumerate(front) if v == ORANGE}
    assert lit_rows <= set(range(top, bottom))
    glasses.assert_ok()


# ---------------------------------------------------------------- words

def test_the_phones_words_replace_the_picture(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL}))
    flipper(glasses, b"sno Flipper found")
    assert "no Flipper found" in glasses.screen_text()
    assert orange(glasses) == 0
    glasses.advance(3)                           # the tick keeps them
    assert "no Flipper found" in glasses.screen_text()
    glasses.screenshot("flipper-status")
    # and the next frame replaces the words
    flipper(glasses, frame_msg(2, {1: FULL}))
    assert "no Flipper found" not in glasses.screen_text()
    assert flipper_pixel(glasses, 0, 1) == ORANGE
    assert flipper_pixel(glasses, 0, 0) != ORANGE  # gone with the words
    glasses.assert_ok()


def test_empty_words_leave_the_screen_blank(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL}))
    flipper(glasses, b"s")
    glasses.advance(1)
    assert glasses.screen_text() == ""
    assert orange(glasses) == 0
    assert glasses.emu.display.front.count(BROWN) > 0  # the frame stays
    glasses.assert_ok()


def test_the_words_are_gone_when_it_opens_again(glasses):
    opened(glasses)
    flipper(glasses, b"spair the Flipper")
    glasses.tap(2)
    opened(glasses)
    assert "pair the Flipper" not in glasses.screen_text()
    assert "waiting for the phone" in glasses.screen_text()
    assert glasses.sent(FLIPPER) == [WANT]       # and it asks again
    glasses.assert_ok()


def test_a_tilt_leaves_the_picture_as_it_is(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL}))
    glasses.clear_sent()
    glasses.tilt(1)
    glasses.tilt(-1)
    glasses.remote(2, 1)                         # the phone's remote, too
    assert glasses.sent(FLIPPER) == []
    assert orange(glasses) == 128 * 16
    glasses.assert_ok()


def test_an_unknown_call_changes_nothing(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL}))
    glasses.clear_sent()
    flipper(glasses, b"x137")
    assert glasses.sent(FLIPPER) == []
    assert flipper_pixel(glasses, 0, 0) == ORANGE
    glasses.assert_ok()


# ---------------------------------------------------------------- closing

def test_a_double_tap_closes_it_and_tells_the_phone(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL}))
    glasses.clear_sent()
    glasses.tap(2)
    assert DONE in glasses.sent(FLIPPER)
    assert orange(glasses) == 0
    glasses.assert_ok()


def test_a_frame_after_it_closed_is_not_taken(glasses):
    opened(glasses)
    glasses.tap(2)
    glasses.clear_sent()
    flipper(glasses, frame_msg(9, {0: FULL}))
    glasses.advance(5)
    assert glasses.sent(FLIPPER) == []           # no seq, no new WANT
    assert orange(glasses) == 0
    glasses.assert_ok()


def test_closes_after_a_minute_without_frames_or_taps(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL}))
    glasses.clear_sent()
    glasses.advance(55)
    assert DONE not in glasses.sent(FLIPPER)
    glasses.advance(10)                          # past APP_TIMEOUT
    assert DONE in glasses.sent(FLIPPER)
    assert orange(glasses) == 0
    glasses.assert_ok()


def test_a_tap_keeps_it_open(glasses):
    opened(glasses)
    for _ in range(3):
        glasses.advance(40)
        glasses.tap(1)
    assert DONE not in glasses.sent(FLIPPER)
    assert "waiting for the phone" in glasses.screen_text()
    glasses.assert_ok()


def test_frames_alone_keep_it_open_five_minutes_and_no_more(glasses):
    # the Flipper's desktop animates by itself: without a tap it must
    # still close, or the glasses would never sleep
    opened(glasses)
    for seq in range(9):                         # 9 x 30 s = 270 s
        flipper(glasses, frame_msg(seq, {seq: FULL}))
        glasses.advance(30)
    assert DONE not in glasses.sent(FLIPPER)
    for seq in range(9, 12):                     # past 300 s
        flipper(glasses, frame_msg(seq, {seq: FULL}))
        glasses.advance(30)
    assert DONE in glasses.sent(FLIPPER)
    assert glasses.sent(MENU_OPEN)               # back to the menu
    assert orange(glasses) == 0
    glasses.assert_ok()


def test_a_tap_resets_the_five_minutes(glasses):
    opened(glasses)
    for seq in range(16):                        # 16 x 30 s = 480 s
        if seq == 8:
            glasses.tap(1)                       # at 240 s
        flipper(glasses, frame_msg(seq, {seq: FULL}))
        glasses.advance(30)
    assert DONE not in glasses.sent(FLIPPER)
    glasses.assert_ok()


def test_a_tap_from_the_phones_remote_resets_the_five_minutes(glasses):
    opened(glasses)
    for seq in range(16):                        # 16 x 30 s = 480 s
        if seq == 8:
            glasses.remote(1, 1)                 # one tap, at 240 s
        flipper(glasses, frame_msg(seq, {seq: FULL}))
        glasses.advance(30)
    assert DONE not in glasses.sent(FLIPPER)
    glasses.assert_ok()


def test_a_double_tap_from_the_phones_remote_closes_it(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL}))
    glasses.clear_sent()
    glasses.remote(1, 2)
    assert glasses.sent(FLIPPER) == [DONE]
    assert glasses.sent(MENU_OPEN)
    assert orange(glasses) == 0
    glasses.assert_ok()


def test_a_triple_tap_puts_it_away_for_sleep(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL}))
    glasses.clear_sent()
    glasses.tap(3)
    glasses.advance(2)
    assert DONE in glasses.sent(FLIPPER)
    assert orange(glasses) == 0
    glasses.assert_ok()


def test_opened_again_it_asks_again_from_a_clean_screen(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL}))
    glasses.tap(2)
    opened(glasses)
    assert glasses.sent(FLIPPER) == [WANT]
    assert orange(glasses) == 0
    assert "waiting for the phone" in glasses.screen_text()
    glasses.assert_ok()


# ---------------------------------------------------------------- the link

def test_without_the_phone_it_says_so_and_asks_when_it_is_back(frame):
    opened(frame)
    flipper(frame, frame_msg(1, {0: FULL}))
    frame.emu.connected = False
    frame.advance(2)
    assert "no phone" in frame.screen_text()
    assert orange(frame) == 0                    # the old picture is gone
    frame.screenshot("flipper-no-phone")
    frame.clear_sent()
    frame.emu.connected = True
    frame.advance(2)
    assert frame.sent(FLIPPER) == [WANT]         # asked at once, not heard
    assert "waiting for the phone" in frame.screen_text()
    frame.assert_ok()


def test_closed_without_the_phone_it_says_nothing(frame):
    opened(frame)
    frame.emu.connected = False
    frame.advance(2)
    frame.tap(2)
    frame.emu.connected = True
    assert frame.sent(FLIPPER) == [WANT]         # the first, and no DONE
    frame.assert_ok()


class Busy:
    """emu.connected for a link busy n sends, then free: Bluetooth's send
    reads it once a try."""

    def __init__(self, n: int):
        self.left = n

    def __bool__(self):
        self.left -= 1
        return self.left < 0


def call_while_busy(frame, payload: bytes, busy: int):
    """MODULE_CALL in one write, then the link busy for the answer."""
    body = b"flipper\n" + payload
    frame.emu.receive(bytes([MODULE_CALL, len(body) >> 8, len(body) & 0xFF])
                      + body)
    frame.emu.connected = Busy(busy)
    frame.advance(0.2)
    frame.emu.connected = True


def test_the_answer_is_retried_while_the_link_is_busy(frame):
    opened(frame)
    flipper(frame, b"sready")                    # heard: no more WANT
    frame.clear_sent()
    call_while_busy(frame, frame_msg(137, {0: FULL}), busy=5)
    assert frame.sent(FLIPPER) == [bytes([FLIPPER, 2, 137])]
    assert flipper_pixel(frame, 0, 0) == ORANGE
    frame.assert_ok()


def test_an_answer_the_link_never_takes_is_dropped_quietly(frame):
    opened(frame)
    flipper(frame, b"sready")
    frame.clear_sent()
    call_while_busy(frame, frame_msg(137, {0: FULL}), busy=1000)
    assert frame.sent(FLIPPER) == []             # 20 tries, then given up
    assert flipper_pixel(frame, 0, 0) == ORANGE  # drawn all the same
    # and the next frame goes as usual
    flipper(frame, frame_msg(138, {1: FULL}))
    assert frame.sent(FLIPPER) == [bytes([FLIPPER, 2, 138])]
    frame.assert_ok()


# ---------------------------------------------------------------- edges

def test_a_frame_of_just_a_mask_is_taken_one_byte_less_is_not(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL}))
    glasses.clear_sent()
    flipper(glasses, b"f\x89" + bytes(7))        # 9 bytes: no whole mask
    assert glasses.sent(FLIPPER) == []
    flipper(glasses, b"f\x89" + bytes(8))        # 10: a frame of no rows
    assert glasses.sent(FLIPPER) == [bytes([FLIPPER, 2, 0x89])]
    assert flipper_pixel(glasses, 0, 0) == ORANGE  # nothing changed
    glasses.assert_ok()


def test_a_mask_of_every_row_with_no_rows_after_it_clears_the_picture(glasses):
    # the rows were lost on the way: each is cut off, so each is blank
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL, 63: FULL}))
    flipper(glasses, b"f\x02" + b"\xff" * 8)
    assert bytes([FLIPPER, 2, 2]) in glasses.sent(FLIPPER)
    assert orange(glasses) == 0
    assert glasses.screen_text() == ""           # a blank picture, no words
    glasses.assert_ok()


def test_bytes_past_the_last_row_are_ignored(glasses):
    opened(glasses)
    flipper(glasses, frame_msg(1, {5: nibbles("#")}) + FULL * 3)
    assert bytes([FLIPPER, 2, 1]) in glasses.sent(FLIPPER)
    assert orange(glasses) == 16                 # the one pixel of row 5
    glasses.assert_ok()


def test_the_same_frame_twice_is_answered_twice_and_drawn_once(glasses):
    # the phone, without an answer, sends the frame again
    opened(glasses)
    msg = frame_msg(137, {0: FULL, 1: nibbles("#")})
    flipper(glasses, msg)
    flipper(glasses, msg)
    taken = bytes([FLIPPER, 2, 137])
    assert glasses.sent(FLIPPER).count(taken) == 2
    assert orange(glasses) == (128 + 1) * 16
    glasses.assert_ok()


def test_an_older_seq_is_taken_as_any(glasses):
    # frames are not put in order here: the phone sends one at a time
    opened(glasses)
    flipper(glasses, frame_msg(9, {0: FULL}))
    flipper(glasses, frame_msg(8, {0: BLANK, 1: FULL}))
    assert glasses.sent(FLIPPER)[-1] == bytes([FLIPPER, 2, 8])
    assert flipper_pixel(glasses, 0, 0) != ORANGE
    assert flipper_pixel(glasses, 0, 1) == ORANGE
    glasses.assert_ok()


def test_words_after_it_closed_are_not_shown_when_it_opens_again(glasses):
    opened(glasses)
    glasses.tap(2)
    glasses.clear_sent()
    flipper(glasses, b"sno Flipper found")
    glasses.advance(5)
    assert glasses.sent(FLIPPER) == []           # not started for it
    assert "no Flipper found" not in glasses.screen_text()
    opened(glasses)
    assert "waiting for the phone" in glasses.screen_text()
    glasses.assert_ok()


def test_frames_under_a_notification_are_still_answered(glasses):
    # the phone waits for each seq: unanswered, the stream would stall
    opened(glasses)
    flipper(glasses, frame_msg(1, {0: FULL}))
    glasses.notify("Chat", "Hi", "137 apples")
    assert "137 apples" in glasses.screen_text()
    for seq in (2, 3):
        flipper(glasses, frame_msg(seq, {seq: FULL}))
        assert glasses.sent(FLIPPER)[-1] == bytes([FLIPPER, 2, seq])
    glasses.tap(1)                               # the notification away
    assert "137 apples" not in glasses.screen_text()
    assert orange(glasses) == 3 * 128 * 16       # every row it took since
    assert not glasses.sent(FLIPPER).count(DONE)  # the tap did not close it
    glasses.assert_ok()


def test_long_words_from_the_phone_are_drawn_without_trouble(glasses):
    opened(glasses)
    flipper(glasses, b"s" + b"137 " * 40)
    glasses.advance(1)
    assert "137" in glasses.screen_text()
    glasses.assert_ok()


def test_halo_ignores_a_call_for_it(halo):
    halo.advance(5)
    halo.clear_sent()
    before = halo.screen_text()
    halo.send(MODULE_CALL, b"flipper\n" + frame_msg(137, {0: FULL}))
    halo.advance(1)
    assert halo.sent(FLIPPER) == []
    assert not halo.sent(APP_START)
    assert halo.screen_text() == before
    halo.assert_ok()

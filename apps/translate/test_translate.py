"""Translate (apps/translate/translate.lua), Frame only: the chooser of Voice and
Photo, the mode kept as a pref; Voice streams the microphone with
REC_START's fourth byte 2, a tap pauses and listens again; Photo sends a
photo with PHOTO_FROM 255; the log window the phone sends (w:, n:, s:,
x:), following its end and scrolling back with TRANSLATE requests; the
link lost and back, the 30-minute pause, settings and bad payloads
(docs/PROTOCOL.md, "Translate").
"""
import struct

import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, LUA_EVAL,
                     LUA_RESULT, has_module)

pytestmark = pytest.mark.module("translate")

TRANSLATE, REC_START, AUDIO, AUDIO_END, REC_DROP = 0x0F, 0x1F, 0x05, 0x06, 0x10
PHOTO_FROM, CHUNK, END = 0x1A, 0x07, 0x08
PACKET = 242          # max_length() 243, less the code, made even
TOP_Y, ROW_H = 65, 55
STATUS_Y = TOP_Y + ROW_H * 4
# Translate, the camera library and glaz_photo take some 40 KB here, as
# source with its debug information and 64-bit pointers, and the photo
# finds no room; on Frame they are bytecode, 32-bit, and smaller
# (docs/TESTING.md, "Memory")
PHOTO_HEAP = pytest.mark.heap(16)


def asks(g) -> list[tuple]:
    """The TRANSLATE requests sent: (op, sess, from, count) each."""
    return [struct.unpack(">BBHB", m[1:]) for m in g.sent(TRANSLATE)]


def window(g, sess, start, total, f, lines=()):
    """The phone's w: answer or push, lines as 'K|text'."""
    g.call("translate", f"w:{sess}:{start}:{total}:{f}" +
           "".join("\n" + l for l in lines))
    g.advance(0.3)


def log(start, n, kind="T"):
    """n lines of the log from line number start."""
    return [f"{kind}|line {i}" for i in range(start, start + n)]


def status(g) -> str:
    rows = [t.text for t in g.texts() if t.y == STATUS_Y]
    return rows[-1] if rows else ""


def cursor_row(g) -> int:
    """The chooser's row with the '>' on it, 0 Voice, 1 Photo."""
    ys = [t.y for t in g.texts() if t.text == ">"]
    assert len(ys) == 1, g.texts()
    return (ys[0] - TOP_Y) // ROW_H


def voice(g):
    """Translate on screen, Voice picked."""
    g.open_app("translate")
    g.clear_sent()
    g.tap(1)


def photo_mode(g):
    g.open_app("translate")
    g.tilt(1)
    g.clear_sent()
    g.tap(1)


def lua(g, code: str) -> bytes:
    """Runs code in the app's globals, as the phone's Lua console does."""
    g.send(LUA_EVAL, b"\x89" + code.encode())
    g.advance(0.5)
    answers = [a for i, a in g.joined(LUA_RESULT) if i == 0x89]
    assert answers and answers[-1][:1] == b"+", answers
    return answers[-1]


def audio(g) -> bytes:
    return b"".join(m[1:] for m in g.sent(AUDIO))


def red_dot(g) -> bool:
    """The recording dot, red, in the top bar where the icon goes."""
    img = g.image()
    return any(r > 150 and gr < 100 and b < 100
               for x in range(370, 396) for y in range(0, 24)
               for r, gr, b in [img.getpixel((x, y))])


def photos(g) -> list[bytes]:
    out, jpeg = [], None
    for m in g.sent():
        if m[0] == PHOTO_FROM:
            jpeg = bytearray()
        elif m[0] == CHUNK and jpeg is not None:
            jpeg.extend(m[1:])
        elif m == bytes([END]) and jpeg is not None:
            out.append(bytes(jpeg))
            jpeg = None
    return out


def scrolled_back(g):
    """Voice with a log of 10 lines, scrolled back a screen: lines 3..6
    on screen, 0..7 held."""
    voice(g)
    window(g, 1, 6, 10, 1, log(6, 4))
    g.clear_sent()
    g.tilt(-1)
    assert asks(g) == [(1, 1, 0, 8)]
    window(g, 1, 0, 10, 0, log(0, 8))


# ---------------------------------------------------------------- where

def test_only_frame_has_it():
    assert has_module("frame", "translate")
    assert not has_module("halo", "translate")


def test_halo_ignores_the_phones_calls(halo):
    halo.clear_sent()
    halo.call("translate", "w:1:0:0:1")
    halo.advance(1)
    assert not halo.sent(TRANSLATE)
    assert not halo.sent(APP_BACKGROUND)
    halo.assert_ok()


# ---------------------------------------------------------------- chooser

def test_opens_on_the_chooser_asking_nothing(glasses):
    glasses.clear_sent()
    glasses.open_app("translate")
    assert glasses.sent(APP_START)
    text = glasses.screen_text()
    for s in ("Voice", "Photo", "en > ru", "tap = pick"):
        assert s in text
    assert cursor_row(glasses) == 0
    assert not glasses.sent(TRANSLATE)
    assert not glasses.sent(REC_START)
    assert not red_dot(glasses)
    glasses.screenshot("translate")
    glasses.assert_ok()


def test_the_chooser_shows_the_phones_languages(glasses):
    glasses.settings({"translate.from": "de", "translate.to": "uk"})
    glasses.open_app("translate")
    assert "de > uk" in glasses.screen_text()
    glasses.assert_ok()


def test_tilting_moves_the_cursor_round(glasses):
    glasses.open_app("translate")
    glasses.tilt(1)
    assert cursor_row(glasses) == 1
    glasses.tilt(1)
    assert cursor_row(glasses) == 0
    glasses.tilt(-1)
    assert cursor_row(glasses) == 1
    glasses.remote(2, 255)                       # the phone's remote
    assert cursor_row(glasses) == 0
    glasses.assert_ok()


def test_the_phone_is_not_heard_in_the_chooser(glasses):
    glasses.open_app("translate")
    before = glasses.screen_text()
    window(glasses, 1, 0, 1, 1, ["T|137"])
    glasses.call("translate", "s:downloading en>ru..")
    glasses.advance(0.5)
    assert glasses.screen_text() == before
    glasses.assert_ok()


def test_a_double_tap_in_the_chooser_leaves(glasses):
    glasses.open_app("translate")
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(TRANSLATE)           # nothing was open
    assert "Voice" not in glasses.screen_text()
    glasses.assert_ok()


def test_not_running_it_ignores_the_phone(glasses):
    glasses.tap(2)                               # the menu
    menu = glasses.screen_text()
    glasses.clear_sent()
    glasses.call("translate", "w:1:0:1:1\nT|137")
    glasses.advance(1)
    assert not glasses.sent(APP_BACKGROUND)
    assert not glasses.sent(TRANSLATE)
    assert glasses.screen_text() == menu
    glasses.assert_ok()


# ---------------------------------------------------------------- Voice

def test_voice_asks_for_the_tail_and_listens(glasses):
    voice(glasses)
    assert asks(glasses) == [(2, 0, 0, 4)]
    assert glasses.sent(REC_START) == [bytes([REC_START, 16, 8, 2])]
    order = [m[0] for m in glasses.sent() if m[0] in (TRANSLATE, REC_START)]
    assert order == [TRANSLATE, REC_START]
    assert "loading.." in glasses.screen_text()
    assert status(glasses) == "-  listening"
    assert red_dot(glasses)
    glasses.assert_ok()


def test_an_empty_log_says_it_listens(glasses):
    voice(glasses)
    window(glasses, 1, 0, 0, 1)
    assert "listening.." in glasses.screen_text()
    assert status(glasses) == "-  listening"
    glasses.screenshot("translate-listening")
    glasses.assert_ok()


def test_the_log_is_shown_in_its_colours(glasses):
    voice(glasses)
    window(glasses, 1, 0, 5, 1, ["I|en > ru 13:37", "S|good morning",
                                 "T|dobroe utro", "E|not translated: 137",
                                 "P|how are"])
    shown = {t.text: t.color for t in glasses.texts()}
    # the tail: the last four of the five
    assert "en > ru 13:37" not in shown
    assert shown["good morning"] == "GREY"
    assert shown["dobroe utro"] == "WHITE"
    assert shown["not translated: 137"] == "RED"
    assert shown["how are"] == "GREY"
    assert status(glasses) == "5:5  listening"
    glasses.screenshot("translate-log")
    glasses.assert_ok()


def test_an_info_line_is_sky_blue_and_text_splits_on_the_first_bar(glasses):
    voice(glasses)
    window(glasses, 1, 0, 2, 1, ["I|en > ru 13:37", "T|a|b"])
    shown = {t.text: t.color for t in glasses.texts()}
    assert shown["en > ru 13:37"] == "SKYBLUE"
    assert "a|b" in shown
    glasses.assert_ok()


def test_empty_lines_are_not_drawn(glasses):
    voice(glasses)
    window(glasses, 1, 0, 2, 1, ["T|", "T|137"])
    rows = [t for t in glasses.texts() if TOP_Y <= t.y < STATUS_Y]
    assert [t.text for t in rows] == ["137"]
    glasses.assert_ok()


def test_the_status_row_is_all_in_the_font(frame):
    from frame_emulator.display import Fonts
    glyphs = Fonts.get().glyphs
    voice(frame)
    window(frame, 1, 133, 137, 1, log(133, 4))
    assert status(frame) == "137:137  listening"
    assert all(ord(c) in glyphs for c in status(frame))
    frame.assert_ok()


def test_the_tail_answer_is_not_asked_again(glasses):
    voice(glasses)
    window(glasses, 1, 133, 137, 1, log(133, 4))
    assert status(glasses) == "137:137  listening"
    glasses.clear_sent()
    glasses.advance(13.7)
    assert not glasses.sent(TRANSLATE)
    glasses.assert_ok()


def test_pushes_scroll_new_lines_in(glasses):
    voice(glasses)
    window(glasses, 1, 0, 2, 1, log(0, 2))
    window(glasses, 1, 133, 137, 1, log(133, 4))
    text = glasses.screen_text()
    assert "line 136" in text and "line 1\n" not in text + "\n"
    assert status(glasses) == "137:137  listening"
    glasses.assert_ok()


def test_no_answer_asks_again_after_five_seconds(glasses):
    voice(glasses)
    glasses.clear_sent()
    glasses.advance(4)
    assert not glasses.sent(TRANSLATE)
    glasses.advance(1.5)
    assert asks(glasses) == [(2, 0, 0, 4)]
    glasses.assert_ok()


def test_the_microphones_bytes_go_to_the_phone(glasses):
    voice(glasses)
    sound = bytes(i % 251 for i in range(137 * 10))
    glasses.emu.mic_data.extend(sound)
    glasses.advance(1)
    assert audio(glasses) == sound
    assert all(len(p) - 1 <= PACKET and (len(p) - 1) % 2 == 0
               for p in glasses.sent(AUDIO))
    assert glasses.emu._mic_fmt == (8000, 16)
    glasses.assert_ok()


def test_a_tap_pauses_and_another_listens_again(glasses):
    voice(glasses)
    window(glasses, 1, 0, 0, 1)
    glasses.emu.mic_data.extend(b"\x89" * 1370)
    glasses.clear_sent()
    glasses.tap(1)
    assert audio(glasses) == b"\x89" * 1370      # what was left goes first
    assert glasses.sent()[-1] == bytes([AUDIO_END])
    assert not glasses.sent(REC_DROP)
    assert not glasses.emu._mic_on
    assert "paused, tap to listen" in glasses.screen_text()
    assert status(glasses) == "-  paused"
    assert not red_dot(glasses)
    glasses.screenshot("translate-paused")
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(REC_START) == [bytes([REC_START, 16, 8, 2])]
    assert status(glasses) == "-  listening"
    assert red_dot(glasses)
    glasses.assert_ok()


@pytest.mark.parametrize("bits,sent", [("8", 8), ("16", 16), ("137", 16),
                                       ("nonsense", 16)])
def test_quality_is_8_or_16_bit(glasses, bits, sent):
    glasses.settings({"translate.bits": bits})
    voice(glasses)
    assert glasses.sent(REC_START) == [bytes([REC_START, sent, 8, 2])]
    assert glasses.emu._mic_fmt == (8000, sent)
    glasses.assert_ok()


def test_listening_keeps_it_open_and_pausing_lets_it_close(glasses):
    voice(glasses)
    window(glasses, 1, 0, 0, 1)
    glasses.advance(65)                          # past APP_TIMEOUT
    assert "listening.." in glasses.screen_text()
    glasses.tap(1)
    glasses.clear_sent()
    glasses.advance(65)
    assert glasses.sent(APP_STOP)
    assert asks(glasses) == [(0, 1, 0, 0)]       # the phone is told
    assert not glasses.sent(APP_BACKGROUND)
    glasses.assert_ok()


def test_it_pauses_itself_after_30_minutes(frame):
    voice(frame)
    window(frame, 1, 0, 0, 1)
    frame.clear_sent()
    frame.advance(1795)
    assert not frame.sent(AUDIO_END)
    frame.advance(10)
    assert frame.sent(AUDIO_END)
    assert status(frame) == "-  paused (30 min)"
    assert not red_dot(frame)
    frame.tap(1)                                 # on again: the note goes
    assert status(frame) == "-  listening"
    frame.assert_ok()


def test_a_double_tap_ends_the_sound_and_closes_the_session(glasses):
    voice(glasses)
    window(glasses, 137, 0, 0, 1)
    glasses.clear_sent()
    glasses.tap(2)
    codes = [m[0] for m in glasses.sent()]
    assert codes == [AUDIO_END, TRANSLATE]
    assert asks(glasses) == [(0, 137, 0, 0)]
    assert not glasses.emu._mic_on
    assert not red_dot(glasses)
    assert cursor_row(glasses) == 0              # back on the chooser
    assert "tap = pick" in glasses.screen_text()
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(TRANSLATE)           # closed once only
    glasses.assert_ok()


def test_back_on_the_chooser_the_phone_is_not_heard(glasses):
    voice(glasses)
    window(glasses, 1, 0, 0, 1)
    glasses.tap(2)
    before = glasses.screen_text()
    glasses.call("translate", "x:Translate is off on phone")
    window(glasses, 1, 0, 1, 1, ["T|137"])
    assert glasses.screen_text() == before
    glasses.assert_ok()


# ---------------------------------------------------------------- the phone

def test_the_status_row_shows_the_phones_text_and_clears(glasses):
    voice(glasses)
    window(glasses, 1, 0, 0, 1)
    glasses.call("translate", "s:downloading en>ru..")
    assert status(glasses) == "-  downloading en>ru.."
    assert glasses.emu._mic_on                   # still listening
    glasses.call("translate", "s:")
    assert status(glasses) == "-  listening"
    glasses.assert_ok()


def test_x_stops_the_microphone(glasses):
    voice(glasses)
    window(glasses, 1, 0, 0, 1)
    glasses.clear_sent()
    glasses.call("translate", "x:Translate is off on phone")
    assert glasses.sent(AUDIO_END)
    assert not glasses.emu._mic_on
    assert not red_dot(glasses)
    assert status(glasses) == "-  Translate is off on phone"
    assert "paused, tap to listen" in glasses.screen_text()
    glasses.screenshot("translate-off-on-phone")
    glasses.assert_ok()


def test_n_while_following_asks_for_the_tail_again(glasses):
    voice(glasses)
    window(glasses, 1, 0, 2, 1, log(0, 2))
    glasses.clear_sent()
    glasses.call("translate", "n:1:3")
    glasses.advance(0.5)
    assert asks(glasses) == [(2, 1, 0, 4)]
    glasses.assert_ok()


def test_a_new_session_drops_the_lines_and_follows_its_end(glasses):
    voice(glasses)
    window(glasses, 1, 0, 2, 1, log(0, 2))
    glasses.clear_sent()
    glasses.call("translate", "n:137:4000")
    glasses.advance(0.5)
    assert "line 0" not in glasses.screen_text()
    assert "loading.." in glasses.screen_text()
    assert asks(glasses) == [(2, 137, 0, 4)]
    glasses.assert_ok()


def test_a_window_of_a_new_session_replaces_the_old(glasses):
    voice(glasses)
    window(glasses, 1, 0, 2, 1, log(0, 2))
    window(glasses, 2, 0, 1, 1, ["T|137"])
    text = glasses.screen_text()
    assert "137" in text and "line 0" not in text
    assert status(glasses) == "1:1  listening"
    glasses.clear_sent()
    glasses.advance(1)
    assert not glasses.sent(TRANSLATE)
    glasses.assert_ok()


@pytest.mark.parametrize("arg", ["", "137", "w:", "w:1:0:2", "w:a:0:1:1",
                                 "n:1", "n:x:137", "q:137", "W:1:0:1:1"])
def test_payloads_it_does_not_know_change_nothing(glasses, arg):
    voice(glasses)
    window(glasses, 1, 0, 1, 1, ["T|137"])
    before = glasses.screen_text()
    glasses.call("translate", arg)
    glasses.advance(0.5)
    assert glasses.screen_text() == before
    glasses.assert_ok()


def test_lines_without_a_kind_are_skipped(glasses):
    voice(glasses)
    window(glasses, 1, 0, 1, 1, ["no bar here", "T|137"])
    text = glasses.screen_text()
    assert "137" in text and "no bar here" not in text
    glasses.assert_ok()


# ---------------------------------------------------------------- scrolling

def test_a_tilt_left_scrolls_back_a_screen(glasses):
    voice(glasses)
    window(glasses, 1, 6, 10, 1, log(6, 4))
    glasses.clear_sent()
    glasses.tilt(-1)
    assert asks(glasses) == [(1, 1, 0, 8)]       # four above, eight
    assert "loading.." in glasses.screen_text()
    window(glasses, 1, 0, 10, 0, log(0, 8))
    text = glasses.screen_text()
    for i in range(3, 7):
        assert f"line {i}" in text
    assert "line 7" not in text and "line 2" not in text
    assert status(glasses) == "7:10  listening  ^"
    glasses.screenshot("translate-scrolled-back")
    glasses.assert_ok()


def test_a_tilt_right_on_the_end_does_nothing(glasses):
    voice(glasses)
    window(glasses, 1, 6, 10, 1, log(6, 4))
    glasses.clear_sent()
    glasses.tilt(1)
    assert not glasses.sent(TRANSLATE)
    assert status(glasses) == "10:10  listening"
    glasses.assert_ok()


def test_a_tilt_left_at_the_start_does_nothing(glasses):
    voice(glasses)
    window(glasses, 1, 0, 3, 1, log(0, 3))
    glasses.clear_sent()
    glasses.tilt(-1)
    assert not glasses.sent(TRANSLATE)
    assert status(glasses) == "3:3  listening"
    glasses.assert_ok()


def test_a_tilt_before_any_answer_does_nothing(glasses):
    voice(glasses)
    glasses.clear_sent()
    glasses.tilt(-1)
    glasses.tilt(1)
    assert not glasses.sent(TRANSLATE)
    glasses.assert_ok()


def test_a_tilt_right_back_at_the_end_follows_again(glasses):
    scrolled_back(glasses)
    glasses.clear_sent()
    glasses.tilt(1)
    assert asks(glasses) == [(2, 1, 0, 4)]
    window(glasses, 1, 6, 10, 1, log(6, 4))
    assert status(glasses) == "10:10  listening"
    glasses.assert_ok()


def test_lines_held_scroll_without_asking(glasses):
    voice(glasses)
    window(glasses, 1, 133, 137, 1, log(133, 4))
    glasses.tilt(-1)                             # top 130: asks 126..133
    window(glasses, 1, 126, 137, 0, log(126, 8))
    glasses.tilt(-1)                             # top 127: held
    glasses.clear_sent()
    glasses.advance(6)
    assert not glasses.sent(TRANSLATE)
    assert "line 127" in glasses.screen_text()
    assert status(glasses) == "131:137  listening  ^"
    glasses.tilt(1)                              # top 130: held too
    assert not glasses.sent(TRANSLATE)
    assert status(glasses) == "134:137  listening  ^"
    glasses.assert_ok()


def test_reading_back_a_push_only_counts_the_lines(glasses):
    scrolled_back(glasses)
    window(glasses, 1, 7, 11, 1, log(7, 4))
    text = glasses.screen_text()
    assert "line 3" in text and "line 10" not in text
    assert status(glasses) == "7:11  listening  ^"
    glasses.assert_ok()


def test_an_answer_no_longer_waited_on_is_dropped(glasses):
    scrolled_back(glasses)
    before = glasses.screen_text()
    window(glasses, 1, 2, 10, 0, log(2, 8, "E"))
    assert glasses.screen_text() == before
    glasses.assert_ok()


def test_a_short_answer_asks_for_the_screen_itself(glasses):
    voice(glasses)
    window(glasses, 1, 6, 10, 1, log(6, 4))
    glasses.tilt(-1)                             # asks 0..7 for 3..6
    glasses.clear_sent()
    window(glasses, 1, 0, 10, 0, log(0, 4))      # only 0..3
    glasses.advance(0.5)
    assert asks(glasses) == [(1, 1, 3, 4)]
    glasses.assert_ok()


def test_n_while_reading_back_drops_the_pending_lines(glasses):
    voice(glasses)
    window(glasses, 1, 6, 10, 1, log(6, 4))
    glasses.tilt(-1)
    window(glasses, 1, 0, 10, 0, log(0, 5) + ["P|being heard"] + log(6, 2))
    assert "being heard" in glasses.screen_text()
    glasses.clear_sent()
    glasses.call("translate", "n:1:11")
    glasses.advance(0.5)
    assert asks(glasses) == [(1, 1, 0, 8)]       # the screen again
    assert status(glasses).startswith("7:11")
    glasses.assert_ok()


def test_n_while_reading_back_keeps_finished_lines(glasses):
    scrolled_back(glasses)
    glasses.clear_sent()
    glasses.call("translate", "n:1:12")
    glasses.advance(6)
    assert not glasses.sent(TRANSLATE)
    assert status(glasses) == "7:12  listening  ^"
    glasses.assert_ok()


# ---------------------------------------------------------------- Photo

def test_photo_asks_for_the_tail_and_does_not_listen(glasses):
    photo_mode(glasses)
    assert asks(glasses) == [(2, 0, 0, 4)]
    assert not glasses.sent(REC_START)
    assert not red_dot(glasses)
    window(glasses, 1, 0, 0, 1)
    assert "tap = photo" in glasses.screen_text()
    assert status(glasses) == "-  tap = photo"
    glasses.screenshot("translate-photo")
    glasses.assert_ok()


@PHOTO_HEAP
def test_a_tap_in_photo_sends_a_photo_to_read(glasses):
    photo_mode(glasses)
    window(glasses, 1, 0, 0, 1)
    glasses.clear_sent()
    glasses.tap(1)
    glasses.advance(3)
    assert glasses.sent(PHOTO_FROM) == [bytes([PHOTO_FROM, 255])]
    shots = photos(glasses)
    assert len(shots) == 1
    from io import BytesIO
    from PIL import Image
    assert Image.open(BytesIO(shots[0])).size == (720, 720)
    assert glasses.emu._camera_awake             # on until Translate closes
    glasses.tap(2)
    assert not glasses.emu._camera_awake
    glasses.assert_ok()


def test_the_mode_picked_is_kept(glasses):
    photo_mode(glasses)
    assert "translate.mode=photo" in glasses.emu.files.path(
        "prefs.txt").read_text()
    glasses.tap(2)                               # the chooser
    assert cursor_row(glasses) == 1
    glasses.tap(2)                               # the menu
    glasses.open_app("translate")
    assert cursor_row(glasses) == 1
    glasses.tilt(1)
    glasses.tap(1)                               # Voice again
    glasses.tap(2)
    glasses.tap(2)
    glasses.open_app("translate")
    assert cursor_row(glasses) == 0
    glasses.assert_ok()


@PHOTO_HEAP
def test_a_camera_that_fails_says_so(frame):
    photo_mode(frame)
    window(frame, 1, 0, 0, 1)
    lua(frame, "glaz_req = require; require = function(n) "
               "if n == 'glaz_photo' then error('broken') end "
               "return glaz_req(n) end")
    frame.clear_sent()
    frame.tap(1)
    assert status(frame) == "-  no camera"
    assert not frame.sent(PHOTO_FROM)
    lua(frame, "require = glaz_req")
    frame.tap(1)
    frame.advance(3)
    assert photos(frame)
    assert status(frame) == "-  tap = photo"
    frame.assert_ok()


# ---------------------------------------------------------------- trouble

def test_with_no_phone_it_says_so(frame):
    frame.open_app("translate")
    frame.emu.connected = False
    frame.clear_sent()
    frame.tap(1)
    assert status(frame) == "-  no phone"
    assert not frame.sent()
    assert not frame.emu._mic_on
    assert not red_dot(frame)
    frame.screenshot("translate-no-phone")
    frame.emu.connected = True
    frame.advance(1)
    assert asks(frame) == [(2, 0, 0, 4)]         # asked once the link is up
    assert status(frame) == "-  paused"
    frame.assert_ok()


def test_with_no_phone_photo_takes_none(frame):
    photo_mode(frame)
    window(frame, 1, 0, 0, 1)
    frame.emu.connected = False
    frame.clear_sent()
    frame.tap(1)
    frame.advance(2)
    assert status(frame) == "-  no phone"
    assert not frame.sent()
    frame.assert_ok()


def test_the_link_lost_and_back_asks_again(frame):
    voice(frame)
    window(frame, 1, 0, 2, 1, log(0, 2))
    frame.emu.connected = False
    frame.advance(1)
    assert status(frame) == "2:2  no phone"
    assert not frame.emu._mic_on
    assert not red_dot(frame)
    frame.emu.connected = True
    frame.clear_sent()
    frame.advance(1)
    assert asks(frame) == [(2, 1, 0, 4)]
    assert status(frame) == "2:2  paused"
    frame.assert_ok()


def test_the_link_lost_while_reading_back_asks_for_the_screen(frame):
    scrolled_back(frame)
    frame.emu.connected = False
    frame.advance(1)
    frame.emu.connected = True
    frame.clear_sent()
    frame.advance(1)
    assert asks(frame) == [(1, 1, 0, 8)]
    frame.assert_ok()


def test_a_microphone_that_will_not_start_says_so(frame):
    frame.open_app("translate")
    lua(frame, "frame.microphone.start = function() error('no mic') end")
    frame.clear_sent()
    frame.tap(1)
    assert not frame.sent(REC_START)
    assert status(frame) == "-  no microphone"
    assert not red_dot(frame)
    frame.assert_ok()


def test_when_rec_start_cannot_be_sent_the_microphone_stops(frame):
    frame.open_app("translate")
    lua(frame, "glaz_send = frame.bluetooth.send; frame.bluetooth.send = "
               "function(s) if s:byte(1) == 0x1F then error('busy') end "
               "return glaz_send(s) end")
    frame.clear_sent()
    frame.tap(1)
    assert status(frame) == "-  no microphone"
    assert not frame.emu._mic_on
    frame.assert_ok()


def test_what_the_link_cannot_take_is_counted_lost(frame):
    voice(frame)
    window(frame, 1, 0, 0, 1)
    lua(frame, "glaz_send = frame.bluetooth.send; frame.bluetooth.send = "
               "function(s) if s:byte(1) == 5 then error('busy') end "
               "return glaz_send(s) end")
    frame.emu.mic_data.extend(bytes(3 * 1024))
    frame.advance(5)
    assert status(frame) == "-  listening  lost 3K"
    assert not frame.sent(AUDIO)
    frame.screenshot("translate-lost")
    lua(frame, "frame.bluetooth.send = glaz_send")
    frame.tap(1)
    frame.tap(1)                                 # listening again: from 0
    assert "lost" not in status(frame)
    frame.assert_ok()


def test_a_blip_the_glasses_only_saw_in_a_send_listens_again(frame):
    voice(frame)
    window(frame, 1, 0, 2, 1, log(0, 2))
    # one AUDIO packet fails all its tries, and the link is down just then
    lua(frame, "glaz_n = 20; glaz_send = frame.bluetooth.send; "
               "glaz_conn = frame.bluetooth.is_connected; "
               "frame.bluetooth.send = function(s) "
               "if s:byte(1) == 5 and glaz_n > 0 then glaz_n = glaz_n - 1 "
               "if glaz_n == 0 then glaz_drop = true end error('busy') end "
               "return glaz_send(s) end; "
               "frame.bluetooth.is_connected = function() "
               "if glaz_drop then glaz_drop = false return false end "
               "return glaz_conn() end")
    frame.clear_sent()
    frame.emu.mic_data.extend(bytes(137))
    frame.advance(1)
    codes = [m[0] for m in frame.sent() if m[0] != AUDIO]
    assert codes == [TRANSLATE, AUDIO_END, REC_START]
    assert asks(frame) == [(2, 1, 0, 4)]
    assert frame.sent(REC_START) == [bytes([REC_START, 16, 8, 2])]
    assert status(frame) == "2:2  listening"
    assert red_dot(frame)
    frame.assert_ok()


def test_less_than_a_kilobyte_lost_shows_and_clears(frame):
    voice(frame)
    window(frame, 1, 0, 0, 1)
    lua(frame, "glaz_send = frame.bluetooth.send; frame.bluetooth.send = "
               "function(s) if s:byte(1) == 5 then error('busy') end "
               "return glaz_send(s) end")
    frame.emu.mic_data.extend(bytes(137))
    frame.advance(1)
    assert status(frame) == "-  listening  lost 0K"
    lua(frame, "frame.bluetooth.send = glaz_send")
    frame.tap(1)
    frame.tap(1)
    assert status(frame) == "-  listening"
    frame.assert_ok()


BLIP = ("glaz_n = 20; glaz_send = frame.bluetooth.send; "
        "glaz_conn = frame.bluetooth.is_connected; "
        "frame.bluetooth.send = function(s) "
        "if s:byte(1) == 5 and glaz_n > 0 then glaz_n = glaz_n - 1 "
        "if glaz_n == 0 then glaz_drop = true end error('busy') end "
        "return glaz_send(s) end; "
        "frame.bluetooth.is_connected = function() "
        "if glaz_drop then glaz_drop = false return false end "
        "return glaz_conn() end")


def test_listening_again_after_a_blip_keeps_the_30_minutes(frame):
    voice(frame)
    window(frame, 1, 0, 0, 1)
    frame.advance(1000)
    lua(frame, BLIP)
    frame.emu.mic_data.extend(bytes(137))
    frame.advance(1)
    assert frame.sent(REC_START)[-1] == bytes([REC_START, 16, 8, 2])
    frame.clear_sent()
    frame.advance(790)                           # about 1792 s since the tap
    assert not frame.sent(AUDIO_END)
    frame.advance(15)
    assert frame.sent(AUDIO_END)
    assert status(frame) == "-  paused (30 min)"
    frame.assert_ok()


# ---------------------------------------------------------------- leaving

def test_halo_does_not_open_it(halo):
    halo.clear_sent()
    halo.open_app("translate")
    assert "Voice" not in halo.screen_text()
    assert not halo.sent(TRANSLATE)
    halo.assert_ok()


def test_another_app_opened_while_listening_ends_it(glasses):
    voice(glasses)
    window(glasses, 137, 0, 0, 1)
    glasses.clear_sent()
    glasses.open_app("stopwatch")
    assert glasses.sent(AUDIO_END)
    assert asks(glasses) == [(0, 137, 0, 0)]
    assert not glasses.emu._mic_on
    assert not red_dot(glasses)
    assert not glasses.sent(APP_BACKGROUND)      # it sleeps, not runs on
    glasses.assert_ok()


@PHOTO_HEAP
def test_photo_left_alone_closes_and_the_camera_sleeps(glasses):
    photo_mode(glasses)
    window(glasses, 1, 0, 0, 1)
    glasses.tap(1)
    glasses.advance(3)
    assert glasses.emu._camera_awake
    glasses.clear_sent()
    glasses.advance(65)                          # nothing keeps it busy
    assert glasses.sent(APP_STOP)
    assert asks(glasses) == [(0, 1, 0, 0)]
    assert not glasses.emu._camera_awake
    glasses.assert_ok()


def test_a_double_tap_with_the_link_down_sends_nothing(frame):
    voice(frame)
    window(frame, 1, 0, 0, 1)
    frame.emu.connected = False
    frame.clear_sent()
    frame.tap(2)
    assert not frame.sent()
    assert not frame.emu._mic_on
    assert cursor_row(frame) == 0
    assert "no phone" not in frame.screen_text()
    frame.emu.connected = True
    frame.advance(1)
    assert not frame.sent(TRANSLATE)             # the chooser asks nothing
    frame.assert_ok()


def test_leaving_a_mode_clears_the_phones_note(glasses):
    voice(glasses)
    window(glasses, 1, 0, 0, 1)
    glasses.call("translate", "s:downloading en>ru..")
    glasses.tap(2)
    assert "downloading" not in glasses.screen_text()
    glasses.tap(1)
    window(glasses, 1, 0, 0, 1)
    assert status(glasses) == "-  listening"
    glasses.assert_ok()


# ---------------------------------------------------------------- more paths

def test_photo_scrolls_back_as_voice_does(glasses):
    photo_mode(glasses)
    window(glasses, 1, 6, 10, 1, log(6, 4))
    glasses.clear_sent()
    glasses.remote(2, 255)                       # the phone's remote, back
    assert asks(glasses) == [(1, 1, 0, 8)]
    window(glasses, 1, 0, 10, 0, log(0, 8))
    assert status(glasses) == "7:10  tap = photo  ^"
    glasses.clear_sent()
    glasses.remote(2, 1)                         # and on, to the end
    assert asks(glasses) == [(2, 1, 0, 4)]
    glasses.assert_ok()


def test_scrolling_back_with_no_answer_asks_again(glasses):
    voice(glasses)
    window(glasses, 1, 6, 10, 1, log(6, 4))
    glasses.tilt(-1)
    glasses.clear_sent()
    glasses.advance(4)
    assert not glasses.sent(TRANSLATE)
    glasses.advance(1.5)
    assert asks(glasses) == [(1, 1, 0, 8)]
    glasses.assert_ok()


def test_a_tilt_right_short_of_the_end_asks_for_lines_not_held(glasses):
    voice(glasses)
    window(glasses, 1, 133, 137, 1, log(133, 4))
    glasses.tilt(-1)                             # top 130
    window(glasses, 1, 126, 137, 0, log(126, 8))
    glasses.tilt(-1)                             # top 127, held
    glasses.tilt(-1)                             # top 124: asks 120..127
    window(glasses, 1, 120, 137, 0, log(120, 8))
    assert status(glasses) == "128:137  listening  ^"
    glasses.clear_sent()
    glasses.tilt(1)                              # top 127: 128..130 not held
    assert asks(glasses) == [(1, 1, 123, 8)]
    assert "loading.." in glasses.screen_text()
    glasses.assert_ok()


def test_a_new_session_while_reading_back_follows_its_end(glasses):
    scrolled_back(glasses)
    window(glasses, 2, 0, 2, 0, ["T|137", "T|138"])
    text = glasses.screen_text()
    assert "137" in text and "line 3" not in text
    assert status(glasses) == "2:2  listening"
    glasses.assert_ok()


def test_a_shorter_log_drops_the_lines_past_its_end(glasses):
    scrolled_back(glasses)                       # 0..7 held, 3..6 shown
    glasses.call("translate", "n:1:5")
    glasses.advance(0.5)
    text = glasses.screen_text()
    assert "line 3" in text and "line 4" in text
    assert "line 5" not in text and "line 6" not in text
    assert status(glasses) == "5:5  listening  ^"
    glasses.assert_ok()


def test_x_in_photo_only_shows_the_text(glasses):
    photo_mode(glasses)
    window(glasses, 1, 0, 0, 1)
    glasses.clear_sent()
    glasses.call("translate", "x:Translate is off on phone")
    assert not glasses.sent(AUDIO_END)
    assert status(glasses) == "-  Translate is off on phone"
    glasses.assert_ok()


def test_the_bits_setting_counts_from_the_next_listen(glasses):
    voice(glasses)
    window(glasses, 1, 0, 0, 1)
    glasses.settings({"translate.bits": "8"})
    glasses.clear_sent()
    glasses.advance(1)
    assert not glasses.sent(REC_START)
    glasses.tap(1)
    glasses.tap(1)
    assert glasses.sent(REC_START) == [bytes([REC_START, 8, 8, 2])]
    assert glasses.emu._mic_fmt == (8000, 8)
    glasses.assert_ok()


def test_a_microphone_that_fails_to_read_keeps_listening(frame):
    voice(frame)
    window(frame, 1, 0, 0, 1)
    lua(frame, "frame.microphone.read = function() error('dma') end")
    frame.clear_sent()
    frame.advance(2)
    assert not frame.sent(AUDIO)
    assert status(frame) == "-  listening"
    assert red_dot(frame)
    frame.assert_ok()


def test_with_no_phone_in_photo_the_link_back_clears_it(frame):
    photo_mode(frame)
    window(frame, 1, 0, 0, 1)
    frame.emu.connected = False
    frame.tap(1)
    assert status(frame) == "-  no phone"
    frame.emu.connected = True
    frame.clear_sent()
    frame.advance(1)
    assert status(frame) == "-  tap = photo"
    assert asks(frame) == [(2, 1, 0, 4)]
    frame.assert_ok()


def test_the_longest_status_fits_the_screen():
    # Frame's text() drops every glyph past x = 640: the end of the status,
    # 'lost NK', must not be the part that goes (display.c)
    from frame_emulator.display import Fonts, WIDTH
    glyphs = Fonts.get().glyphs
    status = "137:137  listening  ^  lost 137K"
    x = 60                                       # LEFT_X in glaz.frame.lua
    for c in status:
        x += glyphs[ord(c)][0] + 4
    assert x - 4 <= WIDTH

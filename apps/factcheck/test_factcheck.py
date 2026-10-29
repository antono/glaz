"""Factchecker (apps/factcheck/factcheck.lua) on Frame, the only glasses that
have it: it listens from the start, the sound streamed to the phone; a tap
on the bottom row cuts the conversation there for the phone to check; the
facts the phone keeps shown four at a time, each window asked for as the
view moves, with a mark and a colour by verdict; one opened to read its
check, four lines at a time; notes that go by themselves; the link lost and
back; leaving tells the phone (docs/PROTOCOL.md, "Factchecker").
"""
import struct

import pytest

from glasses import APP_START, APP_STOP, has_module

pytestmark = pytest.mark.module("factcheck")

# Glasses -> phone (apps/factcheck/factcheck.lua)
FACTS, AUDIO, AUDIO_END = 0x01, 0x05, 0x06
REC_DROP, REC_START = 0x10, 0x1F
ROWS = 4

FOUR = [("T", "Water boils at 100 C"), ("F", "Minsk has 137k people"),
        ("M", "Coffee dehydrates"), ("P", "Everest is 8849 m")]
CHECK = ["FALSE", "Minsk has 137 thousand", "people.",
         "About 2 million live in", "Minsk.", "belstat.gov.by"]


def facts(op, a=0, b=0):
    return struct.pack(">BBHH", FACTS, op, a, b)   # Lua's >BBI2I2


def window(session, start, pending=0):
    """The phone's f: for facts [(v, text), ...] from number start, 0 the
    newest, as services/factcheck.dart makes it."""
    tail = max(1, len(session) - ROWS + 1)
    start = tail if start == 0 else min(max(start, 1), tail)
    rows = "".join(f"\n{i}|{v}|{t}" for i, (v, t)
                   in enumerate(session[start - 1:start - 1 + ROWS], start))
    return f"f:{pending}:{len(session)}:{start}{rows}"


def check_window(ident, v, lines, start):
    last = max(1, len(lines) - ROWS + 1)
    start = min(max(start, 1), last)
    body = "".join(f"\n{l}" for l in lines[start - 1:start - 1 + ROWS])
    return f"d:{ident}:{v}:{len(lines)}:{start}{body}"


def asked(g, op):
    """The last FACTS the glasses sent with op: (a, b)."""
    for m in reversed(g.sent(FACTS)):
        if m[1] == op:
            return struct.unpack(">HH", m[2:6])
    return None


def answer(g, session, pending=0):
    """The phone answers the glasses' last ask for the list."""
    g.call("factcheck", window(session, asked(g, 3)[0], pending))


def opened(g, session=FOUR):
    """Factchecker from the menu, listening, the phone's facts on screen."""
    g.open_app("factcheck")
    if session is not None:
        answer(g, session)
    return g


def numbered(n):
    return [("T", f"Fact {i}") for i in range(1, n + 1)]


def color_of(g, text):
    return next(t.color for t in g.texts() if t.text == text)


def cursor_row(g):
    cursor = next(t for t in g.texts() if t.text == ">")
    return next(t.text for t in g.texts() if t.y == cursor.y and t.x > cursor.x)


# ---------------------------------------------------------------- devices

def test_only_frame_has_it():
    assert has_module("frame", "factcheck")
    assert not has_module("halo", "factcheck")


# ---------------------------------------------------------------- listening

def test_opens_listening_and_asking_for_the_list(glasses):
    glasses.clear_sent()
    glasses.open_app("factcheck")
    sent = glasses.sent()
    assert glasses.sent(APP_START)
    assert bytes([REC_START, 16, 8, 4]) in sent and facts(3) in sent
    assert glasses.emu._mic_on
    assert glasses.emu._mic_fmt == (8000, 16)
    text = glasses.screen_text()
    assert "Tap when you hear" in text and "a claim to check" in text
    assert "0:00  tap = check" in text
    glasses.screenshot("factcheck-empty")
    glasses.assert_ok()


def test_the_sound_streams_to_the_phone(glasses):
    opened(glasses)
    sound = bytes(range(256)) * 13 + b"\x01\x37"
    glasses.emu.mic_data.extend(sound)
    glasses.advance(1)
    audio = glasses.sent(AUDIO)
    assert audio
    assert all(len(m) <= 245 and (len(m) - 1) % 2 == 0 for m in audio)
    assert b"".join(m[1:] for m in audio) == sound
    assert not glasses.sent(AUDIO_END)


def test_the_clock_counts_minutes_and_seconds(glasses):
    opened(glasses)
    glasses.advance(137)
    text = glasses.screen_text()
    assert "2:17  tap = check" in text or "2:18  tap = check" in text


def test_eight_bit_sound_when_set(glasses):
    glasses.settings({"factcheck.bits": "8"})
    opened(glasses)
    assert glasses.sent(REC_START)[-1] == bytes([REC_START, 8, 8, 4])


def test_listening_keeps_it_open_past_the_minute(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.advance(137)                         # past APP_TIMEOUT, 60 s
    assert not glasses.sent(APP_STOP)
    assert glasses.emu._mic_on
    glasses.assert_ok()


def test_pauses_by_itself_after_half_an_hour(glasses):
    opened(glasses)
    for _ in range(30):                          # a minute at a time: each
        glasses.advance(60)                      # advance() waits 30 s at most
    glasses.advance(1)                           # past MAX_LISTEN
    assert not glasses.emu._mic_on
    text = glasses.screen_text()
    assert "paused (30 min)" in text
    glasses.advance(13.7)                        # it stays: not a note
    assert "paused (30 min)" in glasses.screen_text()
    glasses.clear_sent()
    glasses.tap(1)                               # listens again
    assert glasses.emu._mic_on
    assert glasses.sent(REC_START)
    glasses.assert_ok()


# ---------------------------------------------------------------- checking

def test_a_tap_on_the_bottom_row_cuts_and_shows_it_at_once(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(FACTS) == [facts(1)]
    assert glasses.emu._mic_on                   # it goes on listening
    assert not glasses.sent(AUDIO_END)
    assert "reading..  tap = check" in glasses.screen_text()
    glasses.call("factcheck", window(FOUR, 0))   # the phone has read it
    assert "reading.." not in glasses.screen_text()
    glasses.assert_ok()


def test_the_facts_are_marked_and_coloured_by_verdict(glasses):
    opened(glasses)
    for text, color in (("+ Water boils at 100 C", "GREEN"),
                        ("x Minsk has 137k people", "RED"),
                        ("~ Coffee dehydrates", "YELLOW"),
                        (". Everest is 8849 m", "WHITE")):
        assert color_of(glasses, text) == color
    five = FOUR + [("U", "Cats sleep 16 h")]
    glasses.call("factcheck", window(five, 0))
    assert color_of(glasses, "? Cats sleep 16 h") == "GREY"
    glasses.tilt(-1)
    glasses.tilt(-1)
    glasses.screenshot("factcheck-list")
    glasses.assert_ok()


def test_opening_asks_for_the_newest_four_only(glasses):
    glasses.clear_sent()
    opened(glasses, numbered(137))
    assert asked(glasses, 3) == (0, 0)           # the newest, followed
    text = glasses.screen_text()
    assert "Fact 133" not in text
    for i in (134, 135, 136, 137):
        assert f"+ Fact {i}" in text
    assert cursor_row(glasses).endswith("tap = check")
    assert color_of(glasses, cursor_row(glasses)) == "YELLOW"
    glasses.assert_ok()


def test_tilting_up_asks_for_the_facts_above(glasses):
    session = numbered(137)
    opened(glasses, session)
    for _ in range(4):
        glasses.tilt(-1)
    assert cursor_row(glasses) == "+ Fact 134"
    glasses.clear_sent()
    glasses.tilt(-1)                             # off the top of the window
    assert asked(glasses, 3) == (133, 0)
    assert cursor_row(glasses) == ".."           # not here yet
    answer(glasses, session)
    assert cursor_row(glasses) == "+ Fact 133"
    assert "Fact 137" not in glasses.screen_text()
    glasses.assert_ok()


def test_tilting_back_down_follows_the_newest_again(glasses):
    session = numbered(137)
    opened(glasses, session)
    for _ in range(5):
        glasses.tilt(-1)
    answer(glasses, session)
    for _ in range(5):
        glasses.tilt(1)
    assert asked(glasses, 3) == (0, 0)
    answer(glasses, session)
    assert cursor_row(glasses).endswith("tap = check")
    assert "+ Fact 137" in glasses.screen_text()
    glasses.tilt(1)                              # no further
    assert cursor_row(glasses).endswith("tap = check")
    glasses.assert_ok()


def test_a_window_for_a_view_since_left_is_ignored(glasses):
    session = numbered(137)
    opened(glasses, session)
    for _ in range(5):
        glasses.tilt(-1)
    glasses.call("factcheck", window(session, 0))   # the tail, too late
    assert cursor_row(glasses) == ".."
    answer(glasses, session)
    assert cursor_row(glasses) == "+ Fact 133"


def test_the_cursor_stays_on_its_fact_as_the_list_grows(glasses):
    opened(glasses)
    glasses.tilt(-1)
    glasses.tilt(-1)
    assert cursor_row(glasses) == "~ Coffee dehydrates"
    five = FOUR + [("P", "Cats sleep 16 h")]
    glasses.call("factcheck", window(five, 1))   # its window, sent again
    assert cursor_row(glasses) == "~ Coffee dehydrates"
    glasses.assert_ok()


def test_new_facts_follow_with_the_cursor_below(glasses):
    opened(glasses)
    five = FOUR + [("P", "Cats sleep 16 h")]
    glasses.call("factcheck", window(five, 0))
    text = glasses.screen_text()
    assert ". Cats sleep 16 h" in text and "Water boils" not in text
    assert cursor_row(glasses).endswith("tap = check")


def test_tilts_with_no_facts_do_nothing(glasses):
    opened(glasses, [])
    glasses.tilt(-1)
    assert cursor_row(glasses).endswith("tap = check")
    glasses.assert_ok()


# ---------------------------------------------------------------- one fact

def test_a_tap_on_a_fact_opens_its_check(glasses):
    opened(glasses)
    glasses.tilt(-1)
    glasses.tilt(-1)
    glasses.tilt(-1)
    assert cursor_row(glasses) == "x Minsk has 137k people"
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(FACTS) == [facts(2, 2, 1)]
    assert "loading.." in glasses.screen_text()
    glasses.call("factcheck", check_window(2, "F", CHECK, 1))
    text = glasses.screen_text()
    assert "FALSE" in text and "Minsk has 137 thousand" in text
    assert "Minsk." not in text                  # four lines only
    assert color_of(glasses, "FALSE") == "RED"
    assert color_of(glasses, "people.") == "WHITE"
    assert "tap = back  v" in text
    glasses.screenshot("factcheck-fact")
    glasses.assert_ok()


def test_a_check_asks_for_the_next_lines_as_it_scrolls(glasses):
    opened(glasses)
    for _ in range(3):
        glasses.tilt(-1)
    glasses.tap(1)
    glasses.call("factcheck", check_window(2, "F", CHECK, 1))
    glasses.clear_sent()
    glasses.tilt(1)
    assert glasses.sent(FACTS) == [facts(2, 2, 3)]   # a screen on, 3 rows
    assert "loading.." in glasses.screen_text()
    glasses.call("factcheck", check_window(2, "F", CHECK, 3))
    text = glasses.screen_text()
    assert "FALSE" not in text and "belstat.gov.by" in text
    assert "tap = back  ^" in text
    glasses.tilt(-1)
    assert glasses.sent(FACTS)[-1] == facts(2, 2, 1)
    glasses.call("factcheck", check_window(2, "F", CHECK, 1))
    assert color_of(glasses, "FALSE") == "RED"
    glasses.assert_ok()


def test_a_check_for_another_fact_is_ignored(glasses):
    opened(glasses)
    for _ in range(3):
        glasses.tilt(-1)
    glasses.tap(1)
    glasses.call("factcheck", check_window(3, "M", ["PARTLY TRUE"], 1))
    assert "PARTLY TRUE" not in glasses.screen_text()
    assert "loading.." in glasses.screen_text()


def test_tap_or_double_tap_goes_back_to_the_list(glasses):
    opened(glasses)
    glasses.tilt(-1)
    glasses.tap(1)
    glasses.call("factcheck",
                 check_window(4, "P", ["CHECKING..", "Everest is 8849 m"], 1))
    glasses.clear_sent()
    glasses.tap(1)
    assert asked(glasses, 3) == (1, 0)           # its window again
    answer(glasses, FOUR)
    assert cursor_row(glasses) == ". Everest is 8849 m"
    glasses.tap(1)
    glasses.clear_sent()
    glasses.tap(2)
    assert not glasses.sent(APP_STOP)            # back, not out
    assert cursor_row(glasses) == ". Everest is 8849 m"
    assert glasses.emu._mic_on
    glasses.assert_ok()


def kb(glasses):
    """The Lua heap in use, after a full collection, in KB."""
    glasses.send(0x30, b"\x07" + b"collectgarbage('collect') "
                 b"print(collectgarbage('count'))")
    glasses.advance(0.2)
    return float(glasses.joined(0x09)[-1][1].lstrip(b"+").split()[0])


def test_a_long_session_takes_no_more_memory(glasses):
    """The glasses hold four facts whatever the phone has: memory after
    paging through 137 is what it was after the first four."""
    def kb():
        return globals()["kb"](glasses)

    session = numbered(137)
    opened(glasses, session[:4])
    glasses.tilt(-1)
    before = kb()
    glasses.tilt(1)
    opened_at = kb()
    for _ in range(140):
        glasses.tilt(-1)
        if asked(glasses, 3)[0] != 0:
            answer(glasses, session)
    assert cursor_row(glasses) == "+ Fact 1"
    after = kb()
    assert after - min(before, opened_at) < 4    # KB
    glasses.assert_ok()


# ---------------------------------------------------------------- notes

def test_a_note_is_grey_and_goes_by_itself(glasses):
    opened(glasses)
    glasses.call("factcheck", "n:No facts in that")
    assert color_of(glasses, "No facts in that") == "GREY"
    glasses.advance(6)                           # past NOTE_TIME
    assert "No facts in that" not in glasses.screen_text()
    assert "tap = check" in glasses.screen_text()


def test_an_error_is_red(glasses):
    opened(glasses)
    glasses.call("factcheck", "e:Set up the agent")
    assert color_of(glasses, "Set up the agent") == "RED"
    glasses.screenshot("factcheck-error")
    glasses.assert_ok()


def test_a_late_answer_does_not_start_it_listening(glasses):
    glasses.clear_sent()
    glasses.call("factcheck", window(FOUR, 0))   # not running
    assert not glasses.emu._mic_on
    assert not glasses.sent(REC_START)
    assert not glasses.sent(FACTS)
    glasses.assert_ok()


# ---------------------------------------------------------------- the link

def test_the_link_lost_stops_listening_and_back_listens_again(glasses):
    opened(glasses)
    glasses.emu.connected = False
    glasses.advance(1)
    assert not glasses.emu._mic_on
    assert color_of(glasses, "no phone") == "RED"
    glasses.advance(13.7)                        # it stays: not a note
    assert "no phone" in glasses.screen_text()
    glasses.clear_sent()
    glasses.emu.connected = True
    glasses.advance(1)
    assert glasses.emu._mic_on
    sent = glasses.sent()
    assert bytes([REC_START, 16, 8, 4]) in sent and facts(3) in sent
    assert "no phone" not in glasses.screen_text()
    glasses.assert_ok()


def test_asks_for_the_list_again_until_it_comes(glasses):
    glasses.open_app("factcheck")
    glasses.clear_sent()
    glasses.advance(3)
    assert not glasses.sent(FACTS)
    glasses.advance(3)                           # past RETRY, 5 s
    assert glasses.sent(FACTS) == [facts(3)]
    glasses.call("factcheck", window([], 0))
    glasses.clear_sent()
    glasses.advance(13.7)
    assert not glasses.sent(FACTS)


# ---------------------------------------------------------------- leaving

def test_a_double_tap_from_the_list_leaves_and_tells_the_phone(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert facts(0) in glasses.sent()
    assert not glasses.sent(REC_DROP)            # that is the Assistant's
    assert not glasses.emu._mic_on
    assert "Glaz > Apps" in glasses.screen_text()
    glasses.assert_ok()


def test_opened_again_it_starts_over(glasses):
    opened(glasses)
    glasses.tap(2)
    glasses.clear_sent()
    glasses.open_app("factcheck")
    assert "Water boils" not in glasses.screen_text()
    assert "0:00  tap = check" in glasses.screen_text()
    assert glasses.sent(FACTS) == [facts(3)]
    glasses.assert_ok()

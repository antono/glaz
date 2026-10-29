"""Factchecker (apps/factcheck/factcheck.lua) on Frame, the only glasses that
have it: it listens from the start, the sound streamed to the phone; a tap
on the bottom row cuts the conversation there for the phone to check; the
facts the phone sends back listed with a mark and a colour by verdict, one
opened to read its check; notes that go by themselves; the link lost and
back; leaving tells the phone (docs/PROTOCOL.md, "Factchecker").
"""
import struct

import pytest

from glasses import APP_START, APP_STOP, has_module

pytestmark = pytest.mark.module("factcheck")

# Glasses -> phone (apps/factcheck/factcheck.lua)
FACTS, AUDIO, AUDIO_END = 0x01, 0x05, 0x06
REC_DROP, REC_START = 0x10, 0x1F

LIST = ("f:0\n1|T|Water boils at 100 C\n2|F|Minsk has 137k people"
        "\n3|M|Coffee dehydrates\n4|P|Everest is 8849 m")
CHECK = ("d:2:F\nFALSE\nMinsk has 137 thousand\npeople.\n"
         "About 2 million live in\nMinsk.\nbelstat.gov.by")


def facts(op, ident=0):
    return struct.pack(">BBH", FACTS, op, ident)   # Lua's >BBI2


def opened(g, listed=LIST):
    """Factchecker from the menu, listening, the phone's facts on screen."""
    g.open_app("factcheck")
    if listed is not None:
        g.call("factcheck", listed)
    return g


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
    glasses.advance(1801)                        # past MAX_LISTEN
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
    glasses.call("factcheck", "f:0" + LIST[3:])  # the phone has read it
    assert "reading.." not in glasses.screen_text()
    glasses.assert_ok()


def test_the_facts_are_marked_and_coloured_by_verdict(glasses):
    opened(glasses)
    for text, color in (("+ Water boils at 100 C", "GREEN"),
                        ("x Minsk has 137k people", "RED"),
                        ("~ Coffee dehydrates", "YELLOW"),
                        (". Everest is 8849 m", "WHITE")):
        assert color_of(glasses, text) == color
    glasses.call("factcheck", LIST + "\n5|U|Cats sleep 16 h")
    assert color_of(glasses, "? Cats sleep 16 h") == "GREY"
    glasses.tilt(-1)
    glasses.tilt(-1)
    glasses.screenshot("factcheck-list")
    glasses.assert_ok()


def test_the_list_shows_the_newest_with_the_cursor_below(glasses):
    many = "f:0" + "".join(f"\n{i}|T|Fact {i}" for i in range(1, 8))
    opened(glasses, many)
    text = glasses.screen_text()
    assert "Fact 1" not in text and "+ Fact 4" in text and "+ Fact 7" in text
    assert cursor_row(glasses).endswith("tap = check")
    assert color_of(glasses, cursor_row(glasses)) == "YELLOW"
    glasses.assert_ok()


def test_tilts_move_up_the_facts_and_back_down(glasses):
    many = "f:0" + "".join(f"\n{i}|T|Fact {i}" for i in range(1, 8))
    opened(glasses, many)
    glasses.tilt(-1)
    assert cursor_row(glasses) == "+ Fact 7"
    for _ in range(4):
        glasses.tilt(-1)
    assert cursor_row(glasses) == "+ Fact 3"     # scrolled up to it
    assert "Fact 7" not in glasses.screen_text()
    for _ in range(5):
        glasses.tilt(1)
    assert cursor_row(glasses).endswith("tap = check")
    glasses.tilt(1)                              # no further
    assert cursor_row(glasses).endswith("tap = check")
    glasses.assert_ok()


def test_the_cursor_stays_on_its_fact_as_the_list_changes(glasses):
    opened(glasses)
    glasses.tilt(-1)
    glasses.tilt(-1)
    assert cursor_row(glasses) == "~ Coffee dehydrates"
    glasses.call("factcheck", LIST + "\n5|P|Cats sleep 16 h")
    assert cursor_row(glasses) == "~ Coffee dehydrates"
    glasses.assert_ok()


def test_new_facts_follow_with_the_cursor_below(glasses):
    opened(glasses)
    glasses.call("factcheck", LIST + "\n5|P|Cats sleep 16 h")
    text = glasses.screen_text()
    assert ". Cats sleep 16 h" in text and "Water boils" not in text
    assert cursor_row(glasses).endswith("tap = check")


def test_tilts_with_no_facts_do_nothing(glasses):
    opened(glasses, "f:0")
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
    assert glasses.sent(FACTS) == [facts(2, 2)]
    assert "loading.." in glasses.screen_text()
    glasses.call("factcheck", CHECK)
    text = glasses.screen_text()
    assert "FALSE" in text and "Minsk has 137 thousand" in text
    assert color_of(glasses, "FALSE") == "RED"
    assert color_of(glasses, "people.") == "WHITE"
    assert "tap = back  v" in text
    glasses.screenshot("factcheck-fact")
    glasses.assert_ok()


def test_a_check_scrolls_by_a_screen(glasses):
    opened(glasses)
    for _ in range(3):
        glasses.tilt(-1)
    glasses.tap(1)
    glasses.call("factcheck", CHECK)
    glasses.tilt(1)
    text = glasses.screen_text()
    assert "FALSE" not in text and "belstat.gov.by" in text
    assert "tap = back  ^" in text
    glasses.tilt(-1)
    assert "FALSE" in glasses.screen_text()
    glasses.assert_ok()


def test_a_check_for_another_fact_is_ignored(glasses):
    opened(glasses)
    for _ in range(3):
        glasses.tilt(-1)
    glasses.tap(1)
    glasses.call("factcheck", "d:3:M\nPARTLY TRUE")
    assert "PARTLY TRUE" not in glasses.screen_text()
    assert "loading.." in glasses.screen_text()


def test_tap_or_double_tap_goes_back_to_the_list(glasses):
    opened(glasses)
    glasses.tilt(-1)
    glasses.tap(1)
    glasses.call("factcheck", "d:4:P\nCHECKING..\nEverest is 8849 m")
    glasses.tap(1)
    assert cursor_row(glasses) == ". Everest is 8849 m"
    glasses.tap(1)
    glasses.clear_sent()
    glasses.tap(2)
    assert not glasses.sent(APP_STOP)            # back, not out
    assert cursor_row(glasses) == ". Everest is 8849 m"
    assert glasses.emu._mic_on
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
    glasses.call("factcheck", LIST)              # not running
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
    glasses.call("factcheck", "f:0")
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

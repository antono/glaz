"""Reader (modules/reader.lua), the speed reader, on each pair of glasses
that has it (Frame only for now): one word at a time with its pivot letter
red at a fixed spot, the words asked from the phone in batches (TEXT_GET)
and answered through MODULE_CALL, a tap to read and pause, a tilt for the
speed while reading and for the sentences while paused, the speed set on
the phone, the place told to the phone on a pause, at the end and on
leaving, and what it shows with no text or no phone."""
import struct

import pytest

from glasses import APP_BACKGROUND, APP_OPEN, APP_STOP, HANDS_OFF, has_module

pytestmark = pytest.mark.module("reader")

TEXT_GET = 0x0A
RESUME = 0xFFFFFFFF
PIVOT_X = 250          # the centre of the red letter
WORD_Y = 146


def requests(g):
    """The TEXT_GET requests sent: (place, from, count, wpm, text) each."""
    return [struct.unpack(">IIBHB", m[1:]) for m in g.sent(TEXT_GET)]


class Phone:
    """The phone's side of Reader: a text of words, its number and the
    place in it; answers the glasses' requests for words."""

    def __init__(self, g, words, text=1, place=0):
        self.g, self.words, self.text, self.place = g, words, text, place
        self.seen = 0
        self.kept = []         # (place, wpm) the glasses told it

    def answer(self, frm, count=60):
        body = " ".join(self.words[frm:frm + count])
        self.g.call("reader", f"t:{frm}:{len(self.words)}:{self.text}:{body}")

    def serve(self):
        """Answers every request sent since the last call."""
        reqs = requests(self.g)
        new, self.seen = reqs[self.seen:], len(reqs)
        for place, frm, count, wpm, _ in new:
            if count == 0:
                self.kept.append((place, wpm))
                self.place = place
            else:
                self.answer(self.place if frm == RESUME else frm, count)

    def run(self, seconds, step=0.1):
        """Lets time pass, answering as it goes."""
        for _ in range(round(seconds / step)):
            self.serve()
            self.g.advance(step)
        self.serve()


def word(g):
    """The word on screen, its pieces put together, and its red letter."""
    pieces = [t for t in g.texts() if t.y == WORD_Y]
    red = [t.text for t in pieces if t.color == "RED"]
    return "".join(t.text for t in sorted(pieces, key=lambda t: t.x)), \
        (red[0] if red else None)


def status(g):
    return [t.text for t in g.texts() if t.y == 285]


def opened(g, words, **kw):
    """Reader on screen with the phone's text in it, paused at its place."""
    g.clear_sent()
    g.open_app("reader")
    phone = Phone(g, words, **kw)
    phone.run(0.2)
    return phone


def changes(g, phone, seconds, step=0.02):
    """The words shown as time passes, and when each came."""
    out, last, t = [], None, 0.0
    for _ in range(round(seconds / step)):
        phone.serve()
        g.advance(step)
        t += step
        w = word(g)[0]
        if w != last:
            out.append((round(t, 2), w))
            last = w
    return out


TEXT = "Hello there. How are you?".split()
LONG = [f"w{i}." if i % 10 == 9 else f"w{i}" for i in range(137)]


# ---------------------------------------------------------------- start

def test_opens_loading_and_asks_for_the_place(glasses):
    glasses.clear_sent()
    glasses.open_app("reader")
    assert requests(glasses) == [(0, RESUME, 60, 300, 0)]
    text = glasses.screen_text()
    assert "Reader" in text
    assert "loading" in text
    assert "300 wpm" in text
    glasses.screenshot("reader-loading")
    glasses.assert_ok()


def test_the_first_word_comes_paused_with_its_letter_red(glasses):
    opened(glasses, TEXT)
    assert word(glasses) == ("Hello", "e")
    assert status(glasses) == ["300 wpm", "paused", "20%"]
    red = next(t for t in glasses.texts() if t.color == "RED")
    assert red.y == WORD_Y and abs(red.x - PIVOT_X) < 10
    assert glasses.lit() > 0
    glasses.screenshot("reader-paused")
    glasses.assert_ok()


def test_starts_at_the_phones_place(glasses):
    opened(glasses, LONG, place=37)
    assert word(glasses)[0] == "w37"
    assert "27%" in status(glasses)               # word 38 of 137
    glasses.assert_ok()


@pytest.mark.parametrize("w, red", [
    ("a", "a"), ("Hello,", "e"), ("(quoted)", "o"), ("reader", "a"),
    ("seventeen", "v"), ("understanding", "e"), ("...", "."),
    ("привет", "и"),   # Cyrillic
])
def test_the_red_letter_is_left_of_the_middle(glasses, w, red):
    opened(glasses, [w])
    assert word(glasses) == (w, red)
    glasses.assert_ok()


def test_the_pivot_letter_stays_put_whatever_the_word(frame):
    xs = []
    for w in ("I", "reader", "understanding", "MMMMMMMMWW"):
        opened(frame, [w])
        r = next(t for t in frame.texts() if t.color == "RED")
        width = frame.emu.display.fonts.glyphs[ord(r.text)][0]
        xs.append(r.x + width / 2)
    assert max(xs) - min(xs) <= 2
    assert abs(xs[0] - PIVOT_X) <= 2
    frame.assert_ok()


def test_bytes_not_utf8_are_shown_byte_by_byte(glasses):
    opened(glasses, ["caf\xe9"])                  # sent as UTF-8: fine
    assert word(glasses)[0] == "caf\xe9"
    glasses.call("reader", b"t:0:1:2:ab\xffcd".decode("latin-1"))
    glasses.advance(0.2)
    assert word(glasses)[1] == "b"
    glasses.assert_ok()


# ---------------------------------------------------------------- reading

def test_a_tap_reads_one_word_after_another_to_the_end(glasses):
    phone = opened(glasses, TEXT)
    glasses.tap(1, settle=0)
    seen = [w for _, w in changes(glasses, phone, 4)]
    assert seen == TEXT
    assert status(glasses) == ["300 wpm", "the end", "100%"]
    # the end tells the phone the place
    assert phone.kept == [(4, 300)]
    glasses.screenshot("reader-end")
    glasses.assert_ok()


def test_words_stay_longer_at_a_stop_a_comma_and_for_long_words(glasses):
    words = "one two, three. extraordinary four five".split()
    phone = opened(glasses, words)
    glasses.tap(1, settle=0)
    seen = changes(glasses, phone, 4)
    assert [w for _, w in seen] == words
    t = dict((w, at) for at, w in seen)
    beat = 60 / 300
    # the tap counts after TAP_WINDOW, 0.75 s; the first word of a run
    # then stays twice as long, the eye has to find it
    assert t["two,"] == pytest.approx(0.75 + 2 * beat, abs=0.06)
    assert t["three."] - t["two,"] == pytest.approx(1.5 * beat, abs=0.05)
    assert t["extraordinary"] - t["three."] == pytest.approx(2 * beat,
                                                             abs=0.05)
    assert t["four"] - t["extraordinary"] == pytest.approx(1.25 * beat,
                                                           abs=0.05)
    assert t["five"] - t["four"] == pytest.approx(beat, abs=0.05)
    glasses.assert_ok()


def test_a_tap_pauses_and_tells_the_phone_the_place(glasses):
    phone = opened(glasses, LONG)
    glasses.tap(1)
    phone.run(1)
    glasses.tap(1)
    phone.serve()
    place = phone.kept[-1][0]
    assert place > 0
    shown = word(glasses)[0]
    assert shown == LONG[place]
    assert "paused" in status(glasses)
    phone.run(5)
    assert word(glasses)[0] == shown              # stays
    glasses.assert_ok()


def test_a_tap_at_the_end_reads_again_from_the_start(glasses):
    phone = opened(glasses, TEXT)
    glasses.tap(1)
    phone.run(4)
    assert "the end" in status(glasses)
    glasses.clear_sent()
    phone.seen = 0
    glasses.tap(1, settle=0)
    glasses.advance(1)
    # what was held is dropped and asked again from the first word
    assert requests(glasses)[0][1:3] == (0, 60)
    assert "loading" in glasses.screen_text()
    seen = [w for _, w in changes(glasses, phone, 4)]
    assert seen[0] == "Hello" and seen[-1] == "you?"
    glasses.assert_ok()


def test_asks_for_more_before_running_out(glasses):
    phone = opened(glasses, LONG)
    assert requests(glasses)[-1][1:3] == (RESUME, 60)
    glasses.tap(1)
    phone.run(60 * 0.2 + 3)                       # past word 40
    froms = [r[1] for r in requests(glasses) if r[2]]
    assert froms[:2] == [RESUME, 60]
    phone.run(137 * 0.25)
    assert word(glasses)[0] == "w136"
    assert status(glasses) == ["300 wpm", "the end", "100%"]
    glasses.assert_ok()


def test_waits_on_the_last_word_held_until_more_come(glasses):
    phone = opened(glasses, LONG)
    glasses.tap(1)
    glasses.advance(20)                           # the phone silent
    assert word(glasses)[0] == "w59."
    assert "paused" not in status(glasses)
    # asked for them again every RETRY, 5 s
    assert [r[1] for r in requests(glasses)[-3:]] == [60, 60, 60]
    phone.answer(60)                              # and 0.1 s
    assert word(glasses)[0] == "w60"              # its time long past
    glasses.advance(0.15)
    assert word(glasses)[0] == "w61"              # w60 had its time
    glasses.assert_ok()


def test_asks_again_when_the_phone_does_not_answer(glasses):
    glasses.clear_sent()
    glasses.open_app("reader")
    glasses.advance(4)
    assert len(requests(glasses)) == 1
    glasses.advance(2)                            # past RETRY, 5 s
    assert len(requests(glasses)) == 2
    assert requests(glasses)[1][1] == RESUME
    glasses.assert_ok()


def test_a_late_answer_to_an_old_request_is_ignored(glasses):
    opened(glasses, LONG)                         # words 0 to 59 held
    before = glasses.screen_text()
    glasses.call("reader", "t:100:137:1:" + " ".join(LONG[100:160]))
    glasses.advance(0.2)
    assert glasses.screen_text() == before
    # not taken as the words after 59 either: on past the sentences held,
    # the glasses ask for word 60
    for _ in range(5):
        glasses.tilt(1)
    assert word(glasses)[0] == "w50"
    glasses.clear_sent()
    glasses.tilt(1)
    assert requests(glasses)[0][1:3] == (60, 60)
    assert "w10" not in word(glasses)[0]
    glasses.assert_ok()


def test_reading_does_not_time_out_but_paused_it_does(glasses):
    glasses.settings({"reader.wpm": "100"})
    glasses.advance(0.2)
    phone = opened(glasses, LONG)
    glasses.tap(1)
    glasses.clear_sent()
    phone.run(70)                                 # past APP_TIMEOUT, 60 s
    assert not glasses.sent(APP_STOP)
    assert "the end" not in status(glasses)
    assert word(glasses)[0].startswith("w")
    glasses.tap(1)
    glasses.clear_sent()
    phone.run(65)
    assert glasses.sent(APP_STOP)
    assert "wpm" not in glasses.screen_text()
    glasses.assert_ok()


# ---------------------------------------------------------------- tilt

def test_a_tilt_while_reading_changes_the_speed(glasses):
    phone = opened(glasses, LONG)
    glasses.tap(1)
    glasses.tilt(1)
    assert "325 wpm" in status(glasses)
    assert "paused" not in status(glasses)
    glasses.screenshot("reader-reading")
    glasses.tilt(-1)
    glasses.tilt(-1)
    assert "275 wpm" in status(glasses)
    phone.serve()
    glasses.tap(1)                                # the pause keeps it
    phone.serve()
    assert phone.kept[-1][1] == 275
    glasses.assert_ok()


def test_the_speed_stays_within_100_and_800(glasses):
    glasses.settings({"reader.wpm": "790"})
    glasses.advance(0.2)
    phone = opened(glasses, LONG * 10)
    glasses.tap(1)
    glasses.tilt(1)
    assert "800 wpm" in status(glasses)
    glasses.tilt(1)
    assert "800 wpm" in status(glasses)
    glasses.tap(1)
    glasses.settings({"reader.wpm": "110"})
    phone.run(0.2)
    assert "110 wpm" in status(glasses)
    glasses.tap(1)
    glasses.tilt(-1)
    assert "100 wpm" in status(glasses)
    glasses.assert_ok()


def test_a_tilt_while_paused_goes_by_sentences(glasses):
    words = "One two. Three four five. Six seven.".split()
    opened(glasses, words)
    glasses.tilt(1)
    assert word(glasses)[0] == "Three"
    glasses.tilt(1)
    assert word(glasses)[0] == "Six"
    glasses.tilt(1)                               # no sentence after
    assert word(glasses)[0] == "Six"
    glasses.tilt(-1)
    assert word(glasses)[0] == "Three"
    glasses.tilt(-1)
    glasses.tilt(-1)                              # at the start already
    assert word(glasses)[0] == "One"
    assert "paused" in status(glasses)
    assert "300 wpm" in status(glasses)           # the speed stays
    glasses.assert_ok()


def test_a_tilt_back_before_the_words_held_asks_the_phone(glasses):
    phone = opened(glasses, LONG, place=100)
    glasses.clear_sent()
    phone.seen = 0
    glasses.tilt(-1)
    # word 100 starts the text held: back BEHIND words, asked again
    assert requests(glasses)[0][1:3] == (70, 60)
    phone.run(0.2)
    assert word(glasses)[0] == "w70"
    glasses.assert_ok()


def test_a_tilt_on_past_the_words_held_asks_the_phone(glasses):
    words = [f"w{i}" for i in range(137)]         # not one sentence ends
    phone = opened(glasses, words)
    glasses.clear_sent()
    phone.seen = 0
    glasses.tilt(1)
    assert requests(glasses)[0][1:3] == (60, 60)
    phone.run(0.2)
    assert word(glasses)[0] == "w60"
    glasses.assert_ok()


def test_reading_on_forgets_words_far_behind(glasses):
    phone = opened(glasses, LONG)
    glasses.tap(1)
    phone.run(60 * 0.25)
    glasses.tap(1)
    phone.serve()
    place = phone.kept[-1][0]
    assert place > 45
    glasses.clear_sent()
    phone.seen = 0
    # back by sentences while the words are held: BEHIND, 30, of them
    for _ in range(6):
        at = int(word(glasses)[0].strip("w."))
        glasses.tilt(-1)
        if requests(glasses):
            break
        assert word(glasses)[0] == f"w{(at - 1) // 10 * 10}"
    # the sentence before is not held whole (its first word is, but not the
    # stop before it): the phone sends from BEHIND words back
    assert at - 10 <= place - 30
    assert requests(glasses) == [(at - 30, at - 30, 60, 300, 1)]
    phone.run(0.2)
    assert word(glasses)[0] == f"w{at - 30}"
    glasses.assert_ok()


# ---------------------------------------------------------------- the phone

def test_the_speed_comes_from_the_phones_setting(glasses):
    glasses.settings({"reader.wpm": "137"})
    glasses.advance(0.2)                          # taken before the open
    glasses.clear_sent()
    glasses.open_app("reader")
    assert "137 wpm" in glasses.screen_text()
    assert requests(glasses)[0][3] == 137
    glasses.settings({"reader.wpm": "50"})
    glasses.advance(0.2)
    assert "100 wpm" in glasses.screen_text()     # the least it goes
    glasses.settings({"reader.wpm": "137"})
    glasses.advance(0.2)
    assert "137 wpm" in glasses.screen_text()
    glasses.assert_ok()


def test_a_setting_changed_while_reading_takes_over_a_tilt(glasses):
    phone = opened(glasses, LONG)
    glasses.tap(1)
    glasses.tilt(1)
    assert "325 wpm" in status(glasses)
    glasses.settings({"reader.wpm": "137"})
    phone.run(0.2)
    assert "137 wpm" in status(glasses)
    glasses.assert_ok()


def test_another_text_starts_over_at_its_place(glasses):
    phone = opened(glasses, TEXT)
    glasses.tap(1)
    phone.run(0.5)
    # picked in the phone's library: its words, from its place
    phone.text, phone.words = 2, LONG
    phone.answer(37)
    assert word(glasses)[0] == "w37"
    assert "27%" in status(glasses)
    glasses.tap(1)
    phone.serve()
    assert requests(glasses)[-1][4] == 2          # the text it holds now
    glasses.assert_ok()


def test_new_starts_again_from_the_phones_place(glasses):
    phone = opened(glasses, TEXT)
    glasses.tap(1)
    phone.run(0.5)
    phone.words, phone.place = LONG, 37
    glasses.clear_sent()
    phone.seen = 0
    glasses.call("reader", "new")
    phone.run(0.3)
    assert requests(glasses)[0][1] == RESUME
    assert word(glasses)[0] == "w37"
    assert "paused" in status(glasses)
    glasses.assert_ok()


def test_a_malformed_answer_changes_nothing(glasses):
    opened(glasses, TEXT)
    before = glasses.screen_text()
    for arg in ("", "t:", "t:x:5:1:a b", "t:0:5:a b", "hello", "t:-1:5:1:a"):
        glasses.call("reader", arg)
        glasses.advance(0.1)
    assert glasses.screen_text() == before
    glasses.assert_ok()


def test_no_text_on_the_phone_says_where_to_pick_one(glasses):
    glasses.clear_sent()
    glasses.open_app("reader")
    glasses.call("reader", "t:0:0:1:")
    glasses.advance(0.2)
    text = glasses.screen_text()
    assert "no text" in text
    assert "text: Glaz > Menu" in text
    assert "%" not in status(glasses)[-1]
    glasses.screenshot("reader-no-text")
    # a tap asks again
    glasses.clear_sent()
    glasses.tap(1)
    assert requests(glasses)[0][1] == RESUME
    assert "loading" in glasses.screen_text()
    glasses.assert_ok()


def test_no_phone_says_so_and_a_tap_retries(frame):
    frame.open_app("reader")                      # asks, no answer
    frame.emu.connected = False
    frame.advance(6)                              # past RETRY, 5 s
    text = frame.screen_text()
    assert "no phone" in text
    assert "tap to retry" in text
    frame.screenshot("reader-no-phone")
    frame.emu.connected = True
    frame.clear_sent()
    frame.tap(1)
    # asked again as soon as there is a link, and again for the tap
    assert requests(frame)
    assert {r[1] for r in requests(frame)} == {RESUME}
    assert "loading" in frame.screen_text()
    Phone(frame, TEXT).serve()
    assert word(frame)[0] == "Hello"
    frame.assert_ok()


def test_the_phone_back_answers_without_a_tap(frame):
    frame.open_app("reader")
    frame.emu.connected = False
    frame.advance(6)
    assert "no phone" in frame.screen_text()
    frame.emu.connected = True
    frame.clear_sent()
    frame.advance(0.1)
    assert [r[1] for r in requests(frame)] == [RESUME]
    Phone(frame, TEXT).serve()
    assert word(frame)[0] == "Hello"
    assert "tap to retry" not in frame.screen_text()
    frame.assert_ok()


# ---------------------------------------------------------------- leaving

def test_leaving_tells_the_phone_the_place_and_stops(glasses):
    phone = opened(glasses, LONG, place=37)
    glasses.tilt(1)                               # the next sentence: 40
    glasses.clear_sent()
    glasses.tap(2)
    assert requests(glasses) == [(40, 40, 0, 300, 1)]
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)
    glasses.assert_ok()


def test_leaving_before_any_text_tells_the_phone_nothing(glasses):
    glasses.open_app("reader")
    glasses.clear_sent()
    glasses.tap(2)
    assert not requests(glasses)
    glasses.assert_ok()


def test_an_answer_after_leaving_does_not_start_it(glasses):
    glasses.open_app("reader")
    glasses.tap(2)
    glasses.clear_sent()
    glasses.call("reader", "t:0:5:1:" + " ".join(TEXT))
    glasses.advance(1)
    assert not glasses.sent(APP_BACKGROUND)
    assert not requests(glasses)
    assert "Hello" not in glasses.screen_text()
    glasses.assert_ok()


def test_leaving_while_reading_tells_the_place_and_the_tilted_speed(glasses):
    phone = opened(glasses, LONG)
    glasses.tap(1)
    glasses.tilt(1)                               # 325 wpm
    phone.run(1)
    glasses.clear_sent()
    phone.seen = 0
    glasses.tap(2)
    reqs = requests(glasses)
    assert len(reqs) == 1
    place, frm, count, wpm, text = reqs[0]
    assert (frm, count, wpm, text) == (place, 0, 325, 1)
    assert place > 3
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)
    assert "wpm" not in glasses.screen_text()
    glasses.assert_ok()


def test_leaving_with_no_text_tells_the_phone_nothing(glasses):
    glasses.open_app("reader")
    glasses.call("reader", "t:0:0:1:")
    glasses.advance(0.2)
    glasses.clear_sent()
    glasses.tap(2)
    assert not requests(glasses)
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_opening_again_starts_afresh_from_the_phone(glasses):
    phone = opened(glasses, LONG)
    glasses.tap(1)
    glasses.tilt(1)                               # 325, on the glasses only
    phone.run(2)
    glasses.tap(2)
    phone.serve()
    assert phone.place > 0
    glasses.clear_sent()
    phone.seen = 0
    glasses.open_app("reader")
    # the speed set on the phone again, and the place asked of the phone;
    # the module was unloaded on leaving, so no text is held either
    assert requests(glasses) == [(0, RESUME, 60, 300, 0)]
    assert "loading" in glasses.screen_text()
    assert "300 wpm" in glasses.screen_text()
    phone.serve()
    assert word(glasses)[0] == LONG[phone.place]
    glasses.assert_ok()


# ---------------------------------------------------------------- more input

def test_nothing_happens_to_a_tap_or_tilt_while_loading(glasses):
    glasses.clear_sent()
    glasses.open_app("reader")
    glasses.tap(1)
    glasses.tilt(1)
    glasses.tilt(-1)
    # still the one request of the start, still loading, at 300 wpm
    assert len(requests(glasses)) == 1
    assert "loading" in glasses.screen_text()
    assert status(glasses) == ["300 wpm"]
    glasses.assert_ok()


def test_the_first_word_after_a_pause_stays_twice_as_long(glasses):
    phone = opened(glasses, LONG)
    glasses.tap(1)
    phone.run(1)
    glasses.tap(1)                                # pause
    phone.serve()
    at = phone.kept[-1][0]
    glasses.tap(1, settle=0)                      # and on
    seen = changes(glasses, phone, 2)
    # the tap counts after 0.75 s; the word it paused on then stays 2 beats
    assert seen[1][1] == LONG[at + 1]
    assert seen[1][0] == pytest.approx(0.75 + 2 * 0.2, abs=0.06)
    glasses.assert_ok()


def test_the_phones_remote_reads_pauses_and_moves(glasses):
    phone = opened(glasses, LONG)
    glasses.remote(3, 1)                          # Down: the next sentence
    assert word(glasses)[0] == "w10"
    glasses.remote(2, 255)                        # Left: the one before
    assert word(glasses)[0] == "w0"
    glasses.remote(2, 1)                          # Right
    assert word(glasses)[0] == "w10"
    glasses.remote(1, 1)                          # a tap: read
    assert "paused" not in status(glasses)
    glasses.remote(2, 1)                          # reading: faster
    assert "325 wpm" in status(glasses)
    glasses.remote(3, 255)                        # Up: slower
    assert "300 wpm" in status(glasses)
    glasses.remote(1, 1)                          # a tap: pause
    phone.serve()
    assert "paused" in status(glasses)
    assert phone.kept[-1][1] == 300
    glasses.assert_ok()


def test_hands_off_the_head_tilt_does_nothing_but_the_remote_does(glasses):
    opened(glasses, "One two. Three four.".split())
    glasses.send(HANDS_OFF, bytes([1]))
    glasses.tilt(1)
    assert word(glasses)[0] == "One"
    glasses.remote(2, 1)
    assert word(glasses)[0] == "Three"
    glasses.assert_ok()


def test_a_notification_while_reading_does_not_stop_the_words(glasses):
    phone = opened(glasses, LONG)
    glasses.tap(1)
    glasses.notify("Chat", "Ann", "137 words")
    assert "Ann" in glasses.screen_text()
    glasses.tilt(1)                               # under it: not the reader's
    phone.run(15)
    assert "Ann" not in glasses.screen_text()
    assert "300 wpm" in status(glasses)
    assert int(word(glasses)[0].strip("w.")) > 40  # it read on underneath
    glasses.assert_ok()


# ---------------------------------------------------------------- words

def test_closing_quotes_and_brackets_still_end_a_sentence(glasses):
    words = ['He', 'said', '"go."', 'Then', '(sure!)', 'Да', 'нет.»',
             'End']
    opened(glasses, words)
    seen = []
    for _ in range(4):
        glasses.tilt(1)
        seen.append(word(glasses)[0])
    assert seen == ["Then", "Да", "End", "End"]
    glasses.assert_ok()


def test_a_stop_a_question_a_colon_and_a_semicolon_take_their_time(glasses):
    words = ['a', 'Stop!"', 'so;', 'why?', 'thus:', 'b', 'c']
    phone = opened(glasses, words)
    glasses.tap(1, settle=0)
    seen = changes(glasses, phone, 5)
    assert [w for _, w in seen] == words
    t = dict((w, at) for at, w in seen)
    beat = 60 / 300
    assert t["so;"] - t['Stop!"'] == pytest.approx(2 * beat, abs=0.05)
    assert t["why?"] - t["so;"] == pytest.approx(1.5 * beat, abs=0.05)
    assert t["thus:"] - t["why?"] == pytest.approx(2 * beat, abs=0.05)
    assert t["b"] - t["thus:"] == pytest.approx(1.5 * beat, abs=0.05)
    glasses.assert_ok()


def test_a_long_word_is_counted_in_letters_not_bytes(glasses):
    # 'привет' is 6 letters but 12 bytes: no longer than 'reader';
    # 'здравствуйте' is 12 letters: a long word
    words = ['a', 'привет', 'b', 'здравствуйте', 'c']
    phone = opened(glasses, words)
    glasses.tap(1, settle=0)
    seen = changes(glasses, phone, 4)
    assert [w for _, w in seen] == words
    t = dict((w, at) for at, w in seen)
    beat = 60 / 300
    assert t["b"] - t["привет"] == pytest.approx(beat, abs=0.05)
    assert t["c"] - t["здравствуйте"] == pytest.approx(1.25 * beat, abs=0.05)
    glasses.assert_ok()


def test_spaces_around_and_between_words_are_dropped(glasses):
    glasses.open_app("reader")
    glasses.call("reader", "t:0:3:1:  one   two\tthree ")
    glasses.advance(0.2)
    assert word(glasses)[0] == "one"
    assert "33%" in status(glasses)               # word 1 of 3
    glasses.tap(1, settle=0)
    glasses.advance(3)
    assert word(glasses)[0] == "three"
    assert "the end" in status(glasses)
    glasses.assert_ok()


def test_a_short_answer_is_followed_by_the_next_words_while_paused(glasses):
    phone = Phone(glasses, LONG)
    glasses.clear_sent()
    glasses.open_app("reader")
    phone.seen = 1
    phone.answer(0, count=10)                     # 10 of 137: fewer than 20
    glasses.advance(0.1)
    # asked for the next ones at once, though nothing is read
    assert requests(glasses)[-1][1:3] == (10, 60)
    phone.run(0.2)
    assert "paused" in status(glasses)
    glasses.tilt(1)
    glasses.tilt(1)
    assert word(glasses)[0] == "w20"              # past the first 10 held
    glasses.assert_ok()


def test_a_setting_that_is_not_a_number_keeps_300(glasses):
    glasses.settings({"reader.wpm": "fast"})
    glasses.advance(0.2)
    glasses.open_app("reader")
    assert "300 wpm" in glasses.screen_text()
    glasses.assert_ok()


def test_the_end_with_no_phone_says_so(frame):
    phone = opened(frame, TEXT)
    frame.tap(1)
    phone.run(4)
    assert "the end" in status(frame)
    frame.emu.connected = False
    frame.tap(1)                                  # again from the start
    assert "no phone" in frame.screen_text()
    assert "tap to retry" in frame.screen_text()
    frame.assert_ok()


# ---------------------------------------------------------------- drawing

def test_loading_is_centred_on_the_pivot(frame):
    frame.open_app("reader")
    t = next(t for t in frame.texts() if t.text == "loading")
    assert t.color == "GREY" and t.y == WORD_Y
    glyphs = frame.emu.display.fonts.glyphs
    width = sum(glyphs[ord(c)][0] + 4 for c in "loading")
    assert abs(t.x + width / 2 - PIVOT_X) <= 4
    frame.assert_ok()


@pytest.mark.parametrize("w", [
    "reader", "Schöne", "naïveté", "привет", "Ёлка", "«цитата»", "(137)",
])
def test_the_pieces_of_a_word_join_up(frame, w):
    # each piece is a text() of its own, placed with the module's widths
    # (WIDTHS, LATIN1, CYRILLIC): each must start where the one before ends
    opened(frame, [w])
    pieces = sorted((t for t in frame.texts() if t.y == WORD_Y),
                    key=lambda t: t.x)
    assert "".join(t.text for t in pieces) == w
    glyphs = frame.emu.display.fonts.glyphs
    for a, b in zip(pieces, pieces[1:]):
        end = a.x + sum(glyphs[ord(c)][0] + 4 for c in a.text)
        assert end == b.x, (a, b)
    frame.assert_ok()


def test_every_letter_has_the_fonts_width(frame):
    # 'a?b': the middle letter is the red one, so the pieces around it show
    # whether the module's width for it is the font's (system_font.h). Two
    # text numbers in turn: each answer starts over with its one word.
    glyphs = frame.emu.display.fonts.glyphs
    frame.open_app("reader")
    letters = [c for c in range(0x30, 0x7F) if chr(c).isalnum()] + \
        [c for c in range(0xC0, 0x100) if c not in (0xD7, 0xF7)] + \
        list(range(0x400, 0x460))
    wrong = []
    for i, c in enumerate(letters):
        if c not in glyphs:
            continue
        frame.call("reader", f"t:0:1:{i % 2 + 1}:a{chr(c)}b")
        a, red, b = sorted((t for t in frame.texts() if t.y == WORD_Y),
                           key=lambda t: t.x)
        assert red.text == chr(c) and red.color == "RED"
        if (red.x - a.x, b.x - red.x) != (glyphs[ord("a")][0] + 4,
                                          glyphs[c][0] + 4):
            wrong.append(f"U+{c:04X} {chr(c)}")
    assert not wrong
    frame.assert_ok()


def test_the_guide_rules_and_notches_are_drawn(frame):
    opened(frame, TEXT)
    img = frame.image()

    def lit(x, y):
        # the display's coordinates start at 1, the image's at 0
        return img.getpixel((x - 1, y - 1)) != (0, 0, 0)

    for y in (126, 127, 202, 203):                # the rules, 2 px high
        assert all(lit(x, y) for x in (64, 300, 607))
        assert not lit(63, y) and not lit(608, y)
        assert img.getpixel((299, y - 1)) == (119, 119, 119)   # GREY
    assert not lit(100, 160)                      # between them: black
    # the notches, 2 px wide and 12 high, point at the pivot from the rules
    for y in (128, 139, 190, 201):
        assert lit(PIVOT_X - 1, y) and lit(PIVOT_X, y)
        assert not lit(PIVOT_X - 2, y) and not lit(PIVOT_X + 1, y)
    assert not lit(PIVOT_X, 140) and not lit(PIVOT_X, 189)
    frame.assert_ok()


# ---------------------------------------------------------------- Halo

def test_halo_has_no_reader(halo):
    assert not has_module("halo", "reader")
    halo.clear_sent()
    halo.send(APP_OPEN, "reader\n")
    halo.advance(0.5)
    assert not requests(halo)
    assert "wpm" not in halo.screen_text()
    halo.assert_ok()

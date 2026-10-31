"""Tuner (apps/tuner/tuner.lua) on each pair of glasses that has it -- Frame
only for now: the list of instruments, the tilt and the tap that pick
one, the tuning drawn from what the phone hears (MODULE_CALL 'tuner':
'p<pitch> <hz>', 'p', 's<text>'), the colours of in tune and out, TUNER
asked again until the phone answers, the glasses' own microphone
streamed when the setting says so (and when it fails), no phone, the
instrument remembered, the phone's remote, the needle on the scale, and
the module kept open while notes come and stopped when it leaves the
screen."""
import pytest

from glasses import (APP_BACKGROUND, APP_STOP, LUA_EVAL, LUA_RESULT,
                     Glasses, has_module)

pytestmark = pytest.mark.module("tuner")

TUNER, AUDIO, AUDIO_END, REC_START = 0x03, 0x05, 0x06, 0x1F
LISTEN_PHONE = bytes([TUNER, 1, 0])
LISTEN_GLASSES = bytes([TUNER, 1, 1])
QUIT = bytes([TUNER, 0])


def tuning(glasses, tilts=0):
    """The tuner on screen, the cursor tilts rows down, that instrument
    tuned: the phone asked to listen."""
    glasses.open_app("tuner")
    for _ in range(abs(tilts)):
        glasses.tilt(1 if tilts > 0 else -1)
    glasses.clear_sent()
    glasses.tap(1)


def colour_of(glasses, text):
    return next(t.color for t in glasses.texts() if t.text == text)


def needle(glasses):
    """The middle of the needle's lit columns, or None: it alone reaches
    above the scale's ticks (y 204..240, the tallest tick from 220)."""
    img = glasses.image()
    xs = [x for x in range(img.width) if sum(img.getpixel((x, 210))) > 60]
    return sum(xs) / len(xs) if xs else None


def lua(frame, code):
    """Lua run on the glasses, as the phone's console does (LUA_EVAL)."""
    frame.send(LUA_EVAL, b"\x07" + code.encode())
    assert frame.joined(LUA_RESULT)[-1][1][:1] == b"+"


# ---------------------------------------------------------------- the list

def test_only_frame_has_it():
    assert has_module("frame", "tuner")
    assert not has_module("halo", "tuner")


def test_opens_on_the_list_of_instruments(glasses):
    glasses.open_app("tuner")
    text = glasses.screen_text()
    assert "> Guitar" in text
    assert "E A D G B E" in text
    assert "  Banjo" in text and "G D G B D" in text
    assert "Balalaika" in text and "Domra" in text
    assert "Violin" not in text                  # four rows at a time
    assert colour_of(glasses, "> Guitar") == "YELLOW"
    assert not glasses.sent(TUNER)               # nothing to hear yet
    glasses.screenshot("tuner")
    glasses.assert_ok()


def test_a_tilt_moves_the_cursor_and_wraps_round(glasses):
    glasses.open_app("tuner")
    glasses.tilt(1)
    assert "> Banjo" in glasses.screen_text()
    glasses.tilt(-1)
    glasses.tilt(-1)                             # past the top: the last
    text = glasses.screen_text()
    assert "> Violin" in text and "G D A E" in text
    assert "Guitar" not in text                  # scrolled to the end
    assert "Ukulele" in text and "Bass" in text
    glasses.assert_ok()


# ---------------------------------------------------------------- tuning

def test_a_tap_tunes_it_and_asks_the_phone_to_listen(glasses):
    tuning(glasses)
    assert glasses.sent(TUNER) == [LISTEN_PHONE]
    text = glasses.screen_text()
    for name in ("E2", "A2", "D3", "G3", "B3", "E4"):
        assert name in text
    assert "play a string" in text
    assert "Guitar" not in text
    glasses.screenshot("tuner-guitar")
    glasses.assert_ok()


def test_the_banjo_names_its_short_string_first(glasses):
    tuning(glasses, tilts=1)
    strings = [t.text for t in sorted(glasses.texts(), key=lambda t: t.x)
               if t.y == 65]
    assert strings == ["G4", "D3", "G3", "B3", "D4"]
    glasses.assert_ok()


def test_a_note_in_tune_is_green(glasses):
    tuning(glasses)
    glasses.call("tuner", "p4502 1101")          # A2 and 2 cents
    text = glasses.screen_text()
    assert "+2 c" in text and "110.1 Hz" in text and "in tune" in text
    assert colour_of(glasses, "A2") == "GREEN"   # the string lit
    assert colour_of(glasses, "+2 c") == "GREEN"
    assert colour_of(glasses, "E2") == "WHITE"
    glasses.screenshot("tuner-in-tune")
    glasses.assert_ok()


def test_a_little_sharp_is_yellow_and_says_tune_down(glasses):
    tuning(glasses)
    glasses.call("tuner", "p4512 1124")
    text = glasses.screen_text()
    assert "+12 c" in text and "tune down" in text
    assert colour_of(glasses, "A2") == "YELLOW"
    glasses.screenshot("tuner-sharp")
    glasses.assert_ok()


def test_far_flat_is_red_and_says_tune_up(glasses):
    tuning(glasses)
    glasses.call("tuner", "p6363 3241")          # E4 and 37 cents flat
    text = glasses.screen_text()
    assert "-37 c" in text and "tune up" in text and "324.1 Hz" in text
    assert colour_of(glasses, "E4") == "RED"
    assert colour_of(glasses, "-37 c") == "RED"
    glasses.screenshot("tuner-flat")
    glasses.assert_ok()


def test_the_note_heard_is_named_by_the_nearest_semitone(glasses):
    tuning(glasses)
    glasses.call("tuner", "p4551 1137")          # nearer A#2, string A2
    text = glasses.screen_text()
    assert "A#2" in text and "+51 c" in text and "113.7 Hz" in text
    assert colour_of(glasses, "A2") == "RED"
    glasses.assert_ok()


def test_both_strings_of_a_note_are_lit(glasses):
    tuning(glasses, tilts=2)                     # Balalaika: E4 E4 A4
    glasses.call("tuner", "p6400 3296")
    lit = [t for t in glasses.texts() if t.text == "E4" and t.y == 65]
    assert len(lit) == 2 and all(t.color == "GREEN" for t in lit)
    assert colour_of(glasses, "A4") == "WHITE"
    glasses.assert_ok()


def test_nothing_heard_leaves_the_last_note_grey(glasses):
    tuning(glasses)
    glasses.call("tuner", "p4512 1124")
    glasses.call("tuner", "p")
    text = glasses.screen_text()
    assert "+12 c" in text and "112.4 Hz" in text
    assert "tune down" not in text and "play a string" in text
    assert colour_of(glasses, "+12 c") == "GREY"
    assert colour_of(glasses, "A2") == "WHITE"   # no string lit
    glasses.assert_ok()


def test_a_malformed_note_counts_as_nothing_heard(glasses):
    tuning(glasses)
    glasses.call("tuner", "p4512 1124")
    glasses.call("tuner", "p45.12 112")
    assert colour_of(glasses, "+12 c") == "GREY"
    glasses.call("tuner", "x137")                # unknown: ignored
    assert colour_of(glasses, "+12 c") == "GREY"
    glasses.assert_ok()


def test_the_phone_says_why_it_hears_nothing(glasses):
    tuning(glasses)
    glasses.call("tuner", "sopen glaz on the phone")
    assert "open glaz on the phone" in glasses.screen_text()
    assert colour_of(glasses, "open glaz on the phone") == "YELLOW"
    glasses.screenshot("tuner-status")
    glasses.call("tuner", "s")                   # listening again
    assert "play a string" in glasses.screen_text()
    glasses.call("tuner", "sallow the microphone")
    glasses.call("tuner", "p4500 1100")          # a note clears it
    text = glasses.screen_text()
    assert "allow the microphone" not in text and "in tune" in text
    glasses.assert_ok()


# ---------------------------------------------------------------- asking

def test_asks_again_every_3_s_until_the_phone_answers(glasses):
    tuning(glasses)
    glasses.advance(10)
    assert len(glasses.sent(TUNER)) >= 3
    assert set(glasses.sent(TUNER)) == {LISTEN_PHONE}
    glasses.call("tuner", "s")
    glasses.clear_sent()
    glasses.advance(10)
    assert not glasses.sent(TUNER)
    glasses.assert_ok()


def test_a_double_tap_goes_back_to_the_list_and_stops_listening(glasses):
    tuning(glasses, tilts=1)
    glasses.tap(2)
    assert glasses.sent(TUNER)[-1] == QUIT
    assert "> Banjo" in glasses.screen_text()
    glasses.clear_sent()
    glasses.advance(10)
    assert not glasses.sent(TUNER)               # no more asking
    glasses.tap(2)                               # the list leaves
    assert "Banjo" not in glasses.screen_text()
    glasses.assert_ok()


def test_the_list_opens_at_the_instrument_tuned_last(glasses):
    tuning(glasses, tilts=4)                     # Ukulele
    assert "G4" in glasses.screen_text() and "A4" in glasses.screen_text()
    glasses.tap(2)
    glasses.tap(2)
    glasses.open_app("tuner")
    assert "> Ukulele" in glasses.screen_text()
    glasses.assert_ok()


def test_the_instrument_is_kept_on_the_glasses(frame):
    tuning(frame, tilts=-1)                      # Violin
    prefs = frame.emu.files.path("prefs.txt").read_text()
    assert "tuner.instrument=7" in prefs
    frame.assert_ok()


# ---------------------------------------------------------------- no phone

def test_no_phone_says_so_and_asks_again_when_back(frame):
    tuning(frame)
    frame.emu.connected = False
    frame.advance(1)
    assert "no phone" in frame.screen_text()
    frame.emu.connected = True
    frame.advance(1)
    assert "no phone" not in frame.screen_text()
    assert "play a string" in frame.screen_text()
    assert frame.sent(TUNER)[-1] == LISTEN_PHONE
    frame.assert_ok()


# ---------------------------------------------------------------- timeouts

def test_notes_keep_it_open_30_s_past_the_app_timeout(glasses):
    tuning(glasses)
    glasses.call("tuner", "p4500 1100")
    glasses.advance(80)                          # 60 s + busy for 30
    assert "A2" in glasses.screen_text()
    glasses.clear_sent()
    glasses.advance(15)
    assert glasses.sent(APP_STOP)
    assert QUIT in glasses.sent(TUNER)
    glasses.assert_ok()


def test_without_notes_it_closes_after_the_app_timeout(glasses):
    tuning(glasses)
    glasses.call("tuner", "sallow the microphone")
    glasses.clear_sent()
    glasses.advance(65)
    assert glasses.sent(APP_STOP)
    assert QUIT in glasses.sent(TUNER)
    assert "allow the microphone" not in glasses.screen_text()
    glasses.assert_ok()


# ---------------------------------------------------- the glasses' microphone

def test_the_glasses_microphone_is_streamed_to_the_phone(frame):
    frame.settings({"tuner.mic": "glasses"})
    tuning(frame)
    assert frame.sent(TUNER) == [LISTEN_GLASSES]
    assert frame.sent(REC_START) == [bytes([REC_START, 16, 8, 3])]
    sound = bytes(range(256)) * 4 + bytes(137 * 2)
    frame.emu.mic_data.extend(sound)
    frame.advance(0.5)
    packets = frame.sent(AUDIO)
    assert b"".join(p[1:] for p in packets) == sound
    # whole 16-bit samples, each packet within Bluetooth's max_length()
    assert all(len(p) <= 246 and (len(p) - 1) % 2 == 0 for p in packets)
    frame.clear_sent()
    frame.tap(2)
    assert frame.sent(AUDIO_END) and frame.sent(TUNER) == [QUIT]
    assert not frame.emu._mic_on
    frame.assert_ok()


def test_asked_again_the_microphone_is_not_restarted(frame):
    frame.settings({"tuner.mic": "glasses"})
    tuning(frame)
    frame.advance(10)                            # TUNER again, no answer
    assert len(frame.sent(TUNER)) >= 3
    assert len(frame.sent(REC_START)) == 1
    frame.assert_ok()


def test_the_sound_said_before_stopping_is_sent_too(frame):
    frame.settings({"tuner.mic": "glasses"})
    tuning(frame)
    frame.advance(0.5)
    frame.emu.mic_data.extend(bytes(137 * 2))
    frame.clear_sent()
    frame.tap(2)                                 # drained, then the end
    sent = frame.sent()
    ends = [i for i, m in enumerate(sent) if m == bytes([AUDIO_END])]
    assert ends
    assert all(m[:1] != bytes([AUDIO]) for m in sent[ends[0]:])
    frame.assert_ok()


def test_no_phone_stops_the_microphone(frame):
    frame.settings({"tuner.mic": "glasses"})
    tuning(frame)
    frame.emu.connected = False
    frame.advance(1)
    assert not frame.emu._mic_on
    assert "no phone" in frame.screen_text()
    frame.emu.connected = True
    frame.clear_sent()
    frame.advance(1)
    assert frame.sent(TUNER) == [LISTEN_GLASSES]
    assert frame.sent(REC_START)                 # streaming again
    assert frame.emu._mic_on
    frame.assert_ok()


def test_at_most_two_seconds_of_sound_go_out_a_tick(frame):
    frame.settings({"tuner.mic": "glasses"})
    tuning(frame)
    sound = bytes(range(256)) * 137 * 2          # over four seconds' worth
    frame.emu.mic_data.extend(sound)
    frame.clear_sent()
    frame.advance(0.1)                           # one tick
    first = sum(len(p) - 1 for p in frame.sent(AUDIO))
    assert 32000 <= first < len(sound)           # 8000 Hz x 2 bytes x 2 s
    frame.advance(1)
    assert b"".join(p[1:] for p in frame.sent(AUDIO)) == sound
    frame.assert_ok()


def test_the_phones_microphone_leaves_the_glasses_one_off(frame):
    frame.settings({"tuner.mic": "phone"})
    tuning(frame)
    assert frame.sent(TUNER) == [LISTEN_PHONE]
    assert not frame.sent(REC_START) and not frame.emu._mic_on
    frame.emu.mic_data.extend(bytes(137 * 2))
    frame.advance(1)
    assert not frame.sent(AUDIO)
    frame.assert_ok()


def test_the_setting_counts_from_the_next_tuning(frame):
    tuning(frame)
    assert frame.sent(TUNER) == [LISTEN_PHONE]
    frame.settings({"tuner.mic": "glasses"})
    frame.tap(2)
    frame.clear_sent()
    frame.tap(1)
    assert frame.sent(TUNER) == [LISTEN_GLASSES]
    assert frame.sent(REC_START) and frame.emu._mic_on
    frame.assert_ok()


def test_a_microphone_left_running_is_taken_over(frame):
    frame.settings({"tuner.mic": "glasses"})
    frame.open_app("tuner")
    lua(frame, "frame.microphone.start{}")       # someone else's, 8 bit
    frame.clear_sent()
    frame.tap(1)
    assert frame.sent(REC_START) == [bytes([REC_START, 16, 8, 3])]
    assert frame.emu._mic_fmt == (8000, 16)
    assert "no microphone" not in frame.screen_text()
    frame.assert_ok()


def test_a_microphone_that_will_not_start_says_so(frame):
    frame.settings({"tuner.mic": "glasses"})
    frame.open_app("tuner")
    lua(frame, "frame.microphone.start = function() error('busy') end")
    frame.clear_sent()
    frame.tap(1)
    assert frame.sent(TUNER) == [LISTEN_GLASSES]
    assert not frame.sent(REC_START)
    assert "no microphone" in frame.screen_text()
    assert colour_of(frame, "no microphone") == "YELLOW"
    frame.screenshot("tuner-no-microphone")
    frame.advance(4)                             # asked again: still none
    assert "no microphone" in frame.screen_text()
    assert not frame.sent(REC_START)
    frame.tap(2)                                 # never streamed: no end
    assert not frame.sent(AUDIO_END)
    frame.assert_ok()


def test_rec_start_not_sent_stops_the_microphone(frame):
    frame.settings({"tuner.mic": "glasses"})
    frame.open_app("tuner")
    # Bluetooth busy for REC_START alone, every one of its 20 tries
    lua(frame, "local send = frame.bluetooth.send "
               "frame.bluetooth.send = function(p) "
               "if p:byte(1) == 0x1F then error('busy') end "
               "return send(p) end")
    frame.clear_sent()
    frame.tap(1)
    assert frame.sent(TUNER) == [LISTEN_GLASSES]
    assert not frame.emu._mic_on
    frame.emu.mic_data.extend(bytes(137 * 2))
    frame.advance(1)
    assert not frame.sent(AUDIO)
    frame.tap(2)
    assert not frame.sent(AUDIO_END)
    frame.assert_ok()


# ---------------------------------------------------------------- more

def test_tilting_down_past_the_last_wraps_to_the_first(glasses):
    glasses.open_app("tuner")
    glasses.tilt(-1)
    assert "> Violin" in glasses.screen_text()
    glasses.tilt(1)
    text = glasses.screen_text()
    assert "> Guitar" in text and "Violin" not in text
    glasses.assert_ok()


def test_tilts_and_single_taps_change_nothing_while_tuning(glasses):
    tuning(glasses)
    glasses.call("tuner", "p4512 1124")
    before = glasses.screen_text()
    glasses.clear_sent()
    glasses.tilt(1)
    glasses.tilt(-1)
    glasses.tap(1)
    assert glasses.screen_text() == before       # still the guitar
    assert not glasses.sent(TUNER)
    glasses.assert_ok()


def test_the_phones_remote_picks_tunes_and_goes_back(glasses):
    glasses.open_app("tuner")
    glasses.remote(2, 1)                         # next
    glasses.remote(2, 1)
    glasses.remote(2, 255)                       # previous
    assert "> Banjo" in glasses.screen_text()
    glasses.clear_sent()
    glasses.remote(1, 1)                         # a tap
    assert glasses.sent(TUNER) == [LISTEN_PHONE]
    assert "G4" in glasses.screen_text()
    glasses.remote(1, 2)                         # a double tap
    assert glasses.sent(TUNER)[-1] == QUIT
    assert "> Banjo" in glasses.screen_text()
    glasses.assert_ok()


@pytest.mark.parametrize("pitch, cents, colour, hint", [
    ("4505", "+5 c", "GREEN", "in tune"),
    ("4495", "-5 c", "GREEN", "in tune"),
    ("4506", "+6 c", "YELLOW", "tune down"),
    ("4494", "-6 c", "YELLOW", "tune up"),
    ("4520", "+20 c", "YELLOW", "tune down"),
    ("4480", "-20 c", "YELLOW", "tune up"),
    ("4521", "+21 c", "RED", "tune down"),
    ("4479", "-21 c", "RED", "tune up"),
])
def test_the_colour_changes_at_5_and_20_cents(glasses, pitch, cents,
                                               colour, hint):
    tuning(glasses)
    glasses.call("tuner", f"p{pitch} 1100")
    text = glasses.screen_text()
    assert cents in text and hint in text
    assert colour_of(glasses, cents) == colour
    assert colour_of(glasses, hint) == colour
    assert colour_of(glasses, "A2") == colour
    glasses.assert_ok()


def test_hz_has_one_decimal(glasses):
    tuning(glasses)
    glasses.call("tuner", "p4500 1100")
    assert "110.0 Hz" in glasses.screen_text()
    glasses.call("tuner", "p4500 1")
    assert "0.1 Hz" in glasses.screen_text()
    glasses.assert_ok()


def test_the_needle_stands_at_the_cents(frame):
    tuning(frame)
    assert needle(frame) is None                 # no note: no needle
    frame.call("tuner", "p4500 1100")
    assert abs(needle(frame) - 320) <= 3         # the centre tick
    frame.call("tuner", "p4512 1124")
    assert abs(needle(frame) - (320 + 12 * 4.8)) <= 3
    frame.call("tuner", "p4463 1076")
    assert abs(needle(frame) - (320 - 37 * 4.8)) <= 3
    frame.assert_ok()


def test_far_off_notes_pin_the_needle_to_the_ends(frame):
    tuning(frame)
    frame.call("tuner", "p3863 761")             # E2 and 137 cents flat
    text = frame.screen_text()
    assert "-137 c" in text and "tune up" in text and "D#2" in text
    assert colour_of(frame, "E2") == "RED"
    assert abs(needle(frame) - 80) <= 3          # -50: the scale's left end
    frame.screenshot("tuner-far-flat")
    frame.call("tuner", "p6537 3555")            # past E4, 137 cents sharp
    assert "+137 c" in frame.screen_text()
    assert colour_of(frame, "E4") == "RED"
    assert abs(needle(frame) - 560) <= 3         # +50: the right end
    frame.assert_ok()


def test_the_needle_stays_grey_once_nothing_is_heard(frame):
    tuning(frame)
    frame.call("tuner", "p4512 1124")
    at = needle(frame)
    frame.call("tuner", "p")
    assert needle(frame) == at
    img = frame.image()
    r, g, b = img.getpixel((round(at), 210))
    assert abs(r - g) < 16 and abs(g - b) < 16   # grey, not yellow
    frame.assert_ok()


def test_nothing_heard_before_any_note_still_asks_to_play(glasses):
    tuning(glasses)
    glasses.call("tuner", "p")
    text = glasses.screen_text()
    assert "play a string" in text
    assert " c" not in text and "Hz" not in text
    glasses.assert_ok()


def test_the_phones_word_outranks_the_hint_but_not_the_note(glasses):
    tuning(glasses)
    glasses.call("tuner", "p4502 1101")
    glasses.call("tuner", "smicrophone busy")
    text = glasses.screen_text()
    assert "microphone busy" in text and "in tune" not in text
    assert colour_of(glasses, "microphone busy") == "YELLOW"
    assert colour_of(glasses, "+2 c") == "GREEN"
    assert colour_of(glasses, "A2") == "GREEN"
    glasses.assert_ok()


def test_a_note_on_the_list_is_forgotten(glasses):
    glasses.open_app("tuner")
    glasses.call("tuner", "p4512 1124")
    glasses.call("tuner", "sallow the microphone")
    text = glasses.screen_text()
    assert "> Guitar" in text and "+12 c" not in text
    assert "allow the microphone" not in text
    glasses.tap(1)
    text = glasses.screen_text()
    assert "play a string" in text and "+12 c" not in text
    glasses.assert_ok()


def test_tuning_again_starts_from_no_note(glasses):
    tuning(glasses)
    glasses.call("tuner", "p4502 1101")
    glasses.tap(2)
    glasses.clear_sent()
    glasses.tap(1)
    text = glasses.screen_text()
    assert "play a string" in text and "+2 c" not in text
    assert glasses.sent(TUNER) == [LISTEN_PHONE]  # asked afresh
    glasses.assert_ok()


def test_leaving_the_list_tells_the_phone_nothing(glasses):
    glasses.open_app("tuner")
    glasses.clear_sent()
    glasses.tap(2)
    assert not glasses.sent(TUNER)
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_answered_then_lost_the_phone_is_asked_again(frame):
    tuning(frame)
    frame.call("tuner", "p4500 1100")
    frame.clear_sent()
    frame.advance(4)
    assert not frame.sent(TUNER)                 # answered: no asking
    frame.emu.connected = False
    frame.advance(1)
    assert "no phone" in frame.screen_text()
    assert colour_of(frame, "no phone") == "YELLOW"
    frame.screenshot("tuner-no-phone")
    frame.emu.connected = True
    frame.advance(1)
    assert frame.sent(TUNER) == [LISTEN_PHONE]
    frame.assert_ok()


@pytest.mark.parametrize("saved, shown", [
    ("6", "> Bass"),
    ("137", "> Guitar"),                         # no such instrument
    ("lute", "> Guitar"),
])
def test_the_saved_instrument_survives_a_restart(tmp_path, saved, shown):
    g = Glasses("frame", tmp_path)
    g.emu.files.path("prefs.txt").write_text(f"tuner.instrument={saved}")
    g.start()
    try:
        g.set_clock()
        g.open_app("tuner")
        assert shown in g.screen_text()
        g.assert_ok()
    finally:
        g.stop()


def test_the_tuner_has_no_background(frame):
    frame.settings({"tuner.mic": "glasses"})
    tuning(frame)
    frame.clear_sent()
    frame.open_app("stopwatch")                  # off the screen: stopped
    assert frame.sent(AUDIO_END)
    assert QUIT in frame.sent(TUNER)
    assert frame.sent(APP_STOP) and not frame.sent(APP_BACKGROUND)
    assert not frame.emu._mic_on
    frame.clear_sent()
    frame.advance(10)
    assert not frame.sent(TUNER) and not frame.sent(AUDIO)
    frame.assert_ok()


def test_the_timeout_stops_the_glasses_microphone(frame):
    frame.settings({"tuner.mic": "glasses"})
    tuning(frame)
    frame.call("tuner", "s")
    frame.clear_sent()
    frame.advance(65)
    assert frame.sent(APP_STOP) and frame.sent(AUDIO_END)
    assert not frame.emu._mic_on
    frame.assert_ok()


def test_halo_cannot_open_it(halo):
    halo.clear_sent()
    halo.open_app("tuner")
    assert "Guitar" not in halo.screen_text()
    assert not halo.sent(TUNER)
    halo.assert_ok()



# ---------------------------------------------------------------- edges

def test_the_lowest_midi_note_is_c_minus_1(frame):
    tuning(frame)
    frame.call("tuner", "p0 0")
    text = frame.screen_text()
    assert "C-1" in text and "-4000 c" in text and "0.0 Hz" in text
    assert colour_of(frame, "E2") == "RED"       # the nearest string
    assert abs(needle(frame) - 80) <= 3          # pinned to the left end
    frame.assert_ok()


def test_the_highest_midi_note_is_g9(glasses):
    tuning(glasses)
    glasses.call("tuner", "p12700 125440")
    text = glasses.screen_text()
    assert "G9" in text and "+6300 c" in text and "12544.0 Hz" in text
    assert colour_of(glasses, "E4") == "RED"
    glasses.assert_ok()


@pytest.mark.parametrize("arg", [
    "p12800 1",                                  # past MIDI's last note
    "p99999999999999999999999 1",                # too big for an integer
])
def test_a_pitch_past_midi_counts_as_nothing_heard(glasses, arg):
    tuning(glasses)
    glasses.call("tuner", "p4512 1124")
    glasses.call("tuner", arg)
    assert colour_of(glasses, "+12 c") == "GREY"
    assert "play a string" in glasses.screen_text()
    glasses.assert_ok()                          # draw() did not fail


def test_a_negative_pitch_counts_as_nothing_heard(glasses):
    tuning(glasses)
    glasses.call("tuner", "p-100 50")
    text = glasses.screen_text()
    assert "play a string" in text and " c" not in text
    glasses.assert_ok()


def test_halfway_between_two_strings_goes_to_the_lower(glasses):
    tuning(glasses)
    glasses.call("tuner", "p4250 924")           # E2 + 250, A2 - 250
    assert "+250 c" in glasses.screen_text()
    assert colour_of(glasses, "E2") == "RED"
    assert colour_of(glasses, "A2") == "WHITE"
    glasses.assert_ok()


def test_the_bass_low_e_is_its_lowest_string(glasses):
    tuning(glasses, tilts=5)                     # Bass: E1 A1 D2 G2
    glasses.call("tuner", "p2801 412")
    text = glasses.screen_text()
    assert "+1 c" in text and "in tune" in text and "41.2 Hz" in text
    assert colour_of(glasses, "E1") == "GREEN"
    glasses.assert_ok()


def test_a_note_after_it_closed_opens_nothing(glasses):
    tuning(glasses)
    glasses.tap(2)
    glasses.tap(2)                               # the list leaves
    glasses.clear_sent()
    glasses.call("tuner", "p4500 1100")          # the phone, a beat late
    glasses.advance(2)
    assert "A2" not in glasses.screen_text()
    assert not glasses.sent(TUNER) and not glasses.sent(APP_BACKGROUND)
    glasses.assert_ok()


def test_asleep_while_tuning_the_microphone_stops(frame):
    frame.settings({"tuner.mic": "glasses"})
    tuning(frame)
    frame.clear_sent()
    frame.tap(3)                                 # three taps: to sleep
    frame.advance(2)
    assert frame.emu.asleep
    assert frame.sent(AUDIO_END) and QUIT in frame.sent(TUNER)
    assert not frame.emu._mic_on
    frame.assert_ok()


def test_the_hosts_break_stops_the_microphone(frame):
    frame.settings({"tuner.mic": "glasses"})
    tuning(frame)
    frame.clear_sent()
    frame.emu.break_signal()
    frame.advance(2)
    assert not frame.running()
    assert frame.sent(AUDIO_END) and QUIT in frame.sent(TUNER)
    assert not frame.emu._mic_on

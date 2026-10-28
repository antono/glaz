"""Recorder (modules/recorder.lua), Frame only: a tap starts and stops a
recording, the microphone's bytes go to the phone as AUDIO packets between
REC_START and AUDIO_END, at most two seconds' worth a tick and in packets
the link's size, a recording goes on in the background with a red dot in
the top bar, the phone's record button (MODULE_CALL 'on' / 'off') works
with the module on screen, in the background or not running, and a link
or microphone that fails loses sound, never the recording's end.
"""
import re

import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, LUA_EVAL,
                     LUA_RESULT)

pytestmark = pytest.mark.module("recorder")

REC_START, AUDIO, AUDIO_END = 0x1F, 0x05, 0x06
PACKET = 242          # max_length() 243, less the code, made even
TICK = -(-16000 // PACKET) * PACKET  # whole packets, until 2 s at 8 kHz 8-bit


def audio(g) -> bytes:
    """The sound sent so far, the AUDIO packets put together."""
    return b"".join(m[1:] for m in g.sent(AUDIO))


def record(g, data: bytes = b""):
    """Recorder on screen, a tap to start, then data in the microphone."""
    g.open_app("recorder")
    g.clear_sent()
    g.tap(1)
    g.emu.mic_data.extend(data)


def lua(g, code: str) -> bytes:
    """Runs code in the app's globals, as the phone's Lua console does."""
    g.send(LUA_EVAL, b"\x89" + code.encode())
    g.advance(0.5)
    answers = [a for i, a in g.joined(LUA_RESULT) if i == 0x89]
    assert answers and answers[-1][:1] == b"+", answers
    return answers[-1]


def red_dot(g) -> bool:
    """The recording dot, red, in the top bar where the icon goes."""
    img = g.image()
    return any(r > 150 and gr < 100 and b < 100
               for x in range(370, 396) for y in range(0, 24)
               for r, gr, b in [img.getpixel((x, y))])


# ---------------------------------------------------------------- idle

def test_opens_ready_to_record(glasses):
    glasses.clear_sent()
    glasses.open_app("recorder")
    assert glasses.sent(APP_START)
    assert "tap = record" in glasses.screen_text()
    assert not glasses.sent(REC_START)
    glasses.screenshot("recorder")
    glasses.assert_ok()


def test_with_no_host_it_says_so_and_does_not_start(frame):
    frame.open_app("recorder")
    frame.emu.connected = False
    frame.clear_sent()
    frame.tap(1)
    assert "no host" in frame.screen_text()
    assert not frame.sent(REC_START)
    assert not red_dot(frame)
    frame.assert_ok()


def test_without_a_host_open_it_says_so_and_with_one_back_it_is_ready(frame):
    frame.open_app("recorder")
    frame.emu.connected = False
    frame.advance(1)
    assert "no host" in frame.screen_text()
    assert "tap = record" not in frame.screen_text()
    frame.screenshot("recorder-no-host")
    frame.emu.connected = True
    frame.advance(1)
    assert "tap = record" in frame.screen_text()
    frame.assert_ok()


def test_halo_has_no_recorder(halo):
    halo.clear_sent()
    halo.call("recorder", "on")
    halo.advance(2)
    assert not halo.sent(REC_START)
    assert not halo.sent(APP_BACKGROUND)
    halo.assert_ok()


# ---------------------------------------------------------------- recording

def test_a_tap_starts_8_bit_8_khz(glasses):
    record(glasses)
    assert glasses.sent(REC_START) == [bytes([REC_START, 8, 8])]
    text = glasses.screen_text()
    assert "REC 0:00  0 KB" in text
    assert "tap = stop" in text
    assert red_dot(glasses)
    glasses.screenshot("recorder-recording")
    glasses.assert_ok()


def test_the_microphones_bytes_go_to_the_phone_in_order(glasses):
    sound = bytes(i % 251 for i in range(137 * 100))
    record(glasses, sound)
    glasses.advance(2)
    assert audio(glasses) == sound
    packets = glasses.sent(AUDIO)
    assert all(len(p) - 1 <= PACKET and (len(p) - 1) % 2 == 0
               for p in packets)
    assert len(packets[0]) == 1 + PACKET
    glasses.assert_ok()


def test_the_phones_remote_tap_records_too(glasses):
    glasses.open_app("recorder")
    glasses.clear_sent()
    glasses.remote(1, 1)                         # one tap
    glasses.advance(1)
    assert glasses.sent(REC_START) == [bytes([REC_START, 8, 8])]
    assert "tap = stop" in glasses.screen_text()
    glasses.remote(1, 1)
    glasses.advance(1)
    assert glasses.sent()[-1] == bytes([AUDIO_END])
    glasses.assert_ok()


def test_a_backlog_goes_out_two_seconds_a_tick(glasses):
    sound = bytes(i % 137 for i in range(137 * 1024))
    record(glasses, sound)
    glasses.advance(0.25)                        # one tick on screen
    assert len(audio(glasses)) == TICK
    glasses.advance(0.25)
    assert len(audio(glasses)) == 2 * TICK
    glasses.advance(3)
    assert audio(glasses) == sound
    glasses.assert_ok()


def test_16_bit_takes_twice_as_much_a_tick(glasses):
    glasses.settings({"recorder.bits": "16"})
    record(glasses, bytes(137 * 1024))
    glasses.advance(0.25)
    assert len(audio(glasses)) == -(-32000 // PACKET) * PACKET  # 2 s, 16-bit
    glasses.assert_ok()


def test_packets_follow_the_links_size(frame):
    frame.open_app("recorder")
    # an odd max_length() less the code: the packet is made even
    lua(frame, "frame.bluetooth.max_length = function() return 138 end")
    frame.clear_sent()
    frame.tap(1)
    frame.emu.mic_data.extend(bytes(1370))
    frame.advance(1)
    packets = frame.sent(AUDIO)
    assert sum(len(p) - 1 for p in packets) == 1370
    assert {len(p) - 1 for p in packets[:-1]} == {136}
    frame.assert_ok()


def test_the_screen_counts_time_and_kilobytes(glasses):
    record(glasses, bytes(137 * 1024))
    glasses.advance(37)
    text = glasses.screen_text()
    assert "REC 0:3" in text                     # 0:37 and a bit
    assert "137 KB" in text
    assert "lost" not in text
    glasses.assert_ok()


def test_left_alone_the_screen_closes_and_recording_goes_on(glasses):
    record(glasses)
    glasses.advance(65)                          # past APP_TIMEOUT
    assert glasses.sent(APP_BACKGROUND)
    assert "tap = stop" not in glasses.screen_text()
    glasses.emu.mic_data.extend(bytes(1370))
    glasses.advance(2)
    assert len(audio(glasses)) == 1370
    assert not glasses.sent(AUDIO_END)
    glasses.assert_ok()


def test_a_second_tap_stops_and_tells_what_was_saved(glasses):
    record(glasses, bytes(3 * 1024))
    glasses.advance(1)
    glasses.tap(1)
    assert glasses.sent()[-1] == bytes([AUDIO_END])
    text = glasses.screen_text()
    assert "saved 3 KB" in text
    assert "tap = record" in text
    assert not red_dot(glasses)
    glasses.screenshot("recorder-saved")
    glasses.assert_ok()


def test_what_is_left_in_the_microphone_goes_before_the_end(glasses):
    record(glasses)
    glasses.advance(1)
    glasses.emu.mic_data.extend(b"\x89" * 1370)  # not yet read at the tap
    glasses.tap(1, settle=0)
    glasses.advance(1)
    ends = [i for i, m in enumerate(glasses.sent()) if m == bytes([AUDIO_END])]
    assert len(ends) == 1
    assert audio(glasses) == b"\x89" * 1370
    assert all(m[:1] != bytes([AUDIO]) for m in glasses.sent()[ends[0]:])
    glasses.assert_ok()


def test_minutes_on_the_clock(glasses):
    record(glasses)
    glasses.tap(2)                               # on in the background
    glasses.advance(137)
    glasses.open_app("recorder")
    assert re.search(r"REC 2:[0-5]\d  0 KB", glasses.screen_text())
    glasses.assert_ok()


def test_leaving_forgets_what_was_saved(glasses):
    record(glasses, bytes(2 * 1024))
    glasses.advance(1)
    glasses.tap(1)
    assert "saved 2 KB" in glasses.screen_text()
    glasses.tap(2)
    glasses.open_app("recorder")
    assert "saved" not in glasses.screen_text()
    assert "tap = record" in glasses.screen_text()
    glasses.assert_ok()


def test_a_new_recording_starts_counting_again(glasses):
    record(glasses, bytes(2 * 1024))
    glasses.advance(1)
    glasses.tap(1)
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(REC_START)
    assert "REC 0:00  0 KB" in glasses.screen_text()
    glasses.assert_ok()


# ---------------------------------------------------------------- settings

def test_the_phone_can_ask_for_16_bit(glasses):
    glasses.settings({"recorder.bits": "16"})
    record(glasses, bytes(range(256)) * 4)
    assert glasses.sent(REC_START) == [bytes([REC_START, 16, 8])]
    glasses.advance(1)
    assert audio(glasses) == bytes(range(256)) * 4
    glasses.assert_ok()


@pytest.mark.parametrize("bits", ["137", "nonsense"])
def test_bits_other_than_8_or_16_mean_8(glasses, bits):
    glasses.settings({"recorder.bits": bits})
    record(glasses)
    assert glasses.sent(REC_START) == [bytes([REC_START, 8, 8])]
    glasses.assert_ok()


# ---------------------------------------------------------------- trouble

def test_losing_the_host_ends_the_recording(frame):
    record(frame, bytes(2 * 1024))
    frame.advance(1)
    frame.emu.connected = False
    frame.advance(1)
    assert "no host" in frame.screen_text()
    assert not red_dot(frame)
    frame.emu.connected = True
    frame.advance(1.5)
    assert "saved 2 KB" in frame.screen_text()
    assert not frame.sent(AUDIO_END)             # there was nobody to tell
    frame.assert_ok()


def test_what_the_link_cannot_take_is_counted_lost(frame):
    record(frame)
    lua(frame, "glaz_send = frame.bluetooth.send; frame.bluetooth.send = "
               "function(s) if s:byte(1) == 5 then error('busy') end "
               "return glaz_send(s) end")
    # each packet is tried 20 times, 5 ms apart: about 2 s for these 3 KB
    frame.emu.mic_data.extend(bytes(3 * 1024))
    frame.advance(5)
    text = frame.screen_text()
    assert "REC" in text and "  0 KB" in text
    assert "lost 3 KB" in text
    assert not frame.sent(AUDIO)
    frame.screenshot("recorder-lost")
    lua(frame, "frame.bluetooth.send = glaz_send")
    frame.tap(1)
    assert frame.sent()[-1] == bytes([AUDIO_END])
    frame.assert_ok()


def test_a_link_that_takes_a_retry_loses_nothing(frame):
    record(frame)
    # each packet refused twice, then taken
    lua(frame, "glaz_send = frame.bluetooth.send; glaz_tries = 0; "
               "frame.bluetooth.send = function(s) "
               "if s:byte(1) == 5 then glaz_tries = glaz_tries + 1; "
               "if glaz_tries % 3 ~= 0 then error('busy') end end "
               "return glaz_send(s) end")
    sound = bytes(i % 137 for i in range(3 * 1024))
    frame.emu.mic_data.extend(sound)
    frame.advance(2)
    assert audio(frame) == sound
    assert "lost" not in frame.screen_text()
    assert "3 KB" in frame.screen_text()
    frame.assert_ok()


def test_a_microphone_that_will_not_read_sends_nothing(frame):
    record(frame)
    lua(frame, "frame.microphone.read = function() error('mic') end")
    frame.emu.mic_data.extend(bytes(1370))
    frame.advance(2)
    assert not frame.sent(AUDIO)
    assert "REC 0:0" in frame.screen_text()
    assert "tap = stop" in frame.screen_text()
    frame.tap(1)
    assert frame.sent()[-1] == bytes([AUDIO_END])
    assert "tap = record" in frame.screen_text()
    frame.assert_ok()


def test_an_end_the_link_refuses_still_ends_it(frame):
    record(frame)
    lua(frame, "glaz_send = frame.bluetooth.send; frame.bluetooth.send = "
               "function(s) if s:byte(1) == 6 then error('busy') end "
               "return glaz_send(s) end")
    frame.tap(1)
    assert not frame.sent(AUDIO_END)
    assert "tap = record" in frame.screen_text()
    assert not red_dot(frame)
    assert not frame.emu._mic_on
    frame.assert_ok()


def test_a_microphone_left_running_is_restarted(frame):
    frame.open_app("recorder")
    lua(frame, "frame.microphone.start{sample_rate=16000, bit_depth=16}")
    frame.clear_sent()
    frame.tap(1)
    assert frame.sent(REC_START) == [bytes([REC_START, 8, 8])]
    assert frame.emu._mic_fmt == (8000, 8)
    frame.assert_ok()


def test_a_microphone_that_will_not_start_records_nothing(frame):
    frame.open_app("recorder")
    lua(frame, "frame.microphone.start = function() error('no mic') end")
    frame.clear_sent()
    frame.tap(1)
    assert not frame.sent(REC_START)
    assert "tap = record" in frame.screen_text()
    assert not red_dot(frame)
    frame.assert_ok()


def test_when_rec_start_cannot_be_sent_the_microphone_stops(frame):
    frame.open_app("recorder")
    lua(frame, "glaz_send = frame.bluetooth.send; frame.bluetooth.send = "
               "function(s) if s:byte(1) == 0x1F then error('busy') end "
               "return glaz_send(s) end")
    frame.clear_sent()
    frame.tap(1)
    assert "tap = record" in frame.screen_text()
    assert not frame.emu._mic_on
    frame.assert_ok()


# ---------------------------------------------------------------- background

def test_left_recording_it_goes_on_in_the_background(glasses):
    record(glasses)
    glasses.tap(2)                               # back
    assert glasses.sent(APP_BACKGROUND)
    assert not glasses.sent(APP_STOP)
    assert "tap = stop" not in glasses.screen_text()
    assert red_dot(glasses)                      # in the menu's top bar
    glasses.screenshot("recorder-background")
    sound = bytes(i % 137 for i in range(137 * 50))
    glasses.emu.mic_data.extend(sound)
    glasses.advance(5)
    assert audio(glasses) == sound
    glasses.open_app("recorder")
    assert "REC 0:0" in glasses.screen_text()
    assert "6 KB" in glasses.screen_text()       # 6850 bytes
    glasses.assert_ok()


def test_left_idle_it_stops(glasses):
    glasses.open_app("recorder")
    glasses.clear_sent()
    glasses.tap(2)
    assert not glasses.sent(APP_BACKGROUND)
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_stopped_in_the_background_it_leaves_the_background(glasses):
    record(glasses)
    glasses.tap(2)
    glasses.clear_sent()
    glasses.call("recorder", "off")
    glasses.advance(1.5)
    assert glasses.sent(AUDIO_END)
    assert glasses.sent(APP_STOP)
    assert not red_dot(glasses)
    glasses.assert_ok()


def test_another_background_app_ends_the_recording(glasses):
    record(glasses, bytes(1024))
    glasses.tap(2)
    glasses.clear_sent()
    glasses.open_app("stopwatch")
    glasses.tap(1)                               # counting: it stays
    glasses.tap(2)
    assert glasses.sent(AUDIO_END)
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_opened_with_off_from_the_background_it_stops(glasses):
    record(glasses, bytes(1024))
    glasses.tap(2)
    glasses.clear_sent()
    glasses.open_app("recorder", "off")
    assert glasses.sent(AUDIO_END)
    text = glasses.screen_text()
    assert "saved 1 KB" in text
    assert "tap = record" in text
    glasses.assert_ok()


def test_losing_the_host_in_the_background_ends_it_there(frame):
    record(frame)
    frame.tap(2)
    frame.emu.connected = False
    frame.advance(2)                             # a background tick
    assert not red_dot(frame)
    frame.emu.connected = True
    frame.clear_sent()
    frame.call("recorder", "off")                # not running: nothing
    frame.advance(1)
    assert not frame.sent(AUDIO_END)
    frame.assert_ok()


def test_going_to_sleep_ends_the_recording(glasses):
    record(glasses, bytes(1370))
    glasses.advance(1)
    glasses.tap(3)
    glasses.advance(3)                           # the eye closing
    assert glasses.sent(AUDIO_END)
    assert len(audio(glasses)) == 1370
    assert glasses.emu.asleep
    glasses.assert_ok()


# ---------------------------------------------------------------- the phone

def test_the_record_button_records_without_leaving_the_screen(glasses):
    glasses.tap(2)                               # the menu
    menu = glasses.screen_text()
    glasses.clear_sent()
    glasses.call("recorder", "on")
    glasses.advance(0.5)
    assert glasses.sent(REC_START) == [bytes([REC_START, 8, 8])]
    assert glasses.sent(APP_BACKGROUND)
    assert glasses.screen_text() == menu
    assert red_dot(glasses)
    glasses.emu.mic_data.extend(bytes(1370))
    glasses.advance(2)
    assert len(audio(glasses)) == 1370
    glasses.clear_sent()
    glasses.call("recorder", "off")
    glasses.advance(0.5)
    # the 0 is data.lua's ack of the phone's message
    assert [m[0] for m in glasses.sent() if m != b"\0"] == [AUDIO_END,
                                                             APP_STOP]
    assert not red_dot(glasses)
    glasses.assert_ok()


def test_the_record_button_on_screen(glasses):
    glasses.open_app("recorder")
    glasses.clear_sent()
    glasses.call("recorder", "on")
    glasses.advance(0.5)
    assert glasses.sent(REC_START)
    assert "tap = stop" in glasses.screen_text()
    glasses.call("recorder", "off")
    glasses.advance(0.5)
    assert glasses.sent(AUDIO_END)
    assert "tap = record" in glasses.screen_text()
    glasses.assert_ok()


def test_on_when_recording_and_off_when_not_change_nothing(glasses):
    glasses.open_app("recorder")
    glasses.clear_sent()
    glasses.call("recorder", "off")
    glasses.advance(0.5)
    assert not glasses.sent(AUDIO_END)
    glasses.call("recorder", "on")
    glasses.call("recorder", "on")
    glasses.advance(0.5)
    assert len(glasses.sent(REC_START)) == 1
    glasses.assert_ok()


def test_an_unknown_argument_changes_nothing(glasses):
    glasses.open_app("recorder")
    glasses.clear_sent()
    glasses.call("recorder", "137")
    glasses.advance(0.5)
    assert not glasses.sent(REC_START)
    assert "tap = record" in glasses.screen_text()
    glasses.assert_ok()

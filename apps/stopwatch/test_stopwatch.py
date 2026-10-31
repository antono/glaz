"""Stopwatch (apps/stopwatch/stopwatch.lua) on each pair of glasses that has it:
a tap starts and pauses it, a tilt resets it while paused, and leaving it
keeps it counting in the background."""
import re

import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, LUA_EVAL,
                     LUA_RESULT, NOW)

pytestmark = pytest.mark.module("stopwatch")

TIME = re.compile(r"\b(\d+):(\d\d)\.(\d)\b")


def test_opens_at_zero(glasses):
    glasses.clear_sent()
    glasses.open_app("stopwatch")
    assert glasses.sent(APP_START)
    text = glasses.screen_text()
    assert "Stopwatch" in text
    assert "0:00.0" in text
    assert "tap = " in text        # cut to Halo's round screen there
    glasses.screenshot("stopwatch")
    glasses.assert_ok()


def test_a_tap_starts_it_and_time_counts(glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1, settle=0)                     # counted after the window
    glasses.advance(1.0 + 37)                    # within APP_TIMEOUT
    text = glasses.screen_text()
    assert "0:37." in text or "0:38." in text
    glasses.screenshot("stopwatch-running")
    glasses.assert_ok()


def test_a_second_tap_pauses_and_a_tilt_resets(glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1)
    glasses.advance(5)
    glasses.tap(1)
    paused = glasses.screen_text()
    assert "paused" in paused
    glasses.advance(10)
    assert glasses.screen_text() == paused       # stopped, not counting
    glasses.tilt(1)
    assert "0:00.0" in glasses.screen_text()
    glasses.assert_ok()


def test_left_running_it_goes_on_in_the_background(glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1)
    glasses.clear_sent()
    glasses.tap(2)                               # back
    assert glasses.sent(APP_BACKGROUND)
    glasses.advance(137)
    glasses.open_app("stopwatch")
    assert "2:1" in glasses.screen_text()        # 2:17 and more
    glasses.assert_ok()


def test_left_at_zero_it_stops(glasses):
    glasses.open_app("stopwatch")
    glasses.clear_sent()
    glasses.tap(2)
    assert not glasses.sent(APP_BACKGROUND)


def lua(glasses, code: str):
    """Runs Lua on the glasses, as the phone's console does."""
    glasses.send(LUA_EVAL, b"\x89" + code.encode())
    glasses.advance(0.5)
    assert glasses.joined(LUA_RESULT)


def reading(glasses) -> float:
    """The time on the screen, in seconds."""
    m = TIME.search(glasses.screen_text())
    assert m, glasses.screen_text()
    minutes, seconds, tenths = (int(x) for x in m.groups())
    assert seconds < 60
    return minutes * 60 + seconds + tenths / 10


def test_two_runs_add_up_and_the_pause_between_is_left_out(glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1, settle=0)
    glasses.advance(10)
    glasses.tap(1, settle=0)                     # paused at about 10 s
    glasses.advance(1 + 37)                      # not counted
    glasses.tap(1, settle=0)
    glasses.advance(20)
    glasses.tap(1)                               # paused again, about 30 s
    assert "paused" in glasses.screen_text()
    assert 29 <= reading(glasses) <= 33
    glasses.assert_ok()


def test_a_tilt_while_running_does_not_reset_it(glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1)
    glasses.advance(10)
    glasses.tilt(1)
    glasses.tilt(-1)
    glasses.remote(2, 1)                         # the phone's next, a tilt
    text = glasses.screen_text()
    assert "paused" not in text and "tap = start" not in text
    assert reading(glasses) >= 10
    glasses.assert_ok()


def test_a_tilt_at_zero_changes_nothing(glasses):
    glasses.open_app("stopwatch")
    before = glasses.screen_text()
    glasses.tilt(1)
    glasses.tilt(-1)
    assert glasses.screen_text() == before
    assert "0:00.0" in before
    glasses.assert_ok()


def test_the_minute_carries_over_and_seconds_never_reach_60(glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1, settle=0)
    glasses.advance(30)
    glasses.tilt(1)                              # input: kept on screen
    glasses.advance(26.2)
    seen = []
    for _ in range(60):                          # 56 s to 62 s, in tenths
        glasses.advance(0.1)
        seen.append(reading(glasses))
    assert seen == sorted(seen)                  # never back
    assert any(s < 60 for s in seen) and any(s >= 60 for s in seen)
    assert "1:0" in glasses.screen_text()
    glasses.assert_ok()


def test_hours_go_on_as_minutes(glasses):
    # left running for 137 hours: the glasses' clock jumps ahead, as if
    # they had been on all that time
    glasses.open_app("stopwatch")
    glasses.tap(1)
    lua(glasses, "frame.time.utc(math.floor(frame.time.utc()) + 137 * 3600)")
    glasses.open_app("stopwatch")
    line = TIME.search(glasses.screen_text()).group(0)
    assert line.startswith("8220:0")             # 137 * 60 minutes, no hours
    assert line in glasses.screen_text().splitlines()   # whole, not cut
    glasses.assert_ok()


def test_left_alone_running_it_goes_to_the_background_and_a_tap_brings_it_back(
        glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1)
    glasses.clear_sent()
    glasses.advance(60 + 2)                      # APP_TIMEOUT, no input
    assert glasses.sent(APP_BACKGROUND)
    assert not glasses.sent(APP_STOP)
    assert not TIME.search(glasses.screen_text())
    glasses.advance(37)
    glasses.tap(1)                               # the blank screen: back
    assert 100 <= reading(glasses) <= 103        # never stopped counting
    assert "paused" not in glasses.screen_text()
    glasses.assert_ok()


def test_left_paused_it_keeps_its_time(glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1, settle=0)
    glasses.advance(13.7)
    glasses.tap(1)                               # paused
    paused = reading(glasses)
    glasses.clear_sent()
    glasses.tap(2)                               # back: kept, not counting
    assert glasses.sent(APP_BACKGROUND)
    glasses.advance(137)
    glasses.open_app("stopwatch")
    assert reading(glasses) == paused
    assert "paused" in glasses.screen_text()
    glasses.assert_ok()


def test_the_phones_clock_changes_nothing(glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1)
    glasses.advance(10)
    glasses.set_clock(NOW - 137 * 3600)          # back, and ahead
    glasses.set_clock(NOW + 137 * 86400)
    glasses.advance(10)
    assert 20 <= reading(glasses) <= 23
    glasses.assert_ok()


def test_a_tap_that_dismisses_a_notification_does_not_pause_it(glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1)
    glasses.notify("Chat", "Ann", "lunch at 13:37?")
    assert "Ann" in glasses.screen_text()
    glasses.tap(1)                               # the notice goes
    assert "Ann" not in glasses.screen_text()
    text = glasses.screen_text()
    assert "paused" not in text
    first = reading(glasses)
    glasses.advance(5)
    assert reading(glasses) > first              # still counting
    glasses.assert_ok()


def test_frame_counts_on_in_the_background_with_no_phone(frame):
    frame.open_app("stopwatch")
    frame.tap(1)
    frame.tap(2)                                 # back: in the background
    frame.emu.connected = False                  # the phone out of reach
    frame.advance(137)                           # past LINK_GRACE
    assert not frame.emu.asleep                  # it keeps them awake
    frame.tap(1)
    assert 137 <= reading(frame) <= 142
    frame.assert_ok()


def test_frame_a_tap_just_before_the_timeout_pauses_it(frame):
    # Halo's firmware gives the gesture whole: no window, no race
    frame.open_app("stopwatch")
    frame.tap(1, settle=0)                       # counted after the window
    frame.advance(0.75 + 59.6)                   # untouched, 0.4 s to go
    assert TIME.search(frame.screen_text())
    assert "paused" not in frame.screen_text()
    frame.tap(1)
    assert "paused" in frame.screen_text()
    frame.assert_ok()

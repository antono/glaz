"""Stopwatch (apps/stopwatch/stopwatch.lua) on each pair of glasses that has it:
a tap starts and pauses it, a tilt resets it while paused, and leaving it
keeps it counting in the background."""
import pytest

from glasses import APP_BACKGROUND, APP_START

pytestmark = pytest.mark.module("stopwatch")


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

"""Tilt (apps/tilt/tilt.lua), Sensors > Tilt: the head's roll, pitch and
heading from frame.imu.direction(), live, until a double tap or a minute
left alone. Frame only: Halo gets no part of it, so neither the module nor
its menu item."""
import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, MENU_SELECT,
                     MODULE_CALL)

pytestmark = pytest.mark.module("tilt")

READING = "r12  p-36  h0"     # roll 12.4, pitch -35.6: the head at rest


def opened(g, roll=12.4, pitch=-35.6, heading=0.0):
    g.emu.set_direction(roll, pitch, heading)
    g.clear_sent()
    g.open_app("tilt")
    return g


def test_opens_with_the_head_s_direction(glasses):
    opened(glasses)
    assert glasses.sent(APP_START)
    text = glasses.screen_text()
    assert "Tilt" in text
    assert READING in text
    glasses.screenshot("tilt")
    glasses.assert_ok()


def test_reached_through_sensors_in_the_menu(frame):
    frame.tap(2)                          # the menu, at Apps
    frame.tilt(1)                         # Sensors
    frame.tap(1)
    assert "> Battery" in frame.screen_text()
    frame.tilt(1)                         # Tilt
    assert "> Tilt" in frame.screen_text()
    frame.screenshot("tilt-menu")
    frame.emu.set_direction(12.4, -35.6, 0.0)
    frame.clear_sent()
    frame.tap(1)
    assert frame.sent(MENU_SELECT) and frame.sent(APP_START)
    assert READING in frame.screen_text()
    frame.assert_ok()


def test_follows_the_head_live(glasses):
    opened(glasses)
    glasses.emu.set_direction(-25.0, 137.0, 0.0)
    glasses.advance(0.3)                  # past one refresh, 0.25 s
    assert "r-25  p137  h0" in glasses.screen_text()
    glasses.emu.set_direction(16.0, -90.0, 0.0)
    glasses.advance(0.3)
    assert "r16  p-90  h0" in glasses.screen_text()
    glasses.screenshot("tilt-turned")
    glasses.assert_ok()


def test_rounds_to_whole_degrees(glasses):
    opened(glasses, roll=179.6, pitch=-0.4, heading=137.2)
    assert "r180  p0  h137" in glasses.screen_text()
    # half a degree goes up, on either side of zero
    glasses.emu.set_direction(0.5, -179.5, -137.5)
    glasses.advance(0.3)
    assert "r1  p-179  h-137" in glasses.screen_text()
    glasses.assert_ok()


def test_a_level_head_reads_zero_not_minus_zero(glasses):
    opened(glasses, roll=-0.3, pitch=-0.5, heading=0.0)
    text = glasses.screen_text()
    assert "r0  p0  h0" in text
    assert "-0" not in text
    glasses.emu.set_direction(-0.6, -1.5, 0.0)
    glasses.advance(0.3)
    assert "r-1  p-1  h0" in glasses.screen_text()
    glasses.assert_ok()


def test_a_head_tilt_does_not_leave_it(glasses):
    # no on_roll: a tilt only changes the numbers while the head is turned
    opened(glasses)
    glasses.clear_sent()
    glasses.tilt(1)
    glasses.emu.set_direction(12.4, -35.6, 0.0)
    glasses.advance(0.3)
    assert READING in glasses.screen_text()
    assert not glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_the_phone_s_remote_does_not_leave_it(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.remote(2, 1)                  # next
    glasses.remote(2, 255)                # previous
    glasses.remote(3, 1)                  # up and down
    assert READING in glasses.screen_text()
    assert not glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_a_double_tap_stops_it_and_goes_back(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)    # it sleeps, never stays on
    text = glasses.screen_text()
    assert "Sensors" in text and "Tilt" in text
    assert READING not in text
    glasses.assert_ok()


def test_left_alone_for_a_minute_it_closes(glasses):
    opened(glasses)
    glasses.advance(59)
    assert READING in glasses.screen_text()
    assert glasses.lit()                  # kept lit, past SLEEP_AFTER
    assert not glasses.emu.asleep
    glasses.clear_sent()
    glasses.advance(2)
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)
    assert READING not in glasses.screen_text()
    glasses.assert_ok()


def test_a_tap_on_the_blank_screen_brings_it_back(glasses):
    opened(glasses)
    glasses.advance(61)                   # closed, left alone
    assert READING not in glasses.screen_text()
    glasses.emu.set_direction(-25.0, 137.0, 0.0)
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(APP_START)
    assert "r-25  p137  h0" in glasses.screen_text()
    glasses.assert_ok()


def test_a_notification_pops_up_over_it(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.notify("Chat", "Ann", "lunch at 13:37?")
    assert "Ann" in glasses.screen_text()
    glasses.screenshot("tilt-notification")
    glasses.emu.set_direction(-25.0, 137.0, 0.0)
    glasses.advance(6)                    # the pop-up goes by itself
    text = glasses.screen_text()
    assert "Ann" not in text
    assert "r-25  p137  h0" in text       # still running underneath
    assert not glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_a_triple_tap_sleeps_and_a_tap_wakes_into_it(frame):
    opened(frame)
    frame.tap(3, settle=3.0)
    frame.advance(2)
    assert frame.emu.asleep
    frame.emu.set_direction(-25.0, 137.0, 0.0)
    frame.tap(1, settle=2.0)
    assert frame.emu.boots == 2           # waking is a reset
    assert frame.until("Frame app is running", since=2)
    frame.advance(1)
    text = frame.screen_text()
    assert "Tilt" in text
    assert "r-25  p137  h0" in text
    frame.assert_ok()


def test_a_tap_keeps_it_open(glasses):
    opened(glasses)
    glasses.advance(50)
    glasses.tap(1)
    glasses.advance(50)                   # 100 s since it opened
    assert READING in glasses.screen_text()
    glasses.clear_sent()
    glasses.advance(11)                   # a minute since the tap
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_another_app_replaces_it(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.open_app("stopwatch")
    assert glasses.sent(APP_STOP) and glasses.sent(APP_START)
    assert not glasses.sent(APP_BACKGROUND)
    assert READING not in glasses.screen_text()
    assert "Stopwatch" in glasses.screen_text()
    glasses.assert_ok()


def test_the_phone_cannot_call_it(glasses):
    # no remote(): a MODULE_CALL neither starts it nor touches it
    glasses.clear_sent()
    glasses.call("tilt", "137")
    assert not glasses.sent(APP_START)
    opened(glasses)
    glasses.clear_sent()
    glasses.call("tilt", "137")
    assert READING in glasses.screen_text()
    assert not glasses.sent(APP_STOP)
    assert not glasses.sent(MODULE_CALL)
    glasses.assert_ok()


def test_not_on_halo(halo):
    halo.tap(2)                           # the menu
    halo.tilt(1)                          # Sensors
    halo.tap(1)
    assert "Battery" in halo.screen_text()
    assert "Tilt" not in halo.screen_text()
    halo.clear_sent()
    halo.open_app("tilt")
    assert not halo.sent(APP_START)
    halo.assert_ok()

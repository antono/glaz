"""Battery (apps/battery/battery.lua), Sensors > Battery, on each pair of
glasses that has it: the level in percent, read once when it opens, shown
for a few seconds ('info' mode), then the screen goes blank; a tap brings
it back with a fresh reading, a double tap goes to the Sensors menu.
"""
import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, MENU_LEVEL,
                     MENU_OPEN)

pytestmark = pytest.mark.module("battery")


def set_battery(g, level):
    if g.device == "frame":
        g.emu.battery = level
    else:
        g.emu.set_battery_level(level)


def test_shows_the_level_in_percent(glasses):
    set_battery(glasses, 37)
    glasses.clear_sent()
    glasses.open_app("battery")
    assert glasses.sent(APP_START)
    text = glasses.screen_text()
    assert ".. > Battery" in text                # the breadcrumb
    # the module's own reading, under the top bar's mean of the samples
    # (85% since the start)
    assert text.splitlines()[-1] == "37%"
    glasses.screenshot("battery")
    glasses.assert_ok()


@pytest.mark.parametrize("level", [0, 100])
def test_the_ends_of_the_scale(glasses, level):
    set_battery(glasses, level)
    glasses.open_app("battery")
    assert f"{level}%" in glasses.screen_text()
    glasses.assert_ok()


def test_frame_firmware_gives_a_float(frame):
    # system.c pushes roundf(...) with lua_pushnumber: 37.0, not 37
    frame.emu.battery = 37.0
    frame.open_app("battery")
    text = frame.screen_text()
    assert "37%" in text and "37.0" not in text
    frame.assert_ok()


def test_opened_from_the_sensors_menu(glasses):
    set_battery(glasses, 37)
    glasses.tap(2)                               # the menu
    glasses.tilt(1)                              # Sensors
    glasses.tap(1)
    assert "> Battery" in glasses.screen_text()  # its first item
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(APP_START)
    assert "37%" in glasses.screen_text()
    glasses.assert_ok()


def test_goes_by_itself_after_a_few_seconds(glasses):
    set_battery(glasses, 37)
    glasses.open_app("battery")
    glasses.clear_sent()
    glasses.advance(3)
    assert "37%" in glasses.screen_text()        # still up
    assert not glasses.sent(APP_STOP)
    glasses.advance(3)                           # past INFO_TIMEOUT, 5 s
    assert "37%" not in glasses.screen_text()
    assert "Battery" not in glasses.screen_text()
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)      # nothing left running
    glasses.assert_ok()


def test_the_value_is_read_once_while_on_screen(glasses):
    set_battery(glasses, 37)
    glasses.open_app("battery")
    set_battery(glasses, 13)
    glasses.advance(2)
    text = glasses.screen_text()
    assert "37%" in text and "13%" not in text
    glasses.assert_ok()


def test_a_tap_on_the_blank_screen_reads_it_again(glasses):
    set_battery(glasses, 37)
    glasses.open_app("battery")
    glasses.advance(6)
    assert "37%" not in glasses.screen_text()
    set_battery(glasses, 13)
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(APP_START)
    assert "13%" in glasses.screen_text()
    glasses.assert_ok()


def test_a_tap_while_shown_changes_nothing(glasses):
    set_battery(glasses, 37)
    glasses.open_app("battery")
    shown = glasses.screen_text()
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.screen_text() == shown
    assert not glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_a_tap_does_not_keep_it_on_screen(glasses):
    # unlike an 'app' module, an 'info' one is not kept alive by taps
    glasses.open_app("battery")
    glasses.advance(3)
    glasses.tap(1)                               # 4 s and more
    glasses.clear_sent()
    glasses.advance(2)
    assert glasses.sent(APP_STOP)
    assert "%" not in glasses.screen_text()
    glasses.assert_ok()


def test_a_tilt_changes_nothing(glasses):
    set_battery(glasses, 37)
    glasses.open_app("battery")
    shown = glasses.screen_text()
    glasses.tilt(1)
    glasses.tilt(-1)
    assert glasses.screen_text() == shown
    glasses.remote(2, 1)                         # the remote's Right
    assert glasses.screen_text() == shown
    glasses.assert_ok()


def test_a_double_tap_goes_back_to_sensors(glasses):
    set_battery(glasses, 37)
    glasses.open_app("battery")
    glasses.clear_sent()
    glasses.tap(2)
    text = glasses.screen_text()
    assert "Glaz > Sensors" in text and "> Battery" in text
    assert "37%" not in text                     # the top bar's 85% stays
    assert glasses.sent(APP_STOP)
    assert glasses.sent(MENU_OPEN)
    glasses.assert_ok()


def test_opened_by_the_phone_its_path_follows(glasses):
    # opened straight by APP_OPEN, the breadcrumb still leads to Sensors
    glasses.clear_sent()
    glasses.open_app("battery")
    assert glasses.sent(MENU_LEVEL)
    glasses.tap(2)
    assert "Glaz > Sensors" in glasses.screen_text()
    glasses.assert_ok()


def test_the_phone_cannot_call_it(glasses):
    # no remote(): a MODULE_CALL for it is ignored, nothing starts
    glasses.advance(5)                           # the splash gone
    glasses.clear_sent()
    glasses.call("battery", "137")
    glasses.advance(1)
    assert not glasses.sent(APP_START)
    assert "%" not in glasses.screen_text()
    glasses.assert_ok()


def test_a_notification_covers_it(glasses):
    set_battery(glasses, 37)
    glasses.open_app("battery")
    glasses.notify("Phone", "Hello", "Battery is fine")
    text = glasses.screen_text()
    assert "Hello" in text and "37%" not in text
    glasses.assert_ok()


def test_start_and_stop_name_the_same_module(glasses):
    glasses.clear_sent()
    glasses.open_app("battery")
    glasses.advance(6)
    start, stop = glasses.sent(APP_START), glasses.sent(APP_STOP)
    assert len(start) == 1 and len(stop) == 1
    assert start[0][1:] == stop[0][1:]           # the module's index
    glasses.assert_ok()


def test_reopened_it_stays_its_full_time_again(glasses):
    glasses.open_app("battery")
    glasses.advance(6)
    glasses.tap(1)                               # back, 1 s settled
    glasses.clear_sent()
    glasses.advance(3)
    assert "Battery" in glasses.screen_text()
    assert not glasses.sent(APP_STOP)
    glasses.advance(2)
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_opened_again_by_the_phone_while_shown(glasses):
    # on screen already, it is not started again (docs/PROTOCOL.md,
    # APP_OPEN): the same reading, no second APP_START, the same 5 s; an
    # argument would go to remote(), which it does not have
    set_battery(glasses, 37)
    glasses.open_app("battery")
    set_battery(glasses, 13)
    glasses.advance(2)
    glasses.clear_sent()
    glasses.open_app("battery", "137")
    text = glasses.screen_text()
    assert text.splitlines()[-1] == "37%" and "13%" not in text
    assert not glasses.sent(APP_START)
    glasses.advance(2.5)                         # 5 s since it first opened
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_the_blank_screen_after_it(glasses):
    glasses.open_app("battery")
    glasses.advance(6)
    assert glasses.screen_text() == ""
    glasses.screenshot("battery-gone")
    glasses.assert_ok()


def test_the_remote_double_tap_goes_back_to_sensors(glasses):
    set_battery(glasses, 37)
    glasses.open_app("battery")
    glasses.clear_sent()
    glasses.remote(1, 2)                         # two taps from the phone
    text = glasses.screen_text()
    assert "Glaz > Sensors" in text and "37%" not in text
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_the_sensors_menu_with_battery(glasses):
    glasses.tap(2)
    glasses.tilt(1)
    glasses.tap(1)
    assert "Glaz > Sensors" in glasses.screen_text()
    glasses.screenshot("battery-menu")
    glasses.assert_ok()


def test_a_reading_it_cannot_show_is_an_error_not_a_crash(frame):
    # Frame's firmware rounds, so this cannot come from it; it stands for
    # anything that makes run() fail: the error is on screen, the app lives
    frame.emu.battery = 37.5
    frame.open_app("battery")
    assert "err:" in frame.screen_text()
    frame.emu.battery = 37
    frame.advance(6)
    frame.tap(1)
    assert frame.screen_text().splitlines()[-1] == "37%"
    # the app carried on: the one error is the module's, printed once
    errors = frame.errors()
    assert len(errors) == 1 and "Battery err:" in errors[0], errors

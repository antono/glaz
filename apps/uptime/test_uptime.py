"""Info > Uptime (apps/uptime/uptime.lua) on each pair of glasses that has it:
the time since power-on as 'Hh MMm SSs', read from frame.time.utc(), which
glaz never sets, so the phone's clock changes nothing; it comes from the
menu or the phone, shows its value once, with minutes and hours carried
over and no days; goes back with a double tap (the temple's or the phone
remote's), opens the menu with the remote's Menu button, sleeps with a
triple tap, or goes by itself after a few seconds (INFO_TIMEOUT), and a
tap then brings it back counted again; it needs no phone, and has nothing
for the phone to call.

Halo's emulators keep frame.time.utc() as a wall clock (a date in 2025),
too wide a line for Halo's round screen, so each test with the glasses
fixture first sets it to 137 s, as if just powered on."""
import re

import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, LUA_EVAL,
                     LUA_RESULT, MENU_OPEN, MENU_SELECT, NOW)

pytestmark = pytest.mark.module("uptime")

UPTIME = re.compile(r"\b(\d+)h (\d\d)m (\d\d)s\b")


def shown(glasses) -> int:
    """The uptime on the screen, in seconds."""
    m = UPTIME.search(glasses.screen_text())
    assert m, glasses.screen_text()
    h, mm, ss = (int(x) for x in m.groups())
    assert mm < 60 and ss < 60
    return h * 3600 + mm * 60 + ss


def uptime(glasses) -> int:
    """Opens Uptime from the phone and reads it, then lets it go by."""
    glasses.open_app("uptime")
    seconds = shown(glasses)
    glasses.advance(6)                           # past INFO_TIMEOUT
    return seconds


def lua(glasses, code: str):
    """Runs Lua on the glasses, as the phone's console does."""
    glasses.send(LUA_EVAL, b"\x89" + code.encode())
    glasses.advance(0.5)
    assert glasses.joined(LUA_RESULT)


@pytest.fixture(autouse=True)
def just_powered_on(request):
    if "glasses" in request.fixturenames:
        lua(request.getfixturevalue("glasses"), "frame.time.utc(137)")


def to_info(glasses):
    """Glaz > Info, from the clock."""
    glasses.tap(2)
    for _ in range(3):
        glasses.tilt(1)
    glasses.tap(1)


def test_shows_the_uptime(glasses):
    glasses.clear_sent()
    glasses.open_app("uptime")
    assert glasses.sent(APP_START)
    text = glasses.screen_text()
    assert "Uptime" in text
    assert UPTIME.search(text), text
    glasses.screenshot("uptime")
    glasses.assert_ok()


def test_hours_minutes_and_seconds(glasses):
    lua(glasses, "frame.time.utc(137 * 3600 + 2 * 60 + 3)")
    glasses.open_app("uptime")
    assert "137h 02m 03s" in glasses.screen_text()
    glasses.assert_ok()


def test_a_fraction_of_a_second_is_left_out(glasses):
    lua(glasses, "frame.time.utc(7)")
    glasses.open_app("uptime")
    text = glasses.screen_text()
    assert "0h 00m 07s" in text
    assert "." not in UPTIME.search(text).group(0)
    glasses.assert_ok()


def test_it_counts_up_with_time(glasses):
    first = uptime(glasses)                      # 6.5 s on
    glasses.advance(137)
    second = uptime(glasses)
    assert 137 + 6 <= second - first <= 137 + 8
    glasses.assert_ok()


def test_the_phones_clock_changes_nothing(glasses):
    first = uptime(glasses)
    glasses.set_clock(NOW + 137 * 3600)
    glasses.set_clock(NOW - 137 * 86400)
    second = uptime(glasses)
    assert 6 <= second - first <= 8
    glasses.assert_ok()


def test_the_value_does_not_change_while_shown(glasses):
    glasses.open_app("uptime")
    before = glasses.screen_text()
    glasses.advance(3)
    assert glasses.screen_text() == before       # an 'info' module: once
    glasses.assert_ok()


def test_opened_again_while_shown_it_stays_as_it_is(glasses):
    glasses.open_app("uptime")
    before = glasses.screen_text()
    glasses.advance(3)
    glasses.open_app("uptime")                   # on screen already
    assert glasses.screen_text() == before
    glasses.assert_ok()


def test_picked_in_info(glasses):
    to_info(glasses)
    assert "Bluetooth" in glasses.screen_text()
    glasses.tilt(1)                              # Bluetooth, Uptime
    assert "> Uptime" in glasses.screen_text()
    glasses.screenshot("uptime-menu")
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(MENU_SELECT) == [bytes([MENU_SELECT, 2])]
    assert len(glasses.sent(APP_START)) == 1
    text = glasses.screen_text()
    assert "> Uptime" in text                    # the path, cut on Halo
    assert UPTIME.search(text), text
    glasses.assert_ok()


def test_a_double_tap_goes_back_to_where_it_was_picked(glasses):
    to_info(glasses)
    glasses.tilt(1)
    glasses.tap(1)                               # Uptime
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert glasses.sent(MENU_OPEN)
    text = glasses.screen_text()
    assert "Glaz > Info" in text
    assert "> Uptime" in text                    # the cursor where it was
    assert not UPTIME.search(text)
    assert not glasses.sent(APP_BACKGROUND)      # nothing left running
    glasses.assert_ok()


def test_opened_by_the_phone_a_double_tap_goes_to_info(glasses):
    glasses.open_app("uptime")
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    text = glasses.screen_text()
    assert "Glaz > Info" in text
    assert not UPTIME.search(text)
    glasses.assert_ok()


@pytest.mark.parametrize("seconds, line", [
    (59, "0h 00m 59s"),
    (60, "0h 01m 00s"),
    (3599, "0h 59m 59s"),
    (3600, "1h 00m 00s"),
    (86400, "24h 00m 00s"),                      # no days: hours go on
    (1370 * 3600 + 59 * 60 + 59, "1370h 59m 59s"),
])
def test_minutes_and_hours_carry_over(glasses, seconds, line):
    lua(glasses, f"frame.time.utc({seconds})")
    glasses.open_app("uptime")
    assert line in glasses.screen_text().splitlines()   # whole, not cut
    glasses.assert_ok()


def test_start_and_stop_name_the_same_module(glasses):
    glasses.clear_sent()
    glasses.open_app("uptime")
    glasses.advance(6)
    (start,) = glasses.sent(APP_START)
    (stop,) = glasses.sent(APP_STOP)
    assert start[1:] == stop[1:]
    glasses.assert_ok()


def test_a_tap_after_it_went_brings_it_back_counted_again(glasses):
    first = uptime(glasses)                      # gone by itself
    assert glasses.screen_text() == ""
    glasses.advance(137)
    glasses.clear_sent()
    glasses.tap(1)                               # the last module again
    assert glasses.sent(APP_START)
    again = shown(glasses)
    assert 137 + 6 <= again - first <= 137 + 8
    assert "> Uptime" in glasses.screen_text()
    glasses.assert_ok()


def test_the_remotes_double_tap_goes_back(glasses):
    glasses.open_app("uptime")
    glasses.clear_sent()
    glasses.remote(1, 2, settle=1.0)
    assert glasses.sent(APP_STOP)
    text = glasses.screen_text()
    assert "Glaz > Info" in text
    assert not UPTIME.search(text)
    glasses.assert_ok()


def test_the_remotes_tilt_keeps_it_on_screen(glasses):
    glasses.open_app("uptime")
    before = glasses.screen_text()
    glasses.remote(2, 1)
    glasses.remote(2, 255)
    glasses.remote(3, 1)
    assert glasses.screen_text() == before
    glasses.assert_ok()


def test_the_remotes_menu_button_opens_the_menu_then_hides_it(glasses):
    glasses.open_app("uptime")
    glasses.clear_sent()
    glasses.remote(1, 3, settle=1.0)
    assert glasses.sent(APP_STOP)
    assert glasses.sent(MENU_OPEN)
    assert "Glaz > Info" in glasses.screen_text()
    glasses.remote(1, 3, settle=1.0)
    assert glasses.screen_text() == ""
    glasses.assert_ok()


def test_a_triple_tap_stops_it_and_sleeps(glasses):
    glasses.open_app("uptime")
    glasses.clear_sent()
    glasses.tap(3, settle=3.0)
    assert glasses.sent(APP_STOP)
    assert glasses.screen_text() == ""
    glasses.assert_ok()


def test_frame_needs_no_phone(frame):
    frame.advance(5)                             # past the splash
    frame.emu.connected = False
    to_info(frame)
    frame.tilt(1)
    frame.tap(1)
    assert UPTIME.search(frame.screen_text()), frame.screen_text()
    frame.assert_ok()


def test_halos_button_leaves_it_on_screen(halo):
    halo.open_app("uptime")
    before = halo.screen_text()
    halo.button("single")
    assert halo.screen_text() == before
    halo.assert_ok()


def test_stays_a_few_seconds_then_goes_by_itself(glasses):
    glasses.open_app("uptime")                   # 0.5 s
    glasses.clear_sent()
    glasses.advance(4)
    assert UPTIME.search(glasses.screen_text())
    assert not glasses.sent(APP_STOP)
    glasses.advance(1.5)                         # past INFO_TIMEOUT, 5 s
    assert glasses.sent(APP_STOP)
    assert glasses.screen_text() == ""           # the display cleared
    assert not glasses.sent(APP_BACKGROUND)
    glasses.assert_ok()


def test_a_tap_or_a_tilt_keeps_it_on_screen(glasses):
    glasses.open_app("uptime")
    before = glasses.screen_text()
    glasses.tap(1)
    glasses.tilt(1)
    assert glasses.screen_text() == before
    glasses.assert_ok()


def test_an_argument_from_the_phone_changes_nothing(glasses):
    glasses.open_app("uptime", "137")
    assert UPTIME.search(glasses.screen_text())
    glasses.assert_ok()


def test_the_phone_cannot_call_it(glasses):
    glasses.advance(5)                           # past the splash
    glasses.clear_sent()
    before = glasses.screen_text()
    glasses.call("uptime", "137")
    glasses.advance(1)
    assert not glasses.sent(APP_START)
    assert not glasses.sent(APP_BACKGROUND)
    assert glasses.screen_text() == before
    glasses.assert_ok()


def test_frame_counts_from_power_on(frame):
    frame.open_app("uptime")
    assert shown(frame) < 60                     # a few seconds since start
    frame.assert_ok()


def test_frame_starts_again_from_zero_after_sleep(frame):
    lua(frame, "frame.time.utc(137)")
    before = uptime(frame)
    frame.tap(3, settle=3.0)                     # deep sleep
    frame.advance(2)
    frame.tap(1, settle=2.0)
    assert frame.emu.boots == 2                  # waking is a reset
    assert frame.until("Frame app is running", since=2)
    frame.advance(1)
    assert uptime(frame) < before
    frame.assert_ok()

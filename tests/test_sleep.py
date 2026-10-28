"""Sleep (modules/sleep.lua), Settings > Sleep, on Frame, the only glasses
that have it: it says which background module it would stop, a tap puts
the glasses into deep sleep at once -- connected or not, the background
module stopped -- two taps go back with nothing done, and a tap after
waking brings back what ran before, never Sleep itself."""
import pytest

from glasses import APP_BACKGROUND, APP_START, APP_STOP, has_module

pytestmark = pytest.mark.module("sleep")


def until_asleep(g, timeout=5.0):
    """Lets time pass until frame.sleep() parks the glasses: the eye
    blinks for about a second first."""
    waited = 0.0
    while not g.emu.asleep and waited < timeout:
        g.advance(0.1)
        waited += 0.1
    return g.emu.asleep


def with_stopwatch_in_background(g):
    g.open_app("stopwatch")
    g.tap(1)                                     # counting
    g.clear_sent()
    g.tap(2)                                     # back: it goes on
    assert g.sent(APP_BACKGROUND)


def test_only_frame_has_it():
    assert has_module("frame", "sleep")
    assert not has_module("halo", "sleep")


def test_opens_asking_with_nothing_in_background(glasses):
    glasses.clear_sent()
    glasses.open_app("sleep")
    assert glasses.sent(APP_START)
    text = glasses.screen_text()
    assert "Sleep" in text
    assert "sleep now?" in text
    assert "nothing in background" in text
    assert "tap = sleep, 2 taps = back" in text
    assert not glasses.emu.asleep
    glasses.screenshot("sleep")
    glasses.assert_ok()


def test_names_the_background_module_it_will_stop(frame):
    with_stopwatch_in_background(frame)
    frame.open_app("sleep")
    text = frame.screen_text()
    assert "will stop: Stopwatch" in text
    assert "nothing in background" not in text
    frame.screenshot("sleep-will-stop")
    frame.assert_ok()


def test_the_warning_is_fresh_each_time_it_opens(frame):
    with_stopwatch_in_background(frame)
    frame.open_app("sleep")
    assert "will stop: Stopwatch" in frame.screen_text()
    frame.tap(2)                                 # back
    frame.open_app("stopwatch")                  # back from the background
    frame.tap(1)                                 # paused
    frame.tilt(1)                                # reset
    assert "0:00.0" in frame.screen_text()
    frame.clear_sent()
    frame.tap(2)                                 # left at zero: it stops
    assert not frame.sent(APP_BACKGROUND)
    frame.open_app("sleep")
    assert "nothing in background" in frame.screen_text()
    frame.assert_ok()


def test_two_taps_go_back_and_nothing_sleeps(frame):
    with_stopwatch_in_background(frame)
    frame.open_app("sleep")
    frame.clear_sent()
    frame.tap(2)
    assert len(frame.sent(APP_STOP)) == 1        # Sleep itself, only
    assert "sleep now?" not in frame.screen_text()
    frame.advance(5)
    assert not frame.emu.asleep
    frame.open_app("stopwatch")                  # still counting
    assert "paused" not in frame.screen_text()
    assert "0:0" in frame.screen_text()
    frame.assert_ok()


def test_a_tap_puts_the_glasses_to_sleep(frame):
    frame.open_app("sleep")
    assert frame.emu.connected                   # a phone does not keep it up
    frame.tap(1, settle=0)
    assert until_asleep(frame)
    assert frame.lit() == 0                      # the display is off
    assert frame.screen_text() == ""
    frame.advance(137)
    assert frame.emu.asleep                      # until a tap
    assert frame.emu.boots == 1
    frame.assert_ok()


def test_the_remotes_tap_puts_them_to_sleep_too(frame):
    frame.open_app("sleep")
    frame.remote(1, 1)                           # INPUT: one tap
    assert until_asleep(frame)
    frame.assert_ok()


def test_sleeping_stops_the_background_module(frame):
    with_stopwatch_in_background(frame)
    frame.open_app("sleep")
    frame.clear_sent()
    frame.tap(1, settle=0)
    assert until_asleep(frame)
    stopped = {m[1] for m in frame.sent(APP_STOP)}
    assert len(stopped) == 2                     # Sleep and the Stopwatch
    frame.assert_ok()


def test_a_tap_wakes_them_into_the_menu_when_nothing_ran(frame):
    frame.open_app("sleep")
    frame.tap(1, settle=0)
    assert until_asleep(frame)
    frame.tap(1)                                 # a reset, woken by a tap
    assert not frame.emu.asleep
    assert frame.emu.boots == 2
    text = frame.screen_text()
    assert "sleep now?" not in text              # not Sleep again
    assert "Apps" in text and "Settings" in text  # the menu at its root
    assert not (frame.sandbox / "last.txt").exists()
    frame.assert_ok()


def test_waking_brings_back_what_ran_before_not_sleep(frame):
    with_stopwatch_in_background(frame)
    frame.open_app("sleep")
    frame.tap(1, settle=0)
    assert until_asleep(frame)
    assert (frame.sandbox / "last.txt").read_text() == "stopwatch"
    frame.tap(1)
    text = frame.screen_text()
    assert "Stopwatch" in text
    assert "0:00.0" in text                      # stopped, started afresh
    assert "sleep now?" not in text
    assert not (frame.sandbox / "last.txt").exists()
    frame.assert_ok()


def test_left_alone_it_closes_without_sleeping(frame):
    frame.open_app("sleep")
    frame.clear_sent()
    frame.advance(60 + 2)                        # APP_TIMEOUT
    assert frame.sent(APP_STOP)
    assert "sleep now?" not in frame.screen_text()
    frame.advance(30 + 5)                        # SLEEP_AFTER, but connected
    assert not frame.emu.asleep
    frame.assert_ok()


def test_three_taps_sleep_from_it_as_from_anywhere(frame):
    frame.open_app("sleep")
    frame.tap(3, settle=0)
    assert until_asleep(frame)
    frame.assert_ok()


def test_picked_from_settings_in_the_menu(frame):
    frame.tap(2)                                 # the menu
    frame.tilt(1)
    frame.tilt(1)                                # Settings
    frame.tap(1)
    frame.tilt(1)
    frame.tilt(1)                                # Brightness, Notifications, Sleep
    assert "> Sleep" in frame.screen_text()
    frame.screenshot("menu-settings-sleep")
    frame.clear_sent()
    frame.tap(1)
    assert frame.sent(APP_START)
    assert "sleep now?" in frame.screen_text()
    assert not frame.emu.asleep
    frame.assert_ok()


def test_halo_settings_have_no_sleep(halo):
    halo.tap(2)                                  # the menu
    halo.tilt(1)
    halo.tilt(1)                                 # Settings
    halo.tap(1)
    text = halo.screen_text()
    assert "Glaz > Settings" in text
    assert "Sleep" not in text
    halo.assert_ok()


def test_opened_over_a_running_app_it_warns_about_that_app(frame):
    frame.open_app("stopwatch")
    frame.tap(1)                                 # counting, on screen
    frame.clear_sent()
    frame.open_app("sleep")                      # the phone replaces it
    assert frame.sent(APP_BACKGROUND)            # the Stopwatch goes on
    assert "will stop: Stopwatch" in frame.screen_text()
    frame.assert_ok()


def test_the_eye_closes_before_the_screen_goes_dark(frame):
    frame.open_app("sleep")
    frame.tap(1, settle=0)
    waited = 0.0
    while "sleep now?" in frame.screen_text() and waited < 2:
        frame.advance(0.05)
        waited += 0.05
    frame.advance(0.3)                           # into the blink
    assert not frame.emu.asleep
    assert frame.lit() > 0                       # not just a dark screen
    assert "sleep now?" not in frame.screen_text()
    frame.screenshot("sleep-goodnight")
    assert until_asleep(frame)
    assert frame.lit() == 0
    frame.assert_ok()


def test_tilting_does_nothing_on_it(frame):
    frame.open_app("sleep")
    frame.clear_sent()
    frame.tilt(1)
    frame.tilt(-1)
    frame.remote(2, 1)                           # the remote's Down
    assert "sleep now?" in frame.screen_text()
    assert not frame.sent(APP_STOP)
    frame.advance(5)
    assert not frame.emu.asleep
    frame.assert_ok()


def test_the_phone_cannot_call_it(frame):
    frame.clear_sent()
    frame.call("sleep", "137")                   # no remote(): not started
    frame.advance(5)
    assert not frame.sent(APP_START)
    assert not frame.sent(APP_BACKGROUND)
    assert "sleep now?" not in frame.screen_text()
    frame.open_app("sleep")
    frame.call("sleep", "137")                   # on screen: still nothing
    frame.advance(5)
    assert "sleep now?" in frame.screen_text()
    assert not frame.emu.asleep
    frame.assert_ok()


def test_waking_brings_back_an_app_left_before_it(frame):
    frame.open_app("about")
    frame.tap(2)                                 # left: it stops
    frame.open_app("sleep")
    assert "nothing in background" in frame.screen_text()
    frame.tap(1, settle=0)
    assert until_asleep(frame)
    assert (frame.sandbox / "last.txt").read_text() == "about"
    frame.tap(1)
    assert frame.emu.boots == 2
    text = frame.screen_text()
    assert "sleep now?" not in text
    assert "About" in text
    frame.assert_ok()


def test_it_sleeps_without_a_phone_too(frame):
    frame.open_app("sleep")
    frame.emu.connected = False
    frame.tap(1, settle=0)
    assert until_asleep(frame)
    assert not frame.emu.display.powered
    frame.assert_ok()


def test_the_wake_taps_go_back_to_stock_before_sleeping(frame):
    frame.open_app("sleep")
    frame.emu._tap["threshold"] = 137            # as Tap tune leaves them
    frame.emu._tap["duration"] = 7
    frame.tap(1, settle=0)
    assert until_asleep(frame)
    tap = frame.emu._tap
    assert tap["threshold"] == 7 and tap["duration"] == 0
    assert tap["latch"] is True and tap["rate"] == 256
    frame.assert_ok()

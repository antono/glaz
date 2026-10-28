"""Settings > Brightness (apps/brightness/brightness.lua), Frame only: a tilt
previews the next or previous level live, a tap keeps it, and leaving any
other way -- a double tap, the timeout, three taps, the menu, another app
-- puts the last kept level back.

Until a level is kept the module takes the panel to be at the level the
firmware starts it at, 1: display_configuration.h writes 0xCB to register
0x05 at boot, and set_brightness(1) writes the same (display.c). The
emulator's panel starts at 0 instead (see test_the_panel_boots_at_level_1).
"""
import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, HANDS_OFF,
                     MENU_OPEN, has_module)

pytestmark = pytest.mark.module("brightness")

APP_TIMEOUT = 60     # glaz.lua: an 'app' module left alone this long closes
BOOT = 1             # the level the firmware starts the panel at
AT_BOOT = "-2  -1  0  [1]  2"


def scale(g):
    """The line of levels, '-2  -1  0  [1]  2'."""
    lines = [l for l in g.screen_text().splitlines() if "[" in l]
    assert len(lines) == 1, g.screen_text()
    return lines[0]


def keep(frame, level):
    """Opens Brightness, tilts from the boot level to level and keeps it
    with a tap."""
    frame.open_app("brightness")
    for _ in range(abs(level - BOOT)):
        frame.tilt(1 if level > BOOT else -1)
    frame.tap(1)
    assert frame.emu.display.brightness == level


def test_goes_to_frame_only():
    assert has_module("frame", "brightness")
    assert not has_module("halo", "brightness")


def test_halo_ignores_the_phone_opening_it(halo):
    before = halo.screen_text()
    halo.clear_sent()
    halo.open_app("brightness")
    halo.advance(1)
    assert not halo.sent(APP_START)
    assert "Brightness" not in halo.screen_text()
    assert halo.screen_text() == before
    halo.assert_ok()


def test_opens_on_the_scale_at_the_boot_level(glasses):
    glasses.clear_sent()
    glasses.open_app("brightness")
    assert glasses.sent(APP_START)
    text = glasses.screen_text()
    assert "Brightness" in text
    assert AT_BOOT in text
    glasses.screenshot("brightness")
    glasses.assert_ok()


def test_opening_alone_does_not_touch_the_panel(frame):
    frame.emu.display.brightness = BOOT          # as the firmware boots it
    frame.open_app("brightness")
    frame.advance(10)
    assert frame.emu.display.brightness == BOOT
    frame.assert_ok()


def test_a_tilt_previews_the_level_live(frame):
    frame.open_app("brightness")
    frame.tilt(-1)
    assert scale(frame) == "-2  -1  [0]  1  2"
    assert frame.emu.display.brightness == 0
    frame.tilt(1)
    frame.tilt(1)
    assert scale(frame) == "-2  -1  0  1  [2]"
    assert frame.emu.display.brightness == 2
    frame.screenshot("brightness-preview")
    frame.assert_ok()


def test_the_scale_stops_at_its_ends(frame):
    frame.open_app("brightness")
    for _ in range(3):
        frame.tilt(1)
    assert scale(frame) == "-2  -1  0  1  [2]"
    assert frame.emu.display.brightness == 2
    for _ in range(6):
        frame.tilt(-1)
    assert scale(frame) == "[-2]  -1  0  1  2"
    assert frame.emu.display.brightness == -2
    frame.tilt(-1)                               # past the end: nothing
    assert scale(frame) == "[-2]  -1  0  1  2"
    frame.screenshot("brightness-lowest")
    frame.assert_ok()


def test_a_tap_keeps_the_level_and_the_menu_comes_back(frame):
    frame.open_app("brightness")
    frame.tilt(-1)
    frame.clear_sent()
    frame.tap(1)
    assert frame.sent(APP_STOP)
    assert frame.sent(MENU_OPEN)
    assert not frame.sent(APP_BACKGROUND)
    text = frame.screen_text()
    assert "> Brightness" in text                # back in Settings
    assert "[" not in text
    assert frame.emu.display.brightness == 0
    frame.advance(137)
    assert frame.emu.display.brightness == 0
    frame.assert_ok()


def test_a_tap_without_a_tilt_keeps_the_boot_level(frame):
    frame.emu.display.brightness = BOOT          # as the firmware boots it
    frame.open_app("brightness")
    frame.tap(1)
    assert "> Brightness" in frame.screen_text()
    assert frame.emu.display.brightness == BOOT
    frame.open_app("brightness")
    assert scale(frame) == AT_BOOT
    frame.assert_ok()


def test_it_reopens_on_the_kept_level(frame):
    keep(frame, -1)
    frame.open_app("brightness")
    assert scale(frame) == "-2  [-1]  0  1  2"
    frame.assert_ok()


def test_the_kept_level_outlasts_other_apps(frame):
    keep(frame, -2)
    frame.open_app("stopwatch")
    frame.advance(5)
    frame.tap(2)                                 # back, stopped
    assert frame.emu.display.brightness == -2
    frame.open_app("brightness")
    assert scale(frame) == "[-2]  -1  0  1  2"
    frame.assert_ok()


def test_a_double_tap_cancels_the_preview(frame):
    frame.open_app("brightness")
    frame.tilt(1)
    assert frame.emu.display.brightness == 2
    frame.clear_sent()
    frame.tap(2)
    assert frame.sent(APP_STOP)
    assert not frame.sent(APP_BACKGROUND)
    assert "[" not in frame.screen_text()
    assert frame.emu.display.brightness == BOOT
    frame.open_app("brightness")
    assert scale(frame) == AT_BOOT
    frame.assert_ok()


def test_cancelling_restores_the_last_kept_level_not_the_default(frame):
    keep(frame, -2)
    frame.open_app("brightness")
    frame.tilt(1)
    frame.tilt(1)
    assert frame.emu.display.brightness == 0
    frame.tap(2)
    assert frame.emu.display.brightness == -2
    frame.open_app("brightness")
    assert scale(frame) == "[-2]  -1  0  1  2"
    frame.assert_ok()


def test_left_alone_it_closes_and_cancels(frame):
    frame.open_app("brightness")
    frame.tilt(-1)
    assert frame.emu.display.brightness == 0
    frame.clear_sent()
    frame.advance(APP_TIMEOUT - 5)
    assert "[0]" in frame.screen_text()          # still open
    frame.advance(10)
    assert frame.sent(APP_STOP)
    assert "[" not in frame.screen_text()
    assert frame.emu.display.brightness == BOOT
    frame.assert_ok()


def test_a_tilt_keeps_it_open_past_the_timeout(frame):
    frame.open_app("brightness")
    frame.advance(APP_TIMEOUT - 10)
    frame.tilt(-1)
    frame.advance(APP_TIMEOUT - 10)
    assert scale(frame) == "-2  -1  [0]  1  2"
    assert frame.emu.display.brightness == 0
    frame.assert_ok()


def test_three_taps_cancel_and_sleep(frame):
    keep(frame, -1)
    frame.open_app("brightness")
    frame.tilt(1)
    frame.tilt(1)
    assert frame.emu.display.brightness == 1
    frame.clear_sent()
    frame.tap(3, settle=3.0)
    frame.advance(2)
    assert frame.sent(APP_STOP)
    assert frame.emu.asleep
    assert frame.emu.display.brightness == -1    # the preview undone
    frame.assert_ok()


def test_waking_from_sleep_is_back_at_the_boot_level(frame):
    keep(frame, -1)
    frame.open_app("brightness")
    frame.tap(3, settle=3.0)
    frame.advance(2)
    frame.tap(1, settle=2.0)                     # waking is a reset
    assert frame.emu.boots == 2
    assert frame.until("Frame app is running", since=2)
    frame.advance(1)
    assert scale(frame) == AT_BOOT               # back where it was, afresh
    frame.assert_ok()


def test_the_panel_boots_at_level_1(frame):
    assert frame.emu.display.brightness == BOOT
    keep(frame, -1)
    frame.tap(3, settle=3.0)
    frame.advance(2)
    frame.tap(1, settle=2.0)
    assert frame.until("Frame app is running", since=2)
    assert frame.emu.display.brightness == BOOT


def test_the_phone_opening_another_app_cancels(frame):
    frame.open_app("brightness")
    frame.tilt(1)
    assert frame.emu.display.brightness == 2
    frame.clear_sent()
    frame.open_app("stopwatch")
    assert frame.sent(APP_STOP)
    assert not frame.sent(APP_BACKGROUND)
    assert "Stopwatch" in frame.screen_text()
    assert frame.emu.display.brightness == BOOT
    frame.assert_ok()


def test_the_remotes_menu_button_cancels(frame):
    frame.open_app("brightness")
    frame.tilt(-1)
    frame.clear_sent()
    frame.remote(1, 3)                           # Menu
    frame.advance(1)
    assert frame.sent(APP_STOP)
    assert "[" not in frame.screen_text()
    assert frame.emu.display.brightness == BOOT
    frame.assert_ok()


def test_the_phone_opening_it_again_keeps_the_preview(frame):
    frame.open_app("brightness")
    frame.tilt(-1)
    frame.clear_sent()
    frame.open_app("brightness")
    assert not frame.sent(APP_STOP)
    assert scale(frame) == "-2  -1  [0]  1  2"
    assert frame.emu.display.brightness == 0
    frame.assert_ok()


def test_a_module_call_does_nothing(frame):
    # no remote(): the phone cannot call it, open or not
    frame.clear_sent()
    frame.call("brightness", "137")
    frame.advance(1)
    assert not frame.sent(APP_START)
    assert not frame.sent(APP_BACKGROUND)
    frame.open_app("brightness")
    frame.tilt(-1)
    frame.call("brightness", "137")
    frame.advance(1)
    assert scale(frame) == "-2  -1  [0]  1  2"
    assert frame.emu.display.brightness == 0
    frame.assert_ok()


def test_the_phones_remote_moves_and_keeps_the_level(frame):
    frame.open_app("brightness")
    frame.remote(2, 1)                           # Right
    assert scale(frame) == "-2  -1  0  1  [2]"
    frame.remote(2, 255)                         # Left
    frame.remote(2, 255)
    assert scale(frame) == "-2  -1  [0]  1  2"
    frame.remote(3, 255)                         # Up: previous, no on_up_down
    assert scale(frame) == "-2  [-1]  0  1  2"
    frame.remote(3, 1)                           # Down: next
    assert scale(frame) == "-2  -1  [0]  1  2"
    frame.remote(1, 1)                           # a tap: keep
    frame.advance(1)
    assert "[" not in frame.screen_text()
    assert frame.emu.display.brightness == 0
    frame.open_app("brightness")
    assert scale(frame) == "-2  -1  [0]  1  2"
    frame.assert_ok()


def test_the_phones_double_tap_cancels(frame):
    keep(frame, 0)
    frame.open_app("brightness")
    frame.remote(2, 1)
    assert frame.emu.display.brightness == 1
    frame.remote(1, 2)
    frame.advance(1)
    assert "[" not in frame.screen_text()
    assert frame.emu.display.brightness == 0
    frame.assert_ok()


def test_hands_off_the_head_tilt_does_nothing_but_the_remote_does(frame):
    frame.open_app("brightness")
    frame.send(HANDS_OFF, b"\x01")
    frame.tilt(-1)
    assert scale(frame) == AT_BOOT
    frame.remote(2, 255)
    assert scale(frame) == "-2  -1  [0]  1  2"
    assert frame.emu.display.brightness == 0
    frame.assert_ok()


def test_reached_through_the_menu(frame):
    frame.tap(2)                                 # the menu
    for _ in range(10):
        if "> Settings" in frame.screen_text():
            break
        frame.tilt(1)
    assert "> Settings" in frame.screen_text()
    frame.tap(1)
    assert "> Brightness" in frame.screen_text()
    frame.screenshot("brightness-menu")
    frame.tap(1)
    assert scale(frame) == AT_BOOT
    frame.tilt(1)
    frame.tap(1)
    assert "> Brightness" in frame.screen_text()
    assert frame.emu.display.brightness == 2
    frame.assert_ok()

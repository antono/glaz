"""Info > Firmware (apps/firmware/firmware.lua) on each pair of glasses that has
it: it shows the version the firmware gives (frame.FIRMWARE_VERSION), the
one STATUS tells the phone, read again each time it opens; it comes from
the menu, the phone or a tap on the blank screen, goes back with a double
tap (the arm's or the remote's), the remote's Menu button, three taps, or
by itself after a few seconds (INFO_TIMEOUT), under a notification too; a
version that cannot be read shows the error; it has nothing for the phone
to call."""
import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, LUA_EVAL,
                     LUA_RESULT, MENU_OPEN, MENU_SELECT, STATUS,
                     STATUS_GET)

pytestmark = pytest.mark.module("firmware")

# frame.FIRMWARE_VERSION in each emulator: Frame's as tests/frame_emulator
# has it, Halo's as halo-emulator does (cut to Halo's round screen there)
SHOWN = {"frame": "v25.080.0838", "halo": "0.8.12-emulato"}


def version(glasses) -> str:
    """The version the firmware says, as STATUS carries it to the phone."""
    glasses.advance(5)                           # past the splash
    glasses.clear_sent()
    glasses.send(STATUS_GET, b"\x00")
    glasses.advance(0.5)
    return glasses.sent(STATUS)[-1][2:].decode()


def lua(glasses, code: str):
    """Runs Lua on the glasses, as the phone's console does."""
    glasses.send(LUA_EVAL, b"\x89" + code.encode())
    glasses.advance(0.5)
    assert glasses.joined(LUA_RESULT)


def test_shows_the_firmware_version(glasses):
    glasses.clear_sent()
    glasses.open_app("firmware")
    assert glasses.sent(APP_START)
    text = glasses.screen_text()
    assert "Firmware" in text
    assert SHOWN[glasses.device] in text
    glasses.screenshot("firmware")
    glasses.assert_ok()


def test_the_version_is_the_one_the_phone_gets(glasses):
    said = version(glasses)
    assert said.startswith(SHOWN[glasses.device])
    glasses.open_app("firmware")
    assert said[:len(SHOWN[glasses.device])] in glasses.screen_text()


def test_picked_in_info(glasses):
    glasses.tap(2)
    for _ in range(3):
        glasses.tilt(1)                          # Info
    glasses.tap(1)
    assert "Firmware" in glasses.screen_text()
    glasses.tilt(1)
    glasses.tilt(1)                              # Bluetooth, Uptime, Firmware
    assert "> Firmware" in glasses.screen_text()
    glasses.screenshot("firmware_in_info")
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(MENU_SELECT)
    assert glasses.sent(APP_START)
    text = glasses.screen_text()
    assert ".. > Firmware" in text
    assert SHOWN[glasses.device] in text
    glasses.assert_ok()


def test_shows_what_the_firmware_says_not_a_fixed_text(glasses):
    lua(glasses, "frame.FIRMWARE_VERSION = 'v26.137.0137'")
    glasses.open_app("firmware")
    assert "v26.137.0137" in glasses.screen_text()
    assert SHOWN[glasses.device] not in glasses.screen_text()
    glasses.assert_ok()


def test_no_version_shows_nothing_and_breaks_nothing(glasses):
    lua(glasses, "frame.FIRMWARE_VERSION = nil")
    glasses.open_app("firmware")
    text = glasses.screen_text()
    assert "Firmware" in text
    assert "nil" not in text
    assert "error" not in text.lower()
    glasses.assert_ok()


def test_a_number_for_a_version_is_shown_as_text(glasses):
    lua(glasses, "frame.FIRMWARE_VERSION = 137")
    glasses.open_app("firmware")
    assert "137" in glasses.screen_text()
    glasses.assert_ok()


def test_a_double_tap_goes_back_to_where_it_was_picked(glasses):
    glasses.tap(2)
    for _ in range(3):
        glasses.tilt(1)
    glasses.tap(1)                               # Info
    glasses.tilt(1)
    glasses.tilt(1)
    glasses.tap(1)                               # Firmware
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert glasses.sent(MENU_OPEN)
    text = glasses.screen_text()
    assert "Glaz > Info" in text
    assert "> Firmware" in text                  # the cursor where it was
    assert SHOWN[glasses.device] not in text
    assert not glasses.sent(APP_BACKGROUND)      # nothing left running
    glasses.assert_ok()


def test_opened_by_the_phone_a_double_tap_goes_to_info(glasses):
    glasses.open_app("firmware")
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    text = glasses.screen_text()
    assert "Glaz > Info" in text
    assert SHOWN[glasses.device] not in text
    glasses.assert_ok()


def test_stays_a_few_seconds_then_goes_by_itself(glasses):
    glasses.open_app("firmware")                 # 0.5 s
    glasses.clear_sent()
    glasses.advance(4)
    assert SHOWN[glasses.device] in glasses.screen_text()
    assert not glasses.sent(APP_STOP)
    glasses.advance(1.5)                         # past INFO_TIMEOUT, 5 s
    assert glasses.sent(APP_STOP)
    assert glasses.screen_text() == ""           # the display cleared
    assert not glasses.sent(APP_BACKGROUND)
    glasses.assert_ok()


def test_a_tap_does_not_keep_it_longer(glasses):
    glasses.open_app("firmware")
    glasses.advance(3.5)
    glasses.tap(1)                               # 1 s to count
    glasses.advance(1)                           # 2 s past the tap, 6 s in
    assert SHOWN[glasses.device] not in glasses.screen_text()
    glasses.assert_ok()


def test_an_argument_from_the_phone_changes_nothing(glasses):
    glasses.open_app("firmware", "137")
    assert SHOWN[glasses.device] in glasses.screen_text()
    glasses.open_app("firmware", "137")          # again, on screen already
    assert SHOWN[glasses.device] in glasses.screen_text()
    glasses.assert_ok()


def test_the_phone_cannot_call_it(glasses):
    glasses.advance(5)                           # past the splash
    glasses.clear_sent()
    before = glasses.screen_text()
    glasses.call("firmware", "137")
    glasses.advance(1)
    assert not glasses.sent(APP_START)
    assert not glasses.sent(APP_BACKGROUND)
    assert glasses.screen_text() == before
    glasses.assert_ok()


def test_called_while_on_screen_it_stays_as_it_is(glasses):
    glasses.open_app("firmware")
    before = glasses.screen_text()
    glasses.clear_sent()
    glasses.call("firmware", "137")
    glasses.advance(1)
    assert glasses.screen_text() == before
    assert not glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_a_single_tap_keeps_it_on_screen(glasses):
    glasses.open_app("firmware")
    glasses.clear_sent()
    glasses.tap(1)
    assert SHOWN[glasses.device] in glasses.screen_text()
    glasses.assert_ok()


def test_a_tilt_keeps_it_on_screen(glasses):
    glasses.open_app("firmware")
    glasses.tilt(1)
    glasses.tilt(-1)
    assert SHOWN[glasses.device] in glasses.screen_text()
    glasses.assert_ok()


def test_a_tap_on_the_blank_screen_brings_it_back(glasses):
    glasses.open_app("firmware")
    glasses.advance(5.5)                         # gone by itself
    assert glasses.screen_text() == ""
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(APP_START)
    assert SHOWN[glasses.device] in glasses.screen_text()
    glasses.advance(5.5)                         # and goes again
    assert glasses.screen_text() == ""
    glasses.assert_ok()


def test_the_version_is_read_again_each_time_it_opens(glasses):
    glasses.open_app("firmware")
    assert SHOWN[glasses.device] in glasses.screen_text()
    glasses.advance(5.5)
    lua(glasses, "frame.FIRMWARE_VERSION = 'v26.137.0137'")
    glasses.open_app("firmware")
    assert "v26.137.0137" in glasses.screen_text()
    glasses.assert_ok()


def test_opened_again_it_does_not_stay_longer(glasses):
    glasses.open_app("firmware")
    glasses.advance(3)
    glasses.clear_sent()
    glasses.open_app("firmware")                 # on screen already
    assert not glasses.sent(APP_START)
    glasses.advance(2.5)                         # 6 s since the first
    assert glasses.screen_text() == ""
    glasses.assert_ok()


def test_the_remotes_double_tap_goes_back_to_info(glasses):
    glasses.open_app("firmware")
    glasses.clear_sent()
    glasses.remote(1, 2)
    glasses.advance(0.5)
    assert glasses.sent(APP_STOP)
    assert glasses.sent(MENU_OPEN)
    text = glasses.screen_text()
    assert "Glaz > Info" in text
    assert SHOWN[glasses.device] not in text
    glasses.assert_ok()


def test_the_remotes_menu_button_shows_the_menu(glasses):
    glasses.open_app("firmware")
    glasses.clear_sent()
    glasses.remote(1, 3)
    glasses.advance(0.5)
    assert glasses.sent(APP_STOP)
    assert glasses.sent(MENU_OPEN)
    assert "Glaz > Info" in glasses.screen_text()
    glasses.assert_ok()


def test_the_remotes_tilts_keep_it_on_screen(glasses):
    glasses.open_app("firmware")
    glasses.clear_sent()
    glasses.remote(2, 1)
    glasses.remote(2, 255)
    glasses.remote(3, 1)
    assert SHOWN[glasses.device] in glasses.screen_text()
    assert not glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_three_taps_put_it_away_and_the_glasses_to_sleep(glasses):
    glasses.open_app("firmware")
    glasses.clear_sent()
    glasses.tap(3)
    assert glasses.sent(APP_STOP)
    assert SHOWN[glasses.device] not in glasses.screen_text()
    glasses.assert_ok()


def test_a_notification_covers_it_and_it_still_goes_in_time(glasses):
    glasses.open_app("firmware")
    glasses.notify("Chat", "Hi", "137 apples")
    text = glasses.screen_text()
    assert "137 apples" in text
    assert SHOWN[glasses.device] not in text
    glasses.screenshot("firmware_notified")
    glasses.advance(8)
    assert glasses.screen_text() == ""
    glasses.assert_ok()


def test_a_long_version_is_drawn_without_trouble(glasses):
    lua(glasses, "frame.FIRMWARE_VERSION = string.rep('7', 137)")
    glasses.open_app("firmware")
    shown = [t.text for t in glasses.texts() if t.text.startswith("777")]
    assert len(shown) == 1
    if glasses.device == "halo":
        assert len(shown[0]) < 137               # cut to the round screen
    glasses.assert_ok()


def test_a_version_that_cannot_be_read_shows_the_error(glasses):
    # reading frame.FIRMWARE_VERSION raises: run() fails, the app does not
    lua(glasses, "rawset(frame, 'FIRMWARE_VERSION', nil) "
                 "setmetatable(frame, {__index = function(_, k) "
                 "if k == 'FIRMWARE_VERSION' then error('no 137') end end})")
    glasses.open_app("firmware")
    assert glasses.sent(APP_START)
    assert "err: console:1" in glasses.screen_text()
    assert any("Firmware err:" in line and "no 137" in line
               for line in glasses.lines)        # printed for the phone's Log
    glasses.screenshot("firmware_error")
    glasses.advance(5.5)
    assert glasses.screen_text() == ""           # and goes as usual
    assert glasses.running()


# ---------------------------------------------------------------- edges

def test_an_empty_version_shows_nothing_and_breaks_nothing(glasses):
    lua(glasses, "frame.FIRMWARE_VERSION = ''")
    glasses.open_app("firmware")
    text = glasses.screen_text()
    assert "Firmware" in text
    assert SHOWN[glasses.device] not in text
    glasses.advance(5.5)
    assert glasses.screen_text() == ""
    glasses.assert_ok()


def test_opened_by_the_phone_again_and_again_it_starts_once(glasses):
    glasses.clear_sent()
    for _ in range(5):
        glasses.open_app("firmware", settle=0.1)
    assert len(glasses.sent(APP_START)) == 1
    assert SHOWN[glasses.device] in glasses.screen_text()
    glasses.advance(5.5)                         # its own 5 s, no more
    assert glasses.screen_text() == ""
    assert len(glasses.sent(APP_STOP)) == 1
    glasses.assert_ok()


def test_taps_on_the_blank_screen_one_after_another(glasses):
    # each brings it back once; one while it is shown changes nothing
    glasses.open_app("firmware")
    glasses.advance(5.5)
    glasses.clear_sent()
    glasses.tap(1)
    glasses.tap(1)
    assert len(glasses.sent(APP_START)) == 1
    assert SHOWN[glasses.device] in glasses.screen_text()
    glasses.assert_ok()


def test_the_phone_opening_another_app_puts_it_away(glasses):
    glasses.open_app("firmware")
    glasses.clear_sent()
    glasses.open_app("battery")
    assert glasses.sent(APP_STOP)
    assert glasses.sent(APP_START)
    text = glasses.screen_text()
    assert "Battery" in text and SHOWN[glasses.device] not in text
    glasses.assert_ok()


def test_awake_again_it_shows_the_version_as_before(frame):
    frame.open_app("firmware")
    frame.tap(3, settle=3.0)
    frame.advance(2)
    assert frame.emu.asleep
    frame.tap(1, settle=2.0)                     # waking is a reset
    assert frame.until("Frame app is running", since=2)
    frame.open_app("firmware")
    assert SHOWN["frame"] in frame.screen_text()
    frame.assert_ok()

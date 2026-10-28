"""glaz itself on each pair of glasses: start, the menu, gestures, sleep,
the phone's services, the host's break and the restart after a crash
(glaz/; docs/PROTOCOL.md). The modules have tests of their own,
test_<module>.py.
"""
import struct

import pytest

from glasses import (APP_START, APP_STOP, CLOCK_SET, Glasses, LUA_EVAL, NOW,
                     LUA_RESULT, MENU_CLOSE, MENU_CURSOR, MENU_LEVEL,
                     MENU_OPEN, MENU_SELECT, STATUS, STATUS_GET)
from sandbox import modules, stage


# ---------------------------------------------------------------- upload

@pytest.mark.parametrize("device", ["frame", "halo"])
def test_uploads_only_the_glasses_own_files(tmp_path, device):
    other = "halo" if device == "frame" else "frame"
    files = stage(tmp_path, device)
    assert "main.lua" in files and "glaz_app.lua" in files
    assert f"glaz_app.{device}.lua" in files
    assert not [f for f in files if f".{other}." in f]
    # glaz_boot's own part is main.lua, not a file of its own
    assert f"glaz_boot.{device}.lua" not in files
    for m in modules(device):
        assert f"{m}.lua" in files or f"{m}.{device}.lua" in files


def test_frame_has_every_module_and_halo_only_its_own(tmp_path):
    frame, halo = set(modules("frame")), set(modules("halo"))
    assert "reader" in frame and "reader" not in halo
    assert halo <= frame
    assert "about" in halo


# ---------------------------------------------------------------- start

def test_starts_without_errors(glasses):
    glasses.advance(1)
    glasses.assert_ok()
    assert "glaz" in glasses.screen_text()       # <glaz>, the splash
    assert glasses.lit() > 0
    glasses.screenshot("splash")


def test_the_splash_goes_by_itself(glasses):
    glasses.advance(5)
    assert "glaz" not in glasses.screen_text()
    glasses.assert_ok()


def test_answers_status_with_battery_and_version(glasses):
    glasses.emu.set_battery_level(42) if glasses.device == "halo" else \
        setattr(glasses.emu, "battery", 42)
    glasses.advance(11)                          # a battery sample
    glasses.clear_sent()
    glasses.send(STATUS_GET, b"\x00")
    status = glasses.sent(STATUS)
    assert status, glasses.sent()
    # the mean of the samples since the start: 85% then 42%
    assert 42 <= status[-1][1] < 85 or status[-1][1] == 255
    glasses.assert_ok()


def test_the_clock_shows_the_phones_time(glasses):
    glasses.tap(2)
    assert "13:37" in glasses.screen_text()      # 11:37 UTC, UTC+2
    glasses.send(CLOCK_SET, struct.pack(">Ih", NOW + 3 * 3600, 0))
    glasses.advance(1.5)
    assert "14:37" in glasses.screen_text()


# ---------------------------------------------------------------- the menu

def test_a_double_tap_opens_the_menu(glasses):
    glasses.advance(4)
    glasses.tap(2)
    text = glasses.screen_text()
    for label in ("Apps", "Sensors", "Settings", "Info"):
        assert label in text
    assert glasses.sent(MENU_OPEN)
    glasses.screenshot("menu")
    glasses.assert_ok()


def test_tilting_moves_the_cursor(glasses):
    glasses.tap(2)
    glasses.clear_sent()
    glasses.tilt(1)
    assert "> Sensors" in glasses.screen_text()
    assert glasses.sent(MENU_CURSOR)
    glasses.tilt(-1)
    assert "> Apps" in glasses.screen_text()


def test_the_remote_moves_the_cursor_too(glasses):
    glasses.tap(2)
    glasses.remote(2, 1)
    assert "> Sensors" in glasses.screen_text()
    glasses.remote(2, 255)
    assert "> Apps" in glasses.screen_text()


def test_a_tap_goes_into_a_submenu_and_a_double_tap_back(glasses):
    glasses.tap(2)
    glasses.tilt(1)                              # Sensors
    glasses.clear_sent()
    glasses.tap(1)
    text = glasses.screen_text()
    assert "Glaz > Sensors" in text and "Battery" in text
    assert glasses.sent(MENU_LEVEL)
    glasses.screenshot("menu-sensors")
    glasses.tap(2)
    assert "> Sensors" in glasses.screen_text()
    assert "Glaz > Sensors" not in glasses.screen_text()
    glasses.assert_ok()


def test_picking_an_app_starts_it_and_a_double_tap_ends_it(glasses):
    glasses.tap(2)
    glasses.tap(1)                               # Apps
    glasses.clear_sent()
    glasses.tap(1)                               # its first app
    assert glasses.sent(MENU_SELECT) or glasses.sent(APP_START)
    glasses.advance(1)
    glasses.tap(2)                               # back
    glasses.advance(1)
    glasses.assert_ok()


def test_the_menu_hides_after_a_while(glasses):
    glasses.tap(2)
    glasses.clear_sent()
    glasses.advance(11)
    assert "Apps" not in glasses.screen_text()
    assert glasses.sent(MENU_CLOSE)


def test_the_phone_opens_an_app(glasses):
    glasses.clear_sent()
    glasses.open_app("about")
    assert glasses.sent(APP_START)
    assert "glaz" in glasses.screen_text().lower()
    glasses.assert_ok()


def test_an_unknown_app_is_ignored(glasses):
    glasses.open_app("no-such-app")
    glasses.advance(1)
    glasses.assert_ok()


# ---------------------------------------------------------------- sleep

def test_a_triple_tap_sleeps_and_a_tap_wakes(glasses):
    glasses.tap(2)
    glasses.tap(3, settle=3.0)
    glasses.advance(3)
    assert glasses.running()                     # asleep, not ended
    glasses.tap(1, settle=2.0)
    if glasses.device == "frame":               # a reset, then the app
        assert glasses.until("Frame app is running", since=1)
    glasses.advance(2)
    glasses.screenshot("woken")
    glasses.assert_ok()


def test_frame_wakes_from_a_triple_tap_to_the_last_app(frame):
    frame.open_app("stopwatch")
    frame.tap(3, settle=3.0)
    frame.advance(2)
    assert frame.emu.boots == 1
    frame.tap(1, settle=2.0)
    assert frame.emu.boots == 2                  # waking is a reset
    assert frame.until("Frame app is running", since=2)
    frame.advance(1)
    text = frame.screen_text()
    assert "<glaz>" not in text                  # no banner after a wake
    assert "Stopwatch" in text                   # where it was
    frame.assert_ok()


def test_frame_wakes_from_idle_sleep_to_the_last_app(frame):
    frame.open_app("stopwatch")
    frame.tap(2)                                 # left, not running
    frame.emu.connected = False                  # the phone goes
    frame.advance(100)                           # SLEEP_AFTER, LINK_GRACE
    assert not frame.emu.display.powered
    frame.tap(1, settle=2.0)
    assert frame.emu.boots == 2
    frame.advance(1)
    assert "Stopwatch" in frame.screen_text()
    frame.assert_ok()


def test_idle_without_a_phone_frame_sleeps(frame):
    frame.emu.connected = False
    frame.advance(100)                           # SLEEP_AFTER, LINK_GRACE
    assert frame.emu.asleep
    assert not frame.emu.display.powered
    frame.assert_ok()


def test_with_a_phone_frame_stays_awake(frame):
    frame.advance(100)
    assert not frame.emu.asleep
    assert frame.emu.boots == 1


# ---------------------------------------------------------------- notices

def test_a_notification_pops_up_and_goes(glasses):
    glasses.advance(4)
    glasses.notify("Chat", "Ann", "lunch at 13:37?")
    text = glasses.screen_text()
    assert "Ann" in text or "Chat" in text
    glasses.screenshot("notification")
    glasses.advance(6)
    assert "Ann" not in glasses.screen_text()
    glasses.assert_ok()


def test_a_tap_dismisses_a_notification(glasses):
    glasses.advance(4)
    glasses.notify("Chat", "Ann", "hi")
    glasses.tap(1)
    assert "Ann" not in glasses.screen_text()


def test_frame_a_taps_bounce_does_not_dismiss_a_later_notification(frame):
    frame.open_app("stopwatch")                  # the loop at its quickest
    frame.emu.tap()                              # a tap, then
    frame.advance(0.01)
    frame.notify("Chat", "Ann", "hi")            # a notice right after it
    frame.emu.tap()                              # and the tap's rebound
    frame.advance(1)
    assert "Ann" in frame.screen_text()          # the tap was not on it


# ---------------------------------------------------------------- console

def test_the_phones_lua_console_runs_lua(glasses):
    glasses.clear_sent()
    glasses.send(LUA_EVAL, b"\x07return 100 + 37")
    glasses.advance(0.5)
    results = glasses.joined(LUA_RESULT)
    assert results and results[-1][0] == 7
    assert b"137" in results[-1][1]
    glasses.assert_ok()


# ---------------------------------------------------------------- break

def test_the_hosts_break_stops_the_app_cleanly(glasses):
    glasses.tap(2)
    glasses.emu.break_signal()
    glasses.advance(1)
    assert not glasses.running()
    assert not any("restarting" in l for l in glasses.lines)


def test_frame_restarts_after_a_crash(tmp_path):
    g = Glasses("frame", tmp_path)
    # an app whose module fails at once: the boot loader restarts it
    (tmp_path / "about.lua").write_text(
        "local _M = {label = 'About'}\n"
        "function _M.run() error('boom 137') end\nreturn _M\n")
    g.start()
    g.set_clock()
    g.open_app("about")
    g.advance(2)
    assert g.running()
    g.stop()

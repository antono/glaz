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


def test_frame_starts_with_the_room_it_has_on_the_glasses(frame):
    # Frame runs out at about 135 KB and glaz starts at about 89 KB
    # (docs/FRAME.md): the emulator's HEAP leaves the app the same 46 KB.
    # When this fails, the app's start moved: measure HEAP again.
    from frame_emulator import HEAP
    mem = [l for l in frame.lines if l.startswith("mem ")]
    start = int(mem[0].split()[1])
    assert 40 <= HEAP // 1024 - start <= 52, (start, HEAP // 1024)


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


# ---------------------------------------------------------------- more
# What the tests above leave out: the menu as the upload leaves it, the
# last module's file, long notifications, a long level, the menu after a
# timeout, a module's draw() and tick() going wrong, and a development
# host's stay_awake.

def lua(g, code: str):
    """Lua run on the glasses, as the phone's console runs it."""
    g.clear_sent()
    g.send(LUA_EVAL, b"\x07" + code.encode())
    g.advance(0.2)
    result = g.joined(LUA_RESULT)[-1][1]
    assert result.startswith(b"+"), result


def without(device, tmp_path, *names, files=None):
    """glaz started on glasses whose upload left these modules out, with
    files of the test's own (name -> text) in their place."""
    g = Glasses(device, tmp_path / device)
    for name in names:
        for p in g.sandbox.glob(f"{name}.*lua"):
            p.unlink()
    for name, text in (files or {}).items():
        (g.sandbox / name).write_text(text)
    g.start()
    g.set_clock()
    return g


def rows(g, top_y: int) -> list[str]:
    """The strings on the screen under the top bar, top to bottom."""
    return [t.text for t in sorted(g.texts(), key=lambda t: (t.y, t.x))
            if t.y >= top_y]


LAYOUT = {"frame": (65, 55), "halo": (62, 30)}   # top_y, row_h (the parts)


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_a_module_switched_off_on_the_phone_is_not_in_the_menu(
        tmp_path, device):
    g = without(device, tmp_path, "uptime")
    g.open_app("bluetooth")                      # Info > Bluetooth
    g.tap(2)                                     # back: the Info level
    text = g.screen_text()
    assert "Bluetooth" in text and "About" in text
    assert "Uptime" not in text
    g.open_app("uptime")                         # the phone cannot open it
    g.advance(1)
    assert "Uptime" not in g.screen_text()
    g.assert_ok()
    g.stop()


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_a_level_with_every_module_off_is_left_out(tmp_path, device):
    g = without(device, tmp_path, "battery", "tilt", "taptune")
    g.tap(2)
    text = g.screen_text()
    assert "Apps" in text and "Info" in text
    assert "Sensors" not in text
    g.tilt(1)                                    # the next level: Settings
    assert "> Settings" in g.screen_text()
    g.assert_ok()
    g.stop()


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_a_module_that_does_not_load_says_so_in_the_menu(tmp_path, device):
    g = without(device, tmp_path, "uptime",
                files={"uptime.lua": "local _M = {\nreturn _M\n"})
    g.open_app("bluetooth")
    g.tap(2)
    assert "uptime (loa" in g.screen_text()     # cut to Halo's rows there
    g.tilt(1)                                    # onto it
    g.clear_sent()
    g.tap(1)
    assert g.sent(APP_START)
    assert "load failed" in g.screen_text()
    g.tap(2)                                     # back: the menu works on
    assert "Bluetooth" in g.screen_text()
    assert not [l for l in g.errors() if "load failed" not in l]
    g.stop()


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_a_stale_last_file_goes_at_start(tmp_path, device):
    # last.txt is written on the way into deep sleep, for a wake to read:
    # one left from a boot that was not a wake, or naming a module no
    # longer there, is dropped, and the banner shows as usual
    g = without(device, tmp_path, files={"last.txt": "nosuch"})
    assert not (g.sandbox / "last.txt").exists()
    assert "glaz" in g.screen_text()
    g.assert_ok()
    g.stop()
    g = without(device, tmp_path, files={"last.txt": "stopwatch"})
    assert not (g.sandbox / "last.txt").exists()
    assert "glaz" in g.screen_text() and "Stopwatch" not in g.screen_text()
    g.assert_ok()
    g.stop()


def test_frame_wakes_into_the_menu_when_the_last_module_is_gone(frame):
    frame.open_app("stopwatch")
    frame.tap(3, settle=3.0)
    frame.advance(1)
    assert (frame.sandbox / "last.txt").read_text() == "stopwatch"
    (frame.sandbox / "stopwatch.lua").unlink()   # switched off meanwhile
    frame.tap(1, settle=2.0)
    assert frame.emu.boots == 2
    assert frame.until("Frame app is running", since=2)
    frame.advance(1)
    text = frame.screen_text()
    assert "Apps" in text and "Stopwatch" not in text
    assert not (frame.sandbox / "last.txt").exists()
    frame.assert_ok()


def test_a_long_notification_wraps_at_words_and_ends_with_dots(glasses):
    top_y, _ = LAYOUT[glasses.device]
    glasses.advance(4)
    glasses.notify("Mail", "Ann", "lorem ipsum dolor sit amet consectetur "
                   "adipiscing elit sed do eiusmod tempor incididunt ut "
                   "labore et dolore magna aliqua")
    lines = rows(glasses, top_y)
    assert lines[0] == "Ann"
    if glasses.device == "frame":                # 26 characters a line
        assert lines[1:] == ["lorem ipsum dolor sit amet",
                             "consectetur adipiscing",
                             "elit sed do eiusmod tempor",
                             "incididunt ut labore et.."]
    else:                                        # 11
        assert lines[1:] == ["lorem ipsum", "dolor sit", "amet",
                             "consectet.."]
    glasses.screenshot("notification-long")
    glasses.assert_ok()


def test_a_word_longer_than_a_line_is_cut_into_lines(glasses):
    top_y, _ = LAYOUT[glasses.device]
    glasses.advance(4)
    glasses.notify("Mail", "", "ok Supercalifragilisticexpialidocious!")
    lines = rows(glasses, top_y)
    if glasses.device == "frame":
        assert lines == ["ok", "Supercalifragilisticexpial", "idocious!"]
    else:
        assert lines == ["ok", "Supercalifr", "agilisticex",
                         "pialidoci.."]          # four lines, the fourth ..
    glasses.assert_ok()


def test_a_long_level_scrolls_with_the_cursor(frame):
    top_y, _ = LAYOUT["frame"]
    frame.tap(2)
    frame.tap(1)                                 # Apps: 16 modules
    first = rows(frame, top_y)
    assert len(first) == 5 and first[0].startswith("> ")
    for _ in range(5):
        frame.tilt(1)
    shown = rows(frame, top_y)                   # the sixth: the window moved
    assert len(shown) == 5 and shown[-1].startswith("> ")
    assert shown[0] == "  " + first[1][2:]
    for _ in range(5):
        frame.tilt(-1)
    assert rows(frame, top_y) == first           # back at the top
    frame.tilt(-1)                               # round to the last
    shown = rows(frame, top_y)
    assert shown[-1].startswith("> ") and shown[0] not in first
    frame.tilt(1)                                # and round to the first
    assert rows(frame, top_y) == first
    frame.assert_ok()


def test_after_a_timeout_the_menu_opens_at_the_root(glasses):
    glasses.open_app("about")                    # Info > About
    glasses.advance(6)                           # INFO_TIMEOUT: blank
    assert not glasses.screen_text()
    glasses.clear_sent()
    glasses.tap(2)
    text = glasses.screen_text()
    assert "Apps" in text and "Bluetooth" not in text
    assert bytes([MENU_LEVEL, 1]) in glasses.sent(MENU_LEVEL)
    glasses.assert_ok()


def test_a_tap_on_the_blank_screen_flashes_the_banner_and_keeps_awake(
        glasses):
    glasses.emu.connected = False
    glasses.advance(50)                          # the banner long gone
    assert not glasses.screen_text()
    glasses.tap(1)
    assert "glaz" in glasses.screen_text()
    glasses.advance(4)
    assert not glasses.screen_text()             # gone by itself
    if glasses.device == "frame":
        glasses.advance(20)                      # SLEEP_AFTER from the tap
        assert not glasses.emu.asleep
        glasses.advance(10)
        assert glasses.emu.asleep
    glasses.assert_ok()


def test_frame_stays_awake_for_a_development_host(frame):
    lua(frame, "frame.stay_awake(true)")
    frame.open_app("stopwatch")
    frame.tap(1)                                 # counting
    frame.clear_sent()
    frame.tap(3, settle=3.0)                     # sleep: the eye closes
    frame.advance(1)
    assert frame.emu.boots == 1 and not frame.emu.asleep
    assert frame.sent(APP_STOP)                  # stopped on the way
    assert "Stopwatch" in frame.screen_text()    # and back, from the start
    assert "0:00.0" in frame.screen_text()
    assert not (frame.sandbox / "last.txt").exists()
    frame.assert_ok()


DRAWS = r"""
local _M = { label = 'Stopwatch', mode = 'app' }
local n = 0
function _M.tick() n = n + 1 return 'tick ' .. n end
function _M.draw() error('boom 137') end
return _M
"""

DONE = r"""
local _M = { label = 'Stopwatch', mode = 'app' }
local n = 0
function _M.tick() n = n + 1 return 'tick ' .. n, n >= 6 end
return _M
"""

SLEEPY = r"""
local _M = { label = 'Stopwatch', mode = 'app' }
function _M.tick() return 'tap = sleep' end
function _M.on_tap() return nil, 'sleep' end
return _M
"""


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_a_modules_draw_that_fails_shows_the_error_and_prints_it_once(
        tmp_path, device):
    g = without(device, tmp_path, files={"stopwatch.lua": DRAWS})
    g.open_app("stopwatch")
    g.advance(2)                                 # ticks, each drawn
    lines = g.screen_text().split("\n")
    assert any(l.startswith("err: ") for l in lines)
    if device == "frame":                        # Halo cuts it to its row
        assert "err: stopwatch.lua:5: boom 137" in lines
    assert any(l.startswith("tick") for l in lines)   # its text still shows
    assert len([l for l in g.lines if "boom 137" in l]) == 1
    assert "Stopwatch err:" in [l for l in g.lines if "boom 137" in l][0]
    g.stop()


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_a_module_done_from_its_tick_stops_and_the_menu_comes_back(
        tmp_path, device):
    g = without(device, tmp_path, files={"stopwatch.lua": DONE})
    g.clear_sent()
    g.open_app("stopwatch")
    assert "tick" in g.screen_text()
    assert not g.sent(APP_STOP)
    g.advance(1)                                 # the sixth tick: done
    assert g.sent(APP_STOP)
    text = g.screen_text()
    assert "Apps" in text and "> Stopwatch" in text   # the menu, on it
    assert "tick" not in text
    g.assert_ok()
    g.stop()


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_a_module_may_ask_for_sleep_from_a_tap(tmp_path, device):
    g = without(device, tmp_path, files={"stopwatch.lua": SLEEPY})
    g.open_app("stopwatch")
    g.clear_sent()
    g.tap(1, settle=3.0)
    assert g.sent(APP_STOP)
    assert "Stopwatch" not in g.screen_text()
    if device == "frame":
        assert g.emu.asleep and not g.emu.display.powered
    assert g.running()
    g.assert_ok()
    g.stop()

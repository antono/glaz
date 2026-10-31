"""Info > About (apps/about/about.lua) on each pair of glasses that has it:
the app's name, version and author, a line each; reached from the menu or
opened by the phone; an 'info' module, gone from the screen on its own
after a few seconds, never in the background, deaf to tilts, the remote
and the phone's MODULE_CALL; brought back by a tap on the blank screen,
covered by a notification; laid out for each screen."""
import re
from pathlib import Path

import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, LUA_EVAL,
                     LUA_RESULT, MENU_OPEN, MENU_SELECT)

pytestmark = pytest.mark.module("about")

SOURCE = (Path(__file__).parent / "about.lua").read_text()
VERSION = re.search(r"VERSION\s*=\s*'([^']+)'", SOURCE).group(1)
# Frame's lines; Halo's round screen holds 14, 13 and 11 characters on
# its text rows, so its part (about.halo.lua) lays them out to fit whole
LINES = {
    "frame": ["glaz", f"version {VERSION}", "by Anton Vasiljev"],
    "halo": [f"glaz {VERSION}", "by Anton", "Vasiljev"],
}

INFO_TIMEOUT = 5       # glaz.lua: seconds an 'info' module stays on screen


def shown(glasses):
    """The module's own lines on the screen, in order."""
    text = glasses.screen_text().splitlines()
    return [l for l in text if l in LINES[glasses.device]]


def gone(glasses):
    """No version on the screen (the splash says 'glaz' too)."""
    return VERSION not in glasses.screen_text()


def walk_to_about(glasses):
    """The menu, Info, About: as the wearer gets there."""
    glasses.tap(2)
    for _ in range(10):
        if "> Info" in glasses.screen_text():
            break
        glasses.tilt(1)
    glasses.tap(1)
    assert "Glaz > Info" in glasses.screen_text()
    for _ in range(10):
        if "> About" in glasses.screen_text():
            break
        glasses.tilt(1)
    assert "> About" in glasses.screen_text()


def test_the_version_is_semver_and_the_file_ascii():
    assert re.fullmatch(r"\d+\.\d+\.\d+", VERSION)
    for part in ("about.lua", "about.frame.lua", "about.halo.lua"):
        (Path(__file__).parent / part).read_bytes() \
            .decode("ascii")


def test_the_phone_opens_it_name_version_author(glasses):
    glasses.clear_sent()
    glasses.open_app("about")
    assert glasses.sent(APP_START)
    assert shown(glasses) == LINES[glasses.device]               # in this order
    assert "About" in glasses.screen_text()      # the top bar
    glasses.screenshot("about")
    glasses.assert_ok()


def test_picked_in_the_menu_under_info(glasses):
    walk_to_about(glasses)
    glasses.screenshot("about-menu")
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(MENU_SELECT)
    assert glasses.sent(APP_START)
    assert shown(glasses) == LINES[glasses.device]
    assert "Uptime" not in glasses.screen_text()  # the menu is gone
    assert "About" in glasses.screen_text()       # the breadcrumb
    glasses.assert_ok()


def test_it_goes_by_itself_after_a_few_seconds(glasses):
    glasses.open_app("about")
    glasses.clear_sent()
    glasses.advance(INFO_TIMEOUT - 1)
    assert shown(glasses) == LINES[glasses.device]
    glasses.advance(2)
    assert gone(glasses)
    assert glasses.screen_text() == "" and glasses.lit() == 0   # all dark
    assert len(glasses.sent(APP_STOP)) == 1
    assert not glasses.sent(APP_BACKGROUND)      # it has nothing to carry on
    glasses.advance(INFO_TIMEOUT)
    assert len(glasses.sent(APP_STOP)) == 1      # stopped once, for good
    glasses.assert_ok()


def test_start_and_stop_name_the_same_item(glasses):
    glasses.clear_sent()
    glasses.open_app("about")
    glasses.advance(INFO_TIMEOUT + 1)
    (start,), (stop,) = glasses.sent(APP_START), glasses.sent(APP_STOP)
    assert len(start) == 2 and start[1:] == stop[1:]   # [code, index]
    glasses.assert_ok()


def test_a_tap_on_the_blank_screen_brings_it_back(glasses):
    glasses.open_app("about")
    glasses.advance(INFO_TIMEOUT + 1)
    assert gone(glasses)
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(APP_START)
    assert shown(glasses) == LINES[glasses.device]
    glasses.advance(INFO_TIMEOUT + 1)            # and goes again by itself
    assert gone(glasses)
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_a_double_tap_goes_back_to_the_info_menu(glasses):
    walk_to_about(glasses)
    glasses.tap(1)
    glasses.clear_sent()
    glasses.tap(2)
    text = glasses.screen_text()
    assert gone(glasses)
    assert "Glaz > Info" in text and "> About" in text
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)
    glasses.assert_ok()


def test_the_phones_double_tap_goes_back_to_the_info_menu(glasses):
    glasses.open_app("about")
    glasses.clear_sent()
    glasses.remote(1, 1)                         # one tap: nothing
    assert shown(glasses) == LINES[glasses.device]
    assert not glasses.sent(APP_STOP)
    glasses.remote(1, 2)                         # two: back
    text = glasses.screen_text()
    assert gone(glasses)
    assert "Glaz > Info" in text and "  About" in text
    assert glasses.sent(APP_STOP) and glasses.sent(MENU_OPEN)
    glasses.assert_ok()


def test_a_tap_neither_changes_nor_keeps_it(glasses):
    glasses.open_app("about")
    glasses.tap(1)
    assert shown(glasses) == LINES[glasses.device]
    glasses.advance(INFO_TIMEOUT)                # a tap is no activity here
    assert gone(glasses)
    glasses.assert_ok()


def test_tilts_and_the_remote_do_nothing(glasses):
    glasses.open_app("about")
    glasses.clear_sent()
    glasses.tilt(1)
    glasses.tilt(-1)
    glasses.remote(2, 1)                         # next
    glasses.remote(2, 255)                       # previous
    glasses.remote(3, 1)                         # down
    glasses.remote(3, 255)                       # up
    assert shown(glasses) == LINES[glasses.device]
    assert not glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_the_phone_cannot_call_it(glasses):
    glasses.clear_sent()
    glasses.call("about", "137")                 # no remote(): ignored
    glasses.advance(1)
    assert not glasses.sent(APP_START)
    assert not glasses.sent(APP_BACKGROUND)
    assert gone(glasses)
    glasses.open_app("about")
    glasses.call("about", "137")
    assert shown(glasses) == LINES[glasses.device]
    glasses.assert_ok()


def test_opened_again_it_says_the_same(glasses):
    glasses.open_app("about")
    glasses.advance(INFO_TIMEOUT + 1)
    assert gone(glasses)
    glasses.open_app("about", "137")             # an arg it does not use
    assert shown(glasses) == LINES[glasses.device]
    glasses.assert_ok()


def test_a_notification_covers_it(glasses):
    glasses.open_app("about")
    glasses.clear_sent()
    glasses.notify("Mail", "Hi", "137 new")
    text = glasses.screen_text()
    assert "137 new" in text and gone(glasses)
    glasses.advance(2 * INFO_TIMEOUT)
    # its seconds ran out under the notice: nothing comes back after it
    assert glasses.screen_text() == ""
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_frame_draws_it_left_aligned_in_white_under_the_bar(frame):
    frame.open_app("about")
    assert ".. > About" in frame.screen_text()   # the top bar's crumb
    own = [t for t in frame.texts() if t.text in LINES["frame"]]
    assert [t.text for t in sorted(own, key=lambda t: t.y)] == LINES["frame"]
    assert len({t.x for t in own}) == 1          # one left edge
    assert all(t.color == "WHITE" for t in own)
    bar = max(t.y for t in frame.texts() if t.text not in LINES["frame"])
    assert min(t.y for t in own) > bar
    frame.assert_ok()


def test_halo_shows_every_line_whole_on_the_round_screen(halo):
    halo.open_app("about")
    assert "Glaz > Info > About" in halo.screen_text()   # the breadcrumb
    # glaz.halo.lua, D.fit: what the three text rows hold
    for line, room in zip(LINES["halo"], (14, 13, 11)):
        assert len(line) <= room, line
    assert VERSION in halo.screen_text()          # not cut to '0.41.'
    assert "Vasiljev" in halo.screen_text()
    halo.assert_ok()


def test_halo_button_does_nothing_to_it(halo):
    halo.open_app("about")
    halo.clear_sent()
    for kind in ("single", "double", "long"):
        halo.button(kind)
    assert shown(halo) == LINES["halo"]
    assert not halo.sent(APP_STOP)
    halo.assert_ok()


def test_halo_lays_out_any_author_to_fit(halo):
    # the part on its own, as about.lua calls it: one name, and several
    lua = ("local D = require('about.halo') "
           "return (string.gsub(D.lines('glaz', '1.3.7', 'Anton') .. '|' .. "
           "D.lines('glaz', '1.3.7', 'Anton Ivan Vasiljev'), '\\n', '/'))")
    halo.clear_sent()
    halo.send(LUA_EVAL, b"\x07" + lua.encode())
    halo.advance(0.5)
    results = halo.joined(LUA_RESULT)
    assert results and results[-1][0] == 7
    answer = results[-1][1].decode()
    assert "glaz 1.3.7/by Anton/|" in answer
    assert "|glaz 1.3.7/by Anton Ivan/Vasiljev" in answer
    halo.assert_ok()


def test_the_remotes_menu_button_opens_the_menu(glasses):
    glasses.open_app("about")
    glasses.clear_sent()
    glasses.remote(1, 3, settle=1.0)             # Menu: three taps
    assert gone(glasses)
    assert glasses.sent(APP_STOP) and glasses.sent(MENU_OPEN)
    assert "Glaz > Info" in glasses.screen_text()
    glasses.assert_ok()


def test_frame_shows_it_with_no_phone(frame):
    frame.advance(5)                             # past the splash
    frame.emu.connected = False
    walk_to_about(frame)
    frame.tap(1)
    assert shown(frame) == LINES["frame"]        # nothing from the phone
    frame.assert_ok()


def test_frame_a_triple_tap_sleeps_and_a_tap_wakes_into_it(frame):
    frame.open_app("about")
    frame.tap(3, settle=3.0)
    frame.advance(2)
    assert frame.emu.asleep
    frame.tap(1, settle=2.0)
    assert frame.emu.boots == 2                  # waking is a reset
    assert frame.until("Frame app is running", since=2)
    frame.advance(1)
    assert shown(frame) == LINES["frame"]
    frame.assert_ok()


def test_halo_fits_a_version_with_three_digit_minor(halo):
    # a minor bumped past 99, and a two-digit patch: 'glaz 0.137.13'
    lua = ("local D = require('about.halo') "
           "return (string.gsub(D.lines('glaz', '0.137.13', "
           "'Anton Vasiljev'), '\\n', '/'))")
    halo.clear_sent()
    halo.send(LUA_EVAL, b"\x07" + lua.encode())
    halo.advance(0.5)
    results = halo.joined(LUA_RESULT)
    assert results and results[-1][0] == 7
    answer = results[-1][1].decode()
    lines = answer[answer.index("glaz "):].rstrip('"').split("/")
    assert lines == ["glaz 0.137.13", "by Anton", "Vasiljev"]
    for line, room in zip(lines, (14, 13, 11)):
        assert len(line) <= room, line
    halo.assert_ok()

"""Tap tune (apps/taptune/taptune.lua), Sensors > Tap tune, Frame only: the
accelerometer's tap settings on four rows from the top, a tilt to pick one,
a tap to step it and program the chip (frame.imu.tap_config), and on test
the raw hits counted, bounces included (on_hit). Axes go back when it
closes; stock firmware, without tap_config, gets a message instead."""
from pathlib import Path

import lupa.lua54 as lupa
import pytest

from glasses import APP_START, APP_STOP, HANDS_OFF, LUA_EVAL, has_module

pytestmark = pytest.mark.module("taptune")

TAPTUNE = Path(__file__).parent / "taptune.lua"


def lines(g):
    """The module's rows, under the top bar."""
    return [t.text for t in sorted(g.texts(), key=lambda t: (t.y, t.x))
            if t.y > 40]


def chip(g):
    """What the emulated accelerometer is programmed with."""
    return g.emu._tap


def opened(g):
    g.clear_sent()
    g.open_app("taptune")
    return g


def lua(g, code):
    """Lua run in the app's globals, as the phone's console sends it."""
    g.send(LUA_EVAL, b"\x01" + code.encode())
    g.advance(0.5)


# ---------------------------------------------------------------- devices

def test_it_goes_to_frame_only():
    assert has_module("frame", "taptune")
    assert not has_module("halo", "taptune")


# ---------------------------------------------------------------- screen

def test_opens_on_test_with_the_chips_settings(glasses):
    opened(glasses)
    assert glasses.sent(APP_START)
    assert lines(glasses)[:4] == [
        "thr 7 q 0 dur 0 ax 08",
        "[test] knock to count",
        "hits 0",
        "last -",
    ]
    glasses.screenshot("taptune")
    glasses.assert_ok()


def test_a_tilt_walks_the_settings_and_back_to_test(glasses):
    opened(glasses)
    seen = []
    for _ in range(5):
        glasses.tilt(1)
        seen.append(lines(glasses)[:2])
    assert seen == [
        ["[thr 7] q 0 dur 0 ax 08", "tap: threshold 7 > 10"],
        ["thr 7 [q 0] dur 0 ax 08", "tap: quiet 0 > 1"],
        ["thr 7 q 0 [dur 0] ax 08", "tap: duration 0 > 1"],
        ["thr 7 q 0 dur 0 [ax 08]", "tap: axes 08 > 3F"],
        ["thr 7 q 0 dur 0 ax 08", "[test] knock to count"],
    ]
    glasses.assert_ok()


def test_a_tilt_back_goes_from_test_to_axes(glasses):
    opened(glasses)
    glasses.tilt(-1)
    assert lines(glasses)[:2] == ["thr 7 q 0 dur 0 [ax 08]",
                                  "tap: axes 08 > 3F"]
    glasses.screenshot("taptune-axes")
    glasses.assert_ok()


def test_the_remotes_left_and_right_move_the_cursor(glasses):
    opened(glasses)
    glasses.remote(2, 1)
    assert lines(glasses)[0] == "[thr 7] q 0 dur 0 ax 08"
    glasses.remote(2, 255)
    assert lines(glasses)[1] == "[test] knock to count"
    glasses.assert_ok()


def test_the_longest_settings_row_fits_the_screen(glasses):
    chip(glasses).update(threshold=50, y=50, z=50, quiet=12, duration=12,
                         axes=0x3F)
    opened(glasses)
    glasses.tilt(-1)
    row = lines(glasses)[0]
    assert row == "thr 50 q 12 dur 12 [ax 3F]"
    assert len(row) < 29
    glasses.assert_ok()


# ---------------------------------------------------------------- settings

def test_a_tap_on_a_setting_steps_it_and_programs_the_chip(glasses):
    opened(glasses)
    glasses.tilt(1)                              # threshold
    glasses.tap(1)
    assert lines(glasses)[:3] == ["[thr 10] q 0 dur 0 ax 08",
                                  "tap: threshold 10 > 15", "hits 0"]
    t = chip(glasses)
    assert (t["threshold"], t["y"], t["z"]) == (10, 10, 10)
    glasses.screenshot("taptune-threshold")
    glasses.assert_ok()


def test_quiet_and_duration_step_on_their_own(glasses):
    opened(glasses)
    glasses.tilt(1)
    glasses.tilt(1)                              # quiet
    glasses.tap(1)
    glasses.tap(1)
    assert lines(glasses)[:3] == ["thr 7 [q 2] dur 0 ax 08",
                                  "tap: quiet 2 > 3", "hits 0"]
    glasses.screenshot("taptune-quiet")
    glasses.tilt(1)                              # duration
    glasses.tap(1)
    assert lines(glasses)[0] == "thr 7 q 2 [dur 1] ax 08"
    t = chip(glasses)
    assert (t["threshold"], t["quiet"], t["duration"]) == (7, 2, 1)
    glasses.assert_ok()


def test_a_setting_wraps_round_to_its_first_value(glasses):
    opened(glasses)
    glasses.tilt(-1)
    glasses.tilt(-1)                             # duration
    shown = []
    for _ in range(9):                           # 0 -> 1 ... 15 -> 0
        glasses.tap(1)
        shown.append(lines(glasses)[0].split()[5].strip("[]"))
    assert shown == ["1", "2", "3", "4", "6", "8", "12", "15", "0"]
    assert chip(glasses)["duration"] == 0
    assert lines(glasses)[1] == "tap: duration 0 > 1"
    glasses.assert_ok()


def test_axes_step_to_all_six_and_back(glasses):
    opened(glasses)
    glasses.tilt(-1)                             # axes
    glasses.tap(1)
    assert lines(glasses)[:2] == ["thr 7 q 0 dur 0 [ax 3F]",
                                  "tap: axes 3F > 08"]
    assert chip(glasses)["axes"] == 0x3F
    glasses.tap(1)
    assert lines(glasses)[0] == "thr 7 q 0 dur 0 [ax 08]"
    assert chip(glasses)["axes"] == 0x08
    glasses.tap(2)                               # back: nothing to put back
    assert chip(glasses)["axes"] == 0x08
    glasses.assert_ok()


def test_the_remotes_tap_steps_a_setting(glasses):
    opened(glasses)
    glasses.remote(2, 1)                         # threshold
    glasses.remote(2, 1)                         # quiet
    glasses.remote(1, 1)
    assert lines(glasses)[:3] == ["thr 7 [q 1] dur 0 ax 08",
                                  "tap: quiet 1 > 2", "hits 0"]
    assert chip(glasses)["quiet"] == 1
    glasses.assert_ok()


def test_a_value_off_the_list_steps_to_the_first(glasses):
    chip(glasses)["quiet"] = 5                   # set by someone else
    opened(glasses)
    glasses.tilt(1)
    glasses.tilt(1)
    assert lines(glasses)[:2] == ["thr 7 [q 5] dur 0 ax 08",
                                  "tap: quiet 5 > 0"]
    glasses.tap(1)
    assert chip(glasses)["quiet"] == 0
    glasses.assert_ok()


def test_axes_go_back_when_it_closes_and_the_rest_stays(glasses):
    opened(glasses)
    glasses.tilt(1)
    glasses.tilt(1)
    glasses.tap(1)                               # quiet 1
    glasses.tilt(1)
    glasses.tilt(1)                              # duration, then axes
    glasses.tap(1)
    assert "[ax 3F]" in lines(glasses)[0]
    assert chip(glasses)["axes"] == 0x3F
    glasses.clear_sent()
    glasses.tap(2)                               # back
    assert glasses.sent(APP_STOP)
    assert chip(glasses)["axes"] == 0x08
    assert chip(glasses)["quiet"] == 1
    glasses.assert_ok()


def test_axes_go_back_when_three_taps_put_it_to_sleep(glasses):
    opened(glasses)
    glasses.tilt(-1)
    glasses.tap(1)
    assert chip(glasses)["axes"] == 0x3F
    glasses.tap(3)
    glasses.advance(2)
    assert glasses.emu.asleep
    assert chip(glasses)["axes"] == 0x08
    glasses.assert_ok()


def test_axes_go_back_when_it_times_out(glasses):
    opened(glasses)
    glasses.tilt(-1)
    glasses.tap(1)
    assert chip(glasses)["axes"] == 0x3F
    glasses.clear_sent()
    glasses.advance(61)                          # APP_TIMEOUT, untouched
    assert glasses.sent(APP_STOP)
    assert "hits" not in glasses.screen_text()
    assert chip(glasses)["axes"] == 0x08
    glasses.assert_ok()


def test_knocking_keeps_it_open_past_the_timeout(glasses):
    opened(glasses)
    glasses.advance(50)
    glasses.tap(1)
    glasses.advance(50)                          # 100 s open, 51 s idle
    assert lines(glasses)[2] == "hits 1"
    glasses.advance(15)
    assert "hits" not in glasses.screen_text()
    glasses.assert_ok()


def test_it_opens_again_on_test_with_what_was_set(glasses):
    opened(glasses)
    glasses.tilt(-1)
    glasses.tilt(-1)                             # duration
    glasses.tap(1)
    glasses.tap(2)                               # back
    opened(glasses)
    assert lines(glasses)[:3] == ["thr 7 q 0 dur 1 ax 08",
                                  "[test] knock to count", "hits 0"]
    glasses.assert_ok()


# ---------------------------------------------------------------- counting

def test_on_test_a_tap_counts_and_changes_nothing(glasses):
    opened(glasses)
    before = dict(chip(glasses))
    glasses.tap(1)
    assert lines(glasses)[1:3] == ["[test] knock to count", "hits 1"]
    glasses.tap(1)
    assert lines(glasses)[2] == "hits 2"
    assert chip(glasses) == before
    glasses.screenshot("taptune-hits")
    glasses.assert_ok()


def test_bounces_count_as_hits(glasses):
    opened(glasses)
    for _ in range(5):                           # one knock, ringing
        glasses.emu.tap()
        glasses.advance(0.02)
    glasses.advance(1)
    assert lines(glasses)[2] == "hits 5"
    assert glasses.running()
    glasses.assert_ok()


def test_the_remotes_tap_on_test_is_no_knock(glasses):
    opened(glasses)
    glasses.remote(1, 1)
    assert lines(glasses)[2:4] == ["hits 0", "last -"]
    assert glasses.running()
    glasses.assert_ok()


def test_the_count_starts_again_when_it_opens_again(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.tap(1)
    assert lines(glasses)[2:4] == ["hits 2", "firmware sends no flags"]
    glasses.tap(2)                               # back
    opened(glasses)
    assert lines(glasses)[2:4] == ["hits 0", "last -"]
    glasses.assert_ok()


def test_a_change_restarts_the_count(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.tap(1)
    assert lines(glasses)[2] == "hits 2"
    glasses.tilt(1)
    assert lines(glasses)[2] == "hits 2"         # moving changes nothing
    glasses.tap(1)
    assert lines(glasses)[2:4] == ["hits 0", "last -"]
    glasses.tilt(-1)
    glasses.tap(1)
    assert lines(glasses)[2] == "hits 1"
    glasses.assert_ok()


def test_the_tap_that_dismisses_a_notification_is_not_counted(glasses):
    opened(glasses)
    glasses.notify("Chat", "Ann", "137 taps")
    assert "Ann" in glasses.screen_text()
    glasses.tap(1)
    assert "Ann" not in glasses.screen_text()
    assert lines(glasses)[2] == "hits 0"
    glasses.assert_ok()


def test_a_tilt_under_a_notification_moves_nothing(glasses):
    opened(glasses)
    glasses.notify("Chat", "Ann", "137 taps")
    glasses.tilt(1)
    glasses.tap(1)                               # dismisses it
    assert lines(glasses)[:2] == ["thr 7 q 0 dur 0 ax 08",
                                  "[test] knock to count"]
    glasses.assert_ok()


def test_with_the_remote_in_front_knocks_are_not_the_wearers(glasses):
    opened(glasses)
    glasses.send(HANDS_OFF, b"\x01")
    glasses.tap(1)
    glasses.tilt(1)
    assert lines(glasses)[:3] == ["thr 7 q 0 dur 0 ax 08",
                                  "[test] knock to count", "hits 0"]
    glasses.remote(2, 255)                       # the remote still works
    glasses.remote(1, 1)
    assert lines(glasses)[0] == "thr 7 q 0 dur 0 [ax 3F]"
    glasses.remote(2, 1)                         # test
    glasses.send(HANDS_OFF, b"\x00")
    glasses.tap(1)
    assert lines(glasses)[2] == "hits 1"
    glasses.assert_ok()


def test_a_double_tap_leaves_it(glasses):
    opened(glasses)
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert "hits" not in glasses.screen_text()
    glasses.assert_ok()


def test_a_tap_with_no_status_byte_says_so(glasses):
    """The emulator's tap passes no byte, as stock firmware's does."""
    opened(glasses)
    glasses.tap(1)
    assert lines(glasses)[3] == "firmware sends no flags"
    glasses.assert_ok()


def test_a_knock_shows_which_side_it_came_from(frame):
    opened(frame)
    frame.emu.tap(0x08)                          # Y-, as the chip says
    frame.advance(1)
    assert lines(frame)[2:4] == ["hits 1", "last 0x08 Y-"]


def test_a_knocks_rebound_does_not_change_its_side(frame):
    opened(frame)
    frame.emu.tap(0x08)                          # the knock
    frame.advance(0.02)
    frame.emu.tap(0x04)                          # its rebound, the other way
    frame.advance(1)
    assert lines(frame)[2:4] == ["hits 2", "last 0x08 Y-"]


# ---------------------------------------------------------------- errors

def test_a_chip_that_fails_reports_the_error_and_carries_on(glasses):
    lua(glasses, "local get = frame.imu.tap_config\n"
                 "frame.imu.tap_config = function(o)\n"
                 "  if o then error('i2c failed', 0) end\n"
                 "  return get()\n"
                 "end")
    opened(glasses)
    glasses.tilt(1)
    glasses.tap(1)
    assert any("err: i2c failed" in l for l in glasses.lines)
    assert chip(glasses)["threshold"] == 7
    assert glasses.running()                     # glaz.lua's try() took it
    glasses.tilt(1)                              # and the module answers
    assert lines(glasses)[0].startswith("thr ")


# ---------------------------------------------------------------- stock

def test_stock_firmware_gets_a_message_not_an_error(glasses):
    lua(glasses, "frame.imu.tap_config = nil")
    opened(glasses)
    assert lines(glasses)[:2] == ["needs the glaz", "firmware"]
    glasses.tilt(1)
    glasses.tap(1)
    assert lines(glasses)[:2] == ["needs the glaz", "firmware"]
    glasses.screenshot("taptune-stock")
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


# ---------------------------------------------------------------- flags

def module_alone(x=7, y=7, z=7):
    """taptune.lua in a bare Lua 5.4, with a tap_config that does what
    firmware glaz's does (imu.c, lua_imu_tap_config): the per-axis table
    first, then threshold on all three axes; the getter leaves threshold
    out while the axes differ. calls keeps what was programmed."""
    rt = lupa.LuaRuntime()
    rt.execute("""
      local x, y, z = ...
      chip = {x = x, y = y, z = z, quiet = 0, duration = 0, axes = 8}
      calls = {}
      frame = {imu = {tap_config = function(o)
        if o then
          calls[#calls + 1] = o
          local th = o.thresholds
          if th then chip.x, chip.y, chip.z = th.x, th.y, th.z end
          if o.threshold then
            chip.x, chip.y, chip.z = o.threshold, o.threshold, o.threshold
          end
          for _, k in ipairs{'quiet', 'duration', 'axes'} do
            if o[k] then chip[k] = o[k] end
          end
          return
        end
        local t = {thresholds = {x = chip.x, y = chip.y, z = chip.z},
                   quiet = chip.quiet, duration = chip.duration,
                   axes = chip.axes, latch = true, rate = 256}
        if chip.x == chip.y and chip.y == chip.z then t.threshold = chip.x end
        return t
      end}}
    """, x, y, z)
    return rt, launched(rt)


def launched(rt):
    """The module loaded afresh and started, as glaz launches it."""
    m = rt.execute(TAPTUNE.read_text())
    m.start()
    return m


def axes_of(rt):
    c = rt.globals().chip
    return c.x, c.y, c.z


def rows(text):
    return text.split("\n")


def test_a_tap_on_threshold_sets_all_three_axes():
    """tap_config() as the module calls it, against the firmware's
    rules, without the app."""
    rt, m = module_alone()
    m.on_roll(1)                                 # threshold
    assert rows(m.on_tap())[:3] == ["[thr 10] q 0 dur 0 ax 08",
                                    "tap: threshold 10 > 15", "hits 0"]
    assert axes_of(rt) == (10, 10, 10)
    m.stop()
    assert rows(launched(rt).tick())[0] == "thr 10 q 0 dur 0 ax 08"


def test_threshold_wraps_from_50_to_3():
    rt, m = module_alone(50, 50, 50)
    m.on_roll(1)
    assert rows(m.tick())[1] == "tap: threshold 50 > 3"
    m.on_tap()
    assert axes_of(rt) == (3, 3, 3)


def test_axes_set_apart_show_as_unknown_and_a_tap_evens_them():
    rt, m = module_alone(5, 137, 20)             # set per axis elsewhere
    assert rows(m.tick())[0] == "thr ? q 0 dur 0 ax 08"
    m.on_roll(1)
    assert rows(m.tick())[1] == "tap: threshold ? > 3"
    assert rows(m.on_tap())[0] == "[thr 3] q 0 dur 0 ax 08"
    assert axes_of(rt) == (3, 3, 3)


def test_closing_programs_the_chip_only_when_axes_changed():
    rt, m = module_alone()
    m.on_roll(1)
    m.on_roll(1)
    m.on_tap()                                   # quiet 1
    calls = rt.globals().calls
    n = len(calls)
    m.stop()
    assert len(calls) == n                       # axes untouched: no call
    m = launched(rt)
    m.on_roll(-1)                                # axes
    m.on_tap()
    m.stop()
    assert dict(calls[len(calls)].items()) == {"axes": 0x08}
    assert rt.globals().chip.quiet == 1
    assert rt.globals().chip.axes == 0x08


@pytest.mark.parametrize("flags, row", [
    (0x01, "last 0x01 X+"),
    (0x08, "last 0x08 Y-"),
    (0x21, "last 0x21 X+ Z-"),
    (0x3F, "last 0x3F X+ X- Y+ Y- Z+ Z-"),
    (0xC0, "last 0xC0 "),                        # bits 6, 7: raw only
])
def test_the_status_byte_decodes_to_sides(flags, row):
    _, m = module_alone()
    assert m.on_hit(1, flags).split("\n")[3] == row


def test_a_status_byte_belongs_to_the_last_knock_until_a_change():
    _, m = module_alone()
    m.on_hit(3, 0x04)
    text = m.on_hit(2, None).split("\n")
    assert text[2:4] == ["hits 5", "firmware sends no flags"]
    m.on_roll(1)                                 # threshold
    assert m.on_tap().split("\n")[2:4] == ["hits 0", "last -"]

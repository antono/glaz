"""Apps > Timeseries (apps/timeseries/timeseries.lua), Frame only: a photo every
few seconds, sent to the phone. A tilt picks the interval on the scale, a
tap starts and stops the series, and leaving a running series keeps it
shooting in the background. Each photo goes out as PHOTO_FROM [0x1A,
series] and the JPEG in 0x07 chunks and a final 0x08; the phone's settings
give the size, the quality and the interval a series starts at.
"""
import io

import pytest
from PIL import Image

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, MENU_SET,
                     has_module)

pytestmark = pytest.mark.module("timeseries")

PHOTO_FROM, CHUNK, END = 0x1A, 0x07, 0x08
APP_TIMEOUT = 60     # glaz.lua: an 'app' module left alone this long closes
FIRST = 2.0         # after start(): the tap counted, 1.5 s of exposure, a tick
SCALE = "1 2 4 8 10 20 30 40 60".split()


def scale(frame):
    """The interval scale, '1 2 [4] 8 10 20 30 40 60 s'."""
    lines = [l for l in frame.screen_text().splitlines() if "[" in l]
    assert len(lines) == 1, frame.screen_text()
    return lines[0]


def chosen(frame):
    """The interval in brackets, in seconds."""
    line = scale(frame)
    return int(line[line.index("[") + 1:line.index("]")])


def photos(frame):
    """The photos sent so far, each (series, JPEG bytes)."""
    out, series, jpeg = [], None, None
    for m in frame.sent():
        if m[0] == PHOTO_FROM:
            series, jpeg = m[1], bytearray()
        elif m[0] == CHUNK and jpeg is not None:
            jpeg.extend(m[1:])
        elif m[0] == END and jpeg is not None:
            out.append((series, bytes(jpeg)))
            jpeg = None
    return out


def size(jpeg):
    return Image.open(io.BytesIO(jpeg)).size


def start(frame, settings=None):
    """Opens Timeseries and starts a series; nothing sent before it."""
    if settings:
        frame.settings(settings)
    frame.open_app("timeseries")
    frame.clear_sent()
    frame.tap(1, settle=0.8)


# ---------------------------------------------------------------- where

def test_goes_to_frame_only():
    assert has_module("frame", "timeseries")
    assert not has_module("halo", "timeseries")


# ---------------------------------------------------------------- stopped

def test_opens_stopped_at_four_seconds(glasses):
    glasses.clear_sent()
    glasses.open_app("timeseries")
    assert glasses.sent(APP_START)
    text = glasses.screen_text()
    assert "1 2 [4] 8 10 20 30 40 60 s" in text
    assert "stopped, tap = start" in text
    assert "sent 0  failed 0" in text
    glasses.screenshot("timeseries")
    glasses.advance(10)
    assert not photos(glasses)                   # nothing shot while stopped
    glasses.assert_ok()


def test_a_tilt_moves_along_the_scale(glasses):
    glasses.open_app("timeseries")
    glasses.tilt(1)
    assert "1 2 4 [8] 10 20 30 40 60 s" in glasses.screen_text()
    glasses.tilt(-1)
    glasses.tilt(-1)
    assert "1 [2] 4 8 10 20 30 40 60 s" in glasses.screen_text()
    glasses.assert_ok()


def test_the_scale_stops_at_its_ends(glasses):
    glasses.open_app("timeseries")
    for _ in range(4):
        glasses.tilt(-1)
    assert chosen(glasses) == 1
    for _ in range(len(SCALE) + 2):
        glasses.tilt(1)
    assert chosen(glasses) == 60
    assert "[60] s" in glasses.screen_text()
    glasses.assert_ok()


def test_the_remote_tilts_too(glasses):
    glasses.open_app("timeseries")
    glasses.remote(2, 1)
    assert chosen(glasses) == 8
    glasses.remote(2, 255)
    glasses.remote(2, 255)
    assert chosen(glasses) == 2
    glasses.assert_ok()


def test_left_stopped_it_stops(glasses):
    glasses.open_app("timeseries")
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)
    glasses.assert_ok()


def test_left_alone_while_stopped_it_closes(glasses):
    glasses.open_app("timeseries")
    glasses.clear_sent()
    glasses.advance(APP_TIMEOUT + 1)
    assert glasses.sent(APP_STOP)
    assert "stopped" not in glasses.screen_text()
    glasses.assert_ok()


# ---------------------------------------------------------------- shooting

def test_a_tap_starts_after_the_exposure_settles(glasses):
    start(glasses)
    text = glasses.screen_text()
    assert "next in 2s, tap = stop" in text      # 1.5 s of auto exposure
    assert "sent 0  failed 0" in text
    assert not photos(glasses)
    glasses.advance(FIRST)
    shots = photos(glasses)
    assert len(shots) == 1
    series, jpeg = shots[0]
    assert 1 <= series <= 255
    assert size(jpeg) == (512, 512)              # the default size
    assert "sent 1  failed 0" in glasses.screen_text()
    glasses.screenshot("timeseries-running")
    glasses.assert_ok()


def test_photo_from_comes_before_each_photo(glasses):
    start(glasses)
    glasses.advance(FIRST)
    codes = [m[0] for m in glasses.sent() if m[0] in (PHOTO_FROM, CHUNK, END)]
    assert codes[0] == PHOTO_FROM
    assert codes[-1] == END
    assert codes.count(PHOTO_FROM) == codes.count(END) == 1
    # each chunk fits Bluetooth's max_length()
    assert all(len(m) <= 246 for m in glasses.sent(CHUNK))
    glasses.assert_ok()


def test_a_photo_every_interval(glasses):
    start(glasses)
    glasses.advance(FIRST)
    assert len(photos(glasses)) == 1
    glasses.advance(4)
    assert len(photos(glasses)) == 2
    glasses.advance(4 * 5)
    assert len(photos(glasses)) == 7
    assert "sent 7  failed 0" in glasses.screen_text()
    assert len({s for s, _ in photos(glasses)}) == 1   # one series
    glasses.assert_ok()


def test_the_countdown_runs_to_the_next_shot(glasses):
    glasses.open_app("timeseries")
    glasses.tilt(1)
    glasses.tilt(1)                              # 10 s
    glasses.tap(1, settle=0.8)
    glasses.advance(FIRST)                         # the first shot
    assert "next in 10s" in glasses.screen_text()
    glasses.advance(3)
    assert "next in 7s" in glasses.screen_text()
    glasses.assert_ok()


def test_a_second_tap_stops_and_the_camera_sleeps(frame):
    start(frame)
    frame.advance(FIRST)
    frame.tap(1)
    text = frame.screen_text()
    assert "stopped, tap = start" in text
    assert "sent 1  failed 0" in text            # the count stays
    assert frame.emu._camera_awake is False
    frame.clear_sent()
    frame.advance(20)
    assert not photos(frame)
    frame.assert_ok()


def test_a_new_series_starts_counting_again(glasses):
    start(glasses)
    glasses.advance(FIRST + 4)
    first = {s for s, _ in photos(glasses)}
    glasses.tap(1)
    assert "sent 2  failed 0" in glasses.screen_text()
    glasses.advance(37)                          # the clock decides the number
    glasses.clear_sent()
    glasses.tap(1, settle=0.8)
    assert "sent 0  failed 0" in glasses.screen_text()
    glasses.advance(FIRST)
    second = {s for s, _ in photos(glasses)}
    assert len(first) == len(second) == 1
    assert first != second                       # another folder on the phone
    glasses.assert_ok()


def test_a_shorter_interval_does_not_wait_out_the_longer(glasses):
    glasses.open_app("timeseries")
    for _ in range(4):
        glasses.tilt(1)                          # 30 s
    glasses.tap(1, settle=0.8)
    glasses.advance(FIRST)
    assert len(photos(glasses)) == 1
    assert "next in 30s" in glasses.screen_text()
    for _ in range(4):
        glasses.tilt(-1)                         # 4 s
    assert chosen(glasses) == 4
    text = glasses.screen_text()
    assert "next in 4s" in text or "next in 3s" in text
    glasses.advance(4.5)
    assert len(photos(glasses)) == 2
    glasses.assert_ok()


def test_a_longer_interval_counts_from_the_next_shot(glasses):
    start(glasses)
    glasses.advance(FIRST)                       # a shot, the next in 4 s
    glasses.tilt(1)                              # 8 s
    glasses.advance(2.0)
    assert len(photos(glasses)) == 1
    glasses.advance(1.0)                         # the shot already due
    assert len(photos(glasses)) == 2
    glasses.advance(7.0)
    assert len(photos(glasses)) == 2
    glasses.advance(1.0)                         # 8 s after it
    assert len(photos(glasses)) == 3
    glasses.assert_ok()


def test_at_one_second_it_keeps_up(glasses):
    glasses.open_app("timeseries")
    glasses.tilt(-1)
    glasses.tilt(-1)
    glasses.clear_sent()
    glasses.tap(1, settle=0.8)
    glasses.advance(FIRST + 10)
    # one a second, give or take a tick; never a burst of the backlog
    assert 10 <= len(photos(glasses)) <= 12
    glasses.assert_ok()


def test_a_running_series_is_not_closed_by_the_timeout(glasses):
    start(glasses)
    glasses.clear_sent()
    glasses.advance(APP_TIMEOUT + 2)
    assert glasses.sent(APP_BACKGROUND)          # off screen, not stopped
    assert not glasses.sent(APP_STOP)
    before = len(photos(glasses))
    glasses.advance(8)
    assert len(photos(glasses)) >= before + 2
    glasses.assert_ok()


# ---------------------------------------------------------------- background

def test_left_running_it_shoots_in_the_background(glasses):
    start(glasses)
    glasses.advance(FIRST)
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_BACKGROUND)
    assert not glasses.sent(APP_STOP)
    glasses.advance(40)
    assert 9 <= len(photos(glasses)) <= 11       # every 4 s, on whole seconds
    glasses.open_app("timeseries")
    text = glasses.screen_text()
    assert "tap = stop" in text
    sent = int(text.split("sent ")[1].split()[0])
    assert sent >= 10
    glasses.assert_ok()


def test_stopped_from_the_background_view_it_quits(glasses):
    start(glasses)
    glasses.tap(2)
    glasses.open_app("timeseries")
    glasses.tap(1)                               # stop
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    glasses.advance(20)
    assert not photos(glasses)
    glasses.assert_ok()


def test_closed_it_opens_again_from_the_start(glasses):
    start(glasses)
    glasses.tilt(1)                              # 8 s
    glasses.advance(FIRST)
    glasses.tap(1)                               # stop
    assert "sent 1" in glasses.screen_text()
    glasses.tap(2)                               # and closed: dropped
    glasses.open_app("timeseries")
    assert chosen(glasses) == 4
    assert "sent 0  failed 0" in glasses.screen_text()
    glasses.assert_ok()


# ---------------------------------------------------------------- no host

def test_without_a_host_it_waits(frame):
    frame.open_app("timeseries")
    frame.emu.connected = False
    frame.tap(1, settle=0.8)
    frame.advance(10)
    assert "no host, waiting" in frame.screen_text()
    assert not photos(frame)
    frame.clear_sent()
    frame.emu.connected = True
    frame.advance(1)
    assert len(photos(frame)) == 1
    assert "sent 1  failed 0" in frame.screen_text()
    # the missed shots are dropped, not made up for: the rhythm starts
    # again from this one
    frame.advance(3)
    assert len(photos(frame)) == 1
    frame.advance(1.5)
    assert len(photos(frame)) == 2
    frame.assert_ok()


# ---------------------------------------------------------------- failures

def test_a_failed_shot_is_counted_and_the_camera_woken(frame):
    start(frame)
    frame.advance(FIRST)
    # the Camera module powers the camera down on exit
    frame.emu._camera_awake = False
    frame.advance(4)
    assert "sent 1  failed 1" in frame.screen_text()
    assert frame.emu._camera_awake is True
    frame.advance(4)
    assert "sent 2  failed 1" in frame.screen_text()
    assert len(photos(frame)) == 2
    frame.assert_ok()


# ---------------------------------------------------------------- settings

def test_the_phone_sets_where_a_series_starts(glasses):
    start(glasses, {"timeseries.interval": "10"})
    assert chosen(glasses) == 10
    glasses.advance(FIRST + 10)
    assert len(photos(glasses)) == 2
    glasses.tilt(1)                              # tilt still changes it
    assert chosen(glasses) == 20
    glasses.assert_ok()


def test_an_interval_off_the_scale_is_ignored(glasses):
    start(glasses, {"timeseries.interval": "137"})
    assert chosen(glasses) == 4
    glasses.assert_ok()


def test_a_new_size_applies_from_the_next_shot(glasses):
    start(glasses)
    glasses.advance(FIRST)
    glasses.settings({"timeseries.resolution": "200"})
    glasses.advance(4)
    first, second = photos(glasses)
    assert size(first[1]) == (512, 512)
    assert size(second[1]) == (200, 200)
    assert first[0] == second[0]                 # the same series
    glasses.assert_ok()


def test_the_phone_sets_the_size(glasses):
    start(glasses, {"timeseries.resolution": "300"})
    glasses.advance(FIRST)
    assert size(photos(glasses)[0][1]) == (300, 300)
    glasses.assert_ok()


@pytest.mark.parametrize("bad", ["137", "98", "722", "300.5", "big"])
def test_a_size_the_camera_cannot_take_falls_back(glasses, bad):
    start(glasses, {"timeseries.resolution": bad})
    glasses.advance(FIRST)
    shots = photos(glasses)
    assert len(shots) == 1
    assert size(shots[0][1]) == (512, 512)
    assert "failed 0" in glasses.screen_text()
    glasses.assert_ok()


def jpeg_at(frame, settings):
    start(frame, settings)
    frame.advance(FIRST)
    frame.tap(1)                                 # stop
    return photos(frame)[0][1]


def test_the_phone_sets_the_quality(frame):
    medium = jpeg_at(frame, {"timeseries.quality": "MEDIUM"})
    high = jpeg_at(frame, {"timeseries.quality": "HIGH"})
    very_low = jpeg_at(frame, {"timeseries.quality": "VERY_LOW"})
    assert len(very_low) < len(medium) < len(high)
    # unset, it is MEDIUM
    assert jpeg_at(frame, {"photo.quality": "HIGH"}) == medium
    frame.assert_ok()


def test_an_unknown_quality_is_medium(frame):
    medium = jpeg_at(frame, {"timeseries.quality": "MEDIUM"})
    assert jpeg_at(frame, {"timeseries.quality": "ULTRA"}) == medium
    frame.assert_ok()


def test_every_quality_of_the_camera_is_taken(frame):
    names = ["VERY_LOW", "LOW", "MEDIUM", "HIGH", "VERY_HIGH"]
    sizes = [len(jpeg_at(frame, {"timeseries.quality": q})) for q in names]
    assert sizes == sorted(sizes)
    assert len(set(sizes)) == len(sizes)         # none fell back to MEDIUM
    frame.assert_ok()


@pytest.mark.parametrize("res", [100, 720])
def test_the_ends_of_the_size_range_are_taken(glasses, res):
    start(glasses, {"timeseries.resolution": str(res)})
    glasses.advance(FIRST)
    assert size(photos(glasses)[0][1]) == (res, res)
    glasses.assert_ok()


@pytest.mark.parametrize("value", ["1", "60"])
def test_the_phone_interval_at_the_ends_of_the_scale(glasses, value):
    start(glasses, {"timeseries.interval": value})
    assert chosen(glasses) == int(value)
    glasses.assert_ok()


def test_the_phone_interval_wins_over_a_tilt_before_the_start(glasses):
    # the phone sends every setting, the default interval too; a series
    # starts at it, whatever was tilted to before
    glasses.settings({"timeseries.interval": "4"})
    glasses.open_app("timeseries")
    glasses.tilt(1)                              # 8 s
    glasses.tap(1, settle=0.8)
    assert chosen(glasses) == 4
    glasses.assert_ok()


def test_without_a_phone_interval_a_tilt_before_the_start_holds(glasses):
    glasses.open_app("timeseries")
    glasses.tilt(1)                              # 8 s
    glasses.tap(1, settle=0.8)
    assert chosen(glasses) == 8
    glasses.assert_ok()


# ---------------------------------------------------------------- more

def test_the_screen_reads_scale_status_counts(glasses):
    glasses.open_app("timeseries")
    lines = glasses.screen_text().splitlines()
    assert "Time series" in lines[0]             # the breadcrumb
    body = lines[lines.index("1 2 [4] 8 10 20 30 40 60 s"):]
    assert body == ["1 2 [4] 8 10 20 30 40 60 s", "stopped, tap = start",
                    "sent 0  failed 0"]
    glasses.assert_ok()


def test_the_remote_taps_too(glasses):
    glasses.open_app("timeseries")
    glasses.clear_sent()
    glasses.remote(1, 1, settle=0.8)
    assert "tap = stop" in glasses.screen_text()
    glasses.advance(FIRST)
    assert len(photos(glasses)) == 1
    glasses.remote(1, 1)
    assert "stopped, tap = start" in glasses.screen_text()
    glasses.advance(10)
    assert len(photos(glasses)) == 1
    glasses.assert_ok()


def test_the_series_number_comes_from_the_clock(frame):
    frame.open_app("timeseries")
    frame.clear_sent()
    before = frame.emu.utc()
    frame.tap(1, settle=0.8)
    after = frame.emu.utc()
    frame.advance(FIRST)
    series = photos(frame)[0][0]
    # utc() at the tap, modulo 255, plus one: 1..255
    assert series - 1 in {s % 255 for s in range(int(before), int(after) + 1)}
    frame.assert_ok()


def test_stopped_while_warming_up_nothing_is_shot(glasses):
    start(glasses)
    glasses.tap(1)                               # before the 1.5 s are up
    assert "stopped, tap = start" in glasses.screen_text()
    glasses.advance(20)
    assert not glasses.sent(PHOTO_FROM)
    assert not photos(glasses)
    assert "sent 0  failed 0" in glasses.screen_text()
    glasses.assert_ok()


def test_a_start_wakes_the_camera(frame):
    start(frame)
    frame.tap(1)                                 # stopped: the camera sleeps
    assert frame.emu._camera_awake is False
    frame.tap(1, settle=0.8)
    assert frame.emu._camera_awake is True
    frame.advance(FIRST)
    assert "sent 1  failed 0" in frame.screen_text()
    frame.assert_ok()


# ---------------------------------------------------------------- leaving

def background_icon(frame):
    """Pixels of the top bar's play triangle: GREEN, palette 10."""
    return sum(1 for v in frame.emu.display.front[:640 * 40] if v == 10)


def test_the_background_icon_shows_while_it_runs(frame):
    start(frame)
    frame.advance(FIRST)
    frame.tap(2)                                 # into the background
    assert background_icon(frame) > 0
    frame.screenshot("timeseries-background")
    frame.open_app("timeseries")
    frame.tap(1)                                 # stop
    frame.tap(2)                                 # closed: the menu
    assert "Apps" in frame.screen_text()
    assert background_icon(frame) == 0
    frame.assert_ok()


def test_in_the_background_without_a_host_it_waits_awake(frame):
    start(frame)
    frame.advance(FIRST)
    frame.tap(2)                                 # into the background
    frame.emu.connected = False
    frame.clear_sent()
    frame.advance(120)                           # past SLEEP_AFTER, LINK_GRACE
    assert not frame.emu.asleep                  # a series keeps it up
    assert not photos(frame)
    frame.emu.connected = True
    frame.advance(2)
    assert len(photos(frame)) == 1
    frame.advance(4)
    assert len(photos(frame)) == 2
    frame.assert_ok()


def test_a_new_menu_from_the_phone_stops_the_series(glasses):
    start(glasses)
    glasses.advance(FIRST)
    glasses.tap(2)                               # into the background
    glasses.clear_sent()
    glasses.send(MENU_SET, "Coffee\nTea")
    assert glasses.sent(APP_STOP)
    glasses.advance(20)
    assert not photos(glasses)
    assert glasses.emu._camera_awake is False
    glasses.assert_ok()


def test_the_hosts_break_stops_the_series(frame):
    start(frame)
    frame.advance(FIRST)
    frame.tap(2)                                 # into the background
    frame.clear_sent()
    frame.emu.break_signal()
    frame.advance(10)
    assert not frame.running()
    assert not photos(frame)
    assert not any("restarting" in l for l in frame.lines)


def test_the_hosts_break_puts_the_camera_to_sleep(frame):
    start(frame)
    frame.advance(FIRST)
    frame.tap(2)                                 # into the background
    frame.emu.break_signal()
    frame.advance(1)
    assert frame.emu._camera_awake is False      # stop() ran


# ---------------------------------------------------------------- edges

def series_of_start(frame, at=None):
    """Starts a series, at utc() at when given, waits for its first photo
    and stops it: its number."""
    if at is not None:
        frame.advance(at - frame.emu.utc())
    frame.clear_sent()
    frame.tap(1, settle=0.8)
    frame.advance(FIRST)
    frame.tap(1)                                 # stop
    return photos(frame)[0][0]


def test_a_start_255_s_later_is_still_a_new_series(frame):
    # the number comes from the clock, which gives it again 255 s on;
    # the phone would put both series in one folder
    frame.open_app("timeseries")
    at = frame.emu.utc()
    first = series_of_start(frame)
    while frame.emu.utc() < at + 250:            # kept open by tilts
        frame.tilt(1)
        frame.tilt(-1)
        frame.advance(min(40, at + 250 - frame.emu.utc()))
    second = series_of_start(frame, at + 255)    # the same moment, 255 s on
    assert 1 <= second <= 255
    assert second != first
    frame.assert_ok()


def test_a_start_255_s_after_closing_is_still_a_new_series(frame):
    frame.open_app("timeseries")
    at = frame.emu.utc()
    first = series_of_start(frame)
    frame.tap(2)                                 # closed: the module dropped
    frame.advance(at + 250 - frame.emu.utc())
    frame.open_app("timeseries")
    assert series_of_start(frame, at + 255) != first
    frame.assert_ok()


def test_a_tilt_past_the_end_while_shooting_keeps_the_rhythm(glasses):
    start(glasses, {"timeseries.interval": "60"})
    glasses.advance(FIRST)
    assert len(photos(glasses)) == 1
    glasses.tilt(1)                              # nothing past 60
    glasses.tilt(1)
    assert chosen(glasses) == 60
    glasses.advance(55)
    assert len(photos(glasses)) == 1
    glasses.advance(6)
    assert len(photos(glasses)) == 2
    glasses.assert_ok()


def test_rapid_start_stop_start_shoots_one_series(glasses):
    glasses.open_app("timeseries")
    glasses.clear_sent()
    for _ in range(3):                           # start, stop, start
        glasses.tap(1, settle=0.8)
    assert "tap = stop" in glasses.screen_text()
    glasses.advance(FIRST + 4)
    shots = photos(glasses)
    assert len(shots) == 2
    assert len({s for s, _ in shots}) == 1
    assert "sent 2  failed 0" in glasses.screen_text()
    glasses.assert_ok()


def test_the_link_lost_mid_series_keeps_the_counts(frame):
    start(frame)
    frame.advance(FIRST + 4)                     # two shots
    frame.emu.connected = False
    frame.advance(10)
    assert "no host, waiting" in frame.screen_text()
    assert "sent 2  failed 0" in frame.screen_text()
    frame.emu.connected = True
    frame.advance(1)
    assert "sent 3  failed 0" in frame.screen_text()
    assert len({s for s, _ in photos(frame)}) == 1   # still one series
    frame.assert_ok()


def test_asleep_while_shooting_the_series_stops(frame):
    start(frame)
    frame.advance(FIRST)
    frame.tap(3)                                 # three taps: to sleep
    frame.advance(2)
    assert frame.emu.asleep
    assert frame.emu._camera_awake is False
    frame.clear_sent()
    frame.advance(20)
    assert not photos(frame)
    frame.assert_ok()

"""Camera (modules/photo.lua) and the phone remote's photo (PHOTO_TAKE,
app/glaz_photo.frame.lua), on Frame, the only glasses that have them: a
tap sends a JPEG to the phone, PHOTO_FROM first, then 0x07 chunks and an
0x08 end; the cross where the photo's centre is; the phone's settings for
size, quality and aim, bad ones falling back to the defaults; no host, a
transfer cut short; taps while a shot is under way; the camera powered
only while it is needed, and left on for a Timeseries series running in
the background.
"""
import io
import struct

import pytest
from PIL import Image

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, PHOTO_TAKE,
                     has_module)

pytestmark = pytest.mark.module("photo")

PHOTO_FROM, CHUNK, END = 0x1A, 0x07, 0x08
AIM = (261, 327)                 # the cross's default centre
WARMUP = 1.5                     # auto exposure before the first shot


def shoot(g, settle=3.0):
    """A tap in Camera, and time for the warm-up and the transfer."""
    g.clear_sent()
    g.tap(1)
    g.advance(settle)


def photos(g) -> list[bytes]:
    """The JPEGs sent, each put together from its chunks."""
    out, jpeg = [], None
    for m in g.sent():
        if m[0] == PHOTO_FROM:
            jpeg = bytearray()
        elif m[0] == CHUNK and jpeg is not None:
            jpeg.extend(m[1:])
        elif m == bytes([END]) and jpeg is not None:
            out.append(bytes(jpeg))
            jpeg = None
    return out


def picture(jpeg: bytes) -> Image.Image:
    return Image.open(io.BytesIO(jpeg))


def camera_on(g) -> bool:
    return g.emu._camera_awake


def lit_at(g, x, y) -> bool:
    """A pixel at x, y as Lua draws them: from 1, the image from 0."""
    return sum(g.image().getpixel((x - 1, y - 1))) > 60


# ---------------------------------------------------------------- where

def test_only_frame_has_it():
    assert has_module("frame", "photo")
    assert not has_module("halo", "photo")


def test_halo_ignores_the_remotes_photo(halo):
    halo.clear_sent()
    halo.send(PHOTO_TAKE, struct.pack(">HB", 512, 3))
    halo.advance(3)
    assert not halo.sent(PHOTO_FROM)
    assert not halo.sent(CHUNK)
    halo.assert_ok()


# ---------------------------------------------------------------- Camera

def test_opens_with_the_camera_on(glasses):
    assert not camera_on(glasses)                # off at boot
    glasses.clear_sent()
    glasses.open_app("photo")
    assert glasses.sent(APP_START)
    text = glasses.screen_text()
    assert "Camera" in text
    assert "tap = photo" in text
    assert camera_on(glasses)
    glasses.screenshot("camera")
    glasses.assert_ok()


def test_a_cross_marks_the_photos_centre(glasses):
    glasses.open_app("photo")
    x, y = AIM
    assert not lit_at(glasses, x, y)             # the hole in the middle
    for dx, dy in ((-20, 0), (20, 0), (0, -20), (0, 20)):
        assert lit_at(glasses, x + dx, y + dy), (dx, dy)
    glasses.assert_ok()


def test_the_phone_moves_the_cross(glasses):
    glasses.settings({"photo.aim_x": "137", "photo.aim_y": "137"})
    glasses.open_app("photo")
    assert lit_at(glasses, 137 - 20, 137)
    assert lit_at(glasses, 137, 137 + 20)
    assert not lit_at(glasses, AIM[0] - 20, AIM[1])
    glasses.assert_ok()


def test_the_cross_stays_on_the_screen(glasses):
    glasses.settings({"photo.aim_x": "-137", "photo.aim_y": "1370"})
    glasses.open_app("photo")
    # clamped by an arm, the hole and a margin: x 40, y 400 - 40
    x, y = 40, 360
    assert lit_at(glasses, x - 20, y)
    assert lit_at(glasses, x, y - 20)
    assert lit_at(glasses, x, y + 20)
    glasses.assert_ok()


def test_a_tap_sends_a_photo(glasses):
    glasses.open_app("photo")
    shoot(glasses)
    sent = glasses.sent()
    # the label first: a single shot, filed under the day
    assert sent[0] == bytes([PHOTO_FROM, 0])
    assert sent[-1] == bytes([END])
    assert all(m[0] == CHUNK for m in sent[1:-1])
    assert all(len(m) <= 246 for m in sent)      # max_length()
    [jpeg] = photos(glasses)
    assert picture(jpeg).size == (512, 512)
    assert "sent 1, tap = photo" in glasses.screen_text()
    glasses.screenshot("camera-sent")
    glasses.assert_ok()


def test_the_photo_is_what_the_camera_sees(glasses):
    glasses.emu.picture = Image.new("RGB", (720, 720), (200, 30, 30))
    glasses.open_app("photo")
    shoot(glasses)
    [jpeg] = photos(glasses)
    r, g, b = picture(jpeg).convert("RGB").getpixel((256, 256))
    assert r > 150 and g < 80 and b < 80
    glasses.assert_ok()


def test_every_tap_another_photo(glasses):
    glasses.open_app("photo")
    shoot(glasses)
    shoot(glasses)
    assert len(photos(glasses)) == 1             # cleared between
    assert "sent 2, tap = photo" in glasses.screen_text()
    glasses.assert_ok()


def test_the_remotes_tap_takes_one_too(glasses):
    glasses.open_app("photo")
    glasses.clear_sent()
    glasses.remote(1, 1)
    glasses.advance(3)
    assert len(photos(glasses)) == 1
    assert "sent 1" in glasses.screen_text()
    glasses.assert_ok()


def test_an_early_tap_waits_for_the_exposure(glasses):
    glasses.clear_sent()
    glasses.open_app("photo", settle=0)
    glasses.tap(1, settle=0)
    glasses.advance(WARMUP - 0.5)                # still warming up
    assert not glasses.sent(PHOTO_FROM)
    glasses.advance(2)
    assert len(photos(glasses)) == 1
    glasses.assert_ok()


def test_the_phone_sets_size_and_quality(glasses):
    glasses.settings({"photo.resolution": "200", "photo.quality": "VERY_LOW"})
    glasses.open_app("photo")
    shoot(glasses)
    [small] = photos(glasses)
    assert picture(small).size == (200, 200)
    glasses.settings({"photo.resolution": "200",
                      "photo.quality": "VERY_HIGH"})
    shoot(glasses)
    [fine] = photos(glasses)
    assert picture(fine).size == (200, 200)
    assert len(fine) > len(small)
    glasses.assert_ok()


@pytest.mark.parametrize("resolution, quality", [
    ("137", "MEDIUM"),           # odd
    ("98", "MEDIUM"),            # too small
    ("722", "MEDIUM"),           # too big
    ("big", "MEDIUM"),           # not a number
    ("137.5", "MEDIUM"),         # no integer: the firmware's error
    ("512", "ULTRA"),            # no such quality
    ("512", ""),
])
def test_bad_settings_fall_back_to_the_defaults(glasses, resolution,
                                                quality):
    glasses.settings({"photo.resolution": resolution,
                      "photo.quality": quality})
    glasses.open_app("photo")
    shoot(glasses)
    [jpeg] = photos(glasses)
    assert picture(jpeg).size == (512, 512)
    assert "sent 1" in glasses.screen_text()
    glasses.assert_ok()


def test_with_no_host_it_says_so_and_does_not_shoot(glasses):
    glasses.open_app("photo")
    glasses.emu.connected = False
    glasses.advance(0.5)                         # the next tick
    assert "no host" in glasses.screen_text()
    glasses.tap(1)
    glasses.advance(3)
    assert not glasses.sent(PHOTO_FROM) and not glasses.sent(CHUNK)
    assert "no host" in glasses.screen_text()
    glasses.screenshot("camera-no-host")
    glasses.emu.connected = True
    glasses.advance(1.5)                         # the next tick
    assert "tap = photo" in glasses.screen_text()
    glasses.assert_ok()


def test_a_transfer_cut_short_says_send_failed(glasses):
    glasses.open_app("photo", settle=0)
    glasses.clear_sent()
    glasses.tap(1)                               # counted, in the warm-up
    glasses.emu.connected = False                # the link goes
    glasses.advance(5)                           # 2 s of retries a chunk
    assert "no host" in glasses.screen_text()
    assert not photos(glasses)
    glasses.emu.connected = True
    glasses.advance(0.5)
    assert "send failed, tap = photo" in glasses.screen_text()
    glasses.advance(10)                          # said until the next shot
    assert "send failed" in glasses.screen_text()
    glasses.screenshot("camera-send-failed")
    shoot(glasses)                               # and it shoots again
    assert len(photos(glasses)) == 1
    assert "sent 1, tap = photo" in glasses.screen_text()
    glasses.assert_ok()


def test_leaving_powers_the_camera_down(glasses):
    glasses.open_app("photo")
    shoot(glasses)
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)      # not kept running
    assert not camera_on(glasses)
    glasses.assert_ok()


def test_left_alone_it_closes_and_powers_down(glasses):
    glasses.open_app("photo")
    glasses.clear_sent()
    glasses.advance(58)
    assert not glasses.sent(APP_STOP)            # not before APP_TIMEOUT
    assert camera_on(glasses)
    glasses.advance(4)                           # past 60 s
    assert glasses.sent(APP_STOP)
    assert "tap = photo" not in glasses.screen_text()
    assert not camera_on(glasses)
    glasses.assert_ok()


def test_sleep_from_camera_powers_it_down(glasses):
    glasses.open_app("photo")
    glasses.tap(3)                               # deep sleep
    glasses.advance(3)
    assert glasses.emu.asleep
    assert not camera_on(glasses)
    glasses.assert_ok()


def test_opened_again_it_counts_from_zero(glasses):
    glasses.open_app("photo")
    shoot(glasses)
    glasses.tap(2)
    glasses.open_app("photo")
    assert "tap = photo" in glasses.screen_text()
    assert "sent" not in glasses.screen_text()
    glasses.assert_ok()


# ---------------------------------------------------------------- remote

def remote_photo(g, size=512, quality=3, settle=3.0):
    g.clear_sent()
    g.send(PHOTO_TAKE, struct.pack(">HB", size, quality))
    g.advance(settle)


def test_the_remote_takes_a_photo_from_the_menu(glasses):
    glasses.tap(2)
    remote_photo(glasses, 200, 1)
    assert glasses.sent(PHOTO_FROM) == [bytes([PHOTO_FROM, 0])]
    [jpeg] = photos(glasses)
    assert picture(jpeg).size == (200, 200)
    assert not camera_on(glasses)                # off again after
    assert "Glaz" in glasses.screen_text()       # the menu stays
    glasses.assert_ok()


def test_the_remotes_quality_runs_from_very_low_to_very_high(glasses):
    remote_photo(glasses, 512, 1)
    [low] = photos(glasses)
    remote_photo(glasses, 512, 5)
    [high] = photos(glasses)
    assert len(high) > len(low)
    glasses.assert_ok()


@pytest.mark.parametrize("quality", [0, 137])
def test_an_unknown_quality_is_medium(glasses, quality):
    remote_photo(glasses, 512, 3)
    [medium] = photos(glasses)
    remote_photo(glasses, 512, quality)
    [jpeg] = photos(glasses)
    assert jpeg == medium                        # the same picture
    glasses.assert_ok()


@pytest.mark.parametrize("size", [137, 98, 722, 0, 65535])
def test_a_bad_size_is_512(glasses, size):
    remote_photo(glasses, size, 3)
    [jpeg] = photos(glasses)
    assert picture(jpeg).size == (512, 512)
    glasses.assert_ok()


def test_a_short_photo_take_is_ignored(glasses):
    glasses.clear_sent()
    glasses.send(PHOTO_TAKE, b"\x02\x00")        # no quality
    glasses.advance(3)
    assert not glasses.sent(PHOTO_FROM) and not glasses.sent(CHUNK)
    glasses.assert_ok()


def test_the_remote_needs_a_host(glasses):
    # the link goes after the request came, before the loop takes it
    glasses.emu.receive(bytes([PHOTO_TAKE, 0, 3]) + struct.pack(">HB", 512, 3))
    glasses.emu.connected = False
    glasses.advance(3)
    assert not glasses.sent(PHOTO_FROM)
    assert not camera_on(glasses)
    glasses.assert_ok()


def test_the_remotes_photo_leaves_camera_open_and_on(glasses):
    glasses.open_app("photo")
    remote_photo(glasses, 200, 3)
    assert len(photos(glasses)) == 1
    assert camera_on(glasses)                    # Camera still needs it
    text = glasses.screen_text()
    assert "Camera" in text
    shoot(glasses)                               # and still shoots
    assert len(photos(glasses)) == 1
    glasses.assert_ok()


def test_the_remotes_photo_waits_for_the_exposure(glasses):
    glasses.clear_sent()
    glasses.send(PHOTO_TAKE, struct.pack(">HB", 512, 3))
    glasses.advance(WARMUP - 0.3)
    assert not glasses.sent(PHOTO_FROM)
    glasses.advance(2)
    assert len(photos(glasses)) == 1
    glasses.assert_ok()


# ---------------------------------------------------------------- edges

def test_a_tap_while_a_shot_is_under_way_is_not_lost(glasses):
    # on_tap blocks the loop through the warm-up and the transfer; the
    # emulator sends in no time, so the warm-up is where a tap can fall
    glasses.open_app("photo", settle=0)
    glasses.clear_sent()
    glasses.tap(1)                               # the shot, warming up
    assert not glasses.sent(PHOTO_FROM)
    glasses.tap(1, settle=0)                     # while it is under way
    glasses.advance(3)
    assert len(photos(glasses)) == 2
    assert "sent 2, tap = photo" in glasses.screen_text()
    glasses.assert_ok()


def test_shooting_keeps_camera_open(glasses):
    glasses.open_app("photo")
    glasses.advance(50)
    shoot(glasses)                               # 53 s after it opened
    glasses.advance(50)
    assert not glasses.sent(APP_STOP)
    assert "sent 1" in glasses.screen_text()
    assert camera_on(glasses)
    glasses.advance(10)                          # 60 s after the shot
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


@pytest.mark.parametrize("aim_x, aim_y", [("left", "up"), ("", "")])
def test_an_aim_that_is_no_number_is_the_default(glasses, aim_x, aim_y):
    glasses.settings({"photo.aim_x": aim_x, "photo.aim_y": aim_y})
    glasses.open_app("photo")
    x, y = AIM
    assert lit_at(glasses, x - 20, y) and lit_at(glasses, x, y + 20)
    glasses.assert_ok()


def test_a_fractional_aim_is_rounded_down(glasses):
    glasses.settings({"photo.aim_x": "137.9", "photo.aim_y": "137.9"})
    glasses.open_app("photo")
    assert lit_at(glasses, 137 - 20, 137)
    assert lit_at(glasses, 137, 137 + 20)
    glasses.assert_ok()


def test_a_tilt_neither_shoots_nor_leaves(glasses):
    glasses.open_app("photo")
    glasses.clear_sent()
    glasses.tilt(1)
    glasses.tilt(-1)
    glasses.advance(3)
    assert not glasses.sent(PHOTO_FROM) and not glasses.sent(APP_STOP)
    assert "tap = photo" in glasses.screen_text()
    glasses.assert_ok()


def test_halo_cannot_open_camera(halo):
    halo.clear_sent()
    halo.open_app("photo")
    assert not halo.sent(APP_START)
    assert "tap = photo" not in halo.screen_text()
    halo.assert_ok()


def test_a_longer_photo_take_still_takes_the_photo(glasses):
    glasses.clear_sent()
    glasses.send(PHOTO_TAKE, struct.pack(">HB", 200, 3) + b"\x89")
    glasses.advance(3)
    [jpeg] = photos(glasses)
    assert picture(jpeg).size == (200, 200)
    glasses.assert_ok()


def test_the_remotes_photo_keeps_camera_open(glasses):
    glasses.open_app("photo")
    glasses.advance(50)
    remote_photo(glasses)                        # 53 s after it opened
    glasses.advance(50)
    assert not glasses.sent(APP_STOP)
    glasses.assert_ok()


def start_series(frame):
    frame.open_app("timeseries")
    frame.tap(1, settle=0.8)                     # a photo every 4 s
    frame.tap(2)                                 # into the background
    frame.advance(3)


def test_the_remotes_photo_leaves_a_series_its_camera(frame):
    start_series(frame)
    remote_photo(frame, 200, 3)
    assert camera_on(frame)                      # the series still shoots
    frame.clear_sent()
    frame.advance(9)
    assert len(photos(frame)) >= 2
    frame.assert_ok()


def test_leaving_camera_leaves_a_series_its_camera(frame):
    start_series(frame)
    frame.open_app("photo")
    shoot(frame)
    frame.tap(2)
    frame.clear_sent()
    frame.advance(9)
    assert camera_on(frame)
    assert len(photos(frame)) >= 2
    frame.open_app("timeseries")
    assert "failed 0" in frame.screen_text()
    frame.assert_ok()


def test_left_beside_a_stopwatch_the_camera_powers_down(frame):
    # glaz.lua keeps release_hardware() for when no module is in the
    # background; with one that does not shoot, the module powers it down
    frame.open_app("stopwatch")
    frame.tap(1)                                 # running
    frame.tap(2)                                 # to the background
    frame.open_app("photo")
    assert frame.emu._camera_awake
    frame.tap(2)
    assert not frame.emu._camera_awake
    frame.assert_ok()

"""glaz on Halo, in Brilliant Labs' Halo emulator (halo-emulator; see
docs/HALO.md, "Trying it without a Halo").

The files go in as the phone uploads them to Halo (halo_sandbox.py), and
the app starts as it does there: main.lua, glaz_boot.halo.lua, loads
glaz_boot.lua, which loads the app with its Halo part. Taps come as
Halo's firmware gives them, whole: 'single', 'double', 'triple'.

    pytest tests                      # in the root devenv shell
    HALO_SHOTS=/tmp/halo pytest tests # and keep the screens as PNG
"""
import os
import time
from pathlib import Path

import pytest

from halo_sandbox import emulator, stage

SHOTS = os.environ.get("HALO_SHOTS")


class Halo:
    """The emulator running glaz, with what it printed."""

    def __init__(self, sandbox: Path):
        self.files = stage(sandbox)
        self.lines: list[str] = []
        self.emu = emulator(sandbox, print_handler=self.lines.append)

    def until(self, text: str, timeout: float = 10.0) -> bool:
        end = time.time() + timeout
        while time.time() < end and self.emu.is_running():
            if any(text in line for line in self.lines):
                return True
            time.sleep(0.05)
        return any(text in line for line in self.lines)

    def tap(self, kind: str, settle: float = 1.5):
        self.emu.inject_imu_tap(kind)
        time.sleep(settle)

    def screen(self, name: str):
        img = self.emu.get_framebuffer().convert("RGB")
        if SHOTS:
            Path(SHOTS).mkdir(parents=True, exist_ok=True)
            img.save(Path(SHOTS) / f"{name}.png")
        return img

    def errors(self) -> list[str]:
        return [l for l in self.lines if "error" in l.lower()]


def lit(img) -> int:
    """Pixels that are not black."""
    return sum(1 for p in img.getdata() if sum(p) > 60)


@pytest.fixture
def halo(tmp_path):
    h = Halo(tmp_path)
    h.emu.start("main.lua")
    assert h.until("Frame app is running"), h.lines
    yield h
    if h.emu.is_running():
        h.emu.stop()


def test_uploads_only_halos_files(tmp_path):
    files = stage(tmp_path)
    assert "main.lua" in files and "glaz_app.halo.lua" in files
    assert not [f for f in files if ".frame." in f]
    # an app with a Halo part goes; one without does not
    assert "about.lua" in files and "reader.lua" not in files
    # glaz_boot's own part is main.lua, not a file of its own
    assert "glaz_boot.halo.lua" not in files
    assert "glaz_boot.frame.lua" not in files


def test_starts_without_errors(halo):
    time.sleep(1)
    assert halo.emu.get_error() is None
    assert not halo.errors(), halo.errors()
    assert lit(halo.screen("1-splash")) > 0   # <glaz>


def test_taps_open_the_menu_and_go_in(halo):
    before = halo.screen("1-splash")
    halo.tap("double")                        # the menu, at the root
    menu = halo.screen("2-menu")
    assert list(menu.getdata()) != list(before.getdata())
    halo.tap("single")                        # into Apps
    apps = halo.screen("3-apps")
    assert list(apps.getdata()) != list(menu.getdata())
    halo.tap("single")                        # the first app there
    halo.screen("4-app")
    halo.tap("double")                        # back
    halo.screen("5-back")
    assert halo.emu.get_error() is None
    assert not halo.errors(), halo.errors()


def test_triple_tap_sleeps_and_a_tap_wakes(halo):
    halo.tap("double")
    halo.tap("triple", settle=3.0)            # to sleep: standby() on Halo
    assert halo.emu.is_running()              # standby, not deep sleep
    halo.tap("single", settle=2.0)
    halo.screen("6-woken")
    assert halo.emu.get_error() is None
    assert not halo.errors(), halo.errors()

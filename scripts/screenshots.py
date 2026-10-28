"""Screenshots of glaz on the emulated glasses, for the docs.

    python scripts/screenshots.py                 # every app, Frame and Halo
    python scripts/screenshots.py -d frame reader # some apps, on Frame only
    python scripts/screenshots.py -o docs/screens # where (default: screens/)

For every app: the glasses start as after an upload, the phone sets the
clock (13:37 UTC, shown as 15:37), the app is opened as the phone's Menu
tab opens it, and its screen is saved a few seconds later as
<out>/<device>/<app>.png. The menu, the splash and a notification come
too. Frame's screens are drawn with the firmware's own fonts
(tests/frame_emulator); Halo's by Brilliant Labs' emulator. The tests
take screenshots of their own as well, of more screens: SHOTS=dir pytest
tests (docs/TESTING.md).
"""
import argparse
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))

from glasses import Glasses  # noqa: E402
from sandbox import modules  # noqa: E402


def shoot(device: str, apps: list[str], out: Path, seconds: float):
    where = out / device
    with tempfile.TemporaryDirectory() as tmp:
        g = Glasses(device, Path(tmp) / "start")
        g.start()
        g.set_clock()
        g.screenshot("splash", where)
        g.advance(4)
        g.tap(2)
        g.screenshot("menu", where)
        g.notify("Chat", "Ann", "Lunch at 13:37?")
        g.screenshot("notification", where)
        g.stop()
        for app in apps:
            g = Glasses(device, Path(tmp) / app)
            g.start()
            g.set_clock()
            g.advance(4)
            g.open_app(app)
            g.advance(seconds)
            g.screenshot(app, where)
            bad = g.errors()
            g.stop()
            print(f"{device}/{app}.png" + (f"  ({bad[0]})" if bad else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("apps", nargs="*", help="apps (modules/); all by default")
    ap.add_argument("-d", "--device", choices=["frame", "halo"],
                    action="append", help="glasses; both by default")
    ap.add_argument("-o", "--out", default="screens", type=Path)
    ap.add_argument("-s", "--seconds", default=1.0, type=float,
                    help="the glasses' seconds between opening and the shot")
    a = ap.parse_args()
    for device in a.device or ["frame", "halo"]:
        have = modules(device)
        apps = [m for m in (a.apps or have) if m in have]
        shoot(device, apps, a.out, a.seconds)


if __name__ == "__main__":
    main()

# Testing glaz on emulated glasses

## Plain-language summary

The apps on the glasses are tested without the glasses. A program on the
computer pretends to be them: it runs the same Lua the glasses run, gives
it a screen, a clock, taps, a head to tilt and a phone to talk to, and
lets a test look at what ends up on the screen. Every app has such tests,
on Frame and, where it runs there, on Halo. They take seconds, run on
every push (GitHub Actions), and save pictures of the screens, which the
docs can use.

## The emulators

**Frame.** Brilliant Labs have none, so glaz has its own,
`tests/frame_emulator/`, built the way their Halo emulator is, after
Frame's firmware (`lab-frame-codebase`, branch `glaz/main`,
`source/application/lua_libraries/*.c`):

- Lua 5.4 (lupa), with only the libraries Frame opens: no `io`, `os` or
  `package`.
- `frame.display`: 640x400 in the 16 palette colours, drawn to a back
  buffer that `show()` flips to the panel and empties, as the FPGA does.
  Text is drawn with the firmware's own fonts, the proportional one of
  `text()` and the Terminus of `mono()`, taken from its sources by
  `tests/frame_emulator/make_fonts.py` into `fonts.json.gz`. So a
  screenshot is what the wearer sees.
- `frame.file`: littlefs as a directory: its modes, `read()` a line of at
  most 512 bytes without its break, `listdir()` with `.` and `..`,
  `space()` and running out of it (`error writing to file`).
- `frame.imu`: the tap callback once a tap, with the status byte firmware
  glaz passes (which side); the head's roll as the test sets it;
  `tap_config()`, `woke_by_tap()`.
- `frame.sleep()` without an argument is deep sleep: Bluetooth gone, the
  panel off, and a tap wakes the glasses with a reset, `main.lua` run
  again with `woke_by_tap()` true; unless `stay_awake(true)`. A wake is
  a power-on: the clock from 0, the tap settings and brightness back to
  their defaults. `double_tap_wake` asks for the second tap glaz/main
  wants; glaz/stable, which the phone app ships, wakes on one.
- The firmware's start takes 2 s before `main.lua` runs: `utc()` is 2.0
  there.
- `frame.bluetooth`: what the app sends is kept, a string longer than
  `max_length()` is the firmware's error, nothing arrives without a link.
- The host's break: `break signal`, raised once, as Frame's `luaport.c`
  does: a `pcall` that catches it has to raise it again, which glaz's
  `try` does.
- The camera takes a JPEG of a picture the test sets; the microphone
  reads bytes the test gives; `fpga_read` says no flip is pending.
- Errors have the firmware's words: `Invalid color name`, `number has no
  integer representation` for an `x` of 60.5.

**Halo.** Brilliant Labs' [`halo-emulator`](https://pypi.org/project/halo-emulator/),
adjusted by `tests/halo_sandbox.py` to Halo's firmware of today
(docs/HALO.md): its `frame.file`, its break (`interrupted`, once), and
the same virtual time.

**Virtual time** (`tests/vclock.py`). The glasses' clock moves only when
the test moves it. The app's `frame.sleep(0.01)` waits until the test says
"a second passes", and a tap lands between two of its steps, as the
firmware's callback does. So a test of a minute's timeout takes
milliseconds, and the same test does the same thing on every run, on any
machine. A test that leaves Lua stuck outside `frame.sleep()` fails after
30 real seconds with a `TimeoutError`.

## The tests

`tests/glasses.py` is glaz on a pair of emulated glasses:

```python
def test_a_tap_starts_it(glasses):         # on each glasses with the app
    glasses.open_app('stopwatch')          # as the phone's Menu tab does
    glasses.tap(1)                         # a tap on the temple
    glasses.advance(37)                    # 37 s of the glasses' time
    assert '0:37' in glasses.screen_text() # the strings on screen
    glasses.screenshot('stopwatch')        # PNG, with SHOTS set
```

- The files go in as the phone uploads them (`tests/sandbox.py`, after
  `luaFiles()` in `upload.dart`): the glasses' own parts, the modules with
  a part for them, `main.lua` the boot part. They are not minified or
  compiled, so the emulator counts what is there at the start as a full
  upload, with 32 KB left.
- The fixtures (`tests/conftest.py`): `frame`, `halo`, and `glasses`, which
  runs a test on each pair of glasses that has the module named by
  `pytestmark = pytest.mark.module('name')`. Each starts glaz from
  `main.lua` and sets the phone's clock: 13:37 UTC, shown as 15:37.
- The wearer: `tap(n)`, `tilt(±1)`, `button()` (Halo).
- The phone: `send(code, payload)` with the codes of docs/PROTOCOL.md, and
  `open_app()`, `call()`, `remote()`, `notify()`, `settings()`,
  `set_clock()`; what the glasses said back is in `sent(code)`, and
  `joined(code)` puts messages split over packets together.
- What is shown: `screen_text()`, `texts()` with where each string went,
  `image()`, `screenshot(name)`.
- `assert_ok()`: nothing printed an error.

`test_app.py` is the app itself: start, menu, gestures, sleep and waking,
notifications, the console, the break. `test_services.py` the phone's
services, `test_boot.py` the loader and its restarts, `test_<module>.py`
each app, and `test_frame_emulator.py` the emulator against the firmware.

## Running them

In the root devenv shell:

```sh
tests                          # pytest tests: everything, both glasses
tests tests/test_reader.py     # one app
halo                           # Halo's only
SHOTS=/tmp/shots tests         # and keep the screens the tests took
screens -o docs/screens        # a screenshot of every app, both glasses
```

Without devenv: `pip install -r requirements.txt`, then `pytest tests`.

## Screenshots for the docs

`utils/screenshots.py` (`screens` in the shell) opens every app on both
glasses as the phone does and saves its screen as
`<out>/<device>/<app>.png`, with the splash, the menu and a notification.
The tests save more, the screens along the way (`SHOTS=dir`), in
`<dir>/<device>/<name>.png`.

## CI

`.github/workflows/tests.yml` runs `check.sh` and the tests on every push
and pull request that touches the Lua or the tests, and keeps the screens
(both the tests' and `screens`') as the `screens` artifact of the run.

## When the firmware changes

- New or changed Lua functions: `tests/frame_emulator/__init__.py`, after
  the firmware's C, and a test in `test_frame_emulator.py`.
- New fonts: `python tests/frame_emulator/make_fonts.py [FRAME_CODEBASE]`.
- A new halo-emulator: `requirements.txt`, and what `halo_sandbox.py`
  patches, which is said there.

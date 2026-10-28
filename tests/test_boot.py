"""The boot loader (glaz/glaz_boot.lua, its parts glaz_boot.frame.lua and
glaz_boot.halo.lua, main.lua on the glasses) and the goodnight blink
(glaz/glaz_blink.frame.lua) on each pair of glasses: files loaded in
pieces, require() with the glasses' own parts, the app started again
after a crash and left stopped when it keeps crashing, the host's break
let through, and the eye closing before deep sleep.

Most tests here run a small app of their own in place of glaz.lua: it
prints what it found, and the boot around it is the real one.
"""
import re

import pytest

from glasses import Glasses

DEVICES = ["frame", "halo"]
GREENS = (9, 10, 11)     # the eye's iris: DARKGREEN, GREEN, LIGHTGREEN


@pytest.fixture
def make(tmp_path):
    """Glasses with a test app as glaz_app.lua, and files of the test's
    own beside it; started until the app prints wait_for."""
    made = []

    def make(device, app=None, files=None, wait_for="ready 137",
             start=True):
        g = Glasses(device, tmp_path / device)
        if app is not None:
            (g.sandbox / f"glaz_app.{device}.lua").unlink(missing_ok=True)
            (g.sandbox / "glaz_app.lua").write_text(app)
        for name, text in (files or {}).items():
            path = g.sandbox / name
            if text is None:
                path.unlink(missing_ok=True)
            elif isinstance(text, bytes):
                path.write_bytes(text)
            else:
                path.write_text(text)
        made.append(g)
        if start:
            g.start(wait_for=wait_for)
        return g

    yield make
    for g in made:
        g.stop()


def emu_error(g) -> str:
    err = g.emu.error if g.device == "frame" else g.emu.get_error()
    return "" if err is None else str(err)


def count(g, text) -> int:
    return sum(1 for line in g.lines if text in line)


# ------------------------------------------------------------- loading

def long_lines_module() -> tuple[str, str]:
    """A module that returns a long string of lines 0 to 1100 bytes long,
    around read()'s 512, and that string."""
    lengths = [0, 1, 137, 510, 511, 512, 513, 0, 0, 1023, 1024, 1025, 1100,
               512, 512, 0, 137]
    body = "\n".join(("abcdefghij" * 111)[:n] for n in lengths)
    return f"return [==[\n{body}]==]\n", body


@pytest.mark.parametrize("device", DEVICES)
def test_a_module_with_long_and_empty_lines_loads_whole(make, device):
    src, body = long_lines_module()
    app = ("local s = require('lines137')\n"
           "local f = frame.file.open('out137.txt', 'write')\n"
           "f:write(s) f:close()\n"
           "print('ready 137', #s)\n")
    g = make(device, app, {"lines137.lua": src})
    assert (g.sandbox / "out137.txt").read_text() == body
    g.assert_ok()


@pytest.mark.parametrize("device", DEVICES)
@pytest.mark.parametrize("ending", ["\n", "", "\n\n"])
def test_a_file_loads_with_or_without_a_last_line_break(make, device,
                                                        ending):
    src = "local x = 100\nreturn x + 37" + ending
    app = "print('ready 137', require('end137'))\n"
    g = make(device, app, {"end137.lua": src})
    assert any(l == "ready 137\t137" for l in g.lines), g.lines
    g.assert_ok()


@pytest.mark.parametrize("device", DEVICES)
@pytest.mark.parametrize("size", [511, 512, 513, 1024, 1025,
                                  4095, 4096, 4097, 8193])
@pytest.mark.parametrize("tail", ["return 137\n", "return 137"])
def test_files_around_a_reads_size_load(make, device, size, tail):
    # one long line of a comment, then the code: a line break falls on
    # either side of Frame's 512-byte pieces and Halo's 4096-byte reads
    pad = size - len(tail) - 1
    src = "--" + "x" * (pad - 2) + "\n" + tail
    assert len(src) == size
    app = "print('ready 137', require('size137'))\n"
    g = make(device, app, {"size137.lua": src})
    assert any(l == "ready 137\t137" for l in g.lines), g.lines


@pytest.mark.parametrize("device", DEVICES)
def test_a_file_exactly_512_bytes_on_one_line(make, device):
    src = "return '" + "y" * 501 + "'  "
    assert len(src) == 512
    app = "print('ready 137', #require('one137'))\n"
    g = make(device, app, {"one137.lua": src})
    assert any(l == "ready 137\t501" for l in g.lines), g.lines


def test_frame_loads_bytecode_with_line_breaks_in_it(make):
    # what the phone uploads to Frame: luac's output, 0x0A bytes anywhere
    lupa = pytest.importorskip("lupa.lua54")
    lua = lupa.LuaRuntime(encoding="latin-1")
    code = ("local t = {}\n"
            "for i = 1, 137 do t[i] = ('\\n'):rep(i % 7) .. i end\n"
            "return #table.concat(t)\n")
    dump = lua.eval(f"string.dump(load({code!r}), true)")
    assert isinstance(dump, str)
    raw = dump.encode("latin-1")
    assert b"\n" in raw
    expected = lua.execute(code)
    app = "print('ready 137', require('dump137'))\n"
    g = make("frame", app, {"dump137.lua": raw})
    assert any(l == f"ready 137\t{expected}" for l in g.lines), g.lines


def test_halo_loads_text_only(make):
    lupa = pytest.importorskip("lupa.lua54")
    lua = lupa.LuaRuntime(encoding="latin-1")
    raw = lua.eval("string.dump(load('return 137'), true)").encode("latin-1")
    app = ("local ok, err = pcall(require, 'dump137')\n"
           "print('ready 137', ok, err)\n")
    g = make("halo", app, {"dump137.lua": raw})
    line = next(l for l in g.lines if l.startswith("ready 137"))
    assert "false" in line and "dump137" in line


# ------------------------------------------------------------- require()

@pytest.mark.parametrize("device", DEVICES)
def test_require_hands_the_glasses_part_to_the_module(make, device):
    other = "halo" if device == "frame" else "frame"
    files = {
        "pair137.lua": "local name, D = ...\n"
                       "return {name = name, part = D and D.who}\n",
        f"pair137.{device}.lua": f"return {{who = '{device}'}}\n",
        f"pair137.{other}.lua": "error('the other glasses part')\n",
    }
    app = ("local m = require('pair137')\n"
           "print('ready 137', m.name, m.part)\n")
    g = make(device, app, files)
    assert f"ready 137\tpair137\t{device}" in g.lines
    g.assert_ok()


@pytest.mark.parametrize("device", DEVICES)
def test_a_module_without_a_part_gets_none(make, device):
    files = {"plain137.lua": "local _, D = ...\nreturn tostring(D)\n"}
    app = "print('ready 137', require('plain137'))\n"
    g = make(device, app, files)
    assert "ready 137\tnil" in g.lines


@pytest.mark.parametrize("device", DEVICES)
def test_a_part_alone_is_the_module(make, device):
    files = {f"only137.{device}.lua": "local name = ...\n"
                                      "return {v = 137, name = name}\n"}
    app = ("local m = require('only137')\n"
           "print('ready 137', m.v, m.name)\n")
    g = make(device, app, files)
    assert "ready 137\t137\tonly137" in g.lines


@pytest.mark.parametrize("device", DEVICES)
def test_a_module_that_returns_nothing_is_still_found(make, device):
    files = {"none137.lua": "x137 = 137\n"}
    app = ("local ok, m = pcall(require, 'none137')\n"
           "print('ready 137', ok, m, x137)\n")
    g = make(device, app, files)
    assert "ready 137\ttrue\tnil\t137" in g.lines


@pytest.mark.parametrize("device", DEVICES)
def test_a_missing_module_is_an_error_naming_it(make, device):
    app = ("local ok, err = pcall(require, 'nope137')\n"
           "print('ready 137', ok, err)\n")
    g = make(device, app)
    line = next(l for l in g.lines if l.startswith("ready 137"))
    assert "false" in line and "cannot open file: nope137.lua" in line
    # the error points at the caller, not at the boot loader
    assert "glaz_boot" not in line


@pytest.mark.parametrize("device", DEVICES)
def test_a_module_that_does_not_compile_says_so(make, device):
    files = {"bad137.lua": "return 137 +\n"}
    app = ("local ok, err = pcall(require, 'bad137')\n"
           "print('ready 137', ok, err)\n")
    g = make(device, app, files)
    line = next(l for l in g.lines if l.startswith("ready 137"))
    assert "false" in line
    assert "exiting module 'bad137'" in line and "bad137.lua" in line


@pytest.mark.parametrize("device", DEVICES)
def test_a_part_that_does_not_compile_says_so(make, device):
    files = {"pair137.lua": "return 137\n",
             f"pair137.{device}.lua": "return {\n"}
    app = ("local ok, err = pcall(require, 'pair137')\n"
           "print('ready 137', ok, err)\n")
    g = make(device, app, files)
    line = next(l for l in g.lines if l.startswith("ready 137"))
    assert "false" in line and f"pair137.{device}.lua" in line
    assert "exiting module 'pair137'" in line


@pytest.mark.parametrize("device", DEVICES)
def test_require_errors_point_at_the_line_that_required(make, device):
    app = ("local function a() local m = require('nope137') return m end\n"
           "local function b() local m = require('bad137') return m end\n"
           "print('missing 137', select(2, pcall(a)))\n"
           "print('broken 137', select(2, pcall(b)))\n"
           "print('ready 137')\n")
    g = make(device, app, {"bad137.lua": "return +\n"})
    assert ("missing 137\tglaz_app.lua:1: cannot open file: nope137.lua"
            in g.lines), g.lines
    broken = next(l for l in g.lines if l.startswith("broken 137"))
    assert broken.startswith(
        "broken 137\tglaz_app.lua:2: exiting module 'bad137': bad137.lua:1:")


@pytest.mark.parametrize("device", DEVICES)
def test_the_other_glasses_part_is_no_module_here(make, device):
    other = "halo" if device == "frame" else "frame"
    files = {f"theirs137.{other}.lua": "return 137\n"}
    app = ("local ok, err = pcall(require, 'theirs137')\n"
           "print('ready 137', ok, err)\n")
    g = make(device, app, files)
    assert "ready 137\tfalse\tcannot open file: theirs137.lua" in g.lines


@pytest.mark.parametrize("device", DEVICES)
def test_glaz_break_knows_these_glasses_break(make, device):
    # Frame's firmware raises 'break signal', Halo's 'interrupted'
    app = ("print('ready 137',\n"
           "  glaz_break('x.lua:137: break signal'),\n"
           "  glaz_break('x.lua:137: interrupted'),\n"
           "  glaz_break('boom 137'), glaz_break(nil), glaz_break({}))\n")
    g = make(device, app)
    mine = {"frame": "true\tfalse", "halo": "false\ttrue"}[device]
    assert f"ready 137\t{mine}\tfalse\tfalse\tfalse" in g.lines, g.lines


@pytest.mark.parametrize("device", DEVICES)
def test_a_modules_own_error_comes_through(make, device):
    files = {"boom137.lua": "error('boom 137')\n"}
    app = ("local ok, err = pcall(require, 'boom137')\n"
           "print('ready 137', ok, err)\n")
    g = make(device, app, files)
    line = next(l for l in g.lines if l.startswith("ready 137"))
    assert "false" in line and "boom 137" in line


@pytest.mark.parametrize("device", DEVICES)
def test_require_runs_the_file_every_time(make, device):
    # as Frame's firmware does: no package.loaded to keep it
    files = {"count137.lua": "n137 = (n137 or 0) + 1\nreturn n137\n"}
    app = ("require('count137') require('count137')\n"
           "print('ready 137', require('count137'))\n")
    g = make(device, app, files)
    assert "ready 137\t3" in g.lines


@pytest.mark.parametrize("device", DEVICES)
def test_the_app_gets_its_own_part(make, device):
    app = ("local name, D = ...\n"
           "print('ready 137', name, D and D.mark)\n")
    files = {f"glaz_app.{device}.lua": "return {mark = 137}\n"}
    g = make(device, app, files)
    assert "ready 137\tglaz_app\t137" in g.lines


@pytest.mark.parametrize("device", DEVICES)
def test_without_the_boot_loader_main_says_so(make, device):
    g = make(device, files={"glaz_boot.lua": None}, start=False)
    g.start(wait_for=None)
    g.advance(1)
    assert not g.running()
    text = emu_error(g) + "\n".join(g.lines)
    assert "cannot open file: glaz_boot.lua" in text


@pytest.mark.parametrize("device", DEVICES)
def test_a_boot_loader_that_does_not_compile_stops_main(make, device):
    g = make(device, files={"glaz_boot.lua": "local x = = 137\n"},
             start=False)
    g.start(wait_for=None)
    g.advance(1)
    assert not g.running()
    assert "glaz_boot.lua:1" in emu_error(g) + "\n".join(g.lines)


# ------------------------------------------------------------- restart

CRASH_AT_ONCE = ("print('app start', tostring(left137))\n"
                 "left137 = 137\n"
                 "error('boom 137')\n")


@pytest.mark.parametrize("device", DEVICES)
def test_a_crash_restarts_the_app_three_times_then_stops(make, device):
    g = make(device, CRASH_AT_ONCE, wait_for="app start")
    g.advance(10)
    assert not g.running()
    assert count(g, "app start") == 4            # the first and 3 restarts
    assert count(g, "glaz app error, restarting: ") == 3
    assert "boom 137" in emu_error(g) + g.lines[-1]
    crash = (g.sandbox / "crash.txt").read_text()
    assert re.fullmatch(r"\d+ .*boom 137", crash), crash


@pytest.mark.parametrize("device", DEVICES)
def test_it_stops_with_the_apps_own_error(make, device):
    g = make(device, CRASH_AT_ONCE, wait_for="app start")
    g.advance(10)
    assert not g.running()
    assert "glaz_app.lua:3: boom 137" in emu_error(g)


@pytest.mark.parametrize("device", DEVICES)
def test_the_log_and_crash_file_tell_the_error_and_when(make, device):
    app = ("print('app start', math.floor(frame.time.utc()))\n"
           "if pcall(frame.file.open, 'crash.txt', 'read') then\n"
           "  if pcall(frame.file.open, 'second137', 'read') then\n"
           "    print('ready 137') while true do frame.sleep(1) end\n"
           "  end\n"
           "  frame.file.open('second137', 'write'):close()\n"
           "  error('second 137')\n"
           "end\n"
           "error('first 137')\n")
    g = make(device, app, wait_for="app start")
    g.advance(5)
    starts = [l.split("\t")[1] for l in g.lines if l.startswith("app start")]
    restarts = [l for l in g.lines if "restarting: " in l]
    assert restarts[:2] == [
        "glaz app error, restarting: glaz_app.lua:9: first 137",
        "glaz app error, restarting: glaz_app.lua:7: second 137"]
    # the last crash only, at the time it happened
    crash = (g.sandbox / "crash.txt").read_text()
    assert crash == f"{starts[1]} glaz_app.lua:7: second 137"


@pytest.mark.parametrize("device", DEVICES)
def test_a_restart_waits_a_second(make, device):
    app = ("print('app start', frame.time.utc())\n"
           "error('boom 137')\n")
    g = make(device, app, wait_for="app start")
    g.advance(10)
    times = [float(l.split("\t")[1]) for l in g.lines
             if l.startswith("app start")]
    assert len(times) == 4
    for a, b in zip(times, times[1:]):
        assert 1.0 <= b - a <= 1.1


@pytest.mark.parametrize("device", DEVICES)
def test_an_app_that_returns_is_not_restarted(make, device):
    g = make(device, "print('ready 137')\nreturn 137\n")
    g.advance(5)
    assert not g.running()
    assert count(g, "ready 137") == 1
    assert not (g.sandbox / "crash.txt").exists()
    assert emu_error(g) == ""


@pytest.mark.parametrize("device", DEVICES)
def test_the_boots_own_globals_outlive_a_restart(make, device):
    files = {"mod137.lua": "return 137\n"}
    app = ("if not pcall(frame.file.open, 'crash.txt', 'read') then\n"
           "  error('boom 137')\n"
           "end\n"
           "print('ready 137', require('mod137'),\n"
           "      glaz_break('boom'), type(frame), type(string))\n")
    g = make(device, app, files)
    assert "ready 137\t137\tfalse\ttable\ttable" in g.lines


@pytest.mark.parametrize("device", DEVICES)
def test_a_restart_clears_what_the_app_left(make, device):
    g = make(device, CRASH_AT_ONCE, wait_for="app start")
    g.advance(10)
    # every start finds the global unset: the one before was cleared
    assert count(g, "app start\tnil") == 4


@pytest.mark.parametrize("device", DEVICES)
def test_the_screen_says_restarted(make, device):
    # what the crashed app had on screen is gone: only the word is left
    app = ("print('app start')\n"
           "if pcall(frame.file.open, 'crash.txt', 'read') then\n"
           "  print('ready 137')\n"
           "  while true do frame.sleep(1) end\n"
           "end\n"
           "frame.display.text('left 137', 50, 200)\n"
           "if frame.display.show then frame.display.show() end\n"
           "error('boom 137')\n")
    g = make(device, app)
    assert count(g, "app start") == 2
    assert g.screen_text() == "restarted"
    where = {"frame": (50, 65), "halo": (56, 120)}[device]
    assert [(t.x, t.y) for t in g.texts()] == [where]
    g.screenshot("restarted")
    assert g.running()


@pytest.mark.parametrize("device", DEVICES)
def test_crashes_a_minute_apart_restart_for_ever(make, device):
    app = ("print('app start')\n"
           "frame.sleep(25)\n"
           "error('boom 137')\n")
    g = make(device, app, wait_for="app start")
    g.advance(6 * 27)
    assert g.running()
    assert count(g, "glaz app error, restarting") >= 5
    assert count(g, "app start") >= 6


@pytest.mark.parametrize("device", DEVICES)
def test_crashes_within_a_minute_stop_it(make, device):
    app = ("print('app start')\n"
           "frame.sleep(10)\n"
           "error('boom 137')\n")
    g = make(device, app, wait_for="app start")
    g.advance(60)
    assert not g.running()
    assert count(g, "app start") == 4
    assert count(g, "glaz app error, restarting") == 3


@pytest.mark.parametrize("device", DEVICES)
def test_a_crash_with_a_table_restarts_too(make, device):
    app = ("print('app start')\n"
           "if not pcall(frame.file.open, 'crash.txt', 'read') then\n"
           "  error({code = 137})\n"
           "end\n"
           "print('ready 137')\n"
           "while true do frame.sleep(1) end\n")
    g = make(device, app)
    assert "table:" in (g.sandbox / "crash.txt").read_text()
    assert g.running()


@pytest.mark.parametrize("device", DEVICES)
def test_the_hosts_break_is_not_restarted(make, device):
    app = ("print('ready 137')\n"
           "while true do frame.sleep(0.1) end\n")
    g = make(device, app)
    g.emu.break_signal()
    g.advance(2)
    assert not g.running()
    assert count(g, "restarting") == 0
    assert not (g.sandbox / "crash.txt").exists()


@pytest.mark.parametrize("device", DEVICES)
def test_a_break_caught_and_raised_again_is_not_restarted(make, device):
    # an app's pcall that raises the break again, with its own position
    app = ("print('ready 137')\n"
           "local ok, err = pcall(function()\n"
           "  while true do frame.sleep(0.1) end\n"
           "end)\n"
           "error('caught: ' .. tostring(err))\n")
    g = make(device, app)
    g.emu.break_signal()
    g.advance(2)
    assert not g.running()
    assert count(g, "restarting") == 0
    assert not (g.sandbox / "crash.txt").exists()


def test_frame_restart_drops_the_old_callbacks(make):
    app = ("print('app start')\n"
           "if not pcall(frame.file.open, 'crash.txt', 'read') then\n"
           "  frame.imu.tap_callback(function() print('old tap') end)\n"
           "  frame.bluetooth.receive_callback(function(d)\n"
           "    print('old data') end)\n"
           "  error('boom 137')\n"
           "end\n"
           "print('ready 137')\n"
           "while true do frame.sleep(0.1) end\n")
    g = make("frame", app)
    g.emu.tap()
    g.emu.receive(b"\x26\x00\x01\x00")
    g.advance(1)
    assert count(g, "old tap") == 0
    assert count(g, "old data") == 0
    assert g.running()


@pytest.mark.parametrize("device", DEVICES)
def test_after_a_crash_glaz_comes_back_and_works(make, device):
    # glaz itself, behind an app that fails on its first start
    g = make(device, start=False)
    real = (g.sandbox / "glaz_app.lua").read_text()
    (g.sandbox / "real137.lua").write_text(real)
    part = g.sandbox / f"glaz_app.{device}.lua"
    if part.exists():
        part.rename(g.sandbox / f"real137.{device}.lua")
    (g.sandbox / "glaz_app.lua").write_text(
        "if not pcall(frame.file.open, 'crash.txt', 'read') then\n"
        "  error('first start 137')\n"
        "end\n"
        "return require('real137')\n")
    g.start()
    assert count(g, "restarting: ") == 1
    g.set_clock()
    g.advance(4)
    g.tap(2)
    assert "Apps" in g.screen_text()
    assert count(g, "Frame app is running") == 1


# ------------------------------------------------------------- goodnight

def trace_sleep(g, timeout=5.0, step=0.05):
    """From a triple tap until the glasses sleep: (time, eye pixels lit,
    green ones) each step."""
    g.tap(3, settle=0)
    out = []
    waited = 0.0
    while not g.emu.asleep and waited < timeout:
        g.advance(step)
        waited += step
        front = g.emu.display.front
        lit = sum(1 for p in front if p)
        green = sum(1 for p in front if p in GREENS)
        out.append((g.clock.now, lit, green, g.screen_text()))
    return out


def test_frame_blinks_before_deep_sleep(frame):
    frame.advance(4)                             # past the splash
    trace = trace_sleep(frame)
    assert frame.emu.asleep
    assert not frame.emu.display.powered
    eye = [t for t in trace if t[2] > 0]
    assert eye, "the open eye never showed"
    # the open eye first, then less and less of it
    assert eye[0][2] == max(t[2] for t in eye)
    assert eye[-1][2] < eye[0][2]
    # closing and shut: about a second, then sleep
    shown = [t for t in trace if t[1] > 0]
    assert 0.9 <= trace[-1][0] - shown[0][0] <= 1.5
    assert not any("sleeping" in t[3] for t in trace)
    frame.assert_ok()


def test_frame_ends_the_blink_with_the_eye_shut(frame):
    frame.advance(4)
    trace = trace_sleep(frame)
    shut = [t for t in trace if t[1] > 0 and t[2] == 0]
    assert shut, "the shut eye never showed"
    frame.emu.display.powered = True             # to look at the last frame
    frame.screenshot("goodnight")


def test_frame_blink_closes_in_six_steps_in_the_middle(frame):
    frame.advance(4)
    frame.tap(3, settle=0)
    frames = []                      # (lit, green, x0, x1, y0, y1)
    for _ in range(60):
        frame.advance(0.05)
        front = frame.emu.display.front
        on = [i for i, p in enumerate(front) if p]
        if not on:
            if frames:
                break
            continue
        xs, ys = [i % 640 for i in on], [i // 640 for i in on]
        f = (len(on), sum(1 for p in front if p in GREENS),
             min(xs), max(xs), min(ys), max(ys))
        if not frames or frames[-1] != f:
            frames.append(f)
    closing, shut = frames[:-1], frames[-1]
    # six frames, each with less of the eye and its iris than the last
    assert len(closing) == 6, frames
    for a, b in zip(closing, closing[1:]):
        assert b[0] < a[0] and b[1] <= a[1]
    assert shut[1] == 0 and shut[0] < closing[-1][0]
    # in the middle of the 640 x 340 the wearer sees, 8 px a pixel of
    # art: 32 x 20 of it from (192, 90), 0-based (191, 89) here
    for lit, green, x0, x1, y0, y1 in frames:
        assert 191 <= x0 and x1 < 191 + 256 and 89 <= y0 and y1 < 89 + 160
        assert abs((x0 + x1) / 2 - 319.5) <= 1
    assert abs((closing[0][4] + closing[0][5]) / 2 - 169.5) <= 1


def test_frame_says_sleeping_without_the_blink(make):
    g = make("frame", files={"glaz_blink.frame.lua": None},
             wait_for="Frame app is running")
    g.set_clock()
    g.advance(4)
    trace = trace_sleep(g)
    assert g.emu.asleep
    assert any("sleeping..." in t[3] for t in trace)
    assert not any(t[2] for t in trace)


def test_frame_says_sleeping_when_the_blink_fails(make):
    g = make("frame", files={
        "glaz_blink.frame.lua": "return function() error('blink 137') end\n"},
        wait_for="Frame app is running")
    g.set_clock()
    g.advance(4)
    trace = trace_sleep(g)
    assert g.emu.asleep
    assert any("sleeping..." in t[3] for t in trace)
    # about a second of it
    said = [t for t in trace if "sleeping..." in t[3]]
    assert 0.9 <= said[-1][0] - said[0][0] + 0.05 <= 1.5


def test_frame_wakes_after_the_blink(frame):
    frame.advance(4)
    trace_sleep(frame)
    frame.tap(1, settle=2.0)
    assert frame.emu.boots == 2
    assert frame.until("Frame app is running", since=1)
    frame.assert_ok()


def test_halo_has_no_blink_and_says_sleeping(halo):
    halo.advance(4)
    halo.tap(3, settle=0)
    said = False
    for _ in range(40):
        halo.advance(0.05)
        said = said or "sleeping..." in halo.screen_text()
    assert said
    assert halo.running()
    halo.assert_ok()

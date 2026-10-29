"""The services glaz gives the phone and the modules (glaz.lua,
glaz/glaz_host.lua, glaz/glaz_files.lua, glaz/glaz_lua.lua; docs/PROTOCOL.md):
STATUS, the Lua console, browsing the files, a module's HTTP requests and
location, the settings from the phone, the phone's own menus and the
remote's HANDS_OFF lease.

A module's side of the services is seen through a probe: a module of the
test's own in place of Stopwatch, which hands its _M.host to the console
(probe.host) and polls the answers from tick(), as Weather does. A busy
radio is a frame.bluetooth.send of the test's, put in through the console.
"""
import re
import struct

import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, FILE_DATA,
                     FILE_GET, FILES, FILES_GET, Glasses, HANDS_OFF,
                     LOCATION, LOCATION_GET, LUA_EVAL, LUA_RESULT,
                     MENU_CLOSE, MENU_CURSOR, MENU_HIDE, MENU_OPEN, MENU_SELECT, MENU_SET,
                     MENU_SHOW, NET_REQUEST, NET_RESPONSE, SETTINGS_SET,
                     STATUS, STATUS_GET)

PROBE = r"""
local _M = { label = 'Probe', mode = 'app' }

function _M.start() probe = { host = _M.host } end

function _M.tick()
  local p = probe
  if p.req then
    local status, body = p.host.result(p.req)
    if status ~= nil then
      p.last, p.req, p.status, p.body = p.req, nil, status, body
    end
  end
  if p.loc then
    local fix, why = p.host.location(p.loc)
    if fix or why then p.loc, p.fix, p.why = nil, fix, why end
  end
  if p.later and frame.time.utc() >= p.later then   -- when the test says
    p.later = nil
    p.http_id, p.http_err = p.host.http('GET', 'https://example.com/')
    p.loc_id, p.loc_err = p.host.locate()
  end
  if p.say then print(p.say) p.say = nil end
  if p.status then return 'HTTP ' .. p.status end
  if p.fix then return 'at ' .. p.fix.lat .. ' ' .. p.fix.lon end
  if p.why then return 'no place: ' .. p.why end
  return 'waiting'
end

return _M
"""


def with_probe(device, sandbox, open_it=True):
    """glaz with the probe as its Stopwatch, started, the clock set, and the
    probe on screen."""
    g = Glasses(device, sandbox)
    (g.sandbox / "stopwatch.lua").write_text(PROBE)
    g.start()
    g.set_clock()
    if open_it:
        g.open_app("stopwatch")
    return g


@pytest.fixture(params=["frame", "halo"])
def probed(request, tmp_path):
    g = with_probe(request.param, tmp_path / request.param)
    yield g
    g.stop()


_ids = iter(range(10**9))


def lua(g, code: str, settle: float = 0.3) -> str:
    """The phone's Lua console: the answer, '+' or '-' first."""
    ident = next(_ids) % 200 + 1
    g.send(LUA_EVAL, bytes([ident]) + code.encode())
    g.advance(settle)
    answers = [b for i, b in g.joined(LUA_RESULT) if i == ident]
    assert answers, g.lines[-10:]
    return answers[-1].decode("latin-1")


def max_length(g) -> int:
    return int(lua(g, "frame.bluetooth.max_length()")[1:])


def assert_packets(g, code: int, ident: int):
    """A message's packets: none longer than the link carries, more = 1 on
    all but the last."""
    packets = [m for m in g.sent(code) if m[1] == ident]
    assert packets
    assert all(len(m) <= max_length(g) for m in packets)
    assert [m[2] for m in packets] == [1] * (len(packets) - 1) + [0]
    return packets


def response(ident: int, status: int, body: bytes = b"") -> bytes:
    return struct.pack(">BH", ident, status) + body


def fix(ident: int, status: int, lat=0, lon=0, acc=0, age=0) -> bytes:
    return struct.pack(">BBiiHH", ident, status, lat, lon, acc, age)


# ---------------------------------------------------------------- status

def test_status_tells_the_firmware_version(glasses):
    version = lua(glasses, "frame.FIRMWARE_VERSION")[1:].strip('"')
    glasses.clear_sent()
    glasses.send(STATUS_GET, b"\x89")            # whatever the payload
    glasses.advance(0.5)                         # a pass of the loop
    status = glasses.sent(STATUS)
    assert len(status) == 1
    assert status[0][2:].decode() == version
    assert 0 <= status[0][1] <= 100 or status[0][1] == 255
    glasses.assert_ok()


def test_status_is_answered_every_time_it_is_asked(glasses):
    glasses.clear_sent()
    for _ in range(3):
        glasses.send(STATUS_GET, b"\x01")
        glasses.advance(60)
    assert len(glasses.sent(STATUS)) == 3


# ---------------------------------------------------------------- console

def test_the_console_answers_with_the_id_it_was_asked_with(glasses):
    glasses.clear_sent()
    glasses.send(LUA_EVAL, b"\x89return 137")
    glasses.advance(0.3)
    glasses.send(LUA_EVAL, b"\x2areturn 'a'")
    glasses.advance(0.3)
    assert glasses.joined(LUA_RESULT) == [(0x89, b"+137"), (0x2A, b'+"a"')]


def test_a_statement_answers_nothing_and_its_globals_stay(glasses):
    assert lua(glasses, "answer = 100 + 37") == "+"
    assert lua(glasses, "answer") == "+137"
    assert lua(glasses, "") == "+"


def test_prints_come_first_then_every_value(glasses):
    out = lua(glasses, "print('one', 1) print('two') return 137, nil, true")
    assert out == "+one\t1\ntwo\n137\nnil\ntrue"


def test_strings_are_quoted_and_tables_shown_sorted(glasses):
    assert lua(glasses, "'a\\nb'") == '+"a\\\nb"'
    out = lua(glasses, "{ b = 2, a = 'x', t = {}, f = print }")
    assert out == '+{ a = "x", b = 2, f = function, t = {...} }'


def test_a_big_table_shows_its_first_forty_entries(glasses):
    out = lua(glasses, "local t = {} for i = 1, 137 do t[i] = i end return t")
    assert out.endswith(", ... 97 more }")
    assert out.count(" = ") == 40


def test_an_error_answers_with_minus_and_what_was_printed(glasses):
    out = lua(glasses, "print('before') error('boom 137')")
    assert out.startswith("-before\n")
    assert "boom 137" in out
    out = lua(glasses, "x = = 1")
    assert out.startswith("-console:")
    glasses.assert_ok()


def test_prints_go_to_the_log_again_after_an_error(probed):
    assert lua(probed, "print('caught 137') error('y')").startswith(
        "-caught 137\n")
    assert not any("caught 137" in l for l in probed.lines)
    lua(probed, "probe.say = 'to the log 137'")  # printed by the probe
    probed.advance(0.5)
    assert any("to the log 137" in l for l in probed.lines)


def test_a_long_answer_is_cut_at_8_kb_and_sent_in_packets(glasses):
    glasses.clear_sent()
    glasses.send(LUA_EVAL, b"\x07string.rep('x', 13700)")
    glasses.advance(0.5)
    ((ident, out),) = glasses.joined(LUA_RESULT)
    assert ident == 7
    assert out == b'+"' + b"x" * 8191 + b"\n... cut at 8192 bytes"
    assert len(assert_packets(glasses, LUA_RESULT, 7)) > 30
    glasses.assert_ok()


def test_a_request_that_runs_out_of_memory_is_still_answered(frame):
    glasses = frame
    # 137 KB is more than the app has on Frame: Lua's error, and the app
    # goes on (Halo's emulator has no limit)
    glasses.clear_sent()
    glasses.send(LUA_EVAL, b"\x07#string.rep('x', 137 * 1024)")
    glasses.advance(0.5)
    assert glasses.joined(LUA_RESULT) == [(7, b"-not enough memory")]
    glasses.send(LUA_EVAL, b"\x081 + 1")
    glasses.advance(0.5)
    assert glasses.joined(LUA_RESULT)[-1] == (8, b"+2")
    glasses.assert_ok()


def test_an_empty_console_request_is_ignored(glasses):
    glasses.clear_sent()
    glasses.send(LUA_EVAL, b"")
    glasses.advance(0.5)
    assert not glasses.sent(LUA_RESULT)
    glasses.assert_ok()


# ---------------------------------------------------------------- files

def listing(g, path: str, ident: int = 5) -> list[str]:
    g.clear_sent()
    g.send(FILES_GET, bytes([ident]) + path.encode())
    g.advance(0.3)
    ((got, text),) = g.joined(FILES)
    assert got == ident
    return text.decode("latin-1").split("\n")


def test_the_root_lists_the_files_with_their_sizes(glasses):
    (glasses.sandbox / "notes").mkdir()
    lines = listing(glasses, "")
    assert lines[0].startswith("+")
    lines[0] = lines[0][1:]
    size = (glasses.sandbox / "glaz_app.lua").stat().st_size
    assert f"f\t{size}\tglaz_app.lua" in lines
    assert "f\t%d\tmain.lua" % (glasses.sandbox / "main.lua").stat().st_size \
        in lines
    assert "d\tnotes" in lines
    assert not [l for l in lines if l.endswith("\t.") or l.endswith("\t..")]
    assert listing(glasses, "/") == ["+" + lines[0]] + lines[1:]
    assert_packets(glasses, FILES, 5)


def test_frame_ends_the_roots_listing_with_its_free_space(frame):
    lines = listing(frame, "")
    assert re.fullmatch(r"s\t\d+\t176128", lines[-1])   # 43 blocks of 4 KB
    assert [l for l in lines if l.startswith("s\t")] == [lines[-1]]
    (frame.sandbox / "notes").mkdir()
    assert not [l for l in listing(frame, "notes") if l.startswith("s\t")]


def test_halo_has_no_free_space_line(halo):
    assert not [l for l in listing(halo, "") if l.startswith("s\t")]


def test_a_folder_lists_its_own_files(glasses):
    (glasses.sandbox / "notes").mkdir()
    (glasses.sandbox / "notes" / "todo.txt").write_text("x" * 137)
    (glasses.sandbox / "notes" / "old").mkdir()
    lines = listing(glasses, "notes")
    assert lines == ["+d\told", "f\t137\ttodo.txt"]


def test_a_missing_folder_answers_with_why(glasses):
    lines = listing(glasses, "nowhere")
    assert lines[0].startswith("-") and len(lines[0]) > 1
    glasses.assert_ok()


def read(g, path: str, ident: int = 9) -> bytes:
    g.clear_sent()
    g.send(FILE_GET, bytes([ident]) + path.encode())
    g.advance(0.3)
    ((got, data),) = g.joined(FILE_DATA)
    assert got == ident
    return data


def test_a_file_is_read_line_by_line(glasses):
    (glasses.sandbox / "note.txt").write_text("first\n\nthird 137\n")
    assert read(glasses, "note.txt") == b"+first\n\nthird 137\n"
    # the last line comes with a line break, had it one or not
    (glasses.sandbox / "bare.txt").write_text("137")
    assert read(glasses, "bare.txt") == b"+137\n"
    (glasses.sandbox / "empty.txt").write_text("")
    assert read(glasses, "empty.txt") == b"+"


def test_a_file_in_a_folder_is_read_by_its_path(glasses):
    (glasses.sandbox / "notes").mkdir()
    (glasses.sandbox / "notes" / "todo.txt").write_text("buy 137 eggs\n")
    assert read(glasses, "notes/todo.txt") == b"+buy 137 eggs\n"


def test_a_long_file_comes_in_packets(glasses):
    text = "".join(f"line {i:04d} of the file\n" for i in range(137))
    (glasses.sandbox / "long.txt").write_text(text)
    assert read(glasses, "long.txt") == b"+" + text.encode()
    assert len(assert_packets(glasses, FILE_DATA, 9)) > 10


def test_a_file_over_64_kb_is_cut(glasses):
    text = "".join(f"{i:07d}\n" for i in range(10_000))     # 80 KB
    (glasses.sandbox / "big.txt").write_text(text)
    data = read(glasses, "big.txt", ident=137)
    assert data.endswith(b"\n... cut at 65536 bytes\n")
    body = data[1:-len(b"... cut at 65536 bytes\n")]
    assert len(body) <= 65536 and text.encode().startswith(body)
    assert_packets(glasses, FILE_DATA, 137)
    glasses.tap(2)                               # the app goes on
    assert "Apps" in glasses.screen_text()
    glasses.assert_ok()


def test_a_missing_file_answers_with_why(glasses):
    data = read(glasses, "nope.txt")
    assert data.startswith(b"-") and b"nope.txt" in data
    glasses.assert_ok()


def test_a_folder_is_not_a_file(glasses):
    (glasses.sandbox / "notes").mkdir()
    assert read(glasses, "notes").startswith(b"-")
    glasses.assert_ok()


def test_a_line_over_512_bytes_goes_whole(glasses):
    # Frame reads 512 bytes at most (file.c), Halo whole lines: the parts
    # say which (D.read_piece), and on both the text comes out as it is
    text = "x" * 600 + "\n" + "y" * 512 + "\n" + "z" * 1024 + "\nend\n"
    (glasses.sandbox / "wide.txt").write_text(text)
    assert read(glasses, "wide.txt") == b"+" + text.encode()


def test_empty_file_requests_are_ignored(glasses):
    glasses.clear_sent()
    glasses.send(FILES_GET, b"")
    glasses.send(FILE_GET, b"")
    glasses.advance(0.5)
    assert not glasses.sent(FILES) and not glasses.sent(FILE_DATA)
    glasses.assert_ok()


# ---------------------------------------------------------------- internet

def ask(g, method="GET", url="https://wttr.in/?format=%t", body=None):
    """The probe asks; returns the request's id."""
    arg = f", {body!r}" if body is not None else ""
    lua(g, f"probe.req = probe.host.http({method!r}, {url!r}{arg})")
    return int(lua(g, "probe.req")[1:])


def test_a_request_goes_to_the_phone_with_the_modules_name(probed):
    probed.clear_sent()
    ident = ask(probed)
    assert probed.joined(NET_REQUEST) == [
        (ident, b"stopwatch\nGET\nhttps://wttr.in/?format=%t\n")]
    assert "waiting" in probed.screen_text()
    probed.assert_ok()


def test_a_long_post_goes_in_packets(probed):
    probed.clear_sent()
    body = "137," * 150
    ident = ask(probed, "POST", "https://example.com/post", body)
    ((got, payload),) = probed.joined(NET_REQUEST)
    assert got == ident
    assert payload == ("stopwatch\nPOST\nhttps://example.com/post\n"
                       + body).encode()
    assert len(assert_packets(probed, NET_REQUEST, ident)) >= 3


def test_the_answer_reaches_the_module(probed):
    ident = ask(probed)
    probed.send(NET_RESPONSE, response(ident, 200, b"+13 C"))
    probed.advance(0.5)
    assert lua(probed, "probe.status, probe.body") == '+200\n"+13 C"'
    assert "HTTP 200" in probed.screen_text()
    probed.screenshot("services-http")
    probed.assert_ok()


def test_a_long_answer_arrives_whole(probed):
    ident = ask(probed)
    body = b"0123456789abcdefghij" * 190        # 3800 bytes, many writes
    probed.send(NET_RESPONSE, response(ident, 200, body))
    probed.advance(0.5)
    assert lua(probed, "#probe.body") == "+3800"
    assert lua(probed, "probe.body == string.rep('0123456789abcdefghij', "
               "190)") == "+true"


def test_http_errors_reach_the_module_as_they_are(probed):
    ident = ask(probed)
    probed.send(NET_RESPONSE, response(ident, 403, b"not allowed: Glaz > Menu"))
    probed.advance(0.5)
    assert lua(probed, "probe.status, probe.body") == \
        '+403\n"not allowed: Glaz > Menu"'
    ident = ask(probed)
    probed.send(NET_RESPONSE, response(ident, 0, b"no answer"))
    probed.advance(0.5)
    assert lua(probed, "probe.status, probe.body") == '+0\n"no answer"'
    assert "HTTP 0" in probed.screen_text()


def test_an_answer_is_handed_out_once(probed):
    ident = ask(probed)
    probed.send(NET_RESPONSE, response(ident, 200, b"ok"))
    probed.advance(0.5)
    assert lua(probed, "probe.last") == f"+{ident}"
    assert lua(probed, f"probe.host.result({ident})") == \
        '+0\n"unknown request"'


def test_unanswered_a_request_times_out_after_20_s(probed):
    ident = ask(probed)
    probed.advance(19)
    assert lua(probed, "probe.status") == "+nil"
    probed.advance(2)
    assert lua(probed, "probe.status, probe.body") == '+0\n"timeout"'
    # the answer that comes after is dropped
    probed.send(NET_RESPONSE, response(ident, 200, b"late"))
    probed.advance(0.5)
    assert lua(probed, "probe.body") == '+"timeout"'
    probed.assert_ok()


def test_answers_nobody_asked_for_are_dropped(probed):
    ident = ask(probed)
    probed.send(NET_RESPONSE, response((ident + 137) % 256, 200, b"stray"))
    probed.send(NET_RESPONSE, b"\x01\x00")      # too short to be one
    probed.advance(0.5)
    assert lua(probed, "probe.req") == f"+{ident}"   # still pending
    probed.send(NET_RESPONSE, response(ident, 200, b"mine"))
    probed.advance(0.5)
    assert lua(probed, "probe.body") == '+"mine"'
    probed.assert_ok()


def test_request_ids_run_to_255_and_wrap(probed):
    # answered as they go, as the phone does: 260 waiting at once would be
    # more than the app has room for on Frame
    probed.clear_sent()
    for _ in range(5):
        lua(probed, "probe.ids = {} for i = 1, 52 do "
                    "probe.ids[i] = probe.host.http('GET', 'x') end",
            settle=1.0)
        for ident in map(int, lua(probed, "table.concat(probe.ids, ' ')")
                         [2:-1].split()):
            probed.send(NET_RESPONSE, response(ident, 200))
        lua(probed, "for _, id in ipairs(probe.ids) do "
                    "probe.host.result(id) end probe.ids = nil")
    ids = [i for i, _ in probed.joined(NET_REQUEST)]
    assert len(ids) == 260
    start = ids[0]
    assert ids == [(start - 1 + n) % 255 + 1 for n in range(260)]
    assert 0 not in ids


def test_a_stopped_modules_requests_are_dropped(probed):
    ident = ask(probed)
    probed.clear_sent()
    probed.tap(2)                                # back: the probe stops
    assert probed.sent(APP_STOP)
    probed.send(NET_RESPONSE, response(ident, 200, b"too late"))
    probed.open_app("stopwatch")
    assert lua(probed, f"probe.host.result({ident})") == \
        '+0\n"unknown request"'
    probed.assert_ok()


def test_frame_without_a_phone_asks_nothing(tmp_path):
    g = with_probe("frame", tmp_path)
    lua(g, "probe.later = frame.time.utc() + 1", settle=0)
    g.clear_sent()
    g.emu.connected = False
    g.advance(2)
    g.emu.connected = True
    assert lua(g, "probe.http_id, probe.http_err, probe.loc_id, "
               "probe.loc_err") == '+nil\n"no phone"\nnil\n"no phone"'
    assert not g.sent(NET_REQUEST) and not g.sent(LOCATION_GET)
    g.stop()


# ---------------------------------------------------------------- location

def locate(g) -> int:
    lua(g, "probe.loc = probe.host.locate()")
    return int(lua(g, "probe.loc")[1:])


def test_locate_asks_the_phone_with_the_modules_name(probed):
    probed.clear_sent()
    ident = locate(probed)
    assert probed.sent(LOCATION_GET) == [bytes([LOCATION_GET, ident])
                                         + b"stopwatch"]


def test_a_fix_reaches_the_module_in_degrees(probed):
    ident = locate(probed)
    probed.send(LOCATION, fix(ident, 0, 59_437_000, -24_753_600, 137, 7))
    probed.advance(0.5)
    assert lua(probed, "probe.fix.lat, probe.fix.lon, probe.fix.accuracy, "
               "probe.fix.age, probe.why") == \
        "+59.437\n-24.7536\n137\n7\nnil"
    assert "at 59.437" in probed.screen_text()
    probed.screenshot("services-location")


@pytest.mark.parametrize("status, why", [(1, "not allowed"), (2, "no fix"),
                                         (137, "no fix")])
def test_no_fix_says_why(probed, status, why):
    ident = locate(probed)
    probed.send(LOCATION, fix(ident, status))
    probed.advance(0.5)
    assert lua(probed, "probe.fix, probe.why") == f'+nil\n"{why}"'


def test_unanswered_a_location_times_out(probed):
    ident = locate(probed)
    probed.send(LOCATION, fix(ident, 0)[:13])    # one byte short: dropped
    probed.advance(19)
    assert lua(probed, "probe.why") == "+nil"
    probed.advance(2)
    assert lua(probed, "probe.fix, probe.why") == '+nil\n"timeout"'
    probed.send(LOCATION, fix(ident, 0, 1, 1))   # too late
    probed.advance(0.5)
    assert lua(probed, "probe.fix") == "+nil"
    probed.assert_ok()


def test_a_fix_is_handed_out_once(probed):
    ident = locate(probed)
    probed.send(LOCATION, fix(ident, 0, 137, 137))
    probed.advance(0.5)
    assert lua(probed, f"probe.host.location({ident})") == \
        '+nil\n"unknown request"'


# ---------------------------------------------------------------- settings

def setting(g, key, default) -> str:
    return lua(g, f"probe.host.setting({key!r}, {default})")[1:]


def test_a_module_reads_its_own_settings(probed):
    probed.settings({"stopwatch.city": "Tallinn", "weather.city": "Riga",
                     "stopwatch.count": "137", "stopwatch.bad": "abc",
                     "stopwatch.blank": "",
                     "stopwatch.url": "https://x.org/?a=1&b=2"})
    assert setting(probed, "city", "'none'") == '"Tallinn"'
    assert setting(probed, "count", 0) == "137"       # a number, as asked
    assert setting(probed, "count", "''") == '"137"'
    assert setting(probed, "bad", 7) == "7"
    assert setting(probed, "blank", "'dflt'") == '"dflt"'
    assert setting(probed, "url", "''") == '"https://x.org/?a=1&b=2"'
    assert setting(probed, "missing", "'dflt'") == '"dflt"'


def test_settings_are_kept_in_a_file(probed):
    text = "stopwatch.city=Tallinn\nweather.units=m"
    probed.send(SETTINGS_SET, text)
    assert (probed.sandbox / "settings.txt").read_text() == text


def test_each_set_replaces_the_last(probed):
    probed.settings({"stopwatch.city": "Tallinn"})
    probed.settings({"stopwatch.units": "m"})
    assert setting(probed, "city", "'none'") == '"none"'
    assert setting(probed, "units", "''") == '"m"'


def test_lines_that_are_not_settings_are_skipped(probed):
    probed.send(SETTINGS_SET, "garbage\nno_dot=1\nstopwatch.a.b=2\n"
                "stopwatch.ok=137\n\n=3")
    assert setting(probed, "ok", 0) == "137"
    assert setting(probed, "a", "'none'") == '"none"'
    probed.assert_ok()


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_settings_outlive_a_restart(tmp_path, device):
    g = with_probe(device, tmp_path)
    g.settings({"stopwatch.city": "Tallinn"})
    g.stop()
    again = with_probe(device, tmp_path)         # no SETTINGS_SET this time
    assert setting(again, "city", "'none'") == '"Tallinn"'
    again.stop()


def test_the_phones_settings_leave_the_glasses_own_alone(probed):
    lua(probed, "probe.host.set_pref('step', 137)")
    probed.settings({"stopwatch.step": "1"})
    assert lua(probed, "probe.host.pref('step', 0)") == "+137"
    assert "stopwatch.step=137" in (probed.sandbox / "prefs.txt").read_text()
    assert setting(probed, "step", 0) == "1"


# ---------------------------------------------------------------- menus

def test_the_phones_menu_loads_quietly_and_a_double_tap_shows_it(glasses):
    glasses.advance(4)
    glasses.send(MENU_SET, "Coffee\nTea\nWater")
    glasses.advance(0.5)
    assert "Coffee" not in glasses.screen_text()
    glasses.tap(2)
    text = glasses.screen_text()
    assert "> Coffee" in text and "Tea" in text and "Water" in text
    assert "Apps" not in text
    glasses.screenshot("services-host-menu")
    glasses.assert_ok()


def test_picking_a_phones_item_only_tells_the_phone(glasses):
    glasses.send(MENU_SET, "Coffee\nTea\nWater")
    glasses.tap(2)
    glasses.clear_sent()
    glasses.tilt(1)
    assert "> Tea" in glasses.screen_text()
    assert glasses.sent(MENU_CURSOR) == [bytes([MENU_CURSOR, 2])]
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(MENU_SELECT) == [bytes([MENU_SELECT, 2])]
    assert glasses.sent(APP_START) == [bytes([APP_START, 2])]
    assert "(host item)" in glasses.screen_text()
    glasses.assert_ok()


def test_a_new_menu_replaces_the_one_on_screen(glasses):
    glasses.send(MENU_SET, "Coffee\nTea")
    glasses.tap(2)
    glasses.tilt(1)
    glasses.send(MENU_SET, "Black\r\n\r\nGreen\r\n")   # the next level
    glasses.advance(0.3)
    text = glasses.screen_text()
    assert "> Black" in text and "Green" in text and "Tea" not in text
    glasses.tilt(1)
    assert "> Green" in glasses.screen_text()
    glasses.tilt(1)                              # two items: round again
    assert "> Black" in glasses.screen_text()
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(MENU_SELECT) == [bytes([MENU_SELECT, 1])]


def test_the_phones_menu_stops_a_module_in_the_background(glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1)                               # counting
    glasses.tap(2)
    assert glasses.sent(APP_BACKGROUND)
    glasses.clear_sent()
    glasses.send(MENU_SET, "Coffee")
    assert glasses.sent(APP_STOP)
    glasses.advance(1)
    glasses.assert_ok()


def test_with_the_phones_menu_modules_cannot_be_opened(glasses):
    glasses.send(MENU_SET, "Coffee")
    glasses.clear_sent()
    glasses.open_app("stopwatch")
    assert not glasses.sent(APP_START)
    assert "Stopwatch" not in glasses.screen_text()


def test_menu_show_and_hide(glasses):
    glasses.advance(4)
    glasses.clear_sent()
    glasses.send(MENU_SHOW)
    assert "Apps" in glasses.screen_text()
    glasses.send(MENU_SHOW)                      # already up: nothing new
    assert len(glasses.sent(MENU_OPEN)) == 1
    glasses.send(MENU_HIDE)
    assert "Apps" not in glasses.screen_text()
    glasses.send(MENU_HIDE)
    assert len(glasses.sent(MENU_CLOSE)) == 1
    glasses.assert_ok()


def test_menu_show_over_a_module_opens_its_level(glasses):
    glasses.open_app("stopwatch")
    glasses.clear_sent()
    glasses.send(MENU_SHOW)
    text = glasses.screen_text()
    assert "Glaz > Apps" in text and "0:00.0" not in text
    assert glasses.sent(MENU_OPEN)
    glasses.assert_ok()


# ---------------------------------------------------------------- hands off

def hands_off(g, kind: int):
    g.send(HANDS_OFF, bytes([kind]))


def test_with_the_remote_in_front_the_wearers_taps_do_nothing(glasses):
    glasses.tap(2)
    hands_off(glasses, 1)
    glasses.clear_sent()
    glasses.tap(1)
    assert not glasses.sent(MENU_SELECT)
    assert "> Apps" in glasses.screen_text()
    glasses.remote(1, 1)                         # the remote's tap counts
    assert glasses.sent(MENU_SELECT)
    assert "Glaz > Apps" in glasses.screen_text()


def test_with_the_remote_in_front_tilts_do_nothing(glasses):
    glasses.tap(2)
    hands_off(glasses, 1)
    glasses.tilt(1)
    assert "> Apps" in glasses.screen_text()
    glasses.remote(2, 1)
    assert "> Sensors" in glasses.screen_text()


def test_with_the_remote_in_front_a_double_tap_still_opens_the_menu(glasses):
    glasses.advance(4)
    hands_off(glasses, 1)
    glasses.tap(2)
    assert "Apps" in glasses.screen_text()


def test_with_a_keyboard_even_a_blank_screens_taps_do_nothing(glasses):
    glasses.advance(4)
    hands_off(glasses, 2)
    glasses.clear_sent()
    glasses.tap(2)
    assert not glasses.sent(MENU_OPEN)
    assert "Apps" not in glasses.screen_text()


def test_hands_off_0_gives_the_gestures_back(glasses):
    glasses.advance(4)
    hands_off(glasses, 2)
    hands_off(glasses, 0)
    glasses.tap(2)
    assert "Apps" in glasses.screen_text()


def test_hands_off_is_a_lease_the_phone_renews(glasses):
    glasses.advance(4)
    hands_off(glasses, 2)
    glasses.advance(30)
    hands_off(glasses, 2)                        # renewed
    glasses.advance(30)                          # 60 s since the first
    glasses.tap(2)
    assert "Apps" not in glasses.screen_text()
    glasses.advance(41)                          # not renewed: run out
    glasses.tap(2)
    assert "Apps" in glasses.screen_text()
    glasses.assert_ok()


def test_frame_with_a_keyboard_still_sleeps_on_a_triple_tap(frame):
    frame.advance(4)
    hands_off(frame, 2)
    frame.tap(3, settle=3.0)
    frame.advance(2)
    assert frame.emu.asleep


def test_frame_gets_its_gestures_back_when_the_phone_goes(frame):
    frame.advance(4)
    hands_off(frame, 2)
    frame.emu.connected = False
    frame.advance(1)
    frame.tap(2)
    assert "Apps" in frame.screen_text()


# ---------------------------------------------------------------- more
# What the tests above leave out: edges, the radio busy, other modules.

OTHER = r"""
local _M = { label = 'Other', mode = 'app' }
function _M.start() other = _M.host end
function _M.tick() return 'other' end
return _M
"""


@pytest.fixture(params=["frame", "halo"])
def two(request, tmp_path):
    """The probe as Stopwatch and a module of the test's as Battery, whose
    _M.host stays in the global other after it stops."""
    g = Glasses(request.param, tmp_path / request.param)
    (g.sandbox / "stopwatch.lua").write_text(PROBE)
    (g.sandbox / "battery.lua").write_text(OTHER)
    g.start()
    g.set_clock()
    g.open_app("battery")
    g.open_app("stopwatch")
    yield g
    g.stop()


def set_battery(g, level):
    if g.device == "frame":
        g.emu.battery = level
    else:
        g.emu.set_battery_level(level)


def test_status_tells_the_battery_the_top_bar_shows(glasses):
    set_battery(glasses, 37)
    glasses.advance(320)                         # past BATTERY_WINDOW
    glasses.clear_sent()
    glasses.send(STATUS_GET, b"\x00")
    glasses.advance(0.5)                         # a pass of the loop
    assert [m[1] for m in glasses.sent(STATUS)] == [37]


def test_a_code_the_glasses_do_not_know_is_dropped_quietly(glasses):
    glasses.clear_sent()
    glasses.send(0x3F, b"from a newer phone 137")
    glasses.advance(2)
    # data.lua's ack of the packet, and no print to the phone
    assert glasses.sent() == [b"\x00"]
    assert not any("parser" in l for l in glasses.lines)
    glasses.send(STATUS_GET, b"\x00")            # and it still answers
    glasses.advance(0.5)
    assert glasses.sent(STATUS)
    glasses.assert_ok()


def test_prints_of_nil_and_numbers_are_shown_as_text(glasses):
    assert lua(glasses, "print(nil, 137, false)") == "+nil\t137\tfalse"


def test_a_tables_keys_are_sorted_as_text(glasses):
    out = lua(glasses, "local t = {} for i = 1, 11 do t[i] = i * 10 end "
              "return t")
    assert out.startswith("+{ 1 = 10, 10 = 100, 11 = 110, 2 = 20, ")


def test_an_error_that_is_not_a_string_is_shown_too(glasses):
    assert lua(glasses, "error(137)") == "-137"
    assert lua(glasses, "error({})").startswith("-table:")
    assert lua(glasses, "error()") == "-nil"
    glasses.assert_ok()


def test_an_answer_of_exactly_8_kb_is_not_cut(glasses):
    out = lua(glasses, "string.rep('x', 8190)", settle=0.5)  # 8192 quoted
    assert out == '+"' + "x" * 8190 + '"'


def test_an_answer_that_fills_its_packets_has_no_empty_one_after(glasses):
    chunk = max_length(glasses) - 3
    glasses.clear_sent()
    # '+', the quotes and the x's: exactly three packets
    glasses.send(LUA_EVAL, b"\x89string.rep('x', %d)" % (3 * chunk - 3))
    glasses.advance(0.5)
    packets = assert_packets(glasses, LUA_RESULT, 0x89)
    assert [len(p) - 3 for p in packets] == [chunk] * 3


def test_the_hosts_break_stops_lua_that_never_ends(glasses):
    glasses.clear_sent()
    glasses.send(LUA_EVAL, b"\x01while true do frame.sleep(0.1) end")
    glasses.advance(1)
    assert glasses.running()                     # still at it
    glasses.emu.break_signal()
    glasses.advance(2)
    assert not glasses.running()
    assert not glasses.sent(LUA_RESULT)
    assert not any("restarting" in l for l in glasses.lines)


def test_frame_what_the_console_draws_stays_until_the_app_draws(frame):
    frame.tap(2)                                 # the menu up
    lua(frame, "frame.display.text('hello 137', 50, 100) "
        "frame.display.show()")
    frame.advance(2)
    assert frame.screen_text() == "hello 137"
    frame.screenshot("services-console-draws")
    frame.tilt(1)                                # the menu draws again
    assert "hello 137" not in frame.screen_text()
    assert "> Sensors" in frame.screen_text()


def test_an_empty_folder_lists_nothing_in_one_packet(glasses):
    (glasses.sandbox / "empty").mkdir()
    assert listing(glasses, "empty", ident=0) == ["+"]
    assert len(glasses.sent(FILES)) == 1


def test_a_file_is_not_a_folder(glasses):
    (glasses.sandbox / "note.txt").write_text("137\n")
    assert listing(glasses, "note.txt")[0].startswith("-")
    glasses.assert_ok()


def test_a_request_with_only_an_id_lists_the_root(glasses):
    lines = listing(glasses, "", ident=255)
    assert any(l.endswith("\tglaz_app.lua") for l in lines)
    assert read(glasses, "", ident=255).startswith(b"-")
    glasses.assert_ok()


def test_a_file_of_exactly_64_kb_comes_whole(glasses):
    text = "".join(f"{i:07d}\n" for i in range(8192))  # 65536 bytes
    (glasses.sandbox / "full.txt").write_text(text)
    assert read(glasses, "full.txt") == b"+" + text.encode()
    (glasses.sandbox / "over.txt").write_text(text + "x\n")
    assert read(glasses, "over.txt") == \
        b"+" + text.encode() + b"... cut at 65536 bytes\n"


def test_frame_leaves_the_free_space_out_when_the_firmware_cannot_tell(frame):
    lua(frame, "real_space = frame.file.space "
        "frame.file.space = function() error('no 137') end")
    lines = listing(frame, "")
    assert lines[0].startswith("+")
    assert not [l for l in lines if l.startswith("s\t")]
    lua(frame, "frame.file.space = function() return { free = 137 } end")
    assert not [l for l in listing(frame, "") if l.startswith("s\t")]
    lua(frame, "frame.file.space = nil")         # stock firmware
    assert not [l for l in listing(frame, "") if l.startswith("s\t")]
    lua(frame, "frame.file.space = real_space")
    assert listing(frame, "")[-1].startswith("s\t")
    frame.assert_ok()


# The radio busy: frame.bluetooth.send raises for the packets of one code,
# that many times, then works again.
BUSY = r"""
local code, fails = %d, %d
local real = frame.bluetooth.send
frame.bluetooth.send = function(p)
  if string.byte(p, 1) == code and fails > 0 and (not after or sent_one) then
    fails = fails - 1
    if fails == 0 then frame.bluetooth.send = real end
    error('busy')
  end
  if string.byte(p, 1) == code then sent_one = true end
  return real(p)
end
"""


def test_a_packet_is_tried_again_while_the_radio_is_busy(probed):
    lua(probed, BUSY % (NET_REQUEST, 5))
    probed.clear_sent()
    ident = ask(probed)
    assert probed.joined(NET_REQUEST) == [
        (ident, b"stopwatch\nGET\nhttps://wttr.in/?format=%t\n")]
    probed.assert_ok()


def test_a_request_the_radio_never_takes_fails(probed):
    lua(probed, BUSY % (NET_REQUEST, 50))
    # 50 tries, 10 ms apart
    assert lua(probed, "probe.host.http('GET', 'x')", settle=1.0) == \
        '+nil\n"send failed"'
    lua(probed, BUSY % (LOCATION_GET, 50))
    assert lua(probed, "probe.host.locate()", settle=1.0) == \
        '+nil\n"send failed"'
    probed.clear_sent()
    ident = ask(probed)                          # the radio is back
    assert [i for i, _ in probed.joined(NET_REQUEST)] == [ident]
    probed.assert_ok()


def test_a_file_the_radio_stops_taking_is_given_up(glasses):
    text = "".join(f"line {i:04d} of the file\n" for i in range(137))
    (glasses.sandbox / "long.txt").write_text(text)
    # the first packet goes, the next is never taken
    lua(glasses, "after, sent_one = true, false\n" + BUSY % (FILE_DATA, 50))
    glasses.clear_sent()
    glasses.send(FILE_GET, b"\x09long.txt")
    glasses.advance(1)
    packets = glasses.sent(FILE_DATA)
    assert len(packets) == 1 and packets[0][2] == 1   # no last packet
    assert read(glasses, "long.txt") == b"+" + text.encode()  # goes on
    glasses.assert_ok()


def test_an_answer_with_no_body_is_an_empty_one(probed):
    ident = ask(probed)
    probed.send(NET_RESPONSE, response(ident, 204))
    probed.advance(0.5)
    assert lua(probed, "probe.status, probe.body") == '+204\n""'


def test_a_second_answer_to_one_request_is_dropped(probed):
    lua(probed, "probe.x = probe.host.http('GET', 'x')")  # not polled
    ident = int(lua(probed, "probe.x")[1:])
    probed.send(NET_RESPONSE, response(ident, 200, b"first"))
    probed.advance(0.5)
    probed.send(NET_RESPONSE, response(ident, 500, b"second"))
    probed.advance(0.5)
    assert lua(probed, "probe.host.result(probe.x)") == '+200\n"first"'


def test_a_module_cannot_take_another_modules_answers(two):
    ident = ask(two)
    assert lua(two, f"other.result({ident})") == '+0\n"unknown request"'
    loc = locate(two)
    assert lua(two, f"other.location({loc})") == '+nil\n"unknown request"'
    two.send(NET_RESPONSE, response(ident, 200, b"mine"))
    two.advance(0.5)
    two.send(LOCATION, fix(loc, 1))
    two.advance(0.5)
    assert lua(two, "probe.body, probe.why") == '+"mine"\n"not allowed"'
    two.assert_ok()


def test_a_stopped_modules_location_is_dropped(probed):
    ident = locate(probed)
    probed.tap(2)                                # back: the probe stops
    probed.send(LOCATION, fix(ident, 0, 137, 137))
    probed.open_app("stopwatch")
    assert lua(probed, f"probe.host.location({ident})") == \
        '+nil\n"unknown request"'
    probed.assert_ok()


def test_settings_keep_utf8_as_it_is(probed):
    probed.settings({"stopwatch.city": "Минск"})
    assert lua(probed, "#probe.host.setting('city', ''), "
               "utf8.len(probe.host.setting('city', ''))") == "+10\n5"


def test_empty_settings_clear_them_all(probed):
    probed.settings({"stopwatch.city": "Tallinn"})
    probed.send(SETTINGS_SET, b"\n")
    assert setting(probed, "city", "'none'") == '"none"'
    assert (probed.sandbox / "settings.txt").read_text() == "\n"


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_the_glasses_own_settings_outlive_a_restart(tmp_path, device):
    g = with_probe(device, tmp_path)
    lua(g, "probe.host.set_pref('step', 137) probe.host.set_pref('name', 'x')")
    g.stop()
    again = with_probe(device, tmp_path)
    assert lua(again, "probe.host.pref('step', 0), "
               "probe.host.pref('name', 'y')") == '+137\n"x"'
    again.stop()


def test_a_pref_that_is_not_a_number_falls_back(probed):
    lua(probed, "probe.host.set_pref('step', 'abc') "
        "probe.host.set_pref('blank', '')")
    assert lua(probed, "probe.host.pref('step', 137), "
               "probe.host.pref('blank', 'dflt'), "
               "probe.host.pref('missing', 'dflt')") == \
        '+137\n"dflt"\n"dflt"'


def test_the_phones_menu_ends_the_module_on_screen(glasses):
    glasses.open_app("stopwatch")
    assert "Stopwatch" in glasses.screen_text()
    glasses.clear_sent()
    glasses.send(MENU_SET, "Coffee")
    glasses.advance(0.5)
    assert glasses.sent(APP_STOP)
    assert "Stopwatch" not in glasses.screen_text()
    glasses.call("stopwatch", "x")               # nothing to call now
    glasses.advance(0.5)
    assert "Stopwatch" not in glasses.screen_text()
    glasses.assert_ok()


def test_an_empty_menu_from_the_phone_does_no_harm(glasses):
    glasses.send(MENU_SET, "")
    glasses.tap(2)
    glasses.tap(1)
    glasses.tilt(1)
    glasses.tap(2)
    assert glasses.running()
    glasses.assert_ok()


def test_menu_show_sends_a_counting_module_to_the_background(glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1)                               # counting
    glasses.clear_sent()
    glasses.send(MENU_SHOW)
    assert glasses.sent(APP_BACKGROUND) and glasses.sent(MENU_OPEN)
    glasses.send(MENU_HIDE)
    assert glasses.sent(MENU_CLOSE)
    assert glasses.screen_text() == ""           # a blank screen
    glasses.tap(1)                               # the module again
    assert "Stopwatch" in glasses.screen_text()
    assert "0:00.0" not in glasses.screen_text()  # it went on counting
    glasses.assert_ok()


def test_hands_off_keeps_the_wearers_taps_from_a_module(glasses):
    glasses.open_app("stopwatch")
    hands_off(glasses, 1)
    glasses.tap(1)
    glasses.advance(3)
    assert "0:00.0" in glasses.screen_text()     # not started
    glasses.remote(1, 1)                         # the remote's tap is taken
    glasses.advance(3)
    assert "0:00.0" not in glasses.screen_text()
    glasses.assert_ok()


def test_hands_off_keeps_the_wearers_tilts_from_a_module(glasses):
    glasses.open_app("stopwatch")
    glasses.tap(1)
    glasses.advance(3)
    glasses.tap(1)                               # paused, not at zero
    hands_off(glasses, 1)
    glasses.tilt(1)                              # would reset it
    assert "0:00.0" not in glasses.screen_text()
    glasses.remote(2, 1)
    assert "0:00.0" in glasses.screen_text()


def test_with_the_remote_in_front_a_tap_brings_the_last_module_back(glasses):
    glasses.open_app("stopwatch")
    glasses.send(MENU_SHOW)
    glasses.send(MENU_HIDE)                      # a blank screen
    assert "Stopwatch" not in glasses.screen_text()
    hands_off(glasses, 1)
    glasses.tap(1)
    assert "Stopwatch" in glasses.screen_text()


def test_an_empty_hands_off_gives_the_gestures_back(glasses):
    glasses.advance(4)
    hands_off(glasses, 2)
    glasses.send(HANDS_OFF, b"")
    glasses.tap(2)
    assert "Apps" in glasses.screen_text()


def test_frame_with_the_remote_in_front_still_sleeps_on_a_triple_tap(frame):
    frame.advance(4)
    hands_off(frame, 1)
    frame.tap(3, settle=3.0)
    frame.advance(2)
    assert frame.emu.asleep


def test_a_keyboard_shows_in_the_top_bar(glasses):
    glasses.tap(2)                               # the menu, and its top bar
    before = glasses.image()
    hands_off(glasses, 2)
    glasses.advance(2)
    assert glasses.image() != before
    glasses.screenshot("services-keyboard")
    hands_off(glasses, 0)
    glasses.advance(2)
    assert glasses.image() == before

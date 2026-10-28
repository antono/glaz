"""Info > Bluetooth (modules/bluetooth.lua) on each pair of glasses that has
it: the link up or down and for how long, drops since boot, how long ago
the phone was heard and how many messages it sent, the MTU and the MAC;
refreshed while open, closed after APP_TIMEOUT, never in the background."""
import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, LUA_EVAL,
                     LUA_RESULT, MENU_OPEN, STATUS_GET)

pytestmark = pytest.mark.module("bluetooth")


def lines(g):
    """The module's three lines, below the top bar and the title."""
    text = g.screen_text().split("\n")
    first = next(i for i, l in enumerate(text)
                 if l.startswith(("up", "down")))
    return text[first:first + 3]


def test_opens_with_the_link_up(glasses):
    glasses.clear_sent()
    glasses.open_app("bluetooth")
    assert glasses.sent(APP_START)
    up, heard, mac = lines(glasses)
    assert up.startswith("up")
    assert "drops 0" in up
    assert heard.startswith("heard ")
    assert "  in " in heard
    assert mac.startswith("MAC AA:BB:C")     # cut to Halo's round screen
    assert "Bluetooth" in glasses.screen_text()
    glasses.screenshot("bluetooth")
    glasses.assert_ok()


def test_frame_shows_the_mtu_and_the_whole_mac(frame):
    frame.emu.address = "13:37:00:00:01:37"
    frame.open_app("bluetooth")
    up, heard, mac = lines(frame)
    assert heard.endswith("MTU 243")         # 247, less 3 and the flag
    assert mac == "MAC 13:37:00:00:01:37"
    frame.assert_ok()


def test_messages_from_the_phone_are_counted(frame):
    frame.open_app("bluetooth")
    frame.advance(1)
    before = int(lines(frame)[1].split("  in ")[1].split()[0])
    for _ in range(3):
        frame.send(STATUS_GET)
    frame.advance(1)
    after = int(lines(frame)[1].split("  in ")[1].split()[0])
    assert after == before + 3
    frame.assert_ok()


def test_heard_counts_up_until_the_phone_speaks(frame):
    frame.open_app("bluetooth")
    frame.advance(37)
    heard = lines(frame)[1]
    assert heard.startswith(("heard 37s", "heard 38s"))
    frame.send(STATUS_GET)
    frame.advance(1)
    assert lines(frame)[1].startswith(("heard 0s", "heard 1s"))
    frame.assert_ok()


def test_a_drop_shows_down_and_counts(frame):
    frame.open_app("bluetooth")
    frame.emu.connected = False
    frame.advance(5)
    up, heard, _ = lines(frame)
    assert up.startswith("down ")
    assert "drops 1" in up
    assert "MTU" not in heard                # means nothing without a host
    frame.assert_ok()


def test_back_up_it_counts_from_the_reconnect(frame):
    frame.emu.connected = False
    frame.advance(5)
    frame.emu.connected = True
    frame.advance(137)                       # 2m17s up
    frame.open_app("bluetooth")
    up, heard, _ = lines(frame)
    assert up.startswith("up 2m1")           # 2m17s and the open's settle
    assert "drops 1" in up
    assert "MTU 243" in heard
    frame.assert_ok()


def test_hours_up_are_shown_as_hours_and_minutes(frame):
    frame.emu.connected = False
    frame.advance(5)
    frame.emu.connected = True
    frame.advance(2 * 3600 + 17 * 60)
    frame.open_app("bluetooth")
    assert lines(frame)[0].startswith("up 2h17m  drops 1")
    frame.assert_ok()


def lua(g, code):
    """Lua run in the app's globals, as the phone's console sends it."""
    g.send(LUA_EVAL, b"\x01" + code.encode())


def test_heard_long_ago_in_minutes_and_hours(glasses):
    glasses.open_app("bluetooth")
    lua(glasses, "glaz_link.heard = glaz_link.heard - 137")
    glasses.advance(1)
    assert lines(glasses)[1].startswith("heard 2m1")     # 2m17s and on
    # the eval is a message too: heard is now, then two hours back
    lua(glasses, "glaz_link.heard = glaz_link.heard - 2 * 3600")
    glasses.advance(1)
    assert lines(glasses)[1].startswith("heard 2h00m")
    glasses.assert_ok()


def test_before_the_phone_is_heard_heard_is_a_dash(glasses):
    glasses.open_app("bluetooth")
    lua(glasses, "glaz_link.heard = nil; glaz_link.rx = 137")
    glasses.advance(1)
    assert lines(glasses)[1].startswith("heard -  in 1")   # 137, cut on Halo
    glasses.assert_ok()


def test_without_the_link_table_only_the_firmware_is_shown(glasses):
    glasses.open_app("bluetooth")
    lua(glasses, "glaz_link = nil")
    glasses.advance(1)
    up, heard, mac = lines(glasses)
    assert up == "up"
    assert heard.startswith("heard -")
    assert "  in " not in heard
    assert mac.startswith("MAC AA:BB:C")
    glasses.assert_ok()


def test_a_failing_bluetooth_call_reads_as_down(glasses):
    lua(glasses, "frame.bluetooth.is_connected = "
                 "function() error('137') end")
    glasses.open_app("bluetooth")
    up, heard, _ = lines(glasses)
    assert up.startswith("down")
    assert "MTU" not in heard
    glasses.assert_ok()


def test_closes_after_a_minute_alone(glasses):
    glasses.open_app("bluetooth")
    glasses.clear_sent()
    glasses.advance(30)
    assert lines(glasses)[0].startswith("up")
    glasses.advance(40)                      # past APP_TIMEOUT
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)
    assert "MAC" not in glasses.screen_text()
    glasses.assert_ok()


def test_leaving_it_does_not_keep_it_in_the_background(glasses):
    glasses.open_app("bluetooth")
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)
    assert glasses.sent(MENU_OPEN)
    # back in Info, the cursor still on Bluetooth
    assert "> Bluetooth" in glasses.screen_text().split("\n")
    assert "MAC" not in glasses.screen_text()
    glasses.assert_ok()


def test_a_tap_keeps_it_open(glasses):
    glasses.open_app("bluetooth")
    glasses.advance(50)
    glasses.clear_sent()
    glasses.tap(1)                           # nothing of its own to do
    assert not glasses.sent()
    glasses.advance(50)                      # 100 s open, 51 s since the tap
    assert not glasses.sent(APP_STOP)
    assert lines(glasses)[0].startswith("up")
    glasses.advance(15)
    assert glasses.sent(APP_STOP)
    assert "MAC" not in glasses.screen_text()
    glasses.assert_ok()


def test_up_time_is_refreshed_while_open(glasses):
    glasses.advance(60)                      # utc() past 50 on every device
    glasses.open_app("bluetooth")
    lua(glasses, "glaz_link.since = frame.time.utc() - 50")
    glasses.advance(1)
    assert lines(glasses)[0].startswith("up 51s  drops")
    glasses.advance(10)                      # past a minute
    assert lines(glasses)[0].startswith("up 1m0")
    glasses.assert_ok()


def test_without_a_start_time_up_has_no_span(glasses):
    glasses.open_app("bluetooth")
    lua(glasses, "glaz_link.since = 0")
    glasses.advance(1)
    assert lines(glasses)[0] == "up  drops 0"
    glasses.assert_ok()


def test_up_since_boot_is_shown(glasses):
    glasses.advance(137)
    glasses.open_app("bluetooth")
    assert lines(glasses)[0].startswith("up 2m")
    glasses.assert_ok()


def value(g, expr):
    """What the phone's Lua console answers for expr."""
    g.clear_sent()
    lua(g, expr)
    g.advance(0.5)
    (_, answer), = g.joined(LUA_RESULT)
    assert answer[:1] == b"+", answer
    return answer[1:].decode()


def drop(g):
    """The link lost, as the firmware's is_connected() tells it."""
    lua(g, "glaz_bt_was = frame.bluetooth.is_connected; "
           "frame.bluetooth.is_connected = function() return false end")


def back(g):
    lua(g, "frame.bluetooth.is_connected = glaz_bt_was")


def test_a_drop_and_the_way_back_on_every_device(glasses):
    glasses.open_app("bluetooth")
    drop(glasses)
    glasses.advance(5)
    up, heard, _ = lines(glasses)
    assert up.startswith(("down 4s", "down 5s"))
    assert "drops" in up                     # its number cut on Halo
    assert value(glasses, "glaz_link.drops") == "1"
    assert "MTU" not in heard
    glasses.screenshot("bluetooth-down")
    back(glasses)
    glasses.advance(3)
    up, _, _ = lines(glasses)
    assert up.startswith("up ")
    assert up.split()[1] in ("2s", "3s")     # counted from the reconnect
    assert value(glasses, "glaz_link.drops") == "1"
    drop(glasses)
    glasses.advance(1)
    assert lines(glasses)[0].startswith("down")
    assert value(glasses, "glaz_link.drops") == "2"
    glasses.assert_ok()


def test_the_phone_hears_how_long_the_link_was_down(frame):
    frame.emu.connected = False
    frame.advance(37)                        # within LINK_GRACE: no sleep
    frame.emu.connected = True
    frame.advance(1)
    assert not any("link back" in l for l in frame.lines)
    frame.send(STATUS_GET)                   # the phone listens again
    frame.advance(1)
    back = [l for l in frame.lines if l.startswith("link back")]
    assert len(back) == 1
    # down from the loop's first look to its first look back
    assert back[0].startswith(("link back after 36s down, 1 drops",
                               "link back after 37s down, 1 drops"))
    frame.assert_ok()


def test_a_failing_address_or_mtu_leaves_the_rest(glasses):
    lua(glasses, "frame.bluetooth.address = function() error('137') end; "
                 "frame.bluetooth.max_length = function() error('137') end")
    glasses.open_app("bluetooth")
    up, heard, mac = lines(glasses)
    assert up.startswith("up")
    assert heard.startswith("heard ") and "  in " in heard
    assert mac.startswith("MAC ")
    assert "AA:BB" not in mac
    glasses.assert_ok()

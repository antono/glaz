"""Settings > Notifications (modules/notifyset.lua) on each pair of glasses
that has it: tilt picks a setting, a tap its next value, kept at once in
prefs.txt; and what they do to the phone's NOTIFY pop-ups -- off, nothing
covers the screen; on, it stays the seconds picked (docs/PROTOCOL.md,
"Notifications").
"""
import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, HANDS_OFF, NOTIFY,
                     Glasses)

pytestmark = pytest.mark.module("notifyset")

TITLE = "Code 137"       # short enough for Halo's notification rows


def rows(g):
    """The module's own rows: the settings and the hint."""
    return [l for l in g.screen_text().split("\n")
            if "pop-up" in l or "stays" in l or "tap = " in l]


def prefs(g):
    path = g.sandbox / "prefs.txt"
    return set(path.read_text().split("\n")) if path.exists() else set()


def popped(g):
    return TITLE in g.screen_text()


def restarted(g):
    """The same glasses started again, with the files they kept."""
    g.stop()
    again = Glasses(g.device, g.sandbox, files=False)
    again.start()
    again.set_clock()
    return again


@pytest.fixture
def fresh(device, tmp_path):
    """Glasses not yet started, their files uploaded: for a prefs.txt
    written before the start."""
    g = Glasses(device, tmp_path / device)
    yield g
    g.stop()


def start_with(g, lines):
    (g.sandbox / "prefs.txt").write_text("\n".join(lines))
    g.start()
    g.set_clock()
    return g


# ---------------------------------------------------------------- the screen

def test_opens_with_the_defaults(glasses):
    glasses.clear_sent()
    glasses.open_app("notifyset")
    assert glasses.sent(APP_START)
    assert "Notifications" in glasses.screen_text()
    r = rows(glasses)
    assert r[0] == "> pop-up: on"
    assert r[1] == "  stays: 5 s"
    assert r[2].startswith("tap = chang")      # cut on Halo's round screen
    glasses.screenshot("notifyset")
    glasses.assert_ok()


def test_a_tilt_moves_to_the_next_setting_and_wraps(glasses):
    glasses.open_app("notifyset")
    glasses.tilt(1)
    assert rows(glasses)[:2] == ["  pop-up: on", "> stays: 5 s"]
    glasses.tilt(1)                            # past the last, the first
    assert rows(glasses)[:2] == ["> pop-up: on", "  stays: 5 s"]
    glasses.tilt(-1)                           # before the first, the last
    assert rows(glasses)[:2] == ["  pop-up: on", "> stays: 5 s"]
    glasses.tilt(-1)
    assert rows(glasses)[:2] == ["> pop-up: on", "  stays: 5 s"]
    glasses.assert_ok()


def test_a_tap_turns_the_pop_up_off_and_on(glasses):
    glasses.open_app("notifyset")
    glasses.tap(1)
    assert rows(glasses)[0] == "> pop-up: off"
    assert "notifyset.popup=off" in prefs(glasses)
    glasses.screenshot("notifyset-off")
    glasses.tap(1)
    assert rows(glasses)[0] == "> pop-up: on"
    assert "notifyset.popup=on" in prefs(glasses)
    assert rows(glasses)[1] == "  stays: 5 s"  # the other one untouched
    glasses.assert_ok()


def test_taps_go_through_the_seconds_round(glasses):
    glasses.open_app("notifyset")
    glasses.tilt(1)
    seen = []
    for _ in range(4):
        glasses.tap(1)
        seen.append(rows(glasses)[1])
        if len(seen) == 2:
            glasses.screenshot("notifyset-seconds")
    assert seen == ["> stays: 3 s", "> stays: 10 s", "> stays: 20 s",
                    "> stays: 5 s"]
    assert "notifyset.seconds=5" in prefs(glasses)
    assert rows(glasses)[0] == "  pop-up: on"
    glasses.assert_ok()


def test_the_phones_remote_tilts_and_taps_too(glasses):
    glasses.open_app("notifyset")
    glasses.remote(2, 1)                       # next
    glasses.remote(1, 1, settle=1.0)           # one tap
    assert rows(glasses)[1] == "> stays: 3 s"
    glasses.remote(2, 255)                     # previous
    assert rows(glasses)[0] == "> pop-up: on"
    glasses.assert_ok()


def test_the_remotes_up_and_down_move_like_tilts(glasses):
    glasses.open_app("notifyset")
    glasses.remote(3, 1)                       # Down: the next
    assert rows(glasses)[:2] == ["  pop-up: on", "> stays: 5 s"]
    glasses.remote(3, 255)                     # Up: the previous
    assert rows(glasses)[:2] == ["> pop-up: on", "  stays: 5 s"]
    glasses.assert_ok()


def test_hands_off_the_head_does_not_tilt_but_the_remote_does(glasses):
    glasses.open_app("notifyset")
    glasses.send(HANDS_OFF, b"\x01")
    glasses.advance(0.3)
    glasses.tilt(1)
    assert rows(glasses)[0] == "> pop-up: on"
    glasses.remote(2, 1)
    assert rows(glasses)[1] == "> stays: 5 s"
    glasses.assert_ok()


def test_it_stays_open_until_left(glasses):
    glasses.open_app("notifyset")
    glasses.advance(30)
    assert rows(glasses)[0] == "> pop-up: on"
    glasses.assert_ok()


def test_a_call_from_the_phone_changes_nothing(glasses):
    glasses.open_app("notifyset")
    glasses.call("notifyset", "off")           # it has no remote()
    glasses.advance(0.5)
    assert rows(glasses)[:2] == ["> pop-up: on", "  stays: 5 s"]
    assert "notifyset.popup=off" not in prefs(glasses)
    glasses.assert_ok()


def test_left_it_sends_app_stop(glasses):
    glasses.open_app("notifyset")
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_reopened_the_cursor_is_on_the_first_setting(glasses):
    glasses.open_app("notifyset")
    glasses.tilt(1)
    glasses.tap(1)
    glasses.tap(2)                             # back to the menu
    glasses.open_app("notifyset")
    assert rows(glasses)[:2] == ["> pop-up: on", "  stays: 3 s"]
    glasses.assert_ok()


def test_it_does_not_stay_in_the_background(glasses):
    glasses.open_app("notifyset")
    glasses.clear_sent()
    glasses.tap(2)
    assert not glasses.sent(APP_BACKGROUND)
    assert "pop-up" not in glasses.screen_text()
    glasses.assert_ok()


# ---------------------------------------------------------------- kept

def test_what_was_picked_survives_a_restart(glasses):
    glasses.open_app("notifyset")
    glasses.tap(1)                             # off
    glasses.tilt(1)
    glasses.tap(1)
    glasses.tap(1)                             # 10 s
    assert prefs(glasses) >= {"notifyset.popup=off", "notifyset.seconds=10"}
    again = restarted(glasses)
    try:
        again.open_app("notifyset")
        assert rows(again)[:2] == ["> pop-up: off", "  stays: 10 s"]
        again.notify("Mail", TITLE, "off since before")
        again.advance(1)
        assert not popped(again)
        again.assert_ok()
    finally:
        again.stop()


def test_the_phones_settings_leave_them_alone(glasses):
    glasses.open_app("notifyset")
    glasses.tap(1)                             # off
    glasses.settings({"notifyset.popup": "on", "notifyset.seconds": "20",
                      "clock.format": "24"})
    glasses.advance(0.5)
    assert rows(glasses)[:2] == ["> pop-up: off", "  stays: 5 s"]
    assert "notifyset.popup=off" in prefs(glasses)
    glasses.notify("Mail", TITLE, "still off")
    glasses.advance(1)
    assert not popped(glasses)
    glasses.assert_ok()


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_a_value_it_does_not_know_goes_to_the_first(fresh):
    g = start_with(fresh, ["notifyset.popup=yes",
                           "notifyset.seconds=137"])
    g.open_app("notifyset")
    assert rows(g)[0] == "> pop-up: yes"
    assert rows(g)[1].startswith("  stays: 137")   # cut on Halo
    g.tap(1)
    assert rows(g)[0] == "> pop-up: on"
    g.tilt(1)
    g.tap(1)
    assert rows(g)[1] == "> stays: 5 s"
    g.assert_ok()


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_an_empty_value_is_the_default(fresh):
    g = start_with(fresh, ["notifyset.popup=", "notifyset.seconds="])
    g.open_app("notifyset")
    assert rows(g)[:2] == ["> pop-up: on", "  stays: 5 s"]
    g.notify("Mail", TITLE, "shown")
    assert popped(g)
    g.assert_ok()


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_a_change_keeps_the_other_prefs(fresh):
    g = start_with(fresh, ["notifyset.seconds=10", "other.key=137"])
    g.open_app("notifyset")
    g.tap(1)                                   # pop-up off
    assert prefs(g) == {"notifyset.popup=off", "notifyset.seconds=10",
                        "other.key=137"}
    g.assert_ok()


# ---------------------------------------------------------------- pop-ups

def test_by_default_a_notification_stays_five_seconds(glasses):
    glasses.advance(4)                         # the splash gone
    glasses.notify("Mail", TITLE, "hello")
    assert popped(glasses)
    assert "Mail" in glasses.screen_text()
    glasses.screenshot("notification")
    glasses.advance(4.5)
    assert popped(glasses)
    glasses.advance(1)
    assert not popped(glasses)
    glasses.assert_ok()


def test_off_a_notification_does_not_cover_the_screen(glasses):
    glasses.open_app("notifyset")
    glasses.tap(1)
    before = rows(glasses)
    glasses.notify("Mail", TITLE, "unseen")
    glasses.advance(0.5)
    assert not popped(glasses)
    assert rows(glasses) == before
    glasses.tap(1)                             # a tap still reaches the module
    assert rows(glasses)[0] == "> pop-up: on"
    glasses.assert_ok()


def test_off_it_stays_off_in_the_menu_too(glasses):
    glasses.open_app("notifyset")
    glasses.tap(1)
    glasses.tap(2)                             # back to the menu
    menu = glasses.screen_text()
    glasses.notify("Mail", TITLE, "unseen")
    glasses.advance(0.5)
    assert not popped(glasses)
    assert glasses.screen_text() == menu
    glasses.assert_ok()


@pytest.mark.parametrize("taps,seconds", [(1, 3), (2, 10), (3, 20)])
def test_a_notification_stays_the_seconds_picked(glasses, taps, seconds):
    glasses.open_app("notifyset")
    glasses.tilt(1)
    for _ in range(taps):
        glasses.tap(1)
    assert rows(glasses)[1] == f"> stays: {seconds} s"
    glasses.notify("Mail", TITLE, "timed")
    assert popped(glasses)
    glasses.advance(seconds - 0.5)
    assert popped(glasses)
    glasses.advance(1)
    assert not popped(glasses)
    assert rows(glasses)[1] == f"> stays: {seconds} s"   # what it covered
    glasses.assert_ok()


def test_on_again_notifications_pop_up_again(glasses):
    glasses.open_app("notifyset")
    glasses.tap(1)                             # off
    glasses.notify("Mail", TITLE, "unseen")
    glasses.advance(0.5)
    assert not popped(glasses)
    glasses.tap(1)                             # on
    glasses.notify("Mail", TITLE, "seen")
    assert popped(glasses)
    glasses.assert_ok()


def test_a_tap_on_a_notification_does_not_change_a_setting(glasses):
    glasses.open_app("notifyset")
    glasses.notify("Mail", TITLE, "dismiss me")
    assert popped(glasses)
    glasses.tap(1)                             # dismisses it, nothing else
    assert not popped(glasses)
    assert rows(glasses)[0] == "> pop-up: on"
    assert "notifyset.popup=off" not in prefs(glasses)
    glasses.tilt(1)
    assert rows(glasses)[1] == "> stays: 5 s"
    glasses.assert_ok()


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_seconds_it_cannot_read_stay_five(fresh):
    g = start_with(fresh, ["notifyset.seconds=soon"])
    g.advance(4)
    g.notify("Mail", TITLE, "default time")
    g.advance(4.5)
    assert popped(g)
    g.advance(1)
    assert not popped(g)
    g.assert_ok()


@pytest.mark.parametrize("device", ["frame", "halo"])
def test_seconds_it_does_not_offer_still_count(fresh):
    g = start_with(fresh, ["notifyset.seconds=137"])
    g.advance(4)
    g.notify("Mail", TITLE, "long")
    g.advance(136)
    assert popped(g)
    g.advance(2)
    assert not popped(g)
    g.assert_ok()


def test_under_a_notification_a_tilt_does_not_move_the_cursor(glasses):
    glasses.open_app("notifyset")
    glasses.notify("Mail", TITLE, "covering")
    assert popped(glasses)
    glasses.tilt(1)
    glasses.remote(2, 1)
    glasses.remote(3, 1)
    glasses.advance(5)
    assert not popped(glasses)
    assert rows(glasses)[:2] == ["> pop-up: on", "  stays: 5 s"]
    glasses.assert_ok()


def test_a_newer_notification_starts_its_seconds_again(glasses):
    glasses.open_app("notifyset")
    glasses.tilt(1)
    glasses.tap(1)                             # 3 s
    glasses.notify("Mail", "first", "one")
    glasses.advance(2)
    glasses.notify("Mail", TITLE, "two")
    assert "first" not in glasses.screen_text()
    assert popped(glasses)
    glasses.advance(2.5)                       # past the first's 3 s
    assert popped(glasses)
    glasses.advance(1)
    assert not popped(glasses)
    glasses.assert_ok()


def test_seconds_changed_count_for_the_next_notification(glasses):
    glasses.open_app("notifyset")
    glasses.notify("Mail", TITLE, "five")
    glasses.advance(5.5)
    assert not popped(glasses)
    glasses.tilt(1)
    glasses.tap(1)
    glasses.tap(1)                             # 10 s
    glasses.notify("Mail", TITLE, "ten")
    glasses.advance(9.5)
    assert popped(glasses)
    glasses.advance(1)
    assert not popped(glasses)
    glasses.assert_ok()


def test_off_a_malformed_or_proper_notify_leaves_the_screen(glasses):
    glasses.open_app("notifyset")
    glasses.tap(1)                             # off
    before = glasses.screen_text()
    glasses.send(NOTIFY, "no newline")
    glasses.send(NOTIFY, f"Mail\n{TITLE}\ntext")
    glasses.advance(0.5)
    assert glasses.screen_text() == before
    glasses.assert_ok()

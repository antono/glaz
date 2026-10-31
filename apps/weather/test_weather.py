"""Weather (apps/weather/weather.lua) on each pair of glasses that has it: with
no place set it asks the phone where it is (LOCATION_GET) and fetches
wttr.in for 'lat,lon'; refused, without a fix or with no answer it lets
wttr.in go by the phone's IP; a city set on the phone wins and asks for no
position. The request goes out as NET_REQUEST, the answer comes back as
NET_RESPONSE: three lines on success, the status and the body on an
error, a timeout of its own. A tap fetches again; leaving drops it all."""
import struct

import pytest

from glasses import (APP_BACKGROUND, APP_START, APP_STOP, LOCATION,
                     LOCATION_GET, MENU_OPEN, NET_REQUEST, NET_RESPONSE)

pytestmark = pytest.mark.module("weather")

FORMAT = "?format=%l|%t|%C"
BY_IP = "https://wttr.in/" + FORMAT
BERLIN = (52.52, 13.405)
SUNNY = "Berlin, Germany|+13°C|Sunny\n"


# ---------------------------------------------------------------- the phone

def location_asks(g):
    """LOCATION_GET sent: (id, module) each."""
    return [(m[1], m[2:].decode()) for m in g.sent(LOCATION_GET)]


def place(g, lat=BERLIN[0], lon=BERLIN[1], status=0, ident=None):
    """The phone's LOCATION answer to the last LOCATION_GET."""
    if ident is None:
        ident = location_asks(g)[-1][0]
    g.send(LOCATION, struct.pack(">BBiiHH", ident, status,
                                 round(lat * 1e6), round(lon * 1e6), 137, 3))
    g.advance(0.3)


def requests(g):
    """NET_REQUEST sent, put together: (id, [module, method, url, body])."""
    return [(i, p.decode().split("\n", 3)) for i, p in g.joined(NET_REQUEST)]


def url(g):
    return requests(g)[-1][1][2]


def answer(g, body, status=200, ident=None):
    """The phone's NET_RESPONSE to the last request."""
    if ident is None:
        ident = requests(g)[-1][0]
    if isinstance(body, str):
        body = body.encode("utf-8")
    g.send(NET_RESPONSE, struct.pack(">BH", ident, status) + body)
    g.advance(0.3)


def settings(g, lines):
    """Weather's settings from the phone, in before the app opens."""
    g.settings(lines)
    g.advance(0.5)


def opened(g):
    g.clear_sent()
    g.open_app("weather")


def link(g, up):
    """The phone in range or not: frame.bluetooth.is_connected()."""
    if g.device == "frame":
        g.emu.connected = up
    else:
        g.emu._bluetooth._connected = up      # halo-emulator's stub, no API


def lines(g):
    """The module's own lines: below the top bar."""
    return [t.text for t in sorted(g.texts(), key=lambda t: (t.y, t.x))
            if t.y > 60]


# ---------------------------------------------------------------- by position

def test_with_no_place_set_it_asks_where_the_phone_is(glasses):
    opened(glasses)
    assert [m for _, m in location_asks(glasses)] == ["weather"]
    assert not requests(glasses)              # not before the answer
    assert "finding the ph" in glasses.screen_text()
    glasses.screenshot("weather-finding")
    glasses.assert_ok()


def test_a_fix_fetches_the_weather_there(glasses):
    opened(glasses)
    place(glasses)
    [(_, (module, method, where, body))] = requests(glasses)
    assert (module, method, body) == ("weather", "GET", "")
    assert where == "https://wttr.in/52.52,13.40" + FORMAT    # 13.405, 2 places
    assert "asking the pho" in glasses.screen_text()
    glasses.assert_ok()


def test_the_weather_there_is_shown_by_its_numbers(glasses):
    opened(glasses)
    place(glasses)
    answer(glasses, "52.52,13.40|+13°C|Partly cloudy\n")
    text = glasses.screen_text()
    assert "here, 52.52,13" in text           # wttr.in's name is not used
    assert "13" in lines(glasses)[1] and "C" in lines(glasses)[1]
    assert "Partly clou" in text              # the newline is gone
    assert "asking" not in text
    glasses.screenshot("weather")
    glasses.assert_ok()


def test_south_and_west_are_negative(glasses):
    opened(glasses)
    place(glasses, -33.8688, -151.2093)
    assert url(glasses) == "https://wttr.in/-33.87,-151.21" + FORMAT


def test_refused_the_position_it_goes_by_the_ip(glasses):
    opened(glasses)
    place(glasses, 0, 0, status=1)            # not allowed: Glaz > Menu
    assert url(glasses) == BY_IP
    answer(glasses, SUNNY)
    text = glasses.screen_text()
    assert "Berlin, Germ" in text             # wttr.in's name this time
    assert "here" not in text
    assert "Sunny" in text
    glasses.assert_ok()


def test_without_a_fix_it_goes_by_the_ip(glasses):
    opened(glasses)
    place(glasses, 0, 0, status=2)
    assert url(glasses) == BY_IP
    glasses.assert_ok()


def test_with_no_answer_about_the_position_it_goes_by_the_ip(glasses):
    opened(glasses)
    glasses.advance(19)
    assert not requests(glasses)
    assert "finding the ph" in glasses.screen_text()
    glasses.advance(2)                        # past NET_TIMEOUT, 20 s
    assert url(glasses) == BY_IP
    assert "asking the pho" in glasses.screen_text()
    glasses.assert_ok()


def test_a_position_that_comes_too_late_is_dropped(glasses):
    opened(glasses)
    ident = location_asks(glasses)[-1][0]
    glasses.advance(21)
    place(glasses, ident=ident)
    assert [u for _, (_, _, u, _) in requests(glasses)] == [BY_IP]
    glasses.assert_ok()


def test_a_position_for_another_request_is_ignored(glasses):
    opened(glasses)
    ident = location_asks(glasses)[-1][0]
    place(glasses, ident=(ident + 137) % 256)
    assert not requests(glasses)
    assert "finding the ph" in glasses.screen_text()
    glasses.assert_ok()


def test_a_short_location_answer_is_ignored(glasses):
    opened(glasses)
    ident = location_asks(glasses)[-1][0]
    glasses.send(LOCATION, bytes([ident, 0, 1, 2, 3]))
    glasses.advance(0.3)
    assert not requests(glasses)
    place(glasses)                            # the whole one still counts
    assert "52.52,13.40" in url(glasses)
    glasses.assert_ok()


# ---------------------------------------------------------------- a set place

def test_a_city_and_country_set_on_the_phone_win(glasses):
    settings(glasses, {"weather.city": "Berlin", "weather.country": "Germany"})
    opened(glasses)
    assert not location_asks(glasses)
    assert url(glasses) == "https://wttr.in/Berlin,Germany" + FORMAT
    answer(glasses, SUNNY)
    assert "Berlin, Germ" in glasses.screen_text()
    assert "here" not in glasses.screen_text()
    glasses.screenshot("weather-city")
    glasses.assert_ok()


def test_a_city_alone_is_enough(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    assert not location_asks(glasses)
    assert url(glasses) == "https://wttr.in/Berlin" + FORMAT


def test_a_country_alone_is_not_a_place(glasses):
    settings(glasses, {"weather.country": "Germany"})
    opened(glasses)
    assert location_asks(glasses)
    assert not requests(glasses)


def test_the_place_is_percent_encoded(glasses):
    settings(glasses, {"weather.city": "San Francisco",
                      "weather.country": "USA"})
    opened(glasses)
    assert url(glasses) == "https://wttr.in/San%20Francisco,USA" + FORMAT


def test_a_cyrillic_place_is_percent_encoded_byte_by_byte(glasses):
    settings(glasses, {"weather.city": "Минск"})
    opened(glasses)
    assert url(glasses) == (
        "https://wttr.in/%D0%9C%D0%B8%D0%BD%D1%81%D0%BA" + FORMAT)


def test_a_new_setting_counts_from_the_next_fetch(glasses):
    opened(glasses)
    settings(glasses, {"weather.city": "Berlin"})
    glasses.clear_sent()
    glasses.tap(1)
    assert url(glasses) == "https://wttr.in/Berlin" + FORMAT
    assert not location_asks(glasses)
    glasses.assert_ok()


# ---------------------------------------------------------------- errors

def test_not_allowed_the_internet_it_says_so(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, "not allowed: Glaz > Menu", status=403)
    text = glasses.screen_text()
    assert "error 403" in text
    assert "not allowed" in text
    glasses.screenshot("weather-error")
    glasses.assert_ok()


def test_a_network_error_shows_its_reason(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, "no route", status=0)
    assert "error 0" in glasses.screen_text()
    assert "no route" in glasses.screen_text()


def test_a_server_error_with_no_body(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, b"", status=503)
    assert lines(glasses)[0] == "error 503"
    glasses.assert_ok()


def test_with_no_answer_it_times_out(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    glasses.advance(19)
    assert "asking the pho" in glasses.screen_text()
    glasses.advance(2)                        # past NET_TIMEOUT, 20 s
    assert "error 0" in glasses.screen_text()
    assert "timeout" in glasses.screen_text()
    glasses.assert_ok()


def test_an_answer_after_the_timeout_is_dropped(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    glasses.advance(21)
    answer(glasses, SUNNY)
    assert "timeout" in glasses.screen_text()
    assert "Sunny" not in glasses.screen_text()
    glasses.assert_ok()


def test_an_answer_not_in_three_fields_is_shown_as_it_is(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, "Unknown location")
    assert lines(glasses) and lines(glasses)[0].startswith("Unknown loc")
    glasses.assert_ok()


def test_a_short_net_response_is_ignored(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    glasses.send(NET_RESPONSE, bytes([requests(glasses)[-1][0], 0]))
    glasses.advance(0.3)
    assert "asking the pho" in glasses.screen_text()
    answer(glasses, SUNNY)
    assert "Sunny" in glasses.screen_text()
    glasses.assert_ok()


def test_an_answer_for_another_request_is_ignored(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    ident = requests(glasses)[-1][0]
    answer(glasses, SUNNY, ident=(ident + 137) % 256)
    assert "asking the pho" in glasses.screen_text()
    glasses.assert_ok()


def test_without_a_phone_a_tap_says_so(glasses):
    opened(glasses)
    link(glasses, False)
    glasses.clear_sent()
    glasses.tap(1)
    assert not glasses.sent(LOCATION_GET) and not glasses.sent(NET_REQUEST)
    assert lines(glasses) == ["no: no phone"]
    glasses.screenshot("weather-no-phone")
    link(glasses, True)
    glasses.tap(1)                            # back in range: asks again
    assert location_asks(glasses)
    glasses.assert_ok()


def test_with_a_city_set_and_no_phone_it_says_so(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    link(glasses, False)
    glasses.clear_sent()
    glasses.tap(1)
    assert not glasses.sent(LOCATION_GET) and not glasses.sent(NET_REQUEST)
    assert lines(glasses) == ["no: no phone"]
    link(glasses, True)
    glasses.assert_ok()


def test_any_other_location_status_counts_as_no_fix(glasses):
    opened(glasses)
    place(glasses, status=137)
    assert url(glasses) == BY_IP              # not Berlin's numbers
    glasses.assert_ok()


def test_a_fix_on_the_equator_and_meridian(glasses):
    opened(glasses)
    place(glasses, 0, 0)
    assert url(glasses) == "https://wttr.in/0.00,0.00" + FORMAT
    answer(glasses, "0.00,0.00|+28°C|Clear\n")
    assert lines(glasses)[0].startswith("here, 0.00,0.0")  # Halo's is cut


def test_an_empty_answer_shows_nothing(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, b"")
    assert lines(glasses) == []               # not 'asking the phone..'
    glasses.assert_ok()


def test_a_fourth_field_stays_with_the_sky(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, "Berlin|+13°C|Sunny|137\n")
    assert lines(glasses)[0] == "Berlin"
    assert lines(glasses)[2] == "Sunny|137"
    glasses.assert_ok()


def test_trailing_blanks_after_the_sky_are_trimmed(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, "Berlin|+13°C|Sunny \t\r\n")
    assert lines(glasses)[2] == "Sunny"
    glasses.assert_ok()


def test_empty_fields_leave_their_lines_blank(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, "||Fog\n")
    assert lines(glasses) == ["Fog"]          # an empty line draws nothing
    glasses.assert_ok()


# ---------------------------------------------------------------- long lines

def test_long_lines_are_cut_to_26_characters(frame):
    settings(frame, {"weather.city": "Berlin"})
    opened(frame)
    long_place = "Llanfairpwllgwyngyllgogerychwyrndrobwll, Wales"
    answer(frame, f"{long_place}|+13°C|Light rain shower\n")
    first, temp, sky = lines(frame)
    assert first == long_place[:24] + ".."
    assert len(first) == 26
    assert sky == "Light rain shower"
    frame.assert_ok()


def test_cyrillic_is_cut_by_characters_not_bytes(frame):
    settings(frame, {"weather.city": "Berlin"})
    opened(frame)
    city = "Б" * 30                      # 60 bytes, 30 characters
    answer(frame, f"{city}|+13°C|Ясно\n")
    first, _, sky = lines(frame)
    assert first == "Б" * 24 + ".."
    assert sky == "Ясно"
    frame.assert_ok()


def test_a_long_error_body_is_cut(frame):
    settings(frame, {"weather.city": "Berlin"})
    opened(frame)
    answer(frame, "x" * 137, status=500)
    assert lines(frame) == ["error 500", "x" * 24 + ".."]


def test_a_long_odd_answer_is_cut(frame):
    settings(frame, {"weather.city": "Berlin"})
    opened(frame)
    answer(frame, "y" * 137)
    assert lines(frame) == ["y" * 24 + ".."]


def test_a_long_temperature_is_cut(frame):
    settings(frame, {"weather.city": "Berlin"})
    opened(frame)
    answer(frame, "Berlin|" + "+13(" * 10 + "|Sunny\n")
    assert lines(frame)[1] == ("+13(" * 10)[:24] + ".."


def test_exactly_26_characters_are_not_cut(frame):
    settings(frame, {"weather.city": "Berlin"})
    opened(frame)
    answer(frame, "z" * 26)
    assert lines(frame) == ["z" * 26]


def test_a_long_answer_that_is_not_utf8_is_cut_by_bytes(frame):
    settings(frame, {"weather.city": "Berlin"})
    opened(frame)
    answer(frame, b"\xff" * 137, status=500)     # utf8.len() fails
    first, second = lines(frame)
    assert first == "error 500"
    assert second.endswith("..")
    assert len(second.encode("utf-8", "surrogateescape")) < 137
    frame.assert_ok()


# ---------------------------------------------------------------- input

def test_a_tap_fetches_again(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, SUNNY)
    glasses.tap(1)
    assert len(requests(glasses)) == 2
    assert "asking the pho" in glasses.screen_text()
    answer(glasses, "Berlin, Germany|+12°C|Rain\n")
    assert "Rain" in glasses.screen_text()
    glasses.assert_ok()


def test_a_tap_asks_for_the_position_again(glasses):
    opened(glasses)
    place(glasses)
    answer(glasses, "52.52,13.40|+13°C|Sunny\n")
    glasses.tap(1)
    assert len(location_asks(glasses)) == 2
    assert "finding the ph" in glasses.screen_text()
    place(glasses, status=2)                  # no fix this time
    assert url(glasses) == BY_IP
    answer(glasses, SUNNY)
    assert "here" not in glasses.screen_text()   # the old fix is forgotten
    glasses.assert_ok()


def test_the_phones_remote_tap_fetches_again(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, SUNNY)
    glasses.remote(1, 1)
    assert len(requests(glasses)) == 2
    glasses.assert_ok()


def test_an_answer_to_the_request_before_a_tap_is_not_shown(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    old = requests(glasses)[-1][0]
    glasses.tap(1)
    answer(glasses, SUNNY, ident=old)
    assert "asking the pho" in glasses.screen_text()
    answer(glasses, "Berlin, Germany|+12°C|Rain\n")
    assert "Rain" in glasses.screen_text()
    glasses.assert_ok()


def test_a_double_tap_leaves_and_does_not_stay_in_the_background(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)
    glasses.assert_ok()


def test_an_answer_after_leaving_is_dropped_and_it_starts_over(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    glasses.tap(2)
    answer(glasses, SUNNY)
    glasses.assert_ok()
    opened(glasses)
    assert len(requests(glasses)) == 1           # a new request
    assert "asking the pho" in glasses.screen_text()
    assert "Sunny" not in glasses.screen_text()
    glasses.assert_ok()


def test_a_tap_forgets_a_position_still_on_its_way(glasses):
    opened(glasses)                              # finding the phone..
    asked = location_asks(glasses)[-1][0]
    settings(glasses, {"weather.city": "Berlin"})
    glasses.tap(1)                               # by the city now
    place(glasses, ident=asked)                  # the old ask's answer
    assert [u for _, (_, _, u, _) in requests(glasses)] == [
        "https://wttr.in/Berlin" + FORMAT]
    answer(glasses, SUNNY)
    assert "here" not in glasses.screen_text()
    glasses.assert_ok()


def test_a_tap_forgets_a_request_still_on_its_way(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    old = requests(glasses)[-1][0]
    settings(glasses, {})                        # the city cleared
    glasses.tap(1)                               # finding the phone..
    answer(glasses, SUNNY, ident=old)
    assert "finding the ph" in glasses.screen_text()
    assert "Sunny" not in glasses.screen_text()
    glasses.assert_ok()


# ---------------------------------------------------------------- the app

def test_left_alone_a_minute_it_closes(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, SUNNY)                    # an answer is not the wearer
    glasses.advance(55)
    assert "Sunny" in glasses.screen_text() and not glasses.sent(APP_STOP)
    glasses.advance(7)                        # past APP_TIMEOUT, 60 s
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(APP_BACKGROUND)   # _M.background = false
    assert "Sunny" not in glasses.screen_text()
    glasses.assert_ok()


def test_a_tap_keeps_it_open(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    glasses.advance(50)
    glasses.tap(1)
    glasses.advance(50)                       # 100 s open, 50 since the tap
    assert not glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_a_tap_on_the_blank_screen_brings_it_back_fetching(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, SUNNY)
    glasses.advance(62)                       # closed: a blank screen
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(APP_START)
    assert url(glasses) == "https://wttr.in/Berlin" + FORMAT
    assert "asking the pho" in glasses.screen_text()
    glasses.assert_ok()


def test_a_double_tap_opens_the_menu(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    glasses.tap(2)
    assert glasses.sent(MENU_OPEN)
    assert "asking the pho" not in glasses.screen_text()
    glasses.assert_ok()


def test_a_tilt_changes_nothing(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, SUNNY)
    before = lines(glasses)
    glasses.tilt(1)
    glasses.tilt(-1)
    glasses.remote(2, 1)                      # the remote's next, too
    assert lines(glasses) == before
    assert len(requests(glasses)) == 1
    glasses.assert_ok()


def test_opened_again_while_on_screen_it_does_not_fetch_again(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, SUNNY)
    glasses.open_app("weather", "137")        # no remote(): the arg is unused
    assert len(requests(glasses)) == 1
    assert "Sunny" in glasses.screen_text()
    glasses.assert_ok()


def test_the_phone_cannot_call_it(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    glasses.clear_sent()
    glasses.call("weather", "137")            # no remote(): not started
    glasses.advance(1)
    assert not requests(glasses) and not glasses.sent(APP_BACKGROUND)
    opened(glasses)
    glasses.call("weather", "137")            # nor while on screen
    glasses.advance(1)
    assert len(requests(glasses)) == 1
    glasses.assert_ok()


def test_the_weather_arrives_under_a_notification(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    glasses.notify("Chat", "Ann", "137 new messages")
    assert "137 new" in glasses.screen_text()
    answer(glasses, SUNNY)
    glasses.tap(1)                            # dismisses it, fetches nothing
    assert len(requests(glasses)) == 1
    assert "Sunny" in glasses.screen_text()
    glasses.assert_ok()


# ---------------------------------------------------------------- edges

def test_the_same_answer_twice_is_taken_once(glasses):
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    ident = requests(glasses)[-1][0]
    answer(glasses, SUNNY, ident=ident)
    answer(glasses, "Berlin, Germany|+12°C|Rain\n", ident=ident)
    assert "Sunny" in glasses.screen_text()       # the request is done
    assert "Rain" not in glasses.screen_text()
    assert len(requests(glasses)) == 1
    glasses.assert_ok()


def test_the_same_position_twice_fetches_once(glasses):
    opened(glasses)
    ident = location_asks(glasses)[-1][0]
    place(glasses, ident=ident)
    place(glasses, -33.8688, -151.2093, ident=ident)
    assert [u for _, (_, _, u, _) in requests(glasses)] == [
        "https://wttr.in/52.52,13.40" + FORMAT]
    glasses.assert_ok()


@pytest.mark.parametrize("lat, lon, where", [
    (90, 180, "90.00,180.00"),                    # the pole, the date line
    (-90, -180, "-90.00,-180.00"),
])
def test_a_fix_at_the_ends_of_the_globe(glasses, lat, lon, where):
    opened(glasses)
    place(glasses, lat, lon)
    assert url(glasses) == f"https://wttr.in/{where}" + FORMAT
    glasses.assert_ok()


def test_a_frost_below_zero_is_shown(glasses):
    settings(glasses, {"weather.city": "Oslo"})
    opened(glasses)
    answer(glasses, "Oslo, Norway|-13°C|Heavy snow\n")
    assert lines(glasses)[0] == "Oslo, Norway"
    assert lines(glasses)[1].startswith("-13")
    assert lines(glasses)[2] == "Heavy snow"
    glasses.assert_ok()


def test_an_html_error_page_keeps_to_the_modules_rows(glasses):
    # a proxy's 502: lines of HTML, cut to 26 characters, the rest unseen
    settings(glasses, {"weather.city": "Berlin"})
    opened(glasses)
    answer(glasses, "<html>\n<body>\n<h1>502 Bad Gateway</h1>\n"
                    "</body>\n</html>\n", status=502)
    shown = lines(glasses)
    assert shown[0] == "error 502"
    assert len(shown) <= 3
    glasses.assert_ok()


def test_asleep_mid_request_it_wakes_asking_afresh(frame):
    settings(frame, {"weather.city": "Berlin"})
    opened(frame)
    frame.tap(3)                                  # to sleep, still asking
    frame.advance(2)
    assert frame.emu.asleep
    frame.clear_sent()
    frame.tap(1)                                  # a wake is a power-on
    assert frame.until("Frame app is running", 20)
    frame.set_clock()
    frame.advance(2)
    assert url(frame) == "https://wttr.in/Berlin" + FORMAT   # asked again
    assert "asking the pho" in frame.screen_text()
    answer(frame, SUNNY)
    assert "Sunny" in frame.screen_text()
    frame.assert_ok()

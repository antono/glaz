"""Assistant (apps/assistant/assistant.lua) on Frame, the only glasses that have
it: the chats the phone keeps, listed and picked; a tap listens, the
microphone's sound streamed to the phone, the next tap asks; the chat the
phone sends back drawn as a coloured log, four lines at a time, the next
four asked for as the view moves; a double tap drops the question;
what the phone sends that is wrong or comes too late; the phone's remote,
the minute an idle list stays up, a link or microphone that fails
(docs/PROTOCOL.md, "Assistant").
"""
import struct

import pytest

from glasses import APP_START, APP_STOP, INPUT, LUA_EVAL, LUA_RESULT, has_module

pytestmark = pytest.mark.module("assistant")

# Glasses -> phone (apps/assistant/assistant.lua)
ASSIST, AUDIO, AUDIO_END = 0x04, 0x05, 0x06
REC_DROP, REC_START = 0x10, 0x1F

CHATS = "c:7\n9|Weather today\n7|Dinner ideas\n3|Old one"
CHAT = "t:0:2:1\nQ|What is 137 times 2\nA|274"


def assist(op, ident=0, start=0):
    return struct.pack(">BBHH", ASSIST, op, ident, start)   # Lua's >BBI2I2


def window(lines, start=0, busy=0):
    """The chat's lines from line start (0: the newest) as the phone sends
    them (AssistantService.onGlasses): four at most."""
    tail = max(1, len(lines) - 3)
    start = tail if start <= 0 or start > tail else start
    shown = "".join("\n" + l for l in lines[start - 1:start + 3])
    return f"t:{busy}:{len(lines)}:{start}{shown}"


def asked(g):
    """The lines the glasses asked for last (ASSIST op 4), their start."""
    reqs = [m for m in g.sent(ASSIST) if m[1] == 4]
    return struct.unpack(">H", reqs[-1][4:6])[0] if reqs else None


def serve(g, lines, busy=0):
    """The phone answering the window the glasses asked for, if any."""
    start = asked(g)
    if start is not None:
        g.clear_sent()
        g.call("assistant", window(lines, start, busy))


def kb(g):
    """The Lua heap in use, after a full collection, in KB."""
    g.send(LUA_EVAL, b"\x07" + b"collectgarbage('collect') "
           b"print(collectgarbage('count'))")
    g.advance(0.2)
    return float(g.joined(LUA_RESULT)[-1][1].lstrip(b"+").split()[0])


def opened(g, chats=CHATS):
    """Assistant from the menu, the phone's chats on screen."""
    g.open_app("assistant")
    if chats is not None:
        g.call("assistant", chats)
    return g


def listening(g):
    """A new chat, listening: New chat picked, tapped."""
    opened(g, "c:0\n9|Weather today")
    g.tap(1)
    assert "listening" in g.screen_text()
    return g


def color_of(g, text):
    return next(t.color for t in g.texts() if t.text == text)


def lua(g, code):
    """Lua run on the glasses, as the phone's console runs it (LUA_EVAL)."""
    g.clear_sent()
    g.send(LUA_EVAL, b"\x07" + code.encode())
    g.advance(0.2)
    result = g.joined(LUA_RESULT)[-1][1]
    assert result.startswith(b"+"), result


def refuse_sends(g, code):
    """bluetooth.send says 'bluetooth is busy' for packets starting with
    code, as the firmware does when its buffer is full (bluetooth.c), while
    the link stays up."""
    lua(g, "local real = frame.bluetooth.send\n"
           "frame.bluetooth.send = function(d)\n"
           f"  if d:byte(1) == {code} then error('bluetooth is busy') end\n"
           "  return real(d)\n"
           "end")


# ---------------------------------------------------------------- devices

def test_only_frame_has_it():
    assert has_module("frame", "assistant")
    assert not has_module("halo", "assistant")


# ---------------------------------------------------------------- the chats

def test_opens_asking_for_the_chats(glasses):
    glasses.clear_sent()
    glasses.open_app("assistant")
    assert glasses.sent(APP_START)
    assert assist(1) in glasses.sent(ASSIST)
    assert "loading.." in glasses.screen_text()
    glasses.assert_ok()


def test_lists_the_chats_with_the_cursor_on_the_live_one(glasses):
    opened(glasses)
    text = glasses.screen_text()
    for title in ("New chat", "Weather today", "Dinner ideas", "Old one"):
        assert title in text
    assert text.index("New chat") < text.index("Weather today") \
        < text.index("Dinner ideas")
    assert color_of(glasses, "Dinner ideas") == "YELLOW"   # chat 7, live
    assert color_of(glasses, "Weather today") == "WHITE"
    assert color_of(glasses, "New chat") == "GREY"
    cursor = next(t for t in glasses.texts() if t.text == ">")
    row = next(t for t in glasses.texts() if t.text == "Dinner ideas")
    assert cursor.y == row.y
    glasses.screenshot("assistant-chats")
    glasses.assert_ok()


def test_no_live_chat_puts_the_cursor_on_new_chat(glasses):
    opened(glasses, "c:0\n9|Weather today")
    assert color_of(glasses, "New chat") == "YELLOW"
    assert color_of(glasses, "Weather today") == "WHITE"


def test_no_chats_at_all_leaves_only_new_chat(glasses):
    opened(glasses, "c:0")
    assert "New chat" in glasses.screen_text()
    assert color_of(glasses, "New chat") == "YELLOW"
    glasses.assert_ok()


def test_asks_for_the_chats_again_until_they_come(glasses):
    glasses.open_app("assistant")
    glasses.clear_sent()
    glasses.advance(3)
    assert not glasses.sent(ASSIST)
    glasses.advance(3)                           # past RETRY, 5 s
    assert glasses.sent(ASSIST) == [assist(1)]
    glasses.call("assistant", CHATS)
    glasses.clear_sent()
    glasses.advance(13.7)
    assert not glasses.sent(ASSIST)


def test_tilts_move_the_cursor_within_the_list(glasses):
    opened(glasses)                              # on Dinner ideas
    glasses.tilt(1)
    assert color_of(glasses, "Old one") == "YELLOW"
    glasses.tilt(1)                              # the last stays
    assert color_of(glasses, "Old one") == "YELLOW"
    for _ in range(3):
        glasses.tilt(-1)
    assert color_of(glasses, "New chat") == "YELLOW"
    glasses.tilt(-1)                             # the first stays
    assert color_of(glasses, "New chat") == "YELLOW"
    glasses.assert_ok()


def test_a_long_list_scrolls_five_rows_at_a_time(glasses):
    many = "c:0\n" + "\n".join(f"{137 + i}|Chat {i}" for i in range(1, 9))
    opened(glasses, many)
    assert "Chat 4" in glasses.screen_text()
    assert "Chat 5" not in glasses.screen_text()  # New chat and four
    for _ in range(6):
        glasses.tilt(1)
    text = glasses.screen_text()
    assert color_of(glasses, "Chat 6") == "YELLOW"
    assert "Chat 6" in text and "Chat 2" in text
    assert "New chat" not in text and "Chat 1" not in text
    glasses.tilt(-1)
    glasses.tilt(-1)
    glasses.tilt(-1)
    glasses.tilt(-1)
    glasses.tilt(-1)                             # on Chat 1, the first row
    text = glasses.screen_text()
    assert "Chat 1" in text and "New chat" not in text
    glasses.assert_ok()


def test_the_live_chat_far_down_is_scrolled_to(glasses):
    many = "c:144\n" + "\n".join(f"{137 + i}|Chat {i}" for i in range(1, 9))
    opened(glasses, many)
    assert color_of(glasses, "Chat 7") == "YELLOW"
    assert "New chat" not in glasses.screen_text()


def test_tapping_a_chat_asks_the_phone_for_it(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.tap(1)                               # Dinner ideas, id 7
    assert glasses.sent(ASSIST) == [assist(2, 7)]
    assert not glasses.sent(REC_START)
    assert "loading.." in glasses.screen_text()
    glasses.call("assistant", CHAT)
    text = glasses.screen_text()
    assert "What is 137 times 2" in text and "274" in text
    assert "loading.." not in text and "tap = ask" in text
    glasses.assert_ok()


def test_the_next_tap_in_a_chat_listens_in_it(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.call("assistant", CHAT)
    glasses.clear_sent()
    glasses.tap(1)
    assert not glasses.sent(ASSIST)              # no new chat
    assert glasses.sent(REC_START) == [bytes([REC_START, 16, 8, 1])]
    assert "What is 137 times 2" in glasses.screen_text()
    assert "listening" in glasses.screen_text()


def test_a_list_that_comes_while_in_a_chat_is_ignored(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.call("assistant", CHAT)
    glasses.call("assistant", CHATS)
    assert "Weather today" not in glasses.screen_text()
    assert "274" in glasses.screen_text()


def test_loading_is_grey_and_shot(glasses):
    glasses.open_app("assistant")
    assert glasses.screen_text().endswith("loading..")
    assert color_of(glasses, "loading..") == "GREY"
    glasses.screenshot("assistant-loading")


def test_tilts_before_the_chats_came_do_nothing(glasses):
    glasses.open_app("assistant")
    glasses.tilt(1)
    glasses.tilt(-1)
    assert "loading.." in glasses.screen_text()
    glasses.call("assistant", CHATS)
    assert color_of(glasses, "Dinner ideas") == "YELLOW"
    glasses.assert_ok()


def test_a_live_id_not_in_the_list_puts_the_cursor_on_new_chat(glasses):
    opened(glasses, "c:137\n9|Weather today")
    assert color_of(glasses, "New chat") == "YELLOW"


def test_the_phones_remote_moves_and_picks_too(glasses):
    opened(glasses)                              # on Dinner ideas
    glasses.remote(2, 1)                         # next
    assert color_of(glasses, "Old one") == "YELLOW"
    glasses.remote(2, 255)                       # previous
    glasses.remote(2, 255)
    assert color_of(glasses, "Weather today") == "YELLOW"
    glasses.clear_sent()
    glasses.remote(1, 1, settle=1.0)             # a tap
    assert glasses.sent(ASSIST) == [assist(2, 9)]
    glasses.remote(1, 2, settle=1.0)             # a double tap: back
    assert glasses.sent(ASSIST)[-1] == assist(1)
    assert "loading.." in glasses.screen_text()
    glasses.assert_ok()


def test_the_chats_left_alone_close_after_a_minute(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.advance(50)
    assert "Dinner ideas" in glasses.screen_text()
    glasses.advance(13.7)                        # past APP_TIMEOUT, 60 s
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(REC_DROP)
    assert "Dinner ideas" not in glasses.screen_text()
    glasses.assert_ok()


def test_opened_again_it_starts_over(glasses):
    opened(glasses)
    glasses.tap(2)                               # leaves
    glasses.clear_sent()
    glasses.open_app("assistant")
    assert glasses.sent(ASSIST) == [assist(1)]
    text = glasses.screen_text()
    assert "loading.." in text and "Dinner ideas" not in text
    glasses.assert_ok()


def test_a_double_tap_from_the_chats_leaves(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(REC_DROP)
    text = glasses.screen_text()
    assert "Glaz > Apps" in text and "New chat" not in text
    glasses.assert_ok()


# ---------------------------------------------------------------- listening

def test_new_chat_tells_the_phone_and_listens_at_once(glasses):
    opened(glasses, "c:0\n9|Weather today")
    glasses.clear_sent()
    glasses.tap(1)
    sent = glasses.sent()
    assert assist(3) in sent and bytes([REC_START, 16, 8, 1]) in sent
    assert sent.index(assist(3)) < sent.index(bytes([REC_START, 16, 8, 1]))
    assert glasses.emu._mic_on
    assert glasses.emu._mic_fmt == (8000, 16)
    assert "listening 0s  tap = ask" in glasses.screen_text()
    glasses.screenshot("assistant-listening")
    glasses.assert_ok()


def test_the_sound_streams_to_the_phone(glasses):
    listening(glasses)
    sound = bytes(range(256)) * 13 + b"\x01\x37"
    glasses.emu.mic_data.extend(sound)
    glasses.advance(1)
    audio = glasses.sent(AUDIO)
    assert audio
    assert all(len(m) <= 245 and (len(m) - 1) % 2 == 0 for m in audio)
    assert b"".join(m[1:] for m in audio) == sound
    assert not glasses.sent(AUDIO_END)


def test_the_time_listening_counts_up(glasses):
    listening(glasses)
    glasses.advance(13.7)
    assert "listening 13s" in glasses.screen_text() \
        or "listening 14s" in glasses.screen_text()


def test_a_tap_stops_listening_and_asks(glasses):
    listening(glasses)
    glasses.emu.mic_data.extend(b"\x01\x37" * 137)
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent()[-1] == bytes([AUDIO_END])
    assert b"".join(m[1:] for m in glasses.sent(AUDIO)) == b"\x01\x37" * 137
    assert not glasses.emu._mic_on
    assert "thinking.." in glasses.screen_text()
    glasses.screenshot("assistant-thinking")
    glasses.assert_ok()


def test_the_phone_can_stop_it_too(glasses):
    listening(glasses)
    glasses.clear_sent()
    glasses.call("assistant", "stop")
    assert glasses.sent(AUDIO_END)
    assert "thinking.." in glasses.screen_text()
    glasses.call("assistant", "stop")            # not listening: nothing
    assert len(glasses.sent(AUDIO_END)) == 1


def test_eight_bit_sound_when_set(glasses):
    glasses.settings({"assistant.bits": "8"})
    listening(glasses)
    assert glasses.sent(REC_START)[-1] == bytes([REC_START, 8, 8, 1])
    assert glasses.emu._mic_fmt == (8000, 8)


def test_a_bits_setting_that_is_neither_falls_back_to_sixteen(glasses):
    glasses.settings({"assistant.bits": "137"})
    listening(glasses)
    assert glasses.sent(REC_START)[-1] == bytes([REC_START, 16, 8, 1])


def test_stops_by_itself_after_two_minutes(glasses):
    listening(glasses)
    glasses.clear_sent()
    glasses.advance(100)
    assert "listening" in glasses.screen_text()
    assert not glasses.sent(REC_DROP)
    glasses.advance(21)                          # past MAX_LISTEN, 120 s
    assert glasses.sent(AUDIO_END)
    assert not glasses.sent(REC_DROP)
    assert "thinking.." in glasses.screen_text()
    glasses.assert_ok()


def test_the_link_lost_while_listening_stops_it(glasses):
    listening(glasses)
    glasses.emu.connected = False
    glasses.advance(1)
    assert not glasses.emu._mic_on
    assert "no phone" in glasses.screen_text()
    assert "listening" not in glasses.screen_text()
    assert color_of(glasses, "no phone") == "RED"
    glasses.emu.connected = True
    glasses.assert_ok()


def test_without_a_phone_a_tap_says_so(glasses):
    glasses.open_app("assistant")
    glasses.emu.connected = False                # before the chats came
    glasses.advance(1)
    assert "no phone, tap = ask" in glasses.screen_text()
    glasses.screenshot("assistant-no-phone")
    glasses.tap(1)
    assert "no phone" in glasses.screen_text()
    assert not glasses.emu._mic_on
    assert not glasses.sent(REC_START)
    glasses.emu.connected = True
    glasses.assert_ok()


def test_sound_the_link_did_not_take_shows_as_lost(glasses):
    listening(glasses)
    refuse_sends(glasses, AUDIO)
    glasses.emu.mic_data.extend(b"\x01\x37" * 1370)
    glasses.advance(3)
    assert "lost 2K" in glasses.screen_text()
    assert not glasses.sent(AUDIO)
    assert "listening" in glasses.screen_text()   # it goes on all the same
    glasses.screenshot("assistant-lost")
    glasses.assert_ok()


def test_a_long_backlog_of_sound_all_arrives(glasses):
    listening(glasses)
    sound = b"\x01\x37" * 137 * 200              # over 3 s of 16-bit sound
    glasses.emu.mic_data.extend(sound)
    glasses.advance(3)
    assert b"".join(m[1:] for m in glasses.sent(AUDIO)) == sound
    assert "lost" not in glasses.screen_text()


def test_a_microphone_that_does_not_start_says_so(glasses):
    lua(glasses, "frame.microphone.start = function() error('no mic') end")
    opened(glasses, "c:0")
    glasses.clear_sent()
    glasses.tap(1)
    assert not glasses.sent(REC_START)
    assert not glasses.emu._mic_on
    assert "no microphone" in glasses.screen_text()
    assert color_of(glasses, "no microphone") == "RED"
    glasses.screenshot("assistant-no-microphone")
    glasses.tap(2)                               # back: nothing to drop
    assert not glasses.sent(REC_DROP)
    assert "no microphone" not in glasses.screen_text()
    glasses.assert_ok()


def test_a_start_the_phone_did_not_take_stops_the_microphone(glasses):
    opened(glasses, "c:0")
    refuse_sends(glasses, REC_START)
    glasses.tap(1)
    assert not glasses.emu._mic_on
    assert "no microphone" in glasses.screen_text()
    assert "listening" not in glasses.screen_text()
    glasses.assert_ok()


def test_listen_while_listening_starts_over(glasses):
    listening(glasses)
    glasses.advance(13.7)
    glasses.clear_sent()
    glasses.call("assistant", "listen")
    sent = glasses.sent()
    assert sent.index(bytes([AUDIO_END])) \
        < sent.index(bytes([REC_START, 16, 8, 1]))
    assert glasses.emu._mic_on
    assert "listening 0s" in glasses.screen_text()


def test_a_tap_before_the_chats_came_listens_without_a_new_chat(glasses):
    glasses.open_app("assistant")
    glasses.clear_sent()
    glasses.tap(1)
    assert not glasses.sent(ASSIST)              # which chat is the phone's
    assert glasses.sent(REC_START) == [bytes([REC_START, 16, 8, 1])]
    assert "listening" in glasses.screen_text()


# ---------------------------------------------------------------- the chat

def test_a_chat_is_drawn_coloured_by_kind(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.call("assistant", "t:0:4:1\nQ|What do I see\nT|* Took a photo"
                 "\nC|@open weather\nA|A cat, 137 cm away")
    assert color_of(glasses, "What do I see") == "SKYBLUE"
    assert color_of(glasses, "* Took a photo") == "ORANGE"
    assert color_of(glasses, "@open weather") == "GREY"
    assert color_of(glasses, "A cat, 137 cm away") == "WHITE"
    assert "tap = ask" in glasses.screen_text()
    glasses.screenshot("assistant-chat")
    glasses.assert_ok()


def test_busy_shows_thinking_until_the_answer(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.call("assistant", "t:1:1:1\nQ|What is 137 times 2")
    assert "thinking.." in glasses.screen_text()
    glasses.call("assistant", CHAT)
    assert "thinking.." not in glasses.screen_text()
    assert "274" in glasses.screen_text()


def test_cyrillic_text_is_shown(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.call("assistant", "t:0:2:1\nQ|Привет\nA|Здравствуй")
    assert "Привет" in glasses.screen_text()
    assert "Здравствуй" in glasses.screen_text()
    glasses.assert_ok()


def test_a_long_chat_keeps_to_its_end_and_tilts_page_back(glasses):
    listening(glasses)
    glasses.tap(1)
    lines = [f"A|line {i}" for i in range(1, 11)]
    glasses.call("assistant", window(lines))
    text = glasses.screen_text()
    assert "line 10" in text and "line 7" in text and "line 6" not in text
    assert "^" not in text
    glasses.clear_sent()
    glasses.tilt(-1)                             # three rows back
    assert asked(glasses) == 4
    # what it had stays where it is until the rest comes
    assert "line 7" in glasses.screen_text()
    serve(glasses, lines)
    text = glasses.screen_text()
    assert "line 4" in text and "line 7" in text and "line 8" not in text
    assert "tap = ask  ^" in text
    # off the end, a new line does not pull the view along
    lines.append("A|line 11")
    glasses.call("assistant", window(lines, 4))
    assert "line 4" in glasses.screen_text()
    for _ in range(3):
        glasses.tilt(-1)
        serve(glasses, lines)
    assert "line 1" in glasses.screen_text()     # the start stays
    for _ in range(4):
        glasses.tilt(1)
        serve(glasses, lines)
    text = glasses.screen_text()
    assert "line 11" in text and "^" not in text
    assert [m for m in glasses.sent(ASSIST)] == []
    glasses.assert_ok()


def test_holds_only_the_lines_on_screen(glasses):
    """A message of the phone is four lines whatever the chat's length,
    and memory after paging through 137 lines is what it was after
    four."""
    listening(glasses)
    glasses.tap(1)
    lines = [f"{'QA'[i % 2]}|line {i} of a chat long enough" for i in
             range(1, 138)]
    glasses.call("assistant", window(lines[:4]))
    glasses.tilt(-1)                             # the same: nothing asked
    before = kb(glasses)
    glasses.call("assistant", window(lines))
    for _ in range(50):
        glasses.tilt(-1)
        serve(glasses, lines)
    assert "line 1 of" in glasses.screen_text()
    after = kb(glasses)
    assert after - before < 4                    # KB
    glasses.assert_ok()


def test_a_window_for_a_view_since_left_asks_again(glasses):
    listening(glasses)
    glasses.tap(1)
    lines = [f"A|line {i}" for i in range(1, 11)]
    glasses.call("assistant", window(lines))
    glasses.tilt(-1)
    glasses.call("assistant", window(lines))     # the newest: not on screen
    assert "line 4" not in glasses.screen_text()
    glasses.clear_sent()
    glasses.advance(6)                           # past RETRY
    assert asked(glasses) == 4
    serve(glasses, lines)
    assert "line 4" in glasses.screen_text()
    glasses.clear_sent()
    glasses.advance(6)
    assert asked(glasses) is None                # came: not asked again


def test_a_chat_shorter_than_the_view_follows_again(glasses):
    listening(glasses)
    glasses.tap(1)
    lines = [f"A|line {i}" for i in range(1, 11)]
    glasses.call("assistant", window(lines))
    glasses.tilt(-1)
    serve(glasses, lines)
    glasses.call("assistant", window(lines[:2]))
    text = glasses.screen_text()
    assert "line 1" in text and "line 2" in text and "^" not in text


def test_errors_keep_to_the_last_four_lines(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.call("assistant", CHAT)
    glasses.call("assistant", "e:" + "\n".join(
        f"error {i}" for i in range(1, 8)))
    text = glasses.screen_text()
    assert "error 7" in text and "error 4" in text and "error 3" not in text
    assert "274" not in text
    glasses.call("assistant", CHAT)              # the chat again: gone
    assert "error" not in glasses.screen_text()


def test_empty_lines_are_not_drawn(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.call("assistant", "t:0:2:1\nQ|137\nA|")
    assert [t.text for t in glasses.texts() if t.text == ""] == []
    assert "137" in glasses.screen_text()


def test_an_error_shows_in_red_and_stops_listening(glasses):
    listening(glasses)
    glasses.clear_sent()
    glasses.call("assistant", "e:Nothing heard\nHTTP 500")
    assert color_of(glasses, "Nothing heard") == "RED"
    assert color_of(glasses, "HTTP 500") == "RED"
    assert glasses.sent(AUDIO_END)
    assert not glasses.emu._mic_on
    assert "tap = ask" in glasses.screen_text()
    glasses.screenshot("assistant-error")
    glasses.assert_ok()


def test_an_error_after_a_chat_goes_under_it_and_ends_thinking(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.call("assistant", "t:1:1:1\nQ|What is 137 times 2")
    glasses.call("assistant", "e:HTTP 503")
    text = glasses.screen_text()
    assert text.index("What is 137 times 2") < text.index("HTTP 503")
    assert "thinking.." not in text and "tap = ask" in text
    assert color_of(glasses, "What is 137 times 2") == "SKYBLUE"
    assert color_of(glasses, "tap = ask") == "GREY"


def test_the_chat_while_listening_keeps_listening(glasses):
    listening(glasses)
    glasses.call("assistant", "t:0:1:1\nQ|What is 137")
    assert glasses.emu._mic_on
    assert "What is 137" in glasses.screen_text()
    assert "listening" in glasses.screen_text()


def test_tilts_in_a_short_chat_stay_put(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.call("assistant", CHAT)
    glasses.tilt(-1)
    glasses.tilt(1)
    text = glasses.screen_text()
    assert "What is 137 times 2" in text and "274" in text
    assert "^" not in text
    glasses.assert_ok()


def test_a_long_chat_scrolled_back_is_shot(glasses):
    listening(glasses)
    glasses.tap(1)
    chat = [f"{'QA'[i % 2]}|line {i}" for i in range(1, 9)]
    glasses.call("assistant", window(chat))
    glasses.tilt(-1)
    serve(glasses, chat)
    assert "line 2" in glasses.screen_text()
    glasses.screenshot("assistant-scrolled")


def test_loading_is_cleared_by_the_phones_answer(glasses):
    opened(glasses)
    glasses.tap(1)
    glasses.call("assistant", "e:No such chat")
    text = glasses.screen_text()
    assert "loading.." not in text and "No such chat" in text
    assert color_of(glasses, "tap = ask") == "GREY"


def test_the_phone_can_make_it_listen_again(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.call("assistant", CHAT)
    glasses.clear_sent()
    glasses.call("assistant", "listen")
    assert glasses.sent(REC_START)
    assert "listening" in glasses.screen_text()
    assert "274" in glasses.screen_text()


# ---------------------------------------------------------------- going back

def test_a_double_tap_while_listening_drops_the_question(glasses):
    listening(glasses)
    glasses.clear_sent()
    glasses.tap(2)
    sent = glasses.sent()
    assert bytes([REC_DROP]) in sent
    assert bytes([AUDIO_END]) not in sent
    assert assist(1) in sent                     # the chats, asked again
    assert not glasses.emu._mic_on
    assert "loading.." in glasses.screen_text()
    glasses.call("assistant", CHATS)
    assert "Dinner ideas" in glasses.screen_text()
    glasses.assert_ok()


def test_a_double_tap_while_thinking_drops_it_too(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.clear_sent()
    glasses.tap(2)
    assert glasses.sent(REC_DROP)


def test_a_double_tap_from_a_finished_chat_drops_nothing(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.call("assistant", CHAT)
    glasses.clear_sent()
    glasses.tap(2)
    assert not glasses.sent(REC_DROP)
    assert glasses.sent(ASSIST) == [assist(1)]


def test_an_answer_that_comes_after_going_back_is_thrown_away(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.tap(2)
    glasses.call("assistant", CHATS)
    glasses.call("assistant", CHAT)
    glasses.call("assistant", "e:Too late")
    text = glasses.screen_text()
    assert "274" not in text and "Too late" not in text
    assert "Dinner ideas" in text
    glasses.assert_ok()


def test_leaving_while_listening_drops_the_question(glasses):
    listening(glasses)
    glasses.clear_sent()
    glasses.open_app("stopwatch")
    assert glasses.sent(REC_DROP)
    assert not glasses.emu._mic_on
    glasses.assert_ok()


# ---------------------------------------------------------------- opened by the phone

def test_opened_with_an_answer_skips_the_list(glasses):
    glasses.clear_sent()
    glasses.open_app("assistant", CHAT)
    assert not glasses.sent(ASSIST)
    text = glasses.screen_text()
    assert "What is 137 times 2" in text and "274" in text
    assert "New chat" not in text
    glasses.tap(1)                               # asks in the same chat
    assert glasses.sent(REC_START) and not glasses.sent(ASSIST)
    glasses.assert_ok()


def test_opened_to_listen(glasses):
    glasses.open_app("assistant", "listen")
    assert "listening" in glasses.screen_text()
    assert glasses.sent(REC_START)


def test_opened_with_an_error(glasses):
    glasses.open_app("assistant", "e:No agent set")
    assert color_of(glasses, "No agent set") == "RED"
    glasses.tap(2)                               # back to the chats
    assert "loading.." in glasses.screen_text()


def test_opened_with_a_list_shows_an_empty_chat(glasses):
    glasses.open_app("assistant", CHATS)         # the list only for the list
    text = glasses.screen_text()
    assert "Dinner ideas" not in text and "tap = ask" in text
    glasses.assert_ok()


def test_an_answer_opened_while_on_screen_goes_to_the_chat(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.clear_sent()
    glasses.open_app("assistant", CHAT)
    assert not glasses.sent(APP_START)           # not started again
    assert "274" in glasses.screen_text()
    assert "thinking.." not in glasses.screen_text()


def test_not_called_when_not_running(glasses):
    glasses.clear_sent()
    glasses.call("assistant", "listen")          # no background: ignored
    assert not glasses.sent(REC_START)
    assert not glasses.emu._mic_on


# ---------------------------------------------------------------- bad input

@pytest.mark.parametrize("arg", [
    "c:", "c:abc", "c:7\nno bar here", "c:7\n|", "t:", "t:x\nQ|137",
    "t:1\nnot a line", "t:1:2\nQ|137", "t:0:3:137\nQ|137",
    "t:0:0:0", "t:0:1:1\nnot a line", "e:", "zzz", "", ":", "x:137",
])
def test_malformed_arguments_do_no_harm(glasses, arg):
    opened(glasses)
    glasses.call("assistant", arg)
    glasses.tap(1)
    glasses.call("assistant", arg)
    glasses.advance(1)
    assert "Assistant" in glasses.screen_text()
    glasses.assert_ok()


# ---------------------------------------------------------------- memory

def peak_while_streaming(g, seconds):
    """The most Lua heap in use while seconds of sound are sent, above what
    it was before, in KB: each packet should go as it is sent
    (docs/PROTOCOL.md, "Memory on the glasses")."""
    lua(g, "peak = 0\n"
           "local real = frame.bluetooth.send\n"
           "frame.bluetooth.send = function(d)\n"
           "  peak = math.max(peak, collectgarbage('count'))\n"
           "  return real(d)\n"
           "end")
    base = kb(g)
    g.emu.mic_data.extend(b"\x01\x37" * 8000 * seconds)
    g.advance(seconds + 1)
    g.send(LUA_EVAL, b"\x07print(peak)")
    g.advance(0.2)
    return float(g.joined(LUA_RESULT)[-1][1].lstrip(b"+").split()[0]) - base


def test_streamed_sound_is_let_go_of_packet_by_packet(glasses):
    listening(glasses)
    # 4 s is 64 KB: 77 KB at its peak before the steps, 14 KB with them
    assert peak_while_streaming(glasses, 4) < 24     # KB


# ---------------------------------------------------------------- edges

def test_an_answer_that_takes_minutes_is_waited_for(glasses):
    """The agent takes up to 120 s a round: thinking is not being left
    alone, or APP_TIMEOUT would drop the question and the phone throw the
    answer away."""
    listening(glasses)
    glasses.tap(1)
    glasses.clear_sent()
    glasses.advance(137)
    assert not glasses.sent(APP_STOP)
    assert not glasses.sent(REC_DROP)
    assert "thinking.." in glasses.screen_text()
    glasses.call("assistant", CHAT)
    assert "274" in glasses.screen_text()
    glasses.advance(65)                          # answered: idle again
    assert glasses.sent(APP_STOP)
    assert not glasses.sent(REC_DROP)
    glasses.assert_ok()


def test_an_answer_that_never_comes_is_given_up_on(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.clear_sent()
    glasses.advance(350)
    assert not glasses.sent(APP_STOP)
    glasses.advance(75)                          # MAX_THINK, 360 s, then
    assert glasses.sent(APP_STOP)                # APP_TIMEOUT's 60 s
    assert glasses.sent(REC_DROP)
    glasses.assert_ok()


def test_thinking_without_the_phone_closes_after_a_minute(glasses):
    listening(glasses)
    glasses.tap(1)
    glasses.emu.connected = False                # no answer can come now
    glasses.clear_sent()
    glasses.advance(65)
    assert "Weather today" not in glasses.screen_text()
    assert "thinking.." not in glasses.screen_text()
    glasses.emu.connected = True
    glasses.assert_ok()


def test_the_phones_thinking_counts_from_when_it_says_so(glasses):
    glasses.open_app("assistant", "t:1:1:1\nQ|What is 137 times 2")
    glasses.clear_sent()
    glasses.advance(137)
    assert "thinking.." in glasses.screen_text()
    assert not glasses.sent(APP_STOP)
    glasses.assert_ok()


def test_a_tap_while_a_chat_loads_listens_in_it(glasses):
    opened(glasses)
    glasses.tap(1)                               # Dinner ideas, loading
    glasses.clear_sent()
    glasses.tap(1)
    assert not glasses.sent(ASSIST)              # no new chat: the phone's
    assert glasses.sent(REC_START) == [bytes([REC_START, 16, 8, 1])]
    assert "loading.." not in glasses.screen_text()
    glasses.call("assistant", CHAT)              # the chat, late
    assert "274" in glasses.screen_text()
    assert "listening" in glasses.screen_text()
    assert glasses.emu._mic_on
    glasses.assert_ok()


def test_the_highest_chat_id_is_asked_for_whole(glasses):
    opened(glasses, "c:65535\n65535|Chat 65535\n137|Chat 137")
    assert color_of(glasses, "Chat 65535") == "YELLOW"
    glasses.clear_sent()
    glasses.tap(1)
    assert glasses.sent(ASSIST) == [assist(2, 65535)]
    glasses.assert_ok()


def test_a_stop_with_nothing_heard_does_nothing(glasses):
    opened(glasses)
    glasses.clear_sent()
    glasses.call("assistant", "stop")
    assert not glasses.sent(AUDIO_END)
    assert color_of(glasses, "Dinner ideas") == "YELLOW"
    assert "thinking.." not in glasses.screen_text()
    glasses.assert_ok()


def test_a_window_in_cyrillic_split_over_packets(glasses):
    """Four long lines of Cyrillic: Bluetooth cuts them every 200 bytes,
    inside a letter too; the glasses put them together first."""
    listening(glasses)
    glasses.tap(1)
    lines = [f"A|Ответ {i}: всё хорошо, ага" for i in range(137, 155)]
    arg = window(lines)
    # a packet ends inside a letter: the next one starts mid-letter
    raw = b"assistant\n" + arg.encode()         # MODULE_CALL's payload
    assert any(0x80 <= raw[n] < 0xC0 for n in range(200, len(raw), 200))
    glasses.call("assistant", arg)
    rows = [t.text for t in sorted(glasses.texts(), key=lambda t: t.y)
            if t.text.startswith("Ответ")]
    assert rows == [l[2:] for l in lines[-4:]]
    glasses.assert_ok()

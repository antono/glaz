# A Flipper Zero's screen on the glasses

**In plain words:** the Flipper Zero can send a copy of its little screen
over Bluetooth whenever the picture changes. glaz on the phone takes it and
passes it on to the glasses, which show it four times the size, in orange
on black, framed, on the whole screen. You hold the Flipper and press its
buttons as usual; the picture is in front of your eye. The phone connects to the glasses and to the
Flipper at once, so the phone has to be near both.

You need:

- glaz on the phone, connected to the glasses;
- a Flipper Zero with Bluetooth on (**Settings > Bluetooth**, ON), and not
  in its Bluetooth Remote app (Keynote and the rest): that turns the
  Flipper into a keyboard, and a keyboard has no screen to share. Leave it
  with Back held. Nor in the Glaz app (flipper-glaz/, docs/REMOTE.md):
  while it is open the Flipper's own Bluetooth is off. Hold Back to leave
  it too.

## Use

1. On the glasses: **Apps > Flipper**.
2. The first time, the phone pairs with the Flipper: the Flipper shows a
   six-digit PIN, and Android asks for it. Afterwards the phone finds the
   Flipper by itself.
3. Press a button on the Flipper: it sends its screen only when the picture
   changes, so the glasses show nothing until it does. The desktop's
   dolphin animation changes the picture about twice a second by itself.

A double tap closes it, as any app, and the phone lets the Flipper go. A
tap keeps it open; so do frames, but not past five minutes without a tap:
the Flipper's desktop animates by itself, and would keep the display lit
and the glasses from ever sleeping. With the picture standing still, it
closes after a minute as every app does (`APP_TIMEOUT`).

While it is open the glasses do not sleep, as with any app on screen: deep
sleep comes only from the blank screen (docs/PROTOCOL.md).

The phone's side is the **Flipper screen** service (More > Services), on
unless turned off.

## How it works

```
Flipper --BLE, RPC--> phone --BLE, glaz--> glasses
128x64, 1024 bytes    pages to rows,       64 rows of 32 nibbles kept,
on every redraw       rows that changed     each drawn 4x as wide, 4x
           <---------- FLIPPER [2, seq] ---------- taken
```

- `apps/flipper/flipper.lua` sends `FLIPPER` `[1]` from its first tick and `[0]`
  when it stops (`0x0B`, see [PROTOCOL.md](PROTOCOL.md)). Without an answer
  it asks again every 3 s: the phone was away, or the link came back.
- The phone (`flutter-glaz/lib/services/flipper.dart`) connects to the
  Flipper (`lib/flipper/flipper_ble.dart`), starts its screen stream and
  turns each frame into the glasses' rows (`lib/flipper/proto.dart`).
- It sends the rows that changed as `MODULE_CALL` `flipper` with
  `'f' seq mask rows`: a mask of 8 bytes, a bit a row, row 0 the high bit,
  then 32 bytes for each changed row, a nibble a byte (see "Memory and
  the link"). Words instead of a picture ('no Flipper found') go as
  `'s' text`.
- **One frame at a time.** The glasses answer `FLIPPER` `[2, seq]`, and only
  then does the next go: a frame never overwrites one not yet drawn (the
  glasses keep one message per code), and frames the glasses could not keep
  up with are skipped, never queued. No answer within 1.5 s: every row
  again.
- The module draws them through `_M.draw()`, with no top bar
  (`_M.fullscreen`): one `frame.display.bitmap` per non-blank row, 512 wide
  and four pixel rows high, centred in the visible 640x340 -- x 65..576,
  y 43..298. A set bit is palette index 7, ORANGE. Round it, 12 px away, a
  frame 2 px thick in BROWN: six more bitmaps, whole bytes wide, as the
  firmware draws no lines.

## The Flipper's side

Read from qFlipper, the Flipper's Android and iOS apps and its firmware;
tried on a Flipper over USB, and the whole way, Flipper to phone to Frame,
over Bluetooth.

**RPC.** A stream of `PB_Main` messages (flipperzero-protobuf,
`flipper.proto`), each after its length as a varint. Over Bluetooth it
starts by itself once the phone is connected and paired; over USB the CLI
command `start_rpc_session` switches the port to it. The few the mirror
uses are encoded by hand:

| `PB_Main` field | Message | |
| --- | --- | --- |
| 1 | `command_id` | the answer carries the request's; frames come with 0 |
| 2 | `command_status` | 0 = OK |
| 20 | `gui_start_screen_stream_request` | empty |
| 21 | `gui_stop_screen_stream_request` | empty |
| 22 | `gui_screen_frame` | `data` = 1, `orientation` = 2 |
| 23 | `gui_send_input_event_request` | `key` = 1 (UP 0, DOWN 1, RIGHT 2, LEFT 3, OK 4, BACK 5), `type` = 2 (PRESS 0, RELEASE 1, SHORT 2, LONG 3, REPEAT 4) |

`StartScreenStream` with command id 137 is `06 08 89 01 a2 01 00`; a
Flipper answered it `05 08 89 01 22 00` (id 137, OK, empty). A key press is
PRESS, then SHORT or LONG, then RELEASE: the firmware drops events without
a PRESS before them.

**The frame** is 1024 bytes, 128x64 at a bit a pixel, as u8g2 keeps it: in
pages. Byte `(y / 8) * 128 + x` holds 8 pixels down, the top one in the
**low** bit; a set bit is a dark pixel. The glasses' sprites are rows, the
first pixel in the **high** bit, so the phone moves every bit
(`toRows()`). `orientation` 1 is the screen turned round, which `toRows()`
turns back; the upright ones (2, 3) are drawn as the screen has them --
256x512 would not fit.

Frames come when the screen is redrawn, not at a rate; frames made while
one is being sent are merged into the newest. Measured over USB: about two
a second on the desktop's animation. No frame comes on start, only at the
next redraw. While the RPC session is open the Flipper shows an icon for it
in its status bar, in the frames too.

**Bluetooth** (firmware `targets/f7/ble_glue/services/serial_service*`):

| | UUID |
| --- | --- |
| service | `8fe5b3d5-2e7f-4a98-2a48-7acc60fe0000` |
| Flipper to phone, indications | `19ed82ae-ed21-4c9d-4145-228e61fe0000` |
| phone to Flipper, writes | `19ed82ae-ed21-4c9d-4145-228e62fe0000` |
| flow control: room left, big-endian uint32, notified | `19ed82ae-ed21-4c9d-4145-228e63fe0000` |
| RPC status, write 0 to restart | `19ed82ae-ed21-4c9d-4145-228e64fe0000` |

- Every characteristic needs an encrypted, authenticated link: the Flipper
  pairs with a PIN it shows.
- The phone never writes more than the flow-control characteristic says is
  left. The Flipper notifies it full again once its buffer is empty.
- A message the Flipper cannot decode closes the RPC session, and over
  Bluetooth the link with it.

## Trying it without the phone

The Flipper over USB, from a computer: open the port, wait for the CLI's
`>: `, write `start_rpc_session\r`, wait for its echo, then the RPC as
above.

## Memory and the link

Measured on the glasses, a full frame, 64 rows: widened and drawn in 79 ms.
The phone splits each byte into two nibbles, and the module widens a row
with `string.gsub` and a table of 16 entries, in C. Widening in Lua a byte
at a time took 145 ms before drawing; a table for whole bytes, 20 KB of the
30 or so KB the app leaves free (about 135 KB is Lua's in all, the app
takes about 105). The module keeps 64 rows of 32 bytes; a frame's garbage --
the message, its rows, each row widened and repeated four times, about
25 KB -- goes with the full collections `data.lua` makes anyway.

A frame is about 9 packets, so the phone waits for the glasses' answer to
each before the next (docs/PROTOCOL.md, "One packet at a time"); without it
the glasses lost packets while drawing and hung.

## Not done yet

- The glasses do not drive the Flipper: a tilt or a tap could be a key
  (`FlipperMirror.press()` is there for it), but a double tap is always
  back on the glasses.
- The upright orientations are not turned.

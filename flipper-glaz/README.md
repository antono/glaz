# flipper-glaz

**In plain words:** an app for the Flipper Zero that makes it a remote for
the glasses. You hold the Flipper upright, as in its own Keynote Vertical
remote, and press its buttons; instead of the buttons its screen shows the
glasses, their name, how much room is left on them, how much memory, and
which app they are showing. Unlike a plain Bluetooth remote, it will tell
a short press from a long one, and give each its own meaning.

A draft. What is here:

- the screen, upright, 64x128: the glasses drawn as Frame looks from the
  front (the display lit in its lens while connected), their name, Disk,
  Mem and App; top right, a dot while the phone is connected, a ring
  while not, and the LED blue, as in the Flipper's Remote;
- the keys, for now, as the Flipper's Keynote has them (below); the last
  short or long press shows at the bottom and goes to the Flipper's log;
- hold Back to leave, as in the Flipper's own remotes.

## The keys, for now

The Flipper is a Bluetooth keyboard while the app is open, the Keynote of
its Remote app moved to Rust (`src/hid.rs`, `src/main.rs`), and glaz on
the phone takes it as any keyboard (docs/REMOTE.md):

| Flipper | Sends | Glasses |
| --- | --- | --- |
| Up / Down / Left / Right | the arrow, held as long as the key | previous / next item |
| OK | Space, held as long as the key | select; held, the menu |
| Back, short | Backspace, then Android's Back | back |
| Back, long | lets go of every key and leaves | |

It is the same keyboard as the Remote's, to the address, the name
("Control" and the Flipper's name) and the pairing: it keeps its keys in
the Remote's own file, `/ext/apps_data/hid_ble/.bt_hid.keys`. A phone
paired with the Flipper's Remote connects to this app with no new pairing;
otherwise pair as in docs/REMOTE.md, step 2, with this app open instead of
Remote. While the app is open the Flipper's own Bluetooth is off, so the
Flipper's screen on the glasses (docs/FLIPPER.md) waits until it closes.

Until the phone tells of glasses -- and it cannot yet, a keyboard only
sends -- the glasses show as disconnected: "(disconnected)" for the name,
the lens empty, "-" for Disk, Mem and App (`Status::unknown()`).

## Build

Rust for the Flipper, from [flipperzero-rs](https://github.com/flipperzero-rs/flipperzero)
0.16, for Flipper API 88 (firmware 1.5; see "Flipper API"). Its own devenv, apart
from the one at the top of the repo:

```sh
cd flipper-glaz
devenv shell
fap            # target/thumbv7em-none-eabihf/release/flipper-glaz.fap
fap-install    # copy it to the Flipper over USB: Apps > Bluetooth > Glaz
fap-run        # copy and start it, the Flipper's log here
```

`fap-install` and `fap-run` need `flipperzero-tools`; the first time they
`cargo install` it into `.devenv/state`.

## Flipper API

A Flipper runs an app only for its own major API version, and refuses
another with "outdated app" (or "outdated firmware"). flipperzero-rs 0.16
is bound to API 87.1 (firmware 1.3.4 to 1.4.x); firmware 1.5.1, on the
Flipper this was tried on, is 88.2. 88 took away the USB smart card
(CCID) and added to the GUI; every function and value this app imports
is the same in both `api_symbols.csv`, and no header it uses changed its
types. So the app is built with the 87.1 bindings and says 88.0 in its
manifest (`API_VERSION` in `src/main.rs`): it runs on any 88.x, and no
longer on 87. When flipperzero-rs comes out for 88, take it and use
`manifest!` again.

## The link to the phone

The keyboard only sends; what the Flipper shows of the glasses comes from
the phone over the same Bluetooth connection. The app's profile carries,
beside the keyboard, a GATT service of its own (`src/link.rs`):

| | UUID |
| --- | --- |
| service | `a96fe95e-083f-402e-8be1-a9d5235813ca` |
| status, phone to Flipper, written | `99a2eadd-2f24-4073-b412-56fc14ba5ecb` |

glaz on the phone (More > Services > Flipper remote,
`flutter-glaz/lib/services/flipper_remote.dart`) looks, while a keyboard
is attached, among the paired devices named "Control ..." for one with
this service, connects to it as a second client beside Android's own, and
writes the status whenever it changes, and free disk and memory once a
minute. Nothing more to pair, the keys go on as they are.

The status, written whole, in one write (glaz asks for an MTU of 185; a
write in pieces is dropped), at most 64 bytes: a version byte, 1, then
fields as tag, length, value. A field left out is not known; no name, no
glasses connected to the phone: "(disconnected)". Tags not known are
skipped.

| Tag | Value | From |
| --- | --- | --- |
| 1 | the glasses' name, ASCII, at most 23 bytes | the phone's link |
| 2 | free disk, bytes, u32 little-endian | `frame.file.space().free` (glaz firmware) |
| 3 | free memory, bytes, u32 little-endian | 135 KB less `collectgarbage('count')` |
| 4 | the app on the glasses, ASCII, at most 23 bytes | `APP_START` / `APP_STOP` (docs/PROTOCOL.md), "Menu" between |

Free memory is an estimate: Lua's heap on the glasses is about 135 KB in
all (docs/FRAME.md), and the glasses tell only what Lua uses of it.

## Not done yet

- **The commands**: what each key, short and long, sends instead of
  Keynote's keys. They need a way back, Flipper to phone: a second
  characteristic in the glaz service, notified.
- **Versions**: `version` in `Cargo.toml` and `app_version` in the
  manifest.

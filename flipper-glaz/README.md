# flipper-glaz

**In plain words:** an app for the Flipper Zero that makes it a remote for
the glasses. You hold the Flipper upright, as in its own Keynote Vertical
remote, and press its buttons; instead of the buttons its screen shows the
Flipper's dolphin in Frame glasses, then the glasses' name, how much room
is left on them, how much memory, and which app they are showing. Unlike
a plain Bluetooth remote, it will tell a short press from a long one,
and give each its own meaning. It is no keyboard to the phone: the
phone's on-screen keyboard stays, and its presses reach glaz and no
other app.

A draft. What is here:

- the screen, upright, 64x128: the Flipper's dolphin in round Frame
  glasses (the display lit in a lens while glasses are connected), under
  it their name, Storage and Mem, and the app on the glasses on the last
  line; top right, a dot while the phone is connected, a ring while not,
  and the LED blue, as in the Flipper's Remote;
- every press sent to the phone (below), short, long or repeated, and
  to the Flipper's log;
- hold Back to leave, as in the Flipper's own remotes.

## The keys

The Flipper is no Bluetooth keyboard (`src/ble.rs`): it sends each press
over its own service to glaz on the phone (below, "The link to the
phone"), and Android, seeing no keyboard, keeps its on-screen one and
gives the presses to no other app. What a press does is glaz's to say
(`flutter-glaz/lib/flipper/presses.dart`); `utils/flipper_keys.py` prints
them on a computer.

| Flipper | Sends |
| --- | --- |
| Up / Down / Left / Right / OK | short, long and repeated presses |
| Back, short | a short press |
| Back, long | nothing: leaves, as in the Flipper's own remotes |

A long press comes about 0.5 s into holding a key, and then no short one;
held on, the key repeats until let go.

It pairs on its own, apart from the Flipper and its Remote: as "Glaz",
no more, for the advertisement to hold the service's 128-bit UUID ("Glaz"
and the Flipper's name, cut to 8, did not fit), at an address of its own (the Flipper's, third
byte two up), with its keys in `/ext/apps_data/glaz/.bt.keys`. The
first time the phone writes to it, both sides show a PIN to confirm.
While the app is open the Flipper's own Bluetooth is off, so the
Flipper's screen on the glasses (docs/FLIPPER.md) waits until it closes.

Until the phone tells of glasses, the glasses show as disconnected:
"(disconnected)" for the name, the lens empty, "-" for Storage, Mem and
the app (`Status::unknown()`).

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

The app's profile carries one GATT service, its own (`src/link.rs`),
advertised so the phone finds it by its UUID:

| | UUID |
| --- | --- |
| service | `a96fe95e-083f-402e-8be1-a9d5235813ca` |
| status, phone to Flipper, written | `99a2eadd-2f24-4073-b412-56fc14ba5ecb` |
| keys, Flipper to phone, notified | `fdf4c755-bc63-4750-9c39-e6ee8b8f55e9` |

A press, notified while the phone listens, is 3 bytes: a version byte,
1, the key (1 Up, 2 Down, 3 Left, 4 Right, 5 OK, 6 Back) and the press
(1 short, 2 long, 3 repeat).

glaz on the phone (More > Services > Flipper remote,
`flutter-glaz/lib/services/flipper_remote.dart`) pairs it there, with
**Pair Flipper**: Android's list of companion devices, filtered by the
service's UUID, then the PIN. No pairing in Android's Bluetooth settings
and no accessibility service is needed. On Android 12 and later glaz
then need not be open: the Companion Device Manager starts it when this
app is open nearby, and glaz holds the link with a notification of its
own (docs/REMOTE.md, "The Glaz app on the Flipper"). iOS and desktop
have no such thing, nor has Android before 12: there glaz finds the
Flipper only while it runs (on iOS and desktop by a scan, while the
glasses are connected). After a force stop in Android's settings,
Android starts glaz for the Flipper again only once glaz has been opened
by hand. `utils/flipper_keys.py` writes a status from a computer.

After a failed or cancelled pairing the Flipper's firmware may keep its
PIN dialog on screen: press Back, or close and reopen Glaz, before
pairing again.

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

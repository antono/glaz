# Driving the glasses with a remote

Frame has no buttons: you tap the arm and tilt your head. A small remote
in your hand, like a presentation clicker, is often easier. The glasses
cannot pair with a remote themselves. The **phone** does: you connect the
remote to the phone like any Bluetooth keyboard, and glaz passes its keys
on to the glasses. A [Flipper Zero](https://flipperzero.one) works well as
that remote, two ways: as a keyboard, in its own Remote app (step 2), or
with the Glaz app on it, which is no keyboard, shows the glasses on the
Flipper's screen and wakes glaz by itself ("The Glaz app on the Flipper").

You need:

- glaz on the phone, connected to the glasses;
- a remote that shows up as a keyboard (HID): a Bluetooth or USB keyboard,
  a presentation clicker, a gamepad, or a Flipper Zero in its Remote app;
- or a Flipper Zero with the Glaz app (`flipper-glaz/`), which needs none
  of steps 1 and 2.

## How it works

The remote sends ordinary key presses to the phone. glaz's **Keyboard
remote** service (`flutter-glaz/lib/services/keys.dart`) turns the keys it
knows into the same `INPUT` messages the Remote tab sends, and the glasses
take them as the wearer's own gestures (docs/PROTOCOL.md, "Remote"):

| Keys | Glasses | `INPUT` |
| --- | --- | --- |
| Left, Page Up, previous track | previous item (tilt left) | `[2, 255]` |
| Right, Page Down, next track | next item (tilt right) | `[2, 1]` |
| Up | the module's own, if it has a use for it (Scales: the previous scale); else previous item | `[3, 255]` |
| Down | the module's own (Scales: the next scale); else next item | `[3, 1]` |
| Space, Enter, D-pad centre, A, play/pause | select (single tap) | `[1, 1]` |
| the same, held 600 ms or longer | show or hide the menu | `[1, 3]` |
| Backspace, Esc, B | back (double tap) | `[1, 2]` |
| Menu, Start | show or hide the menu | `[1, 3]` |

The keys go to the glasses only while the glasses are connected and no
text field in glaz has the focus; otherwise they do what they always do.
Holding OK opens the menu because a clicker or a Flipper has no Menu key.
Sleep (a triple tap) has no key: tap the arm three times.

While the remote is connected to the phone, the glasses ignore your head
and taps on the arm -- all but the triple tap to sleep -- so a nod or a
touch does not get in the way of the remote; the top bar shows a keyboard
where the Bluetooth icon was. Turn the remote off, or let it go out of
range, and the gestures come back by themselves. To keep the gestures
anyway: More > Settings, Glasses gestures off.

## 1. Turn on the Keyboard remote

In glaz: **More > Services > Keyboard remote**, on.

With just that, the keys work while glaz is on screen. Android gives key
presses to the app in front only, so for the remote to work with glaz in
the background (the phone locked in your pocket, another app open), turn
on its accessibility service as well:

1. **More > Services**, then **Keyboard remote in the background** (the
   button shows while the service is on but the background part is not).
2. In Android's Accessibility settings, turn on **Glaz keyboard remote**.

The service (`KeyRemoteService.kt`) reads no screen content. While the
glasses are connected it takes the keys in the table above away from the
other apps; all other keys, and all keys while the glasses are not
connected, pass through untouched. iOS and desktop glaz have only the
in-front mode.

## 2. Pair the Flipper Zero

This is the Flipper as a keyboard, in the Remote app of its own firmware;
for the Glaz app, skip to "The Glaz app on the Flipper".

On the Flipper ([Flipper docs: HID controllers](https://docs.flipper.net/apps/controllers)):

1. **Settings > Bluetooth**, set to **ON**.
2. **Apps > Bluetooth > Remote**.

On the phone, open the Bluetooth settings and pair with **Control
\<your Flipper's name\>**. Press OK on the Flipper to finish pairing.

Then, on the Flipper, open **Keynote** in the Remote app. Its buttons map
to:

| Flipper | Sends | Glasses |
| --- | --- | --- |
| Up / Down | arrow keys | the module's own (Scales: the scale); else previous / next item |
| Left / Right | arrow keys | previous / next item |
| OK | Space | select; held, the menu |
| Back | Backspace | back |

Flipper's Keynote follows its Backspace with Android's own Back key
(`hid_keynote.c` in the Flipper firmware). glaz drops that second Back if
it comes within 500 ms of the Backspace, so pressing Back on the Flipper
goes back on the glasses without also closing glaz or the app in front.
On Android 16 that Back may come not as a key but as the system's own
back (predictive back); glaz drops it the same way, and so, while the
remote drives the glasses, the phone's Back on glaz's main screen is
handled by glaz itself rather than by Android.
Hold Back on the Flipper to leave Keynote.

The Flipper remembers the pairing: next time, open Remote > Keynote and it
reconnects by itself.

### The Glaz app on the Flipper

`flipper-glaz/` is a Flipper app of its own (Apps > Bluetooth > Glaz),
held upright, with the glasses on its screen -- their name, free disk and
memory, and the app they show, or "(disconnected)". Unlike Keynote it is
no keyboard: Android's on-screen keyboard stays, and no app but glaz hears
its keys. Its presses and the glasses' status go both ways over a
Bluetooth service of its own, and it pairs on its own, as **Glaz**
(flipper-glaz/README.md, "The link to the phone"). It needs neither the
pairing in Android's Bluetooth settings nor the accessibility service
above: that stays for real keyboards and Keynote.

To set it up, open Glaz on the Flipper (Apps > Bluetooth > Glaz), then in
glaz **More > Services > Flipper remote**: turn it on, press **Pair
Flipper**, pick **Glaz** in Android's list (Android's companion devices,
showing only what advertises the Glaz service) and confirm the PIN the
Flipper shows. glaz asks to show notifications; say yes, or its
notification stays hidden. Once paired, the service says "Connected to
Glaz"; Forget, beside the Flipper, unpairs it.

| Flipper | Glasses | `INPUT` |
| --- | --- | --- |
| Left, short, long or repeated | previous item | `[2, 255]` |
| Right, short, long or repeated | next item | `[2, 1]` |
| Up, short, long or repeated | the module's own (Scales: the previous scale); else previous item | `[3, 255]` |
| Down, short, long or repeated | the module's own (Scales: the next scale); else next item | `[3, 1]` |
| OK | select | `[1, 1]` |
| OK, long | show or hide the menu | `[1, 3]` |
| Back | back | `[1, 2]` |
| Back, long | nothing: closes Glaz on the Flipper | |

While the Flipper is connected it drives, as a keyboard does: the glasses
take of your gestures only the triple tap to sleep (above, "How it
works"). glaz writes the glasses' name, free disk and memory and the app
they show to the Flipper as they change; with no glasses connected the
Flipper shows "(disconnected)".

On Android 12 and later, glaz need not be open. Android's Companion
Device Manager watches for the paired Flipper and starts glaz when the
Flipper's Glaz app is open nearby, with no screen; glaz then connects
the Flipper and the glasses of last time, as when opened by hand. A
**Glaz** notification says what is connected ("Flipper Glaz and Frame
connected") and keeps glaz running in the background while the Flipper
is near or connected, or the glasses are. When both are gone, glaz lets
go about half a minute later, and the notification with it. Turning the
Flipper remote off, or Forget, stops the watching. Opened by hand, glaz
is the same one: the screen shows what already runs, and closing it
leaves the links up while the notification is there.

- **glaz killed.** If Android or a crash ends glaz, Android binds it
  again about ten seconds later; with the Flipper remote on, glaz then
  starts with no screen and connects what is there.
- **Force stop.** After Settings > Apps > Glaz > Force stop, Android no
  longer starts glaz for the Flipper until glaz is opened by hand once.
- **Android 8 to 11** pair the same way but cannot watch for the
  Flipper: there, as on iOS and desktop, it works only while glaz runs.
- **iOS and desktop** have no Companion Device Manager and no pairing
  in glaz: the Flipper works only while glaz runs, found by a scan for
  its service while the glasses are connected, and looked for again once
  a minute.
- **Nearby devices.** The notification and the hold need glaz's Nearby
  devices permission, which it asks for anyway to reach the glasses.
- **The glasses asleep.** If glaz is gone for more than about a minute
  and a half, the glasses go to sleep, and only a tap wakes them; glaz
  woken by the Flipper then waits for them.
- **A failed pairing.** After a failed or cancelled pairing the Flipper's
  firmware may keep its PIN dialog on screen. Press Back on the Flipper
  (or close and reopen Glaz) before pairing again.

Each press comes to the phone as 3 bytes on the keys characteristic: a
version, 1, the key (1 Up, 2 Down, 3 Left, 4 Right, 5 OK, 6 Back) and the
press (1 short, 2 long, 3 repeat); the status goes the other way
(flipper-glaz/README.md, "The link to the phone").
`scripts/flipper_keys.py` shows its presses on a computer.

### Over USB

The Flipper's USB Remote (**Apps > USB > Remote**) sends the same keys
over a USB-C cable, to a phone that takes USB keyboards (USB OTG). Nothing
to pair; the rest is the same.

A Flipper in Bluetooth Remote is a keyboard and nothing else: its screen
cannot reach the glasses meanwhile. For the screen, leave Remote and open
Apps > Flipper on the glasses ([FLIPPER.md](FLIPPER.md)).

## Other remotes

Anything that sends the keys in the first table works the same way: pair
it with the phone, turn on the Keyboard remote. A presentation clicker
usually sends Page Up and Page Down (previous / next) and sometimes Esc or
B (back); a gamepad sends its D-pad and A, B and Start. A remote that
sends other keys does nothing on the glasses: add its keys to the sets in
`keys.dart`.

## A ring remote (JX-05)

The JX-05 is a cheap Bluetooth ring sold for scrolling TikTok. It is no
keyboard: it pairs with the phone as a pointer (Android: `MOUSE | STYLUS`,
plus a keyboard for its volume keys) and each press of it is a short
touch of its own, a swipe or a tap, as a finger would make. Its chip
(JieLi or Beken, closed toolchains) cannot be reprogrammed, so glaz reads
those touches and turns them back into keys (`lib/services/ring.dart`):

| Ring | Comes to the phone as | Glasses | `INPUT` |
| --- | --- | --- | --- |
| up / down | a swipe up / down, ~0.2 s | the module's own; else previous / next item | `[3, 255]` / `[3, 1]` |
| left / right | a swipe left / right | previous / next item | `[2, 255]` / `[2, 1]` |
| centre | a touch without moving | select | `[1, 1]` |
| centre twice | two touches ~130 ms apart | back | `[1, 2]` |
| centre held | volume down | show or hide the menu | `[1, 3]` |
| up or down held | volume down / up, repeated | the menu / back, once | `[1, 3]` / `[1, 2]` |

A single tap waits 250 ms for a second one before it selects; a swipe
reaches the glasses 50 to 70 ms after the ring lets go. Holding the
ring's centre longer still turns the ring off, its own doing.

It needs the background part of the Keyboard remote: steps 1 and 2 of
"Turn on the Keyboard remote" (Android 14 or later; pair the ring in
Android's Bluetooth settings). Only an accessibility service can keep
the ring's touches from the app in front -- glaz's own screen included,
where a tap would press whatever lies under it. While the glasses are
connected and a ring named `JX-05...` is attached, the service takes all
of the phone's mouse and stylus input (`KeyRemoteService.kt`): the ring's
goes to the glasses, any other mouse's is lost until the ring or the
glasses go. The ring's volume keys are taken too, the phone's own volume
buttons are not. Without the glasses, the ring scrolls TikTok as before.

The ring's events were read with `adb shell getevent -lt` on a Pixel 7:
`ABS_X`/`ABS_Y` 0..3583, `BTN_TOUCH`, and `KEY_VOLUMEUP`,
`KEY_VOLUMEDOWN`, `KEY_POWER`, `KEY_HOMEPAGE`. Power and Home are the
phone's and pass. A ring of another name: add it to `ring()` in
`KeyRemoteService.kt`.

## Trouble

- **Nothing happens.** Check that the glasses are connected (Glaz tab),
  that the Keyboard remote is on, and, for the background, that Android
  still has the accessibility service on: some phones turn it off after an
  update or to save battery.
- **The keys work only with glaz open.** The accessibility service is off;
  see step 1.
- **Arrows move around in another app instead.** The glasses were not
  connected at that moment, so glaz let the keys through.
- **Typing in glaz does not reach the glasses.** On purpose: while a text
  field has the focus, the keys are for typing.
- **The Flipper does not show up on the phone.** Bluetooth on the Flipper
  is off, or the Remote app is not open: the Flipper advertises only while
  it is. For the Glaz app, the same: it advertises only while open.
- **The Flipper's Glaz says "(disconnected)".** The phone has it but not
  the glasses: connect them on the Glaz tab. A ring top right instead of
  a dot: the phone does not have the Flipper either; check that the
  Flipper remote is on and the Flipper paired (More > Services).
- **The ring's presses come late, or as one long touch.** Its Bluetooth
  link is failing: Android shows it connected while it is not. Wake the
  ring (or pair it again) and keep it near the phone.
- **The ring scrolls the app in front instead.** The accessibility
  service is off, the phone is older than Android 14, or the glasses are
  not connected.
- **Glaz no longer starts for the Flipper.** glaz was force-stopped:
  open it once by hand.

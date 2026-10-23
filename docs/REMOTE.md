# Driving the glasses with a remote

Frame has no buttons: you tap the arm and tilt your head. A small remote
in your hand, like a presentation clicker, is often easier. The glasses
cannot pair with a remote themselves. The **phone** does: you connect the
remote to the phone like any Bluetooth keyboard, and glaz passes its keys
on to the glasses. A [Flipper Zero](https://flipperzero.one) works well as
that remote, and this page sets it up as the example.

You need:

- glaz on the phone, connected to the glasses;
- a remote that shows up as a keyboard (HID): a Bluetooth or USB keyboard,
  a presentation clicker, a gamepad, or a Flipper Zero.

## How it works

The remote sends ordinary key presses to the phone. glaz's **Keyboard
remote** service (`flutter-glaz/lib/services/keys.dart`) turns the keys it
knows into the same `INPUT` messages the Remote tab sends, and the glasses
take them as the wearer's own gestures (docs/PROTOCOL.md, "Remote"):

| Keys | Glasses | `INPUT` |
| --- | --- | --- |
| Up, Left, Page Up, previous track | previous item (tilt left) | `[2, 255]` |
| Down, Right, Page Down, next track | next item (tilt right) | `[2, 1]` |
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

On the Flipper ([Flipper docs: HID controllers](https://docs.flipper.net/apps/controllers)):

1. **Settings > Bluetooth**, set to **ON**.
2. **Apps > Bluetooth > Remote**.

On the phone, open the Bluetooth settings and pair with **Control
\<your Flipper's name\>**. Press OK on the Flipper to finish pairing.

Then, on the Flipper, open **Keynote** in the Remote app. Its buttons map
to:

| Flipper | Sends | Glasses |
| --- | --- | --- |
| Up / Down | arrow keys | previous / next item |
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

`flipper-glaz/` is a Flipper app of its own (Apps > Bluetooth > Glaz): the
same keyboard as Keynote, to the pairing, held upright, with the glasses
on its screen instead of the keys -- their name, free disk and memory, and
the app they show, or "(disconnected)". glaz tells it those over the same
connection: More > Services > **Flipper remote**, on unless turned off
(flipper-glaz/README.md, "The link to the phone").

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
  it is.

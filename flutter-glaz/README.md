# glaz companion

The phone side of glaz. The menu and the apps live on the glasses
(`../frame_app.lua`); this app is the host that talks to them over
Bluetooth -- the role `../host_test.py` plays on a laptop today.

Right now it is the stock Flutter template, nothing more.

## Plain-language summary

The glasses already work on their own. This app will be what connects them to
a phone: receive photos, set the clock, show what the glasses report. The
protocol it has to speak is the same one the Python host uses, described in
[`../docs/PROTOCOL.md`](../docs/PROTOCOL.md).

## Running

Everything comes from the repository's devenv (`../devenv.nix`): Flutter, an
Android SDK and JDK 17.

```sh
cd ..                 # repository root
devenv shell
emulator-start &      # Android 16 emulator; first run creates the AVD
cd flutter-glaz
flutter run           # on the emulator, or a phone connected over USB
flutter test
```

Platforms: Android, iOS, Linux, macOS. iOS and macOS builds need Xcode, which
Nix cannot provide. The emulator is for the UI only: it has no Bluetooth, so
talking to the glasses needs a real phone.

## Talking to the glasses

Brilliant Labs publish the same transport the Python host uses as Dart
packages, `frame_ble` and `frame_msg` on pub.dev. Every message code in
`../docs/PROTOCOL.md` is the same on both sides.

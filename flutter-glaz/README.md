# Glaz

The phone side of glaz. The menu and the apps live on the glasses
(`../frame_app.lua`); this app is the host that talks to them over
Bluetooth -- the role `../host_test.py` plays on a laptop today.

It connects to the glasses over Bluetooth (Glasses tab) and provides
services to the Lua apps on them (docs/PROTOCOL.md, "Host services"):

- **Clock** -- sets the time in the top bar on every connect
- **Notifications** -- forwards the phone's notifications; they pop up on
  the glasses and are kept under Info > Notifications. Android only, needs
  the notification-access permission, and only while Glaz runs
- **Internet** -- fetches web pages for the apps the user allowed in the
  Apps tab (`modules/weather.lua` is the example)

Four tabs:

- **Glasses** -- connect; battery, firmware and upload are not wired yet
- **Apps** -- the modules in `../modules/`, grouped like the menu on the
  glasses, with the Internet permission for those that use it
- **Services** -- the above, plus a test notification and recent requests
- **Settings** -- theme: System, Light or Dark

Choices are kept across restarts. The app list in `lib/catalog.dart`
mirrors the `MENU` tree in `../frame_app.lua` by hand for now.

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
cd flutter-glaz
flutter run           # on a phone connected over USB
flutter test
```

Platforms: Android, iOS, Linux, macOS. iOS and macOS builds need Xcode, which
Nix cannot provide. There is no emulator in the devenv on purpose: the app
needs a real phone next to the glasses.

## Talking to the glasses

`lib/frame/link.dart` uses `frame_ble`, the Dart counterpart of the
transport the Python host uses. Connecting sends no break or reset, so
`main.lua` keeps running; the message codes are in `lib/frame/protocol.dart`
and match `../docs/PROTOCOL.md`.

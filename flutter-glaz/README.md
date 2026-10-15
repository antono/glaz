# glaz companion

The phone side of glaz. The menu and the apps live on the glasses
(`../frame_app.lua`); this app is the host that talks to them over
Bluetooth -- the role `../host_test.py` plays on a laptop today.

Tabs:

- **Glasses** -- connect over Bluetooth; battery and firmware; Upload
  (`main.lua` and the apps switched on in Menu), Restart, Firmware (install
  another version over the air); the gestures that drive the glasses
- **Photos** -- photos from Camera and Time series, by date; a series is a
  folder named by when it started
- **Menu** -- what the menu on the glasses contains, section by section;
  which apps Upload sends, and which may use the Internet
- **Services** -- what the phone does for the apps on the glasses: clock,
  notifications, Internet, photos (`../docs/PROTOCOL.md`, "Host services")
- **About** -- version and open-source licences

![logo variants](assets/logo/preview.png)

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

## Look

Dark only, in Frame's own palette (`lib/theme.dart`): the glasses' display is
an OLED, black is "off", so the phone is black too. The logo is a pixel-art
eye drawn by `tool/logo.py` -- plain Python, no Pillow:

```sh
python tool/logo.py preview          # assets/logo/preview.png: all variants
python tool/logo.py icons bloodshot  # the app logo and every platform icon
```

Variants: `bloodshot` (the default), `oled`, `flipper`. `icons` rewrites the
Android, iOS and macOS icons and both launch screens, so switching the logo is
that one command.

## Keeping in step with the glasses

The Menu tab describes `../frame_app.lua`'s `MENU` tree by hand
(`lib/glasses_menu.dart`). `flutter test` reads the Lua and fails when the
sections, items or labels drift apart -- update the Dart list after adding a
module.

## Talking to the glasses

`lib/frame/link.dart` uses `frame_ble`, the Dart counterpart of the
transport the Python host uses. Connecting sends no break or reset, so
`main.lua` keeps running; the message codes are in `lib/frame/protocol.dart`
and match `../docs/PROTOCOL.md`.

Upload takes the Lua from `assets/lua/`, which links to the repository's
`frame_app.lua`, `modules/` and `sprites/`. Firmware offers the zips in
`assets/firmware/`, which are not committed:

```sh
tool/fetch_firmware.sh    # three newest official releases + a custom build
```

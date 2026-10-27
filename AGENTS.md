# AGENTS.md

Guide for coding agents working in this repo.

## What this is

Tooling and an on-glasses app for the Brilliant Labs Frame smart glasses.
The glasses run Lua; a laptop talks to them over Bluetooth using Python.

## Docs

- [`docs/FRAME.md`](docs/FRAME.md) — connecting to the glasses, Lua API
  cheat sheet, known gotchas, repo layout. Start here.
- [`docs/PLATFORM.md`](docs/PLATFORM.md) — development model, hardware,
  firmware, what can be bricked.
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) — the menu app's wire protocol,
  states, input and design notes.
- [`docs/RECOVERY.md`](docs/RECOVERY.md) — glasses that look dead: out of
  range, stuck apps, and stuck in `Frame Update` after a broken firmware
  update (`utils/dfu.py` installs a firmware from a computer).
- [`docs/BATTERY.md`](docs/BATTERY.md) — battery drain measurements and
  where the power goes.
- [`docs/HERMES.md`](docs/HERMES.md) — connecting the Assistant to Hermes
  Agent: its API server, and Tailscale serve, tailnet HTTP or funnel.
- [`docs/REMOTE.md`](docs/REMOTE.md) — a Bluetooth keyboard or Flipper
  Zero as a remote for the glasses, through the phone; the Flipper's Glaz
  app, paired in glaz, which Android wakes when the Flipper comes near.
- [`docs/SCALES.md`](docs/SCALES.md) — Scales, guitar scales on the
  fretboard: two at once, the boxes, the colours, the input.
- [`docs/FLIPPER.md`](docs/FLIPPER.md) — a Flipper Zero's screen on the
  glasses: the Flipper's RPC over Bluetooth, and how the phone passes it on.
- [`docs/HALO.md`](docs/HALO.md) — Brilliant Labs Halo: hardware,
  Bluetooth, its Lua next to Frame's, firmware and recovery; told apart by
  its name (`lib/frame/model.dart`); what of glaz runs on it.
- [`docs/DEVICES.md`](docs/DEVICES.md) — more than one kind of glasses:
  `name.lua` and its parts `name.frame.lua`, `name.halo.lua`; what goes to
  which glasses, and what the phone lists.

## Layout

- `glaz.lua` — app that runs on the glasses (`glaz_app.lua` there), and
  its parts `glaz.frame.lua`, `glaz.halo.lua`: the screen (docs/DEVICES.md)
- `app/` — parts of `glaz.lua` in files of their own (services, file
  browsing, photo), and `glaz_boot.lua`, which loads the app and restarts
  it; its part for the glasses (`glaz_boot.frame.lua`) is `main.lua` there.
  See docs/FRAME.md
- `modules/` — one Lua file per menu item, and its part for each pair of
  glasses it runs on (`reader.frame.lua`)
- `host_test.py` — reference host: uploads everything, then listens
- `utils/` — diagnostics, run individually
- `check.sh` — static checks, no device needed
- `tests/` — glaz on Halo in Brilliant Labs' Halo emulator (`halo` in the
  root shell; docs/HALO.md)
- `sprites/` — the eye as glasses pixel art, for `utils/show_sprite.py`;
  not uploaded: the phone draws the eye itself during Upload
- `flutter-glaz/` — the Flutter companion app (phone side)
- `flipper-glaz/` — a Flipper Zero remote for the glasses, in Rust, with
  its own `devenv.nix` (a draft; see its README)
- `devenv.nix` — the development environment (Lua, Python, firmware)
- `flutter-glaz/devenv.nix` — the companion app's own: Flutter, Android SDK
- `flake.nix` — the companion app as a Linux desktop package (`nix run`)

## Setup

Everything comes from [devenv](https://devenv.sh), in two separate shells.
The root one (`devenv.nix`, `devenv.yaml`) has Lua 5.4, the Python host
tools and the firmware toolchain; `flutter-glaz/` has its own with Flutter
and an Android SDK. Linux first, macOS works too.

```sh
devenv shell             # in the repository root
check                    # ./check.sh
upload                   # python host_test.py
python utils/connect.py
python utils/phone_lua.py 'frame.battery_level()'   # through the phone
halo                     # glaz on Halo, in the Halo emulator (pytest)

cd flutter-glaz && devenv shell   # first run downloads the Android SDK
emulator-start &         # Android emulator
apk                      # the phone app, Lua bytecode and firmware first
```

To try Lua on the glasses while the phone holds them, use
`utils/phone_lua.py` (the phone app's Lua console, open to a computer);
see docs/FRAME.md, "Quick connect".

### Building the phone app

Build Flutter only in the app's own shell, `flutter-glaz/devenv.nix`; the
root shell has no Flutter. From a script or an agent, without entering
the shell:

```sh
cd flutter-glaz
devenv shell -- apk          # debug APK
devenv shell -- linux-app    # the Linux desktop app
```

`apk` does, in order: `reveal-key` (the signing key), `tool/compile_lua.sh`
(the Lua bytecode, from the firmware's Lua in `../../lab-frame-codebase`
or `$FRAME_CODEBASE`), `tool/fetch_firmware.sh` (the three newest
official releases via `gh`, plus our build of firmware branch
`glaz/stable`, which must be there: `firmware` in the root shell builds
it; `FIRMWARE_FEATURE=glaz/<topic>` adds a feature branch's build, after
`firmware glaz/<topic>`), then `flutter build apk --debug`. The result is
`flutter-glaz/build/app/outputs/flutter-apk/app-debug.apk` (about 170 MB).
Gradle alone takes about 4 minutes, so give the command a 10-minute
timeout. Check that the build used the project key and not the debug key:
`apksigner verify --print-certs` (from `$ANDROID_HOME/build-tools/*/`,
inside the shell) shows `CN=glaz, O=glaz`.

The phone app is signed with one key everywhere, so any build installs
over any other: `flutter-glaz/android/glaz.jks` and `key.properties`,
kept encrypted by [git-secret](https://sobolevn.me/git-secret/) as
`*.secret`. The app's devenv decrypts them (`reveal-key`) on entering the shell
and before `apk`, when they are missing or older than their `.secret`,
for those whose GPG key was added (`git secret tell`); without them a
build is signed with the
machine's own debug key and will not install over a release. After
changing the key: `git secret hide`, and update the CI secrets
`ANDROID_KEYSTORE` and `ANDROID_KEY_PROPERTIES` (.github/workflows/release.yml).

Without devenv, the host tools alone still work from a plain venv:

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python utils/connect.py
```

## Rules

- Frame-side Lua must be **ASCII only** — non-ASCII bytes break upload.
- Frame runs **Lua 5.4**; check with 5.4, not older versions.
- Run `./check.sh` after changing any `.lua` file.
- Adding a menu item: add a file in `modules/`, its part for each pair of
  glasses it runs on (`name.frame.lua`, empty `return {}` if it has
  nothing of its own), and list it in the `MENU` tree in `glaz.lua`. See
  `docs/PROTOCOL.md` and `docs/DEVICES.md`.
- What differs between Frame and Halo goes in the parts, never in a check
  of which glasses these are (docs/DEVICES.md); `check.sh` holds to it.
- Every commit that changes an app bumps its version in the same commit,
  by [SemVer](https://semver.org): major for a breaking change (the other
  side or saved data no longer works with it), minor for a feature, patch
  for a fix. Docs, tests and tooling alone bump nothing. While a version
  is `0.x`, a breaking change bumps the minor.
  - Glasses (`glaz.lua`, `app/`, `modules/`, `sprites/`): `VERSION` in
    `modules/about.lua`, shown in Info > About.
  - Phone (`flutter-glaz/`): `version` in `flutter-glaz/pubspec.yaml` and
    `appVersion` in `lib/screens/about_screen.dart` (a test keeps them
    equal); the `+N` build number goes up by one with every bump.
  - Flipper (`flipper-glaz/`): `version` in `flipper-glaz/Cargo.toml`;
    `app_version` in its manifest (`src/main.rs`) goes up by one with
    every bump.
  - A commit that changes both bumps both.

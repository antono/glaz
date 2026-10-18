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
- [`docs/BATTERY.md`](docs/BATTERY.md) — battery drain measurements and
  where the power goes.

## Layout

- `frame_app.lua` — app that runs on the glasses (uploaded as `main.lua`)
- `app/` — parts of `frame_app.lua` in files of their own (services, file
  browsing, photo), and `glaz_boot.lua`, uploaded as `main.lua`: it loads
  the app (`glaz_app.lua` on the glasses) in pieces; see docs/FRAME.md
- `modules/` — one Lua file per menu item
- `host_test.py` — reference host: uploads everything, then listens
- `utils/` — diagnostics, run individually
- `check.sh` — static checks, no device needed
- `sprites/` — the eye as glasses pixel art, for `utils/show_sprite.py`;
  not uploaded: the phone draws the eye itself during Upload
- `flutter-glaz/` — the Flutter companion app (phone side)
- `devenv.nix` — the development environment
- `flake.nix` — the companion app as a Linux desktop package (`nix run`)

## Setup

Everything -- Lua 5.4, the Python host tools, the firmware toolchain and
Flutter with an Android SDK -- comes from [devenv](https://devenv.sh)
(`devenv.nix`, `devenv.yaml`). Linux first, macOS works too.

```sh
devenv shell             # first run downloads the Android SDK
check                    # ./check.sh
upload                   # python host_test.py
emulator-start &         # Android emulator for flutter-glaz/
python utils/connect.py
python utils/phone_lua.py 'frame.battery_level()'   # through the phone
```

To try Lua on the glasses while the phone holds them, use
`utils/phone_lua.py` (the phone app's Lua console, open to a computer);
see docs/FRAME.md, "Quick connect".

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
- Adding a menu item: add a file in `modules/` and list it in the `MENU` tree
  in `frame_app.lua`. See `docs/PROTOCOL.md`.
- Every commit that changes an app bumps its version in the same commit,
  by [SemVer](https://semver.org): major for a breaking change (the other
  side or saved data no longer works with it), minor for a feature, patch
  for a fix. Docs, tests and tooling alone bump nothing. While a version
  is `0.x`, a breaking change bumps the minor.
  - Glasses (`frame_app.lua`, `app/`, `modules/`, `sprites/`): `VERSION` in
    `modules/about.lua`, shown in Info > About.
  - Phone (`flutter-glaz/`): `version` in `flutter-glaz/pubspec.yaml` and
    `appVersion` in `lib/screens/about_screen.dart` (a test keeps them
    equal); the `+N` build number goes up by one with every bump.
  - A commit that changes both bumps both.

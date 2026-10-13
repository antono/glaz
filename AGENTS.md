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
- `modules/` — one Lua file per menu item
- `host_test.py` — reference host: uploads everything, then listens
- `utils/` — diagnostics, run individually
- `check.sh` — static checks, no device needed

## Setup

```sh
python3 -m venv .venv
.venv/bin/pip install frame-ble frame-msg
.venv/bin/python utils/connect.py
```

## Rules

- Frame-side Lua must be **ASCII only** — non-ASCII bytes break upload.
- Frame runs **Lua 5.4**; check with 5.4, not older versions.
- Run `./check.sh` after changing any `.lua` file.
- Adding a menu item: add a file in `modules/` and list it in the `MENU` tree
  in `frame_app.lua`. See `docs/PROTOCOL.md`.

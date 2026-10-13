#!/usr/bin/env bash
# Static checks for the Frame-side Lua, so typos are caught without the device.
#
# Lua 5.4 matters: Frame runs 5.4, and 5.2 rejects valid code (the // integer
# division operator arrived in 5.3). Checking with the wrong version produces
# false failures.
set -uo pipefail
cd "$(dirname "$0")"

fail=0

for f in frame_app.lua modules/*.lua; do
  if out=$(nix run nixpkgs#lua5_4 -- -e "assert(loadfile('$f'))" 2>&1); then
    echo "syntax ok   $f"
  else
    echo "SYNTAX FAIL $f"
    echo "$out" | tail -3
    fail=1
  fi
done

# Non-ASCII breaks upload_file(): it chunks by characters but enforces the MTU
# limit in bytes. See PROTOCOL.md.
for f in frame_app.lua modules/*.lua; do
  if LC_ALL=C grep -qP '[^\x00-\x7F]' "$f" 2>/dev/null; then
    echo "NON-ASCII   $f  (will break upload)"
    fail=1
  else
    echo "ascii ok    $f"
  fi
done

exit $fail

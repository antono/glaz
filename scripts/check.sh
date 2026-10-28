#!/usr/bin/env bash
# Static checks for the Frame-side Lua, so typos are caught without the device.
#
# Lua 5.4 matters: Frame runs 5.4, and 5.2 rejects valid code (the // integer
# division operator arrived in 5.3). Checking with the wrong version produces
# false failures.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

# The lua on PATH if it is 5.4 (the devenv shell provides one), else Nix's.
if command -v lua >/dev/null && lua -v 2>&1 | grep -q 'Lua 5\.4'; then
  lua54=(lua)
  luac54=(luac)
else
  lua54=(nix run nixpkgs#lua5_4 --)
  luac54=(nix shell nixpkgs#lua5_4 -c luac)
fi

for f in glaz/*.lua modules/*.lua sprites/*.lua; do
  if out=$("${lua54[@]}" -e "assert(loadfile('$f'))" 2>&1); then
    echo "syntax ok   $f"
  else
    echo "SYNTAX FAIL $f"
    echo "$out" | tail -3
    fail=1
  fi
done

# Non-ASCII breaks upload_file(): it chunks by characters but enforces the MTU
# limit in bytes. See docs/PROTOCOL.md.
for f in glaz/*.lua modules/*.lua sprites/*.lua; do
  if LC_ALL=C grep -qP '[^\x00-\x7F]' "$f" 2>/dev/null; then
    echo "NON-ASCII   $f  (will break upload)"
    fail=1
  else
    echo "ascii ok    $f"
  fi
done

# Globals. A name read that is neither Lua's own, nor frame, nor set as a
# global by one of these files is a local out of scope or a typo: nil at
# run time. A local declared inside a function by mistake made host.pref
# nil, and every notification stopped the app (glaz/glaz_host.lua).
lua_globals=$("${lua54[@]}" -e 'for k in pairs(_G) do print(k) end')
listing=$(for f in glaz/*.lua modules/*.lua sprites/*.lua; do
  "${luac54[@]}" -p -l "$f" | sed -nE \
    "s/.*(GET|SET)TABUP.*_ENV \"([A-Za-z_][A-Za-z0-9_]*)\".*/$(
      printf '%s' "$f" | sed 's|/|\\/|g') \1 \2/p"
done)
known=$(printf '%s\nframe\n%s\n' "$lua_globals" \
  "$(echo "$listing" | awk '$2 == "SET" { print $3 }')" | sort -u)
unknown=$(echo "$listing" | awk '$2 == "GET"' | sort -u |
  awk 'NR == FNR { ok[$1] = 1; next } !($3 in ok)' <(echo "$known") -)
if [ -n "$unknown" ]; then
  echo "$unknown" | while read -r f _ name; do
    echo "GLOBAL      $f  reads '$name', set nowhere"
  done
  fail=1
else
  echo "globals ok"
fi

# Parts (docs/DEVICES.md). name.<glasses>.lua is name.lua's part for
# those glasses, uploaded to them alone; a module goes only to glasses it
# has a part for, the app's files to all. So: a part's suffix names
# glasses there are; a module without a part is on no glasses; a file that
# reaches more than one pair of glasses -- the app's, or a module with
# several parts -- leaves the display to its parts; and nothing asks which
# glasses these are, the parts on them say so.
devices="frame halo"
parts_ok=1
for f in glaz/*.*.lua modules/*.*.lua; do
  dev=${f%.lua}; dev=${dev##*.}
  case " $devices " in
    *" $dev "*) ;;
    *) echo "PART        $f  names no glasses ($devices)"; parts_ok=0 ;;
  esac
done
shared=()
for f in glaz/*.lua modules/*.lua; do
  base=$(basename "$f" .lua)
  case $base in *.*) continue ;; esac
  if [ "${f%%/*}" = glaz ]; then shared+=("$f"); continue; fi
  n=0
  for d in $devices; do [ -f "modules/$base.$d.lua" ] && n=$((n + 1)); done
  if [ $n -eq 0 ]; then
    echo "PART        $f  has no part: it is on no glasses"
    parts_ok=0
  elif [ $n -gt 1 ]; then
    shared+=("$f")
  fi
done
for f in "${shared[@]}"; do
  if grep -n 'frame\.display\.' "$f" | grep -v '^[0-9]*: *--' >/dev/null; then
    echo "PART        $f  draws: it reaches more than one pair of glasses," \
         "drawing is its parts'"
    parts_ok=0
  fi
done
if grep -n 'display\.width\|HARDWARE_VERSION' glaz/*.lua \
     modules/*.lua | grep -v ':[0-9]*: *--'; then
  echo "PART        asks which glasses these are: the parts say so"
  parts_ok=0
fi
if [ $parts_ok = 1 ]; then echo "parts ok"; else fail=1; fi

exit $fail

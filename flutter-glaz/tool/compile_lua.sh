#!/usr/bin/env bash
# Compiles the Lua the app uploads into assets/luac/, before the app is
# built: the glasses no longer have the memory to compile main.lua
# themselves. Built with the firmware's own Lua (libraries/lua in
# ../frame-codebase, or $FRAME_CODEBASE), so the bytecode is what they load.
#
#   tool/compile_lua.sh
#
# assets/luac/index.txt lists each source asset with the hash of the text
# it was compiled from. Upload sends bytecode only for a source that still
# matches; anything else goes up as source and is compiled on the glasses,
# as before (lib/frame/upload.dart). The output is not committed.
set -euo pipefail
cd "$(dirname "$0")/.."
lua="${FRAME_CODEBASE:-../../lab-frame-codebase}/libraries/lua"
out=assets/luac
tool=build/luac_frame

if [ ! -f "$lua/lua.h" ]; then
  echo "no firmware Lua in $lua; set FRAME_CODEBASE" >&2
  exit 1
fi

mkdir -p build
if [ ! -x "$tool" ] || [ tool/luac_frame.c -nt "$tool" ]; then
  cc -O2 -std=gnu99 -w -Itool/luac_host -I"$lua" -o "$tool" tool/luac_frame.c \
    $(ls "$lua"/*.c | grep -vE '/(lua|luac|onelua)\.c$') -lm
fi

rm -f "$out"/*.luac
index="$out/index.txt"
: > "$index"
for src in assets/lua/glaz/*.lua assets/lua/lib/*.lua \
           assets/lua/modules/*.lua; do
  rel="${src#assets/lua/}"
  # one folder, as Flutter takes an asset folder's files but not its
  # subfolders': modules/photo.lua -> modules.photo.luac
  dst="$out/$(echo "${rel%.lua}" | tr / .).luac"
  hash=$("$tool" "$src" "$dst" "$rel")
  echo "$src $hash" >> "$index"
done
echo "compiled $(wc -l < "$index") files into $out"

#!/usr/bin/env bash
# Puts the firmware the app offers for Update into assets/firmware/:
# the three newest official releases from GitHub, and the custom build from
# ../frame-codebase (or $FRAME_CODEBASE) if one has been packaged there.
# The zips are not committed (.gitignore); run this before building the app.
#
#   tool/fetch_firmware.sh            # official + custom, if present
#   OFFICIAL=0 tool/fetch_firmware.sh # custom only
set -euo pipefail
cd "$(dirname "$0")/.."
out=assets/firmware
mkdir -p "$out"

if [ "${OFFICIAL:-1}" != 0 ]; then
  for tag in $(gh release list -R brilliantlabsAR/frame-codebase -L 3 \
                 --json tagName --jq '.[].tagName'); do
    f="frame-firmware-$tag.zip"
    if [ ! -f "$out/$f" ]; then
      gh release download "$tag" -R brilliantlabsAR/frame-codebase \
        -p "$f" -D "$out"
    fi
    echo "official  $f"
  done
fi

src="${FRAME_CODEBASE:-../../lab-frame-codebase}/build"
for z in "$src"/frame-firmware-*.zip; do
  [ -e "$z" ] || continue
  cp "$z" "$out/"
  echo "custom    $(basename "$z")"
done

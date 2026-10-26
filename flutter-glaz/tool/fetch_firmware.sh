#!/usr/bin/env bash
# Puts the firmware the app offers for Update into assets/firmware/:
# the three newest official releases from GitHub, and our own build of
# branch glaz/stable of antono/frame-codebase, from ../../lab-frame-codebase
# (or $FRAME_CODEBASE). The zips are not committed (.gitignore); run this
# before building the app.
#
#   tool/fetch_firmware.sh                              # official + glaz/stable
#   FIRMWARE_FEATURE=glaz/emoji tool/fetch_firmware.sh  # + a feature branch
#   OFFICIAL=0 tool/fetch_firmware.sh                   # glaz/stable only
#
# Ours is taken only as built from the branch's current commit: the zip's
# name is that commit's time, as ../utils/build_firmware.sh names it (the
# root shell's `firmware`). Without it this fails, so an app is never built
# with another branch's firmware, or an old one. Any other build of ours
# left in assets/firmware/ is removed. FIRMWARE_FEATURE takes several
# branches, separated by spaces.
set -euo pipefail
cd "$(dirname "$0")/.."
out=assets/firmware
mkdir -p "$out"

if [ "${OFFICIAL:-1}" != 0 ]; then
  if tags=$(gh release list -R brilliantlabsAR/frame-codebase -L 3 \
              --json tagName --jq '.[].tagName'); then
    for tag in $tags; do
      f="frame-firmware-$tag.zip"
      if [ ! -f "$out/$f" ]; then
        gh release download "$tag" -R brilliantlabsAR/frame-codebase \
          -p "$f" -D "$out"
      fi
      echo "official  $f"
    done
  else
    echo "official releases not fetched; keeping those in $out" >&2
  fi
fi

fw="${FRAME_CODEBASE:-../../lab-frame-codebase}"
git -C "$fw" fetch -q antono 2>/dev/null || true

# the zip for a branch's commit, named as build_firmware.sh names it
want() {
  local ref=$1 order commit= r v
  # glaz/stable is what is pushed (in CI, the branch checked out);
  # a feature may have commits not pushed yet
  if [ "$ref" = glaz/stable ]; then
    order="antono/$ref $ref origin/$ref"
  else
    order="$ref antono/$ref origin/$ref"
  fi
  for r in $order; do
    commit=$(git -C "$fw" rev-parse -q --verify "$r^{commit}") && break
  done
  if [ -z "$commit" ]; then
    echo "no branch $ref in $fw" >&2
    return 1
  fi
  v=v$(TZ=UTC0 git -C "$fw" log -1 --format=%cd --date=format-local:%y.%j.%H%M "$commit")-glaz
  case "$ref" in
    glaz/stable|glaz/main) ;;
    *) v="$v-$(echo "${ref#glaz/}" | tr -c 'a-zA-Z0-9\n' -)" ;;
  esac
  if [ ! -f "$fw/build/frame-firmware-$v.zip" ]; then
    echo "no firmware for $ref at $(git -C "$fw" rev-parse --short "$commit"):" \
      "build it in the root shell with: firmware $ref" >&2
    return 1
  fi
  echo "frame-firmware-$v.zip"
}

zips=()
for ref in glaz/stable ${FIRMWARE_FEATURE:-}; do
  f=$(want "$ref") || exit 1
  zips+=("$ref $f")
done

# builds of ours carry a suffix after the version; official ones do not
for z in "$out"/frame-firmware-v*-*.zip; do
  [ -e "$z" ] && rm "$z"
done
for e in "${zips[@]}"; do
  f=${e#* }
  cp "$fw/build/$f" "$out/"
  echo "ours      $f (${e%% *})"
done

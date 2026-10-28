#!/usr/bin/env bash
# Builds our firmware from a branch of antono/frame-codebase into a DFU zip
# in its build/, where flutter-glaz/tool/fetch_firmware.sh takes it from.
# Run it in the root devenv shell (arm-none-eabi-gcc, make, nrfutil):
#
#   firmware                  # glaz/stable, what every app build carries
#   firmware glaz/emoji       # a feature branch, for FIRMWARE_FEATURE
#
# The build is of the branch's commit, never of the working tree, in a
# worktree of its own (~/.cache/glaz/firmware-worktree), so the checkout in
# ../lab-frame-codebase is left as it is. The version is the commit's time
# (UTC) with a suffix: -glaz for glaz/stable and glaz/main, -glaz-<topic>
# for glaz/<topic>. The same commit always gets the same name, which is how
# fetch_firmware.sh knows a zip is the one it wants; one already built is
# not built again. Keep the naming in step with fetch_firmware.sh and
# .github/workflows/release.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
fw="$(realpath "${FRAME_CODEBASE:-../lab-frame-codebase}")"
ref="${1:-glaz/stable}"
wt="${XDG_CACHE_HOME:-$HOME/.cache}/glaz/firmware-worktree"

git -C "$fw" fetch -q antono 2>/dev/null || echo "could not fetch antono; using what is here" >&2
# glaz/stable is what is pushed; a feature may have commits not pushed yet
if [ "$ref" = glaz/stable ]; then order="antono/$ref $ref"; else order="$ref antono/$ref"; fi
commit=
for r in $order; do
  commit=$(git -C "$fw" rev-parse -q --verify "$r^{commit}") && break
done
[ -n "$commit" ] || { echo "no branch $ref in $fw" >&2; exit 1; }

v=v$(TZ=UTC0 git -C "$fw" log -1 --format=%cd --date=format-local:%y.%j.%H%M "$commit")-glaz
case "$ref" in
  glaz/stable|glaz/main) ;;
  glaz/*) v="$v-$(echo "${ref#glaz/}" | tr -c 'a-zA-Z0-9\n' -)" ;;
  *) echo "not a glaz/ branch: $ref" >&2; exit 1 ;;
esac
zip="$fw/build/frame-firmware-$v.zip"
if [ -f "$zip" ]; then
  echo "$ref $(git -C "$fw" rev-parse --short "$commit"): built already, $zip"
  exit 0
fi

if [ ! -e "$wt/.git" ]; then
  mkdir -p "$(dirname "$wt")"
  git -C "$fw" worktree prune
  git -C "$fw" worktree add -q --detach "$wt" "$commit"
fi
git -C "$wt" checkout -q --detach "$commit"
git -C "$wt" submodule update -q --init --recursive
rm -rf "$wt/build"
make -C "$wt" application BUILD_VERSION="$v"

# nrfutil 8 brings pkg generate as a plug-in; on NixOS that plug-in only
# runs in an FHS environment (docs/FIRMWARE.md), and not with the shell's
# LD_LIBRARY_PATH: libz.so.1 is then not found
plugin="$HOME/.nrfutil/bin/nrfutil-nrf5sdk-tools"
[ -x "$plugin" ] || nrfutil install nrf5sdk-tools
args=(pkg generate --hw-version 52 --application-version 0
      --application "$wt/build/application.hex" --sd-req 0x0123
      --key-file "$wt/source/bootloader/dfu_private_key.pem" "$zip")
mkdir -p "$fw/build"
if grep -qs "^ID=nixos" /etc/os-release; then
  env -u LD_LIBRARY_PATH NIXPKGS_ALLOW_UNFREE=1 nix run --impure nixpkgs#steam-run -- "$plugin" "${args[@]}"
else
  nrfutil nrf5sdk-tools "${args[@]}"
fi
echo "$ref $(git -C "$fw" rev-parse --short "$commit"): $zip"

#!/usr/bin/env bash
# Links each app's Lua into assets/lua/apps/<name>/, file by file: an app's
# directory (../apps/<name>/) also holds its README, screenshots and
# tests, which the app must not carry. Run after adding an app or a part;
# test/upload_test.dart says when the links are out of step. The links
# are committed; pubspec.yaml lists each app's folder.
#
#   tool/link_apps.sh
set -euo pipefail
cd "$(dirname "$0")/.."
out=assets/lua/apps

rm -rf "$out"
for src in ../apps/*/*.lua; do
  name=$(basename "$(dirname "$src")")
  mkdir -p "$out/$name"
  ln -s "../../../../../apps/$name/$(basename "$src")" "$out/$name/"
done
echo "linked $(find "$out" -type l | wc -l) files into $out"

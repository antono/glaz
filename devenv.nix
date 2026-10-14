# Development environment for glaz: the Lua app on the glasses, the Python
# host tools, the Frame firmware, and the Flutter companion app.
#
#   devenv shell          # enter it; first run downloads the Android SDK
#
# Linux is the primary target; macOS works too, with two gaps noted below.
# What is in here, and why:
#
#   lua 5.4         check.sh -- Frame runs Lua 5.4, older versions reject
#                   valid code (docs/PROTOCOL.md)
#   python + venv   host_test.py and utils/ (frame-ble, frame-msg), from
#                   requirements.txt; libstdc++ and zlib for numpy's wheel
#   gcc-arm-embedded, make
#                   building the firmware in ../frame-codebase
#   nrfutil         packaging the firmware as a DFU zip (docs/FIRMWARE.md)
#   bluez           Linux only: BLE tools for flashing from the command line
#   flutter + Android SDK + JDK 17
#                   the companion app in flutter-glaz/
#
# macOS gaps: iOS builds need Xcode, which Nix cannot provide; and there is
# no command-line DFU path on macOS (docs/FIRMWARE.md) -- use nRF Connect.
{ pkgs, lib, config, inputs, ... }:

let
  available = lib.meta.availableOn pkgs.stdenv.hostPlatform;

  # nrfutil drags in SEGGER J-Link, which needs its own licence flag on top of
  # allowUnfree. devenv.yaml cannot set arbitrary nixpkgs config, so nrfutil
  # comes from a second import that carries both (docs/FIRMWARE.md).
  nordic = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    config = {
      allowUnfree = true;
      segger-jlink.acceptLicense = true;
    };
  };
in
{
  packages = [
    pkgs.git
    pkgs.gnumake
    pkgs.lua5_4
  ]
  ++ lib.optional (available pkgs.gcc-arm-embedded) pkgs.gcc-arm-embedded
  ++ lib.optional (available nordic.nrfutil) nordic.nrfutil
  ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.bluez ];

  languages.python = {
    enable = true;
    venv.enable = true;
    venv.requirements = ./requirements.txt;
    # pip wheels with native code (numpy, pulled in by frame-msg) link
    # against libstdc++ and libz, which NixOS has no global copy of. Without
    # these, host_test.py dies with "libstdc++.so.6: cannot open shared
    # object file". The first entry is the module's default, kept.
    libraries = [
      "${config.devenv.dotfile}/profile"
      pkgs.stdenv.cc.cc.lib
      pkgs.zlib
    ];
  };

  # Flutter for the companion app, with an Android SDK to build it. The app
  # runs on a real phone next to the glasses, so the emulator and its system
  # images (several GB) are left out.
  android = {
    enable = true;
    flutter.enable = true;
    # What Flutter 3.47's Gradle plugin builds against (FlutterExtension.kt:
    # compileSdk/targetSdk 36). The SDK lives in the read-only Nix store, so
    # Gradle cannot fetch missing parts itself; they must be listed here. The
    # NDK default (28.2.13676358) already matches.
    platforms.version = [ "36" "35" ];
    buildTools.version = [ "36.0.0" "35.0.0" ];
    emulator.enable = false;
    systemImages.enable = false;
    googleTVAddOns.enable = false;
  };

  scripts = {
    check.exec = ''./check.sh'';
    upload.exec = ''python host_test.py "$@"'';
    sprite.exec = ''python utils/show_sprite.py "$@"'';
  };

  enterShell = ''
    # Flutter prefers the JDK bundled with an installed Android Studio over
    # JAVA_HOME, and an old Android Studio ships Java 11, which Gradle 9
    # refuses. Point it at this shell's JDK 17 on every entry. This writes
    # Flutter's user config (~/.config/flutter/settings), which is harmless
    # here: Flutter itself only exists inside this shell.
    if [ "$(flutter config --list 2>/dev/null | sed -n 's/^ *jdk-dir: //p')" != "$JAVA_HOME" ]; then
      flutter config --jdk-dir="$JAVA_HOME" >/dev/null 2>&1
    fi

    echo "glaz dev shell"
    echo "  check            static checks for the Lua side"
    echo "  upload           upload the app to the glasses and listen"
    echo "  sprite NAME N    show sprites/NAME.lua at N x on the glasses"
    echo "  cd flutter-glaz && flutter run    the companion app"
  '';
}

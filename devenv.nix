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
#                   requirements.txt
#   gcc-arm-embedded, make
#                   building the firmware in ../frame-codebase
#   nrfutil         packaging the firmware as a DFU zip (docs/FIRMWARE.md)
#   bluez           Linux only: BLE tools for flashing from the command line
#   flutter + Android SDK + JDK 17
#                   the companion app in flutter-glaz/
#   gstreamer, libunwind
#                   Linux only: the companion app as a desktop app
#
# macOS gaps: iOS builds need Xcode, which Nix cannot provide; and there is
# no command-line DFU path on macOS (docs/FIRMWARE.md) -- use nRF Connect.
{ pkgs, lib, inputs, ... }:

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

  # What the phone app carries but git does not: the Lua compiled to
  # bytecode -- the glasses cannot compile main.lua themselves any more --
  # and the firmware for Update. Built without them, the app had no
  # firmware to offer.
  appAssets = ''
    cd "$DEVENV_ROOT/flutter-glaz"
    tool/compile_lua.sh
    tool/fetch_firmware.sh || echo "firmware not fetched; Update offers what is in assets/firmware" >&2
  '';
in
{
  packages = [
    pkgs.git
    pkgs.git-secret  # the app's signing key, flutter-glaz/android/*.secret
    pkgs.gnumake
    pkgs.lua5_4
  ]
  ++ lib.optional (available pkgs.gcc-arm-embedded) pkgs.gcc-arm-embedded
  ++ lib.optional (available nordic.nrfutil) nordic.nrfutil
  ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.bluez ]
  # The companion app as a Linux desktop app: audioplayers plays through
  # GStreamer, and its plugin will not configure without the headers.
  # Flutter's wrapper already brings GTK, clang, cmake and ninja.
  ++ lib.optionals pkgs.stdenv.isLinux (with pkgs.gst_all_1; [
    pkgs.libunwind  # gstreamer-1.0.pc requires it
    pkgs.libsecret  # flutter_secure_storage: the terminal's SSH keys
    gstreamer
    gst-plugins-base
    gst-plugins-good
  ]);

  languages.python = {
    enable = true;
    venv.enable = true;
    venv.requirements = ./requirements.txt;
  };

  # Flutter for the companion app, with an Android SDK to build it and one
  # emulator image to try it on. The image is the host's own architecture
  # only -- arm64 on Apple Silicon and ARM Linux, x86_64 elsewhere -- since
  # each extra one is well over a gigabyte. Talking to the glasses still
  # needs a real phone: the emulator has no Bluetooth.
  android = {
    enable = true;
    flutter.enable = true;
    # What Flutter 3.47's Gradle plugin builds against (FlutterExtension.kt:
    # compileSdk/targetSdk 36). The SDK lives in the read-only Nix store, so
    # Gradle cannot fetch missing parts itself; they must be listed here. The
    # NDK default (28.2.13676358) already matches.
    platforms.version = [ "36" ];
    buildTools.version = [ "36.0.0" "35.0.0" ];
    emulator.enable = true;
    systemImages.enable = true;
    systemImageTypes = [ "google_apis" ];
    abis = if pkgs.stdenv.hostPlatform.isAarch64 then [ "arm64-v8a" ] else [ "x86_64" ];
    googleTVAddOns.enable = false;
  };

  scripts = {
    # Create the emulator on first use, then boot it. The AVD lives in
    # .android/avd (ignored); the system image is the one in the SDK above.
    emulator-start.exec = ''
      abi=${if pkgs.stdenv.hostPlatform.isAarch64 then "arm64-v8a" else "x86_64"}
      if ! avdmanager list avd -c | grep -qx glaz; then
        echo no | avdmanager create avd --force -n glaz -d pixel_6 \
          -k "system-images;android-36;google_apis;$abi"
      fi
      emulator -avd glaz -no-snapshot-save "$@"
    '';
    # The app's signing key (flutter-glaz/android/*.secret): decrypted when
    # missing or older than its .secret, after a pull say, and only on a
    # machine with the GPG key of one of `git secret whoknows`. Without
    # one, builds are signed with the machine's debug key (AGENTS.md).
    reveal-key.exec = ''
      cd "$DEVENV_ROOT"
      stale=
      while IFS=: read -r path _; do
        [ "$path" -nt "$path.secret" ] || stale=1
      done < .gitsecret/paths/mapping.cfg
      [ -n "$stale" ] || exit 0
      for who in $(git secret whoknows 2>/dev/null); do
        if gpg --list-secret-keys "$who" >/dev/null 2>&1; then
          # git-secret asks gpg for the passphrase itself (pinentry-mode
          # loopback), on a terminal that enterShell may not have; "ask"
          # leaves it to gpg-agent's own pinentry window instead.
          if SECRETS_PINENTRY=ask git secret reveal -f >/dev/null; then
            chmod 600 $(cut -d: -f1 .gitsecret/paths/mapping.cfg)
            echo "signing key revealed"
          else
            echo "signing key: git secret reveal failed" >&2
          fi
          exit 0
        fi
      done
      echo "signing key: no GPG key for it here; builds use the debug key" >&2
    '';
    check.exec = ''./check.sh'';
    upload.exec = ''python host_test.py "$@"'';
    sprite.exec = ''python utils/show_sprite.py "$@"'';
    # The phone app, with its bytecode and firmware (appAssets above).
    apk.exec = ''
      reveal-key
      ${appAssets}
      flutter build apk --debug "$@"
    '';
    # The same app for the Linux desktop, talking to the glasses through
    # the laptop's own Bluetooth (BlueZ). A failed first configure leaves
    # /usr/local cached as the install prefix, and every later build then
    # fails to install; a fresh build directory clears it.
    linux-app.exec = ''
      ${appAssets}
      if grep -qs '^CMAKE_INSTALL_PREFIX:PATH=/usr/local$' build/linux/*/*/CMakeCache.txt; then
        rm -rf build/linux
      fi
      flutter build linux --debug "$@"
      ls -d "$PWD"/build/linux/*/*/bundle/glaz
    '';
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

    reveal-key

    echo "glaz dev shell"
    echo "  check            static checks for the Lua side"
    echo "  upload           upload the app to the glasses and listen"
    echo "  sprite NAME N    show sprites/NAME.lua at N x on the glasses"
    echo "  emulator-start   boot the Android emulator (first run creates it)"
    echo "  apk              build the phone app (Lua bytecode and firmware first)"
    echo "  reveal-key       decrypt the app's signing key (git-secret)"
    echo "  linux-app        the same app for the Linux desktop"
    echo "  cd flutter-glaz && tool/compile_lua.sh && flutter run    the companion app"
  '';
}

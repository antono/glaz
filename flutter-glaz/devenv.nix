# Development environment for the companion app: Flutter, an Android SDK
# and an emulator, kept apart from the repository's own (../devenv.nix),
# which has the Lua, the Python host tools and the firmware toolchain.
#
#   cd flutter-glaz
#   devenv shell          # enter it; first run downloads the Android SDK
#
# What is in here, and why:
#
#   flutter + Android SDK + JDK 17
#                   building and running the app
#   cc (stdenv)     tool/compile_lua.sh builds the firmware's own luac
#   git-secret      the app's signing key, android/*.secret
#   gstreamer, libunwind, libsecret
#                   Linux only: the app as a desktop app
#
# macOS gap: iOS and macOS builds need Xcode, which Nix cannot provide.
{ pkgs, lib, ... }:

let
  # What the app carries but git does not: the Lua compiled to bytecode --
  # the glasses cannot compile main.lua themselves any more -- and the
  # firmware for Update. Built without them, the app had no firmware to
  # offer. Without the build of glaz/stable (the root shell's `firmware`)
  # the app is not built at all; FIRMWARE_FEATURE=glaz/<topic> adds a
  # feature branch's build too (tool/fetch_firmware.sh).
  appAssets = ''
    cd "$DEVENV_ROOT"
    tool/compile_lua.sh
    tool/fetch_firmware.sh
  '';
in
{
  packages = [
    pkgs.git
    pkgs.git-secret
  ]
  # The app as a Linux desktop app: audioplayers plays through GStreamer,
  # and its plugin will not configure without the headers. Flutter's
  # wrapper already brings GTK, clang, cmake and ninja.
  ++ lib.optionals pkgs.stdenv.isLinux (with pkgs.gst_all_1; [
    pkgs.libunwind  # gstreamer-1.0.pc requires it
    pkgs.libsecret  # flutter_secure_storage: the terminal's SSH keys
    gstreamer
    gst-plugins-base
    gst-plugins-good
  ]);

  # Flutter, with an Android SDK to build the app and one emulator image to
  # try it on. The image is the host's own architecture only -- arm64 on
  # Apple Silicon and ARM Linux, x86_64 elsewhere -- since each extra one is
  # well over a gigabyte. Talking to the glasses still needs a real phone:
  # the emulator has no Bluetooth.
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
    # The app's signing key (android/*.secret): decrypted when missing or
    # older than its .secret, after a pull say, and only on a machine with
    # the GPG key of one of `git secret whoknows`. Without one, builds are
    # signed with the machine's debug key (../AGENTS.md). git-secret keeps
    # its paths relative to the repository root, so it runs from there.
    reveal-key.exec = ''
      cd "$DEVENV_ROOT/.."
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
    # refuses. Its android-sdk setting likewise beats ANDROID_HOME: one left
    # at ~/Android/Sdk builds against an SDK without this shell's
    # build-tools and platforms ("Failed to install the following SDK
    # components"). Point both at this shell's on every entry. This writes
    # Flutter's user config (~/.config/flutter/settings), which is harmless
    # here: Flutter itself only exists inside this shell.
    flutter_settings=$(flutter config --list 2>/dev/null)
    if [ "$(sed -n 's/^ *jdk-dir: //p' <<<"$flutter_settings")" != "$JAVA_HOME" ]; then
      flutter config --jdk-dir="$JAVA_HOME" >/dev/null 2>&1
    fi
    if [ "$(sed -n 's/^ *android-sdk: //p' <<<"$flutter_settings")" != "$ANDROID_HOME" ]; then
      flutter config --android-sdk="$ANDROID_HOME" >/dev/null 2>&1
    fi
    unset flutter_settings

    reveal-key

    echo "glaz app dev shell"
    echo "  emulator-start   boot the Android emulator (first run creates it)"
    echo "  apk              build the phone app (Lua bytecode and firmware first)"
    echo "  linux-app        the same app for the Linux desktop"
    echo "  reveal-key       decrypt the app's signing key (git-secret)"
    echo "  tool/compile_lua.sh && flutter run    run the app"
  '';
}

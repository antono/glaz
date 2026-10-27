# The companion app (flutter-glaz/) as a Linux desktop app:
#
#   nix build              # ./result/bin/glaz
#   nix run                # or straight away
#   nix profile install .  # with a launcher entry in the desktop's app menu
#
# It talks to the glasses through the laptop's own Bluetooth (BlueZ). The
# development environment is devenv's (flutter-glaz/devenv.nix), not this flake's.
{
  description = "glaz: companion app for the Brilliant Labs Frame glasses";

  inputs = {
    # Locked to the same nixpkgs as flutter-glaz/devenv.lock, so the Flutter here is the
    # one the app is developed with.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # The firmware's own Lua, which Upload's bytecode is compiled with
    # (flutter-glaz/tool/compile_lua.sh). Only libraries/lua is used.
    frame-codebase = {
      url = "github:brilliantlabsAR/frame-codebase";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, frame-codebase }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # One version, the phone app's own (pubspec.yaml), without the +build.
      version = builtins.head (
        builtins.match ".*\nversion: ([0-9.]+).*" (builtins.readFile ./flutter-glaz/pubspec.yaml)
      );

      # What Firmware offers for Update: the official releases
      # tool/fetch_firmware.sh would fetch today. A custom build of the
      # firmware is not part of this; build it with devenv.
      firmware = [
        { tag = "v25.278.1113"; hash = "sha256-6fLPsL1/e8zu1l75CxllFzhP8E44XeQV1fMMXzpggrU="; }
        { tag = "v25.080.0838"; hash = "sha256-VsPu2Ix4cj6/tlnDXTIFLu9CEAHmBGmR+VV1qrA5Wsc="; }
        { tag = "v25.031.0924"; hash = "sha256-j5vz6kr3ItLm5klrOfsaOYCeEgdpS5uF23LNwxxT/3Q="; }
      ];

      mkGlaz =
        pkgs:
        let
          zips = map (
            { tag, hash }:
            pkgs.fetchurl {
              url = "https://github.com/brilliantlabsAR/frame-codebase/releases/download/${tag}/frame-firmware-${tag}.zip";
              inherit hash;
            }
          ) firmware;

          desktopItem = pkgs.makeDesktopItem {
            name = "dev.glaz.glaz";
            desktopName = "Glaz";
            comment = "Companion app for the Frame smart glasses";
            exec = "glaz";
            icon = "glaz";
            startupWMClass = "dev.glaz.glaz";
            categories = [ "Utility" ];
          };
        in
        pkgs.flutter347.buildFlutterApplication {
          pname = "glaz";
          inherit version;

          # The app and the Lua its assets link to (assets/lua -> ../../..).
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./flutter-glaz
              ./glaz.lua
              ./glaz.frame.lua
              ./glaz.halo.lua
              ./app
              ./modules
              ./sprites
            ];
          };
          sourceRoot = "source/flutter-glaz";

          autoPubspecLock = ./flutter-glaz/pubspec.lock;

          nativeBuildInputs = [ pkgs.copyDesktopItems ];
          # audioplayers plays through GStreamer; gstreamer-1.0.pc wants
          # libunwind. The plugins end up on the wrapper's GStreamer path.
          # flutter_secure_storage keeps the terminal's SSH keys in libsecret.
          buildInputs = with pkgs.gst_all_1; [
            pkgs.libunwind
            pkgs.libsecret
            gstreamer
            gst-plugins-base
            gst-plugins-good
          ];

          # What git does not carry: the bytecode and the firmware.
          preBuild = ''
            FRAME_CODEBASE=${frame-codebase} bash tool/compile_lua.sh
            ${lib.concatMapStrings (z: "cp ${z} assets/firmware/${z.name}\n") zips}
          '';

          desktopItems = [ desktopItem ];

          postInstall = ''
            install -Dm644 assets/logo/logo.png \
              $out/share/icons/hicolor/512x512/apps/glaz.png
          '';

          meta = {
            description = "Companion app for the Brilliant Labs Frame smart glasses";
            mainProgram = "glaz";
            platforms = systems;
          };
        };
    in
    {
      packages = forAllSystems (pkgs: rec {
        glaz = mkGlaz pkgs;
        default = glaz;
      });
    };
}

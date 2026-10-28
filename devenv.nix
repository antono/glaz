# Development environment for glaz: the Lua app on the glasses, the Python
# host tools and the Frame firmware. The Flutter companion app has its own,
# kept apart: flutter-glaz/devenv.nix.
#
#   devenv shell
#
# Linux is the primary target; macOS works too, with one gap noted below.
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
#
# macOS gap: there is no command-line DFU path on macOS (docs/FIRMWARE.md)
# -- use nRF Connect.
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
  };

  scripts = {
    check.exec = ''./check.sh'';
    upload.exec = ''python host_test.py "$@"'';
    sprite.exec = ''python utils/show_sprite.py "$@"'';
    # every app on emulated Frame and Halo (docs/TESTING.md)
    tests.exec = ''pytest tests "$@"'';
    # the same, Halo's only
    halo.exec = ''pytest tests -k halo "$@"'';
    # screenshots of every app on both, for the docs
    screens.exec = ''python utils/screenshots.py "$@"'';
    # our firmware from a branch, glaz/stable by default, for the phone app
    firmware.exec = ''utils/build_firmware.sh "$@"'';
  };

  enterShell = ''
    echo "glaz dev shell"
    echo "  check            static checks for the Lua side"
    echo "  upload           upload the app to the glasses and listen"
    echo "  sprite NAME N    show sprites/NAME.lua at N x on the glasses"
    echo "  tests            every app on emulated Frame and Halo (pytest)"
    echo "  halo             the same, Halo only"
    echo "  screens [-o DIR] screenshots of every app, for the docs"
    echo "  firmware [REF]   build our firmware, glaz/stable or REF, for the phone app"
    echo "  the companion app has its own shell: cd flutter-glaz && devenv shell"
  '';
}

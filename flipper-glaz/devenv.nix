# Development environment for flipper-glaz, the Flipper Zero remote for
# the glasses, apart from the one at the top of the repo: no Flutter, no
# Android SDK, just Rust for the Flipper.
#
#   cd flipper-glaz && devenv shell
#
#   rust            the nightly in rust-toolchain.toml, with the Flipper's
#                   target, thumbv7em-none-eabihf (flipperzero-rs needs
#                   nightly: the binary is named .fap)
#   flipperzero-tools
#                   `storage` and `run-fap`: the .fap onto the Flipper
#                   over USB. Not in nixpkgs; `cargo install`ed into the
#                   shell's state on first use. serialport finds the
#                   Flipper through libudev, hence pkg-config and udev.
{ pkgs, lib, config, ... }:

let
  fap = "target/thumbv7em-none-eabihf/release/flipper-glaz.fap";
  # Where the Flipper keeps it: Apps > Bluetooth.
  dest = "/ext/apps/Bluetooth/flipper-glaz.fap";
  tools = "${config.devenv.state}/flipperzero-tools";
in
{
  languages.rust = {
    enable = true;
    toolchainFile = ./rust-toolchain.toml;
  };

  packages = [ pkgs.pkg-config ]
    ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.udev ];

  scripts = {
    flipper-tools.exec = ''
      if [ ! -x "${tools}/bin/run-fap" ]; then
        echo "installing flipperzero-tools (once)" >&2
        cargo install --locked --root "${tools}" --target "$(rustc -vV | sed -n 's/^host: //p')" flipperzero-tools >&2
      fi
      echo "${tools}/bin"
    '';
    fap.exec = ''cd "$DEVENV_ROOT" && cargo build --release "$@" && ls -l ${fap}'';
    # Copy it to the SD card; open it from Apps > Bluetooth.
    fap-install.exec = ''
      bin=$(flipper-tools) && fap && "$bin/storage" send ${fap} ${dest}
    '';
    # Copy and start it at once, the Flipper's log on this terminal.
    fap-run.exec = ''
      bin=$(flipper-tools) && fap && "$bin/run-fap" ${fap} "$@"
    '';
  };

  enterShell = ''
    echo "flipper-glaz dev shell"
    echo "  fap           build $(basename ${fap})"
    echo "  fap-install   build and copy it to the Flipper over USB"
    echo "  fap-run       build, copy and start it, with the Flipper's log"
  '';
}

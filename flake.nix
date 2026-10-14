{
  description = "Dev shell for nerves_livebook_fp3 — Nerves/Livebook firmware for the Fairphone 3";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Matches .tool-versions: erlang 29.1.1, elixir 1.20.4-otp-29.
        beamPkgs = pkgs.beam.packages.erlang_29;
        erlang = beamPkgs.erlang;
        elixir = beamPkgs.elixir_1_20;
      in
      {
        devShells.default = pkgs.mkShell {
          name = "nerves_livebook_fp3";

          packages = [
            erlang
            elixir
            beamPkgs.hex

            # Nerves firmware packaging.
            # hardeningDisable: current nixpkgs' gcc treats fwup's
            # non-literal cfg_error() format strings as -Werror, failing
            # the build; upstream fwup itself is fine.
            (pkgs.fwup.overrideAttrs (old: {
              hardeningDisable = (old.hardeningDisable or [ ]) ++ [ "format" ];
            }))
            pkgs.squashfsTools

            # scripts/flash-fp3.sh (fastboot, adb)
            pkgs.android-tools

            # Buildroot's own host prerequisites (nerves_system_fp3 README),
            # only exercised when actually building the system from source
            # (nerves: [compile: true]) rather than using the prebuilt release.
            pkgs.cmake
            pkgs.bc

            # Building NIFs (input_event, nerves_uevent, vintage_net_wifi,
            # arm_ai's Rust NIF, ...)
            pkgs.gnumake
            pkgs.gcc
            pkgs.pkg-config
            pkgs.autoconf
            pkgs.automake
            pkgs.libtool
            pkgs.openssl

            # Fetching deps and the prebuilt nerves_system_fp3 release
            pkgs.git
            pkgs.curl
            pkgs.wget
            pkgs.unzip

            # arm_ai has no precompiled release; it always builds its NIF
            # from source, cross-compiled for the phone.
            pkgs.rustup

            pkgs.glibcLocales
          ];

          LANG = "en_US.UTF-8";
          LOCALE_ARCHIVE = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux
            "${pkgs.glibcLocales}/lib/locale/locale-archive";

          shellHook = ''
            # Keep Mix/Hex/Rebar/Rust state local to the project (resolved at
            # shell-entry time, not Nix-eval time — a flake-relative path
            # like ./.nix-mix would point into the read-only store copy of
            # this flake's source instead of the real working directory) so
            # the hex/rebar binaries (compiled against this exact Erlang
            # ABI) and the Rust toolchain don't clash with other projects.
            project_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
            export MIX_HOME="$project_root/.nix-mix"
            export HEX_HOME="$project_root/.nix-hex"
            export RUSTUP_HOME="$project_root/.nix-rustup"
            export CARGO_HOME="$project_root/.nix-cargo"
            export PATH="$MIX_HOME/bin:$HEX_HOME/bin:$CARGO_HOME/bin:$PATH"

            mix local.hex --if-missing --force >/dev/null
            mix local.rebar --if-missing --force >/dev/null

            if ! mix archive 2>/dev/null | grep -q nerves_bootstrap; then
              mix archive.install hex nerves_bootstrap "~> 1.14" --force >/dev/null
            fi

            if ! rustup target list --installed 2>/dev/null | grep -q aarch64-unknown-linux-gnu; then
              rustup toolchain install stable >/dev/null 2>&1
              rustup default stable >/dev/null 2>&1
              rustup target add aarch64-unknown-linux-gnu >/dev/null 2>&1
            fi

            echo "nerves_livebook_fp3 dev shell — erlang $(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell), $(elixir --short-version 2>/dev/null || elixir --version | tail -1)"
          '';
        };
      });
}

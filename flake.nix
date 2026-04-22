{
  description = "Development environment for codetracer-shell-recorders";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks.url = "github:cachix/git-hooks.nix";

    # Non-flake source for the codetracer trace format crates.
    # The Rust crates in this repo depend on codetracer_trace_types and
    # codetracer_trace_writer via relative path deps. This input provides the
    # source so Nix package builds can resolve those paths.
    codetracer-trace-format = {
      url = "github:metacraft-labs/codetracer-trace-format/main";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      fenix,
      pre-commit-hooks,
      codetracer-trace-format,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSystem = nixpkgs.lib.genAttrs systems;

      rust-toolchain-for =
        system:
        fenix.packages.${system}.fromToolchainFile {
          file = ./rust-toolchain.toml;
          sha256 = "sha256-Qxt8XAuaUR2OMdKbN4u8dBJOhSHxS+uS06Wl9+flVEk=";
        };
    in
    {
      checks = forEachSystem (system: {
        pre-commit-check = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            lint = {
              enable = true;
              name = "Lint";
              entry = "just lint";
              language = "system";
              pass_filenames = false;
            };
          };
        };
      });

      devShells = forEachSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          preCommit = self.checks.${system}.pre-commit-check;
          isLinux = pkgs.stdenv.isLinux;
          isDarwin = pkgs.stdenv.isDarwin;
        in
        {
          default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                # Shell interpreters (for running recorded scripts)
                bash
                zsh

                # Rust toolchain
                (rust-toolchain-for system)

                # For trace format serialization
                pkg-config
                capnproto

                # Build automation and dev tools
                just
                git-lfs
              ]
              ++ pkgs.lib.optionals isLinux [
                glibc.dev
              ]
              ++ pkgs.lib.optionals isDarwin [
                libiconv
                darwin.apple_sdk.frameworks.CoreFoundation
                darwin.apple_sdk.frameworks.Security
              ]
              ++ preCommit.enabledPackages;

            inherit (preCommit) shellHook;
          };
        }
      );

      packages = forEachSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          isDarwin = pkgs.stdenv.isDarwin;
        in
        {
          # The ct-shell-trace-writer binary reads debugger wire-protocol events
          # from stdin and writes a CodeTracer trace. This package also installs
          # the bash and zsh launcher/recorder scripts.
          default = pkgs.rustPlatform.buildRustPackage {
            pname = "ct-shell-trace-writer";
            version = "0.1.0";

            src = ./.;

            cargoLock.lockFile = ./Cargo.lock;

            nativeBuildInputs = with pkgs; [
              pkg-config
              capnproto
            ];

            buildInputs = pkgs.lib.optionals isDarwin (
              with pkgs;
              [
                libiconv
                darwin.apple_sdk.frameworks.CoreFoundation
                darwin.apple_sdk.frameworks.Security
              ]
            );

            # The Cargo.toml references codetracer_trace_types and
            # codetracer_trace_writer via relative path deps that assume a
            # sibling codetracer-trace-format repo checkout. Patch them to
            # point at the codetracer-trace-format flake input in the nix store.
            postPatch = ''
              substituteInPlace crates/ct-shell-trace-writer/Cargo.toml \
                --replace-fail \
                  'path = "../../../codetracer-trace-format/codetracer_trace_types"' \
                  'path = "${codetracer-trace-format}/codetracer_trace_types"' \
                --replace-fail \
                  'path = "../../../codetracer-trace-format/codetracer_trace_writer_nim"' \
                  'path = "${codetracer-trace-format}/codetracer_trace_writer_nim"'
            '';

            # Install the binary plus the shell launcher/recorder scripts
            postInstall = ''
              cp -r bash-recorder $out/
              cp -r zsh-recorder $out/
            '';

            # Integration tests require a full codetracer checkout with trace
            # fixtures, so they are not runnable inside the Nix sandbox.
            doCheck = false;
          };
        }
      );
    };
}

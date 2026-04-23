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

    # Nim implementation of the trace writer. The Rust crate
    # codetracer_trace_writer_nim links against a pre-built Nim static
    # library (libcodetracer_trace_writer.a) produced from this repo.
    codetracer-trace-format-nim = {
      url = "github:metacraft-labs/codetracer-trace-format-nim/main";
      flake = false;
    };

    # Nim library dependencies required by codetracer-trace-format-nim.
    # Fetched as flake inputs so the Nim compiler can find them inside the
    # Nix sandbox without needing network access for `nimble install`.
    nim-stew = {
      url = "github:status-im/nim-stew";
      flake = false;
    };
    nim-results = {
      url = "github:arnetheduck/nim-results";
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
      codetracer-trace-format-nim,
      nim-stew,
      nim-results,
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

                # Nim compiler + nimble — needed to build the trace writer static library
                # from codetracer-trace-format-nim before cargo can link it.
                nim
                nimble

                # For trace format serialization
                pkg-config
                capnproto
                zstd

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

              # Nim toolchain — used in preBuild to compile the trace writer
              # static library from codetracer-trace-format-nim.
              nim
              nimble

              # zstd headers/lib — needed both by the Nim static library
              # (linked at compile time) and by the Rust crate at link time.
              zstd
            ];

            buildInputs =
              [ pkgs.zstd ]
              ++ pkgs.lib.optionals isDarwin (
                with pkgs;
                [
                  libiconv
                  darwin.apple_sdk.frameworks.CoreFoundation
                  darwin.apple_sdk.frameworks.Security
                ]
              );

            # Build the Nim trace writer static library that the Rust
            # crate codetracer_trace_writer_nim links against at build time.
            # The Nix store source is read-only, so we copy it to a writable
            # location first.
            preBuild = ''
              nim_src="$TMPDIR/codetracer-trace-format-nim"
              cp -r ${codetracer-trace-format-nim} "$nim_src"
              chmod -R u+w "$nim_src"

              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"

              # Compile the Nim static library. Dependencies (stew, results) are
              # provided as -p search paths from their flake inputs, so no network
              # access (nimble install) is needed inside the sandbox.
              nim c --app:staticlib --mm:arc --noMain -d:release \
                --passC:'-fPIC' \
                -p:"$nim_src/src" \
                -p:${nim-stew} \
                -p:${nim-results} \
                --nimcache:"$TMPDIR/nimcache" \
                -o:"$TMPDIR/libcodetracer_trace_writer.a" \
                "$nim_src/src/codetracer_trace_writer_ffi.nim"

              export CODETRACER_NIM_LIB_DIR="$TMPDIR"
            '';

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
                  'path = "${codetracer-trace-format}/codetracer_trace_writer_nim"' \
                --replace-fail \
                  'path = "../../../codetracer-trace-format/codetracer_trace_writer"' \
                  'path = "${codetracer-trace-format}/codetracer_trace_writer"'
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

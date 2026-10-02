{
  description = "Development environment for codetracer-shell-recorders";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks.url = "github:cachix/git-hooks.nix";

    # Non-flake source for the codetracer trace format crates.
    # The Rust crates in this repo depend on codetracer_trace_types and
    # codetracer_trace_writer_nim via relative path deps. This input provides
    # the source so Nix package builds can resolve those paths. The
    # codetracer_trace_writer_nim build script compiles the Nim C ABI archive
    # with the flags the library requires (--threads:off, one process heap),
    # so this revision must carry that build script.
    codetracer-trace-format = {
      url = "github:metacraft-labs/codetracer-trace-format/8fd695e0521277fe2455b7f717a9d4f631461731";
      flake = false;
    };

    # Nim implementation of the trace writer: the sources that build script
    # compiles. This revision must carry the process lock its C ABI needs
    # when built --threads:off.
    codetracer-trace-format-nim = {
      url = "github:metacraft-labs/codetracer-trace-format-nim/9c4bcfff106f7c083974903ba5153be50be91a39";
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
          # git-hooks.nix installs `.pre-commit-config.yaml` and git hooks into
          # `git rev-parse --show-toplevel` of the directory the shell is entered
          # from, so `nix develop /path/to/this-repo` run inside another checkout
          # would plant this repository's hooks there. `ownRepoOnly` runs a snippet
          # only when that toplevel is this repository, recognised by a `flake.nix`
          # identical to the one this shell was evaluated from; anything it cannot
          # establish counts as another repository, so it fails safe.
          # tests/test_dev_shell_writes_nothing_elsewhere.sh
          ownRepoOnly = script: ''
            _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
              && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
                = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
            ${script}
            # git-hooks.nix's installer leaves core.hooksPath as the RELATIVE
            # `.git/hooks`, in the config every worktree shares. A linked worktree
            # cannot resolve it (there `.git` is a file), so git silently runs no
            # hooks there. Point it at the common hooks directory instead.
            if [ "$(${pkgs.git}/bin/git config --local --get core.hooksPath 2>/dev/null)" = .git/hooks ]; then
              ${pkgs.git}/bin/git config --local core.hooksPath "$(${pkgs.git}/bin/git rev-parse --path-format=absolute --git-common-dir)/hooks"
            fi
            fi
            unset _own_repo_root
          '';
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
                prek
                git-lfs
              ]
              ++ pkgs.lib.optionals isLinux [ glibc.dev ]
              ++ pkgs.lib.optionals isDarwin [ libiconv ]
              ++ preCommit.enabledPackages;

            # `cargo <subcommand>` looks for `cargo-<subcommand>` in
            # `$CARGO_HOME/bin` BEFORE it searches PATH. On any machine with
            # rustup — including the self-hosted macOS runner — that directory
            # holds rustup's proxies, so `cargo fmt` and `cargo clippy` run
            # rustup's `cargo-fmt` / `cargo-clippy` instead of this shell's
            # toolchain, and fail with "'cargo-fmt' is not installed for the
            # toolchain".
            #
            # The shell therefore gets its own CARGO_HOME with no `bin/`, so
            # subcommand lookup falls through to PATH. `registry/` and `git/`
            # are symlinks to the real CARGO_HOME, and so are its config and
            # credentials when present: the download cache is shared, and only
            # the proxy directory is left behind.
            shellHook = ownRepoOnly preCommit.shellHook + ''
              _ctsh_real_cargo_home="''${CARGO_HOME:-$HOME/.cargo}"
              _ctsh_cargo_home="''${XDG_CACHE_HOME:-$HOME/.cache}/codetracer-shell-recorders/cargo-home"
              if [ "$_ctsh_real_cargo_home" != "$_ctsh_cargo_home" ]; then
                mkdir -p "$_ctsh_cargo_home" \
                  "$_ctsh_real_cargo_home/registry" "$_ctsh_real_cargo_home/git"
                # Re-pointed on every entry, so a changed CARGO_HOME is followed
                # rather than left sharing the previous one's cache. Only a link
                # is ever replaced; a real file placed here is left alone.
                for _ctsh_entry in registry git config.toml credentials.toml; do
                  if [ -e "$_ctsh_real_cargo_home/$_ctsh_entry" ] &&
                    { [ -L "$_ctsh_cargo_home/$_ctsh_entry" ] ||
                      [ ! -e "$_ctsh_cargo_home/$_ctsh_entry" ]; }; then
                    ln -sfn "$_ctsh_real_cargo_home/$_ctsh_entry" "$_ctsh_cargo_home/$_ctsh_entry"
                  fi
                done
                export CARGO_HOME="$_ctsh_cargo_home"
              fi
              unset _ctsh_real_cargo_home _ctsh_cargo_home _ctsh_entry
            '';
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

            buildInputs = [ pkgs.zstd ] ++ pkgs.lib.optionals isDarwin (with pkgs; [ libiconv ]);

            # The Rust crate codetracer_trace_writer_nim compiles the Nim
            # trace writer's C ABI archive in its build script and links it;
            # this package does not build that archive itself. The Nix store
            # source is read-only, so the build script gets a writable copy.
            preBuild = ''
              nim_src="$TMPDIR/codetracer-trace-format-nim"
              cp -r ${codetracer-trace-format-nim} "$nim_src"
              chmod -R u+w "$nim_src"

              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"

              # codetracer_trace_writer_nim's build.rs (in
              # codetracer-trace-format) looks for the Nim FFI entry
              # point at ``../codetracer-trace-format-nim/src/...``
              # by default, then falls back to
              # ``CODETRACER_TRACE_FORMAT_NIM_DIR``.  Point it at the
              # writable copy preBuild made above so the build doesn't
              # abort with "Nim FFI entry point not found at
              # /nix/store/codetracer-trace-format-nim/src/...".
              # Also skip ``nimble install --depsOnly`` because the
              # nix sandbox has no network access; stew + results come
              # from their flake inputs as extra Nim paths instead.
              export CODETRACER_TRACE_FORMAT_NIM_DIR="$nim_src"
              export CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL=1
              export CODETRACER_TRACE_FORMAT_NIM_EXTRA_PATHS="${nim-stew}:${nim-results}"
            '';

            # The Cargo.toml references codetracer_trace_types and
            # codetracer_trace_writer via relative path deps that assume a
            # sibling codetracer-trace-format repo checkout. Patch them to
            # point at the codetracer-trace-format flake input in the nix store.
            postPatch = ''
              # codetracer_trace_writer (the Rust-native CBOR+Zstd
              # writer) is no longer pulled in here -- shell
              # recorders moved to the Nim-backed
              # codetracer_trace_writer_nim per the CTFS-only
              # contract.  Drop the third --replace-fail so the
              # nix build doesn't abort on the obsolete pattern.
              substituteInPlace crates/ct-shell-trace-writer/Cargo.toml \
                --replace-fail \
                  'path = "../../../codetracer-trace-format/codetracer_trace_types"' \
                  'path = "${codetracer-trace-format}/codetracer_trace_types"' \
                --replace-fail \
                  'path = "../../../codetracer-trace-format/codetracer_trace_writer_nim"' \
                  'path = "${codetracer-trace-format}/codetracer_trace_writer_nim"'
            '';

            # The trace writer's C ABI library warns at compile time when it
            # is built --threads:on: a writer closed on another thread than
            # the one that recorded into it is then freed into a dead
            # per-thread heap. Refuse a package whose linked archive drew
            # that warning (the build script's captured output holds it).
            postBuild = ''
              ffi_out=$(find target -path '*/build/codetracer_trace_writer_nim-*' \
                \( -name output -o -name stderr \) -type f)
              if [ -z "$ffi_out" ]; then
                echo "codetracer_trace_writer_nim build script output not found" >&2
                exit 1
              fi
              if grep -l "should be built with --threads:off" $ffi_out >&2; then
                echo "the trace writer C ABI archive was built --threads:on" >&2
                exit 1
              fi
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

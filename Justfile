alias t := test
alias fmt := format

# Build the trace writer binary
build:
    cargo build --release

# Run all tests: cargo (unit + integration) + CLI convention guards.
test:
    cargo test
    just verify-cli-convention
    just test-bash-cli
    just test-zsh-cli

# Verify both launchers and the trace writer comply with
# `Recorder-CLI-Conventions.md` (CTFS-only, env-var fallbacks, etc.).
# See tests/verify-cli-convention-no-silent-skip.sh for the assertion list.
verify-cli-convention:
    bash tests/verify-cli-convention-no-silent-skip.sh

# End-to-end Bash launcher CLI tests (env vars, format rejection,
# ct-print round-trip).
test-bash-cli:
    bash tests/test_bash_recorder_cli.sh

# End-to-end Zsh launcher CLI tests (skipped at runtime if zsh is
# missing — see require_zsh! in the cargo zsh tests for the convention).
test-zsh-cli:
    bash tests/test_zsh_recorder_cli.sh

# Format Rust code
format-rust:
    cargo fmt

# Format Nix files
format-nix:
    if command -v nixfmt >/dev/null; then find . -name '*.nix' -print0 | xargs -0 nixfmt; fi

# Format all code
format:
    just format-rust
    just format-nix

# Lint Rust code, then run the CLI convention guard so a regression in
# launcher / writer help, env var handling, or `--format` rejection
# fails `just lint` exactly the same way `just test` does.
lint-rust:
    cargo fmt --check
    cargo clippy

# Lint Nix files
lint-nix:
    if command -v nixfmt >/dev/null; then find . -name '*.nix' -print0 | xargs -0 nixfmt --check; fi

# Lint all code
lint:
    just lint-rust
    just lint-nix
    just verify-cli-convention

# Run cross-repo integration tests against sibling codetracer repo
cross-test *ARGS:
    bash scripts/run-cross-repo-tests.sh {{ ARGS }}

# Bump version in Cargo.toml AND the top-level VERSION file (single
# source of truth for the launcher --version output).  Usage:
#   just bump-version 0.2.0
bump-version version:
    sed -i 's/^version = ".*"/version = "{{version}}"/' crates/ct-shell-trace-writer/Cargo.toml
    echo "{{version}}" > VERSION
    @echo "ct-shell-trace-writer → {{version}} (Cargo.toml + VERSION)"

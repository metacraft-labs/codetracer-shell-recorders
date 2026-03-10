alias t := test
alias fmt := format

# Build the trace writer binary
build:
    cargo build --release

# Run all tests
test:
    cargo test

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

# Lint Rust code
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

# Run cross-repo integration tests against sibling codetracer repo
cross-test *ARGS:
    bash scripts/run-cross-repo-tests.sh {{ ARGS }}

## Reprobuild dev env + build recipe for codetracer-shell-recorders.
##
## Ships two shell-script launchers (``bash-recorder``, ``zsh-recorder``)
## plus a single Rust workspace member ``crates/ct-shell-trace-writer``
## that emits the CTFS trace stream. The launchers are interpreted shell
## scripts; ``repro build`` therefore only materialises the Rust binary
## via native cargo edges. The launchers are installed at packaging time
## from the repo's ``bash-recorder/`` and ``zsh-recorder/`` directories
## without a build step.
##
## Per ``codetracer-specs/Repo-Requirements.md`` §2.8 the recipe
## expresses build and test execution NATIVELY through typed-tool
## edges (`cargo.build`, `cargo.test`). No shell delegation.

import repro_project_dsl

package codetracer_shell_recorders:
  uses:
    "rustc >=1.85"
    "cargo >=1.85"
    "nim >=2.2 <3.0"
    "nimble"
    "capnp"
    "zstd"
    # ``bash`` is the launcher interpreter. On Linux/macOS the nix
    # flake supplies it via ``nixpkgs#bash``; on Windows the MR2
    # ``packages/bash.nim`` tarball entry materialises bash.exe out
    # of a PortableGit archive into the engine's store. The build
    # edge therefore invokes the store-provisioned bash rather than
    # whichever bash happens to be on PATH.
    "bash"
    when not defined(windows):
      "pkg-config"
      "openssl"

  executable ctShellTraceWriter:
    name: "ct-shell-trace-writer"

  devEnv:
    activity "default"

  build:
    const binarySuffix = (when defined(windows): ".exe" else: "")
    const traceWriterBinary =
      "target/release/ct-shell-trace-writer" & binarySuffix

    let traceWriterBuild = cargo.build(
      locked = true,
      release = true,
      manifestPath = "crates/ct-shell-trace-writer/Cargo.toml",
      actionId = "ct-shell-trace-writer.cargo-build",
      extraInputs = @[
        "Cargo.toml", "Cargo.lock",
        "crates/ct-shell-trace-writer/Cargo.toml",
        "crates/ct-shell-trace-writer/src"
      ],
      extraOutputs = @[traceWriterBinary])
    discard collect("default", @[traceWriterBuild])

    let testsBuild = cargo.test(
      locked = true,
      noRun = true,
      actionId = "codetracer-shell-recorders.cargo-test-build",
      extraInputs = @["Cargo.toml", "Cargo.lock", "crates", "tests"],
      extraOutputs = @["target/debug/deps"])

    let testsRun = cargo.test(
      locked = true,
      actionId = "codetracer-shell-recorders.cargo-test-run",
      after = @[testsBuild.action],
      extraInputs = @[
        "Cargo.toml", "Cargo.lock",
        "crates", "tests",
        "target/debug/deps"
      ])

    discard collect("test", @[testsRun.action])

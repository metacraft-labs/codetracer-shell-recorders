## Reprobuild dev env + build recipe for codetracer-shell-recorders.
##
## Ships two interpreted shell-script launchers (``bash-recorder/``,
## ``zsh-recorder/``) plus a single Rust workspace member —
## ``crates/ct-shell-trace-writer`` — that reads debugger wire-protocol
## events from stdin and writes the canonical CTFS ``.ct`` container. The
## launchers are interpreted at packaging time straight from the repo's
## ``bash-recorder/`` / ``zsh-recorder/`` directories with no build step,
## so ``repro build`` only materialises the Rust binary via native cargo
## edges.
##
## Mirrors the dev shell declared in ``flake.nix`` (Linux/macOS).
## ``repro build`` / ``repro test`` reproduce the same artefact and the
## same test set that ``just build`` / ``just test`` (``cargo build
## --release`` / ``cargo test``) produce today. Per
## ``codetracer-specs/Repo-Requirements.md`` §2.8 the recipe expresses
## build and test execution NATIVELY through typed-tool edges
## (``cargo.build``, ``cargo.test``) — no ``shell(command = "bash
## scripts/...")`` delegation, which would defeat the engine's
## incremental-build, action-cache, and per-test invalidation.
##
## **This repo is a LEAF (single-crate Rust workspace).** The lone
## member ``crates/ct-shell-trace-writer`` depends on TWO crates from the
## sibling ``codetracer-trace-format`` repo — ``codetracer_trace_types``
## and ``codetracer_trace_writer_nim`` — but purely as cargo ``path``
## dependencies (``path = "../../../codetracer-trace-format/..."`` in the
## crate's ``Cargo.toml``). Cargo resolves those sibling ``path`` deps
## itself, in-process, exactly the way the sibling
## ``codetracer-trace-format`` repo's own ``repro.nim`` documents its ONE
## cross-repo input (the Nim FFI compiled INSIDE a cargo ``build.rs``):
## the consumption happens inside cargo, OUT of reprobuild's reach. The
## reprobuild SC-11 develop-mode source-threading only threads a sibling
## ``library``'s ``src/`` onto a CONSUMER's OWN ``nim c --path:`` — it has
## no cargo/Rust-path channel (see
## ``reprobuild-specs/Cross-Repo-Source-Consumption.md`` §13: the landed
## channels are the executable, C/C++ library, and Nim-source channels;
## there is no from-source cargo channel). So — like
## ``codetracer-trace-format`` itself — this repo declares NO
## ``uses: "<sibling>"`` edge; the ``uses:`` block is the toolchain floor
## only, and the cross-repo ``codetracer_trace_writer_nim`` FFI is built
## by cargo's build.rs (which runs its own ``nimble install --depsOnly``
## + ``nim c``), so the toolchain floor mirrors exactly what
## ``codetracer-trace-format`` and the other Rust recorder recipes declare
## for the identical ``codetracer_trace_writer_nim`` dependency.
##
## **The `just test` corpus.** ``just test`` runs FOUR things, not one:
## ``cargo test`` (the whole-workspace unit + integration suite) PLUS
## three ``bash tests/*.sh`` CLI-convention guards
## (``verify-cli-convention-no-silent-skip.sh``,
## ``test_bash_recorder_cli.sh``, ``test_zsh_recorder_cli.sh``). The
## recipe below models ALL FOUR faithfully: the whole-workspace
## ``cargo.test`` execute edge for the cargo half, and three ``sh.shell``
## execute edges — one per guard script — for the CLI-convention half.
## These guard scripts are genuine shell programs in the repo (there is
## no cargo equivalent), so running them through the typed ``sh``
## executable IS the native way to express them; this is NOT the
## disavowed "delegate the whole build/test to a wrapper script" pattern
## — each guard is one focused, independently-invalidated test edge.
##
## **Per-test platform gating.** No test FILE in this repo carries a
## per-file host gate: there is no ``#[cfg(target_os = …)]``
## test-selection conditional and no ``#[ignore]`` anywhere in the cargo
## suite. The zsh cargo suite self-adapts at RUNTIME via the in-file
## ``require_zsh!()`` macro (which prints "skipping: zsh not found" and
## returns when ``zsh`` is not on ``PATH``) rather than via a
## compile-time OS gate — the nix dev shell puts ``zsh`` on ``PATH`` so
## those tests run in full here. Likewise the ``test_zsh_recorder_cli.sh``
## guard prints "ok: zsh not available — skipping" and exits 0 when
## ``zsh`` is missing, so it is safe on every host. The bash / integration
## suites spawn ``bash`` + the built writer binary and run on every host
## cargo supports. So the corpus runs identically on every host — there
## is no per-OS partition to model.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical Rust-recorder recipes (``codetracer-trace-format`` et al.):
## the nix dev shell puts ``cargo`` / ``rustc`` / ``nim`` / ``nimble`` /
## ``capnp`` / ``zstd`` / ``bash`` on ``PATH`` (and ``PKG_CONFIG_PATH``
## for libzstd), so the weak-local PATH resolver is the right default.
## Without it ``repro build`` refuses to run with "typed tool provisioning
## is required for uses declarations".

import repro_project_dsl

# The three ``bash tests/*.sh`` CLI-convention guards in ``just test`` are
# run through the typed ``sh`` executable's ``shell(command = ...)``
# helper (``sh -c '<cmd>'``). Import it under an explicit alias so the
# call site is unambiguous — the bare ``shell`` name is already taken by
# the from-source ``dsl_port_runtime.shell`` re-exported through
# ``repro_project_dsl``, which is a DIFFERENT proc (the custom-provider
# fetch/shell registry, not a typed execute edge).
import repro_dsl_stdlib/packages/sh as shRunner

package codetracer_shell_recorders:
  defaultToolProvisioning "path"

  uses:
    # Rust toolchain — declared by version so the tarball-direct
    # provisioning entries in repro_dsl_stdlib/packages/cargo.nim /
    # rustc.nim resolve on Windows. On Linux/macOS the nix flake supplies
    # the same versions. The floor matches the workspace and the sibling
    # codetracer-trace-format recipe.
    "rustc >=1.85"
    "cargo >=1.85"

    # Nim toolchain — the ``codetracer_trace_writer_nim`` cargo dependency
    # (a sibling-repo ``path`` crate) carries a ``build.rs`` that compiles
    # the ``codetracer-trace-format-nim`` FFI entry point into a static
    # library via ``nim c`` at cargo build time; ``nimble`` is invoked by
    # the same build.rs (``nimble install --depsOnly``) to resolve that
    # FFI's ``stew`` / ``results`` nimble requirements. This is the
    # IDENTICAL cross-repo shape codetracer-trace-format's own repro.nim
    # declares for the same crate.
    "nim >=2.2 <3.0"
    "nimble"

    # Cap'n Proto schema compiler + libzstd — the CTFS writer stack
    # (reached transitively through ``codetracer_trace_writer_nim`` and
    # the ``zstd-sys`` link) needs ``capnpc`` over the trace schema and
    # links libzstd; the Nim FFI's C output ``#include``s ``zstd.h``.
    "capnp"
    "zstd"

    # ``bash`` is the launcher interpreter AND the process the bash /
    # integration test suites spawn (``Command::new("bash")`` in
    # tests/*.rs). On Linux/macOS the nix flake supplies it; on Windows
    # the MR2 ``packages/bash.nim`` tarball entry materialises bash.exe
    # out of a PortableGit archive into the engine's store, so the test
    # edge invokes the store-provisioned bash rather than whichever bash
    # happens to be on PATH.
    "bash"

    # ``sh`` — the CLI-convention guard test edges below are recorded as
    # ``sh -c 'bash tests/<guard>.sh'`` invocations via ``shRunner.shell``.
    # The ``sh`` selector provisions the POSIX shell that fronts each
    # guard (same PortableGit ``sh.exe`` on Windows). The guard body
    # itself re-invokes ``bash`` (and, for the zsh guard, ``zsh``), which
    # the ``bash`` floor above and the dev-shell ``zsh`` supply.
    "sh"

    # pkg-config — ``zstd-sys`` / the zstd link step consult pkg-config to
    # find libzstd on Linux/macOS (the flake sets ``PKG_CONFIG_PATH`` to
    # zstd's pkgconfig dir). Not on the Windows floor (zstd-sys builds
    # libzstd from source there). Matches the codetracer-trace-format
    # sibling recipe.
    when not defined(windows):
      "pkg-config"

  # The single shipping binary. ``name: "ct-shell-trace-writer"`` pins the
  # hyphenated on-disk artifact for the camelCase Nim identifier; the
  # producing edge is the ``cargo.build`` in the ``build:`` block below.
  executable ctShellTraceWriter:
    name: "ct-shell-trace-writer"

  build:
    # ---- Primary build edge (the `default` collection) ----------------
    #
    # Native release cargo build — the whole (single-member) workspace,
    # exactly what ``just build`` → ``cargo build --release`` does.
    # Enrolled into the conventional ``default`` collection per
    # reprobuild-specs/Build-Graph-Collections.md §"`default`" so
    # ``repro build`` (no positional target) materialises this edge's
    # closure.
    #
    # ``locked = true`` because the root ``Cargo.lock`` IS committed: the
    # build must fail rather than silently regenerate the lock if a
    # member's ``Cargo.toml`` drifts from the pinned resolution.
    #
    # The declared source roots (root manifest + lock + the crate's
    # ``Cargo.toml`` + ``src/``) are the build edge's input set; cargo's
    # own ``.d`` depfiles under ``target/*/deps`` refine this per-crate at
    # action-end via the makeDepfile dependency policy the cargo package
    # declares.
    const binarySuffix = (when defined(windows): ".exe" else: "")
    const traceWriterBinary =
      "target/release/ct-shell-trace-writer" & binarySuffix

    let workspaceInputs = @[
      "Cargo.toml", "Cargo.lock",
      "crates/ct-shell-trace-writer/Cargo.toml",
      "crates/ct-shell-trace-writer/src",
    ]

    let traceWriterBuild = cargo.build(
      locked = true,
      release = true,
      actionId = "ct-shell-trace-writer.cargo-build",
      extraInputs = workspaceInputs,
      extraOutputs = @[traceWriterBinary])
    discard collect("default", @[traceWriterBuild])

    # ---- Test-binary build + run edges (the `test` collection) --------
    #
    # Two-stage shape per Repo-Requirements.md §2.8: ``cargo.test(noRun =
    # true)`` builds every workspace test binary into
    # ``target/debug/deps/<crate>-<hash>`` (the engine tracks the deps
    # directory as the build edge's effect set because the hashed
    # filename floats with input content); the second ``cargo.test``
    # (``noRun`` defaulting to false) then runs the binaries in one cargo
    # invocation — the same whole-workspace pass ``just test`` → ``cargo
    # test`` performs (the unit suites + integration_test +
    # bash_recording_test + zsh_recording_test). The execute edge depends
    # on the build edge so the engine only re-runs tests when an input
    # changed since the last successful execution.
    #
    # The ``tests`` fixtures dir + the launcher directories are declared
    # as inputs because the integration tests read fixtures from
    # ``tests/fixtures/`` and spawn the ``bash-recorder`` / ``zsh-recorder``
    # launchers; a change to a fixture or a launcher must re-run the
    # affected test binary.
    let testInputs = workspaceInputs & @[
      "crates/ct-shell-trace-writer/tests",
      "tests",
      "bash-recorder",
      "zsh-recorder",
    ]

    let testsBuild = cargo.test(
      locked = true,
      noRun = true,
      actionId = "codetracer-shell-recorders.cargo-test-build",
      after = @[traceWriterBuild],
      extraInputs = testInputs,
      extraOutputs = @["target/debug/deps"])

    let testsRun = cargo.test(
      locked = true,
      actionId = "codetracer-shell-recorders.cargo-test-run",
      after = @[testsBuild.action],
      extraInputs = testInputs & @["target/debug/deps"])

    # ---- CLI-convention guard edges (the `test` collection) ----------
    #
    # ``just test`` does NOT stop at ``cargo test`` — after it, the
    # Justfile runs three ``bash tests/*.sh`` CLI-convention guards
    # (``verify-cli-convention``, ``test-bash-cli``, ``test-zsh-cli``).
    # Dropping them would silently shrink the corpus the recipe claims to
    # reproduce, so each guard is modelled here as its OWN typed ``sh``
    # execute edge (``sh -c 'bash tests/<guard>.sh'``) — one edge per
    # guard so the engine invalidates and re-runs each independently.
    #
    # Each guard internally runs ``cargo build --quiet`` to ensure the
    # writer binary exists, then drives the launchers + writer through
    # their user-visible CLI (``--help`` / ``--version`` / ``--format``
    # rejection / env-var fallbacks / ``ct print`` round-trip). The
    # inputs therefore cover the launcher dirs, the crate sources, the
    # ``VERSION`` file (the launchers' ``--version`` single source of
    # truth), and the guard script itself; ``after = @[traceWriterBuild]``
    # sequences them behind the release build so a warm ``target/`` is
    # already present. The default ``automaticMonitor`` dependency policy
    # refines these declared inputs with the syscalls each guard actually
    # performs.
    #
    # The zsh guard self-skips (prints "ok: zsh not available" and exits
    # 0) when ``zsh`` is absent, mirroring the cargo ``require_zsh!``
    # convention, so this edge is safe on hosts without zsh.
    let guardInputs = @[
      "Cargo.toml", "Cargo.lock",
      "crates/ct-shell-trace-writer/Cargo.toml",
      "crates/ct-shell-trace-writer/src",
      "bash-recorder",
      "zsh-recorder",
      "VERSION",
    ]

    let verifyCliGuard = shRunner.shell(
      command = "bash tests/verify-cli-convention-no-silent-skip.sh",
      actionId = "codetracer-shell-recorders.verify-cli-convention",
      after = @[traceWriterBuild],
      extraInputs = guardInputs & @[
        "tests/verify-cli-convention-no-silent-skip.sh"])

    let bashCliGuard = shRunner.shell(
      command = "bash tests/test_bash_recorder_cli.sh",
      actionId = "codetracer-shell-recorders.test-bash-cli",
      after = @[traceWriterBuild],
      extraInputs = guardInputs & @["tests/test_bash_recorder_cli.sh"])

    let zshCliGuard = shRunner.shell(
      command = "bash tests/test_zsh_recorder_cli.sh",
      actionId = "codetracer-shell-recorders.test-zsh-cli",
      after = @[traceWriterBuild],
      extraInputs = guardInputs & @["tests/test_zsh_recorder_cli.sh"])

    discard collect("test", @[
      testsRun.action, verifyCliGuard, bashCliGuard, zshCliGuard])

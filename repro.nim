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
## --release`` / ``cargo test``) produce today. The recipe expresses build
## and test execution NATIVELY through typed-tool edges (``cargo.build``,
## ``cargo.test``) — no ``shell(command = "bash scripts/...")``
## delegation, which would defeat the engine's incremental-build,
## action-cache, and per-test invalidation.
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
## no cargo/Rust-path channel (reprobuild consumes a sibling's sources
## through executable, C/C++ library and Nim-source channels only; there is
## no from-source cargo channel). So — like
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
## ``require_zsh!()`` macro (which prints "SKIPPED: zsh not available on
## this system" to stderr and returns when ``zsh --version`` does not
## run) rather than via a compile-time OS gate — the nix dev shell puts
## ``zsh`` on ``PATH`` so those tests run in full here. Likewise the
## ``test_zsh_recorder_cli.sh`` guard prints "ok: zsh not available —
## skipping test_zsh_recorder_cli" and exits 0 when ``zsh`` is missing,
## so it is safe on every host. The bash / integration
## suites spawn ``bash`` + the built writer binary and run on every host
## cargo supports. So the corpus runs identically on every host — there
## is no per-OS partition to model.
##
## **Tool provisioning.** On Linux and macOS ``defaultToolProvisioning``
## is ``path``, matching the canonical Rust-recorder recipes
## (``codetracer-trace-format`` et al.): the nix dev shell puts ``cargo`` /
## ``rustc`` / ``nim`` / ``nimble`` / ``capnp`` / ``zstd`` / ``bash`` /
## ``zsh`` on ``PATH`` (and ``PKG_CONFIG_PATH`` for libzstd), so the
## weak-local PATH resolver is the right default. Without a mode ``repro
## build`` refuses to run with "typed tool provisioning is required for uses
## declarations". A tool whose package declares a nix realisation (the
## stdlib's ``jq`` and coreutils, and the repo-local ``zsh`` of
## ``zsh_tools.nim``) is provisioned from it when ``PATH`` has none.
##
## On Windows it is ``tarball``: there is no dev shell there, so every
## declared tool is realized from the archive its package pins rather than
## taken from whatever the host's ``PATH`` holds first. That matters most
## for the ct-print edge's ``gcc``: path mode takes the first ``gcc.exe`` on
## the runner's ``PATH``, which need not be a working MinGW gcc at all,
## while tarball mode realizes the pinned WinLibs gcc that the ``zstd-dev``
## archive is built to link with.
##
## Declaring a tool in ``uses:`` is not enough for an edge to run it: an
## edge receives only the tools its typed constructor names plus the ones
## attached to it with ``appendRegisteredActionToolIdentityRefs`` (see the
## end of ``build:``). A ``repro test`` started from a shell that already
## has these tools on ``PATH`` hides a missing attachment; a CI runner with
## a bare ``PATH`` does not.

import repro_project_dsl
import repro_dsl_stdlib/foreign_env

# The three ``bash tests/*.sh`` CLI-convention guards in ``just test`` are
# run through the typed ``sh`` executable's ``shell(command = ...)``
# helper (``sh -c '<cmd>'``). Import it under an explicit alias so the
# call site is unambiguous — the bare ``shell`` name is already taken by
# the from-source ``dsl_port_runtime.shell`` re-exported through
# ``repro_project_dsl``, which is a DIFFERENT proc (the custom-provider
# fetch/shell registry, not a typed execute edge).
import repro_dsl_stdlib/packages/sh as shRunner

# ``jq`` is declared in ``uses:`` below; importing its stdlib package
# registers the nixpkgs channel that provisions it. Without the import the
# declaration resolves only against the caller's ``PATH``.
import repro_dsl_stdlib/packages/jq

# ``zsh`` is declared in ``uses:`` below; reprobuild's stdlib has no package
# for it, so this repository declares the one its flake provides.
import zsh_tools

# The owning constructor of ``ct-print``, which the bash and zsh CLI guards
# decode every recording with. It lives in the sibling checkout this
# repository's cargo ``path`` dependencies already resolve at
# ``../codetracer-trace-format-nim``, and the guards read the binary it
# builds there.
import "../codetracer-trace-format-nim/build_writer_artifacts"

const traceFormatNimRoot = "../codetracer-trace-format-nim"

package codetracer_shell_recorders:
  devEnv:
    when not defined(windows):
      useFlakeDevShell()

  defaultToolProvisioning (when defined(windows): tarball else: path)

  uses:
    # Rust toolchain — declared by version so the tarball-direct
    # provisioning entries in repro_dsl_stdlib/packages/cargo.nim /
    # rustc.nim resolve on Windows. On Linux/macOS the nix flake supplies
    # the same versions. The floor matches the workspace and the sibling
    # codetracer-trace-format recipe.
    "rustc >=1.85"
    "cargo >=1.85"
    # C compiler driver — rustc links through `cc`, and build scripts
    # (cc-rs, the Nim FFI) compile C. Declaring it puts its directory on
    # every cargo edge's PATH. Windows links with MSVC instead, so its cargo
    # edges are not given a C compiler (see the tool refs at the end of
    # ``build:``).
    #
    # Windows still declares ``gcc``: the ct-print edge that
    # ``build_writer_artifacts.buildCtPrint`` constructs compiles with
    # ``nim c``'s gcc back-end on every host but macOS and names ``gcc`` on
    # its edge itself. That ref provisions nothing unless the package
    # declares the tool here, and ``buildCtPrint`` refuses a package that
    # does not (the module's "Native tool contract").
    when defined(macosx):
      "clang"
    else:
      "gcc"

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

    # zstd.h + libzstd for the sibling ct-print edge
    # (``build_writer_artifacts.buildCtPrint`` compiles and links against
    # them; ``zstd`` is the CLI only). The constructor cannot provision a
    # tool from inside ``build:`` and refuses a recipe that omits it, on
    # every host: on Windows ``zstd-dev`` is a MinGW static ``libzstd.a``
    # for the ct-print edge's gcc back-end, beside the ``gcc`` above.
    "zstd-dev"

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
    # the ``bash`` floor above and the ``zsh`` declaration below supply.
    "sh"

    # pkg-config — ``zstd-sys`` / the zstd link step consult pkg-config to
    # find libzstd on Linux/macOS (the flake sets ``PKG_CONFIG_PATH`` to
    # zstd's pkgconfig dir). Not on the Windows floor (zstd-sys builds
    # libzstd from source there). Matches the codetracer-trace-format
    # sibling recipe.
    when not defined(windows):
      "pkg-config"

    # git — the Nim FFI build script's ``nimble install --depsOnly``
    # fetches the FFI's ``requires`` packages with git when they are not
    # installed yet.
    "git"

    # The programs the launchers and the CLI-convention guards run besides
    # bash and cargo: ``jq`` (the guards decode ``ct print --json`` output
    # with it) and the POSIX utilities the scripts call. reprobuild's stdlib
    # provisions these from nixpkgs; on Windows they come with the
    # PortableGit bash, in bash's own directory.
    #
    # ``zsh`` is the interpreter of the zsh launcher, which the zsh cargo
    # suite, the zsh guard and the CLI-convention guard all drive. It has to
    # be declared and attached like every other tool: an edge does not see
    # the caller's ``PATH``, so an undeclared zsh is found only when some
    # other attached tool's directory happens to hold one, and otherwise the
    # zsh suites skip themselves without failing anything. reprobuild's
    # stdlib has no ``zsh`` package, so ``zsh_tools.nim`` declares one: the
    # flake's nixpkgs zsh, the same binary the dev shell puts on ``PATH``.
    # Windows has no zsh and does not declare it.
    when not defined(windows):
      "zsh"
      "jq"
      "basename"
      "cat"
      "chmod"
      "dirname"
      "grep"
      "head"
      "ls"
      "mkdir"
      "mktemp"
      "rm"
      "sed"
      "sort"
      "tr"

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
    # Enrolled into the conventional ``default`` collection, the one
    # ``repro build`` with no positional target materialises.
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
    # Two-stage shape — build the test binaries, then run them:
    # ``cargo.test(noRun = true)`` builds every workspace test binary into
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

    # ---- ``ct-print`` prerequisite of the bash and zsh CLI guards -----
    #
    # Both guards decode their recordings with ``ct-print`` at the fixed
    # sibling path ``../codetracer-trace-format-nim/ct-print`` and FAIL when
    # it is missing. ``just test`` builds it first (``just build-ct-print``);
    # here it is an edge of the graph, constructed by the sibling's own
    # ``buildCtPrint`` so the compile flags stay in the repository that owns
    # them, and so the engine threads the declared ``zstd-dev`` onto the
    # compile's ``CPATH`` / ``LIBRARY_PATH`` on every host. The two guard
    # edges order after it and name the binary as an input, so a missing or
    # rebuilt ``ct-print`` re-runs them.
    #
    # It runs after the test build because that build's
    # ``codetracer_trace_writer_nim`` ``build.rs`` is what installs the
    # sibling's nimble ``requires`` (``results``, ``stew``) into the nimble
    # path the ct-print compile resolves them from. ``just build-ct-print``
    # gets the same packages from ``nimble buildCtPrint``.
    let ctPrintBuild = buildCtPrint(traceFormatNimRoot,
                                    after = @[testsBuild.action])
    let ctPrintBinary = ctPrintPath(traceFormatNimRoot)

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
      after = @[traceWriterBuild, ctPrintBuild],
      extraInputs = guardInputs & @["tests/test_bash_recorder_cli.sh",
                                    ctPrintBinary])

    let zshCliGuard = shRunner.shell(
      command = "bash tests/test_zsh_recorder_cli.sh",
      actionId = "codetracer-shell-recorders.test-zsh-cli",
      after = @[traceWriterBuild, ctPrintBuild],
      extraInputs = guardInputs & @["tests/test_zsh_recorder_cli.sh",
                                    ctPrintBinary])

    # ---- Tools each edge runs -----------------------------------------
    #
    # Every cargo edge runs rustc and the C compiler, and the sibling
    # ``codetracer_trace_writer_nim`` build script runs nim, nimble (which
    # may fetch with git), capnp and zstd. The test run spawns bash and zsh
    # through the launchers, and the recording tests run ``cargo build``
    # themselves. Each guard runs ``cargo build --quiet`` and drives the
    # launchers through sh, bash and zsh, with jq and the POSIX utilities
    # the scripts call.
    let cargoEdges = @[traceWriterBuild, testsBuild.action, testsRun.action,
                       verifyCliGuard, bashCliGuard, zshCliGuard]
    for action in cargoEdges:
      appendRegisteredActionToolIdentityRefs(action.id,
        ["cargo", "rustc", "nim", "nimble", "git", "capnp", "zstd"])
      when defined(linux):
        appendRegisteredActionToolIdentityRefs(action.id,
          ["gcc", "pkg-config"])
      elif defined(macosx):
        appendRegisteredActionToolIdentityRefs(action.id,
          ["clang", "pkg-config"])
    for action in [testsRun.action, verifyCliGuard, bashCliGuard,
                   zshCliGuard]:
      appendRegisteredActionToolIdentityRefs(action.id, ["sh", "bash"])
      when not defined(windows):
        appendRegisteredActionToolIdentityRefs(action.id,
          ["zsh", "jq", "basename", "cat", "chmod", "dirname", "grep",
           "head", "ls", "mkdir", "mktemp", "rm", "sed", "sort", "tr"])

    discard collect("test", @[
      testsRun.action, verifyCliGuard, bashCliGuard, zshCliGuard])

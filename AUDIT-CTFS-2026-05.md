# CTFS audit — codetracer-shell-recorders (2026-05-02)

This document records the CTFS / event-emission audit of the
**bash-recorder** and **zsh-recorder** sibling components in this repo,
performed against the canonical checklist defined in `5.6` of the
`isonim-migration.txt` handoff document and against the worked examples
established by the seventeen prior recorder audits (Ruby 1.21, Python
1.27, JavaScript 1.38, EVM 1.39, PHP 1.41, Solana 1.44, Move 1.46,
Cardano 1.48, Cairo 1.50, Flow/Cadence 1.52, Fuel/Sway 1.53, PolkaVM
1.55, Miden 1.56, TON/Tolk 1.57, Circom 1.58, Leo/Aleo 1.59, WASM/wazero
1.60).

The shell recorders are the **eighteenth** audited recorder family.
They are also the FIRST audited recorders whose call boundary is
defined by *shell function invocations* in a script-driven host
language, rather than by VM frames, transactions, transitions, or
instantiated circuit templates.  Architecture: a launcher shell script
(`bash-recorder/launcher.sh`, `zsh-recorder/launcher.zsh`) sets up an FD
3 FIFO between the recorder shell script (`recorder.sh`,
`recorder.zsh`) and the Rust trace-writer binary
(`crates/ct-shell-trace-writer/`).  The recorder uses bash/zsh DEBUG
+ ERR / ZERR + RETURN traps to instrument every line of a target
script and emits a line-oriented wire protocol on FD 3.  The Rust
binary parses the wire protocol and dispatches to the Nim CTFS or
Rust-native (CBOR+Zstd) trace writer, producing a `.ct` container
plus JSON sidecars (`trace_metadata.json`, `trace_paths.json`,
`symbols.json`, `trace_db_metadata.json`, `files/`).

## Findings vs. section 5.6 checklist

### (a) CTFS format — `TraceEventsFileFormat::Ctfs`

**OK / pre-audit clean.**

`crates/ct-shell-trace-writer/src/main.rs::parse_cli_args` already
defaults `--format` to `TraceEventsFileFormat::Ctfs`, and both
launchers default `_ct_format="ctfs"`.  The `ctfs`/`ct` value is
mapped to `TraceEventsFileFormat::Ctfs`, which routes through
`codetracer_trace_writer_nim::create_trace_writer` to the Nim
multi-stream `.ct` container writer.  This follows the same idiom
established by the eleven prior default-Ctfs CLI fixes (1.44 / 1.46
/ 1.48 / 1.50 / 1.52 / 1.53 / 1.55 / 1.56 / 1.57 / 1.58 / 1.59 /
1.60).

### (b) `register_call` per call

**OK / closed (with one carve-out for non-function call boundaries).**

Shell function invocations route correctly:

* `recorder.sh::_ct_debug_trap` and the `recorder.zsh` DEBUG trap
  detect a function-call boundary as `funcstack`/`FUNCNAME` depth
  increase, emit `FUNC name=... file=... line=...` (once per
  function), then emit `CALL name=...`.
* `crates/ct-shell-trace-writer/src/trace_bridge.rs::handle_call`
  consumes the event, calls `TraceWriter::ensure_function_id`, and
  routes through `TraceWriter::register_call(fid, args)` — the
  canonical CTFS Call entry point post-1.30 (`add_event` was the
  silent-no-op footgun closed in 1.30).

The implicit script-level "top-level" frame is staged by
`handle_start` as an explicit `<toplevel>` `register_call`, with the
matching `register_return` emitted on the final `EXIT` event.  This
mirrors the Ruby 1.21 native-recorder fix (`<top-level>` opened in
`initialize`, closed on `disable_tracing`).

**Carve-out — open follow-up:** external commands, pipelines, and
subshells are NOT currently treated as nested calls.  A pipeline
`cmd1 | cmd2` produces two `STEP` records but no `CALL`/`RETURN`
pair; a subshell `(cmd)` likewise.  Closing this gap would require
the recorder to detect external-command invocations from
`BASH_COMMAND`/`ZSH_DEBUG_CMD` and synthesise call frames around
them, plus a more careful FUNCNAME/funcstack model for subshells
(which fork a child bash).  Documented as a deferred follow-up.

### (c) `register_call_arg` / argv staging

**Closed in this audit.**

Pre-fix the `CALL` wire event carried only `name=`; the bridge
called `register_call(fid, vec![])` unconditionally
(`trace_bridge.rs:411`), so every shell-function call frame had an
empty `args` field in the trace.  The launcher captured the
script-level argv into `_ct_script_args` but only used it for the
post-recording `trace_db_metadata.json` sidecar — the writer never
saw it.

Closed in this audit by:

1. **Extending the wire protocol with an `ARG` event** (one
   positional parameter staged for the next `CALL`):

   ```
   ARG name=$1 value="hello world" type=s
   ARG name=$2 value=42 type=i
   CALL name=greet
   ```

   The new `WireEvent::Arg { name, value, type_flag }` variant in
   `crates/ct-shell-trace-writer/src/wire_protocol.rs` mirrors
   `WireEvent::Var`'s typed-value vocabulary so recorders can stage
   integers, strings, floats, indexed arrays, and assoc arrays on
   call frames using the same `i`/`s`/`F`/`a`/`A` flag set.

2. **Wiring the bridge to drain `ARG` events onto the next `CALL`**
   (`TraceBridge::pending_call_args` in `trace_bridge.rs`).
   `handle_arg` builds a `FullValueRecord` via `TraceWriter::arg`
   and pushes it into the buffer; `handle_call` drains the buffer
   into `register_call(fid, args)`.  Mirrors the canonical
   pre-`register_call` arg-staging pattern (Ruby 1.21, Python 1.27,
   Move 1.46, Cairo 1.50, etc.).

3. **Bash recorder** (`bash-recorder/recorder.sh`): emits one `ARG
   name=$N value=... type=s` line per positional parameter of the
   user function frame, using the `BASH_ARGC` / `BASH_ARGV` arrays
   exposed by `extdebug`.  Because the DEBUG trap fires inside
   `_ct_debug_trap` itself, we read `BASH_ARGC[1]` (the *caller's*
   frame argc) and skip `BASH_ARGV[0..BASH_ARGC[0]-1]` (the trap
   frame's own argv slots, if any) before iterating the user
   function's argv.

4. **Zsh recorder** (`zsh-recorder/recorder.zsh`): zsh DEBUG traps
   inherit `$@`/`argv` from the enclosing function frame (verified
   empirically — see `audit notes` below), so we can iterate `argv`
   directly when depth increases into a user function.

5. **Script-level argv** (the script's `$1..$N` from the launcher
   command line): the bridge constructor now takes the `args` slice
   already passed for metadata, stages each as a `$N` ARG, and
   drains them onto the implicit `<toplevel>` `register_call` from
   `handle_start`.  Both launchers now forward `_ct_script_args` to
   the trace-writer binary via `--args ...`.

All shell positional parameters are staged with the wire-protocol
type flag `s` (string) since shell positional parameters are
always strings at the OS level — typed conversion (e.g. `i` for
integer arguments to bash functions that use `local -i`) is a
follow-up if the recorder later infers types from `declare -p`
post-call.

### (d) Write / EvmEvent / Error routing

**Partial / pre-audit clean for routing; one open content-fidelity issue.**

* `WRITE content=...` events route via
  `register_special_event(EventLogKind::Write, "", content)` —
  canonical post-1.27 path.  Pre-audit clean.
* `ERROR cmd=... status=...` events (emitted by the bash `ERR` trap
  / zsh `ZERR` trap when a command exits non-zero) route via
  `register_special_event(EventLogKind::Error, cmd, message)` —
  canonical post-1.50 / 1.55 / 1.56 / 1.57 / 1.59 / 1.60 pattern.
  Pre-audit clean.
* No `EvmEvent` routing applies (shell scripts have no
  blockchain-style structured events).

**Open — content fidelity:** the recorder captures `WRITE` content
from `BASH_COMMAND` / `ZSH_DEBUG_CMD` (the *literal source command*,
e.g. `echo hello world`) rather than the actual stdout the command
produced.  True stdout capture would require a `tee` proxy or
LD_PRELOAD-style write-syscall interception around every command —
out of scope for this audit; documented as a deferred follow-up.

The current behaviour is equivalent to capturing "the script's
intent" rather than "the script's output", which is at least
useful as a coarse breadcrumb for debugging.  Frontends that show
terminal output will display the literal command string, not the
runtime stdout.

### (e) Thread events (`register_thread_*`)

**N/A.**

Bash and zsh do not expose threads.  Background jobs (`cmd &`) and
coproc (`coproc cmd`) fork child processes with their own
independent shells; the parent recorder cannot observe their
control flow without a fundamentally different instrumentation
model (a separate FIFO + recorder per child).  Documented as a
deferred follow-up.

If background-job tracing is added later, the right shape is to
have the launcher hand each child shell its own recorder.sh +
FIFO + `--args` and have the bridge emit `register_thread_start`
on each `START` event with a non-zero process discriminator.
The Nim multi-stream writer's `register_thread_*` API (post-1.30)
already supports this on the writer side.

### (f) Step records

**OK / pre-audit clean.**

Both recorders emit `STEP file=... line=...` from their DEBUG trap
on every simple command.  The bridge routes through
`TraceWriter::register_step(path, line)` (canonical CTFS path).
Line-by-line stepping is preserved.

Zsh has the additional complication that `$LINENO` inside a
function is relative to the function's definition line, not the
file; `recorder.zsh` correctly compensates by adding
`funcsourcetrace[1]`'s definition line offset.  Bash uses
`BASH_LINENO[0]` directly which is already file-absolute.

### (g) CTFS schema match

**OK / pre-audit clean.**

The default CTFS path produces a `.ct` container with the canonical
multi-stream layout (steps.dat, calls.dat, paths.dat, etc.) plus
the JSON sidecars the launcher writes for downstream tools.  All
event records use the post-1.30 entry points — no `add_event`
silent-drop paths.

### (h) Obsolete `add_event` paths

**OK / clean.**

The only `add_event` reference in the recorder repo is the
`RustWriterAdapter::add_event` delegate in `trace_bridge.rs:203`
(which forwards Nim-trait-method calls through to the Rust-native
writer's identical method when the user requests
`--format binary`).  This is a trait-impl plumbing necessity, not a
silent-drop call site.  All actual event emission goes through
dedicated `register_*` entry points.

## Concrete changes in this audit

1. **`crates/ct-shell-trace-writer/src/wire_protocol.rs`**: new
   `WireEvent::Arg { name, value, type_flag }` variant; new
   `"ARG"` parser arm; new `test_parse_arg_event` unit test.

2. **`crates/ct-shell-trace-writer/src/trace_bridge.rs`**:
   * Two new `TraceBridge` fields: `script_args: Vec<String>` and
     `pending_call_args: Vec<FullValueRecord>`.
   * Refactored `handle_var` to share a new `value_record_for_flag`
     helper with `handle_arg`.
   * New `handle_arg` method that stages args via
     `TraceWriter::arg` into the pending buffer.
   * `handle_call` now drains `pending_call_args` into
     `register_call(fid, args)` (replacing the unconditional empty
     `vec![]`).
   * `handle_start` now stages `script_args` as `$1..$N` ARGs and
     opens an explicit `<toplevel>` call so the implicit top-level
     frame's argv is recorded canonically.

3. **`bash-recorder/recorder.sh`**: emits ARG events for every
   user-function call using `BASH_ARGC[1]` + `BASH_ARGV[base..]`
   indexing.  Skips the trap-frame argv slots correctly.

4. **`zsh-recorder/recorder.zsh`**: emits ARG events for every
   user-function call via direct `$argv` iteration (DEBUG trap
   inherits the function's argv in zsh).

5. **`bash-recorder/launcher.sh` + `zsh-recorder/launcher.zsh`**:
   forward `_ct_script_args` to the trace-writer binary via
   `--args ...` so the implicit top-level call's argv is staged.

6. **`crates/ct-shell-trace-writer/tests/integration_test.rs`**:
   new `test_arg_events_stage_call_args` end-to-end test driving
   ARG → CALL → register_call through the full pipeline with both
   per-function ARGs and script-level args via `TraceBridge::new`.

## Verification

```
cd /home/zahary/metacraft/codetracer-shell-recorders
direnv exec . cargo build --release   # clean
direnv exec . cargo test              # 44 tests pass
direnv exec . cargo clippy --release  # clean
direnv exec . cargo fmt --check       # clean
```

Test counts: 12 unit (wire_protocol) + 17 bash recording + 2
integration + 13 zsh recording = **44 tests, all pass**.  Pre-audit
baseline was 42; +2 for the new `test_parse_arg_event` and
`test_arg_events_stage_call_args`.

## Open gaps (deferred follow-ups)

* **Pipelines / subshells / external commands as call frames.**  The
  current recorder treats only shell-function invocations as call
  boundaries.  Pipelines (`a | b | c`), subshells (`(...)`), and
  external commands (`/usr/bin/ls`) would benefit from being
  surfaced as nested calls in the calltrace.  Closing this requires
  detecting these patterns from `BASH_COMMAND`/`ZSH_DEBUG_CMD` and
  synthesising CALL/RETURN around them.

* **True stdout/stderr capture.**  `WRITE` content currently
  reflects the command source string, not the runtime stdout.  Real
  capture needs a `tee`-based proxy or LD_PRELOAD interceptor.
  Same cross-cutting issue documented in 1.39 / 1.41 for output
  fidelity.

* **Background jobs (`&`) and coproc as threads.**  Bash/zsh
  background jobs are independent processes with their own shell
  state.  Multi-process recording would need a per-child
  recorder.sh + FIFO + writer pipeline plus
  `register_thread_start`/`register_thread_exit` calls keyed by
  PID.  Same architectural class as "PHP per-request workers" if
  that recorder ever needs threads.

* **Multi-stream IO event collapse.**  Same cross-cutting issue
  flagged in every audit since 1.39.  When `Error` events are
  routed through the multi-stream writer, the metadata field is
  dropped because `toIOEventKind` collapses 13 EventLogKinds onto
  4 IO buckets.  Out of scope for any single recorder audit;
  flagged as a writer-side fix.

* **Typed argv inference.**  Shell positional parameters are
  always strings at the OS level, but bash/zsh `local -i name=$1`
  upgrades them to integers post-call.  A follow-up could re-emit
  ARG records once `declare -p` runs inside the function and
  detects integer/array typing for staged args, but this requires
  the bridge to support post-call ARG amendments — a more invasive
  protocol change.

* **Read-side end-to-end content assertions.**  The new
  `test_arg_events_stage_call_args` verifies the trace container
  is produced and is non-trivially sized, but does not walk it and
  assert specific Call.args[] field content.  Same assertion-depth
  follow-up flagged for Cairo / Cardano / Flow / Fuel / PolkaVM /
  Miden / TON / Circom / Leo / WASM in their respective audits.

## Cross-cutting findings

* **First audited recorder family with a wire-protocol intermediary
  layer.**  Unlike Rust-crate recorders (most of the prior list)
  and cgo recorders (PHP 1.41, WASM/wazero 1.60), the shell
  recorders communicate with the trace writer through a stdin
  line-oriented protocol.  This makes the recorder/writer split
  process-cheap (one Rust binary serves both bash + zsh) but adds
  a parsing layer.  The new ARG event slots in cleanly without
  schema versioning because the wire protocol is line-oriented and
  forward-compatible (unknown event types are warned-and-skipped
  rather than fatal-rejected by `main.rs`).

* **`extdebug` BASH_ARGC indexing nuance.**  When a DEBUG trap is
  registered as a function (rather than inline), `BASH_ARGC[0]`
  refers to the *trap function's* argv count, NOT the user
  function's.  This is a subtle gotcha that future bash-based
  recorders (e.g. dash, ksh) should be aware of.  The fix in this
  audit reads `BASH_ARGC[1]` and skips `BASH_ARGC[0]` slots in
  `BASH_ARGV` accordingly.

* **Zsh DEBUG trap argv inheritance.**  Empirically verified:
  zsh DEBUG traps inherit `$@`/`$argv` from the enclosing function
  frame when the trap is registered with `trap '...' DEBUG` (not
  as a function).  This makes ARG emission trivial in zsh.

After this commit section 5.6's recorder list shows
codetracer-shell-recorders as audited (gaps closed for ARG/CALL
plumbing, top-level `<toplevel>` register_call, script-level argv
forwarding; pipelines / subshells as call frames + true stdout
capture + background-job thread events + typed argv inference +
read-side content assertions open as recorder-side / writer-side /
toolchain follow-ups).  Audited recorder count: 17 → 18.

#!/usr/bin/env bash
# End-to-end CLI convention tests for codetracer-bash-recorder.
#
# These tests cover the user-visible CLI surface — the cargo integration
# tests (crates/ct-shell-trace-writer/tests/bash_recording_test.rs)
# already cover the trace bundle's content; here we assert that:
#
#   * `_OUT_DIR` env var is honoured when --out-dir is omitted.
#   * `_DISABLED=1` short-circuits to a direct script execution.
#   * Stale `--format` flag is rejected with a non-zero exit.
#   * `--help` mentions `ct print` and omits `--format`.
#   * `--version` prints the canonical binary-name + version line.
#   * `ct print --json` round-trips the recorded `.ct` bundle (per the
#     cardano/circom/flow/fuel/leo/miden/move/polkavm/python/ruby
#     precedent — JSON is no longer produced by the recorder, it is
#     produced by `ct print` from the recorded CTFS bundle).
#   * `ct print --full --strip-paths` decodes every CBOR ValueRecord
#     back to a structured JSON object; we assert exact decoded values
#     (the cairo / cardano / ... / js / python / ruby `--full` upgrade)
#     so a recorder regression that silently drops or corrupts a value
#     is caught loudly rather than passing a substring-presence check.
#   * A script with no arguments records (and runs under `_DISABLED=1`) on
#     the installed Bash and on Bash 4.0, the specification's floor, named
#     by CT_TEST_BASH_4_0; a Bash 3.2 (CT_TEST_BASH_3_2) is refused by name.
#     Both variables are exported by the Linux dev shell (flake.nix).
#   * The recorded script sees its own absolute path as `$0`, so a
#     `BASH_SOURCE[0] == $0` entry-point guard holds, on both Bashes.
#   * The EXIT event carries the status the process exits with when the
#     script's EXIT action changes it, on both Bashes.
#
# Usage: bash tests/test_bash_recorder_cli.sh
#
# Exit codes: 0 on success, 1 on first failed assertion (loud — every
# failure prints the offending output to stderr).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LAUNCHER="${REPO_ROOT}/bash-recorder/launcher.sh"
BIN="${REPO_ROOT}/bash-recorder/codetracer-bash-recorder"

# `ct print` is the canonical CTFS → JSON converter.  Without it we can
# still cover env-var + format-rejection cases — the round-trip
# assertion is gracefully skipped with a logged "ok: skipped" line so
# the test surface stays additive (no silent skip means: every test we
# do run must pass; tests we cannot run say so loudly).
CT_PRINT="${CT_PRINT:-${REPO_ROOT}/../codetracer-trace-format-nim/ct-print}"

PASS_COUNT=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
pass() {
  echo "ok: $*"
  PASS_COUNT=$((PASS_COUNT + 1))
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ct-bash-cli-XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

# Build the trace writer once up-front so the launcher can find it.
( cd "${REPO_ROOT}" && cargo build --quiet )

# Fixture script — one fast-path command so the recorder does minimal work.
# Used by T1-T5 (env-var fallbacks, format rejection, --help, --version).
FIXTURE="${WORK_DIR}/fixture.sh"
cat > "${FIXTURE}" <<'EOF'
#!/usr/bin/env bash
echo "fixture-marker"
EOF
chmod +x "${FIXTURE}"

# Richer fixture — used by T7 (`ct-print --full` exact-value layer).
# Surfaces a positional-arg call so we can assert on a decoded
# (varname, value) pair (`$1 = "world"`) and a function-table entry.
# The shape mirrors the cairo / cardano / ... / js / python / ruby
# precedents: a small program with one user function called with
# literal arguments, asserted on the decoded ValueRecord.
FIXTURE_FULL="${WORK_DIR}/fixture_full.sh"
cat > "${FIXTURE_FULL}" <<'EOF'
#!/usr/bin/env bash
greet() {
    echo "hello $1"
}
greet "world"
EOF
chmod +x "${FIXTURE_FULL}"

# ---------------------------------------------------------------------------
# T1. --help: --format absent, --out-dir + --version + `ct print` present.
# ---------------------------------------------------------------------------

HELP_OUT="$(bash "${LAUNCHER}" --help)"
grep -qF -- "--format" <<< "${HELP_OUT}" && fail "--help must NOT mention --format"
grep -qF -- "--out-dir" <<< "${HELP_OUT}" || fail "--help missing --out-dir"
grep -qF -- "--version" <<< "${HELP_OUT}" || fail "--help missing --version"
grep -qF -- "ct print" <<< "${HELP_OUT}" || fail "--help missing 'ct print'"
grep -qF -- "CODETRACER_BASH_RECORDER_OUT_DIR" <<< "${HELP_OUT}" \
  || fail "--help missing CODETRACER_BASH_RECORDER_OUT_DIR"
grep -qF -- "CODETRACER_BASH_RECORDER_DISABLED" <<< "${HELP_OUT}" \
  || fail "--help missing CODETRACER_BASH_RECORDER_DISABLED"
pass "--help: --format absent, --out-dir/--version/ct print present"

# ---------------------------------------------------------------------------
# T2. --version: canonical binary-name + version line.
# ---------------------------------------------------------------------------

VERSION_OUT="$(bash "${LAUNCHER}" --version)"
grep -qE '^codetracer-bash-recorder [0-9]+\.[0-9]+\.[0-9]+$' <<< "${VERSION_OUT}" \
  || fail "--version output not in 'codetracer-bash-recorder X.Y.Z' form: ${VERSION_OUT}"
# The wrapper binary must agree with the launcher.
WRAPPER_VERSION_OUT="$(bash "${BIN}" --version)"
[[ "${WRAPPER_VERSION_OUT}" == "${VERSION_OUT}" ]] \
  || fail "wrapper --version mismatch: '${WRAPPER_VERSION_OUT}' vs '${VERSION_OUT}'"
pass "--version: canonical 'codetracer-bash-recorder X.Y.Z' line"

# ---------------------------------------------------------------------------
# T3. --format json must be rejected with a non-zero exit (no silent skip).
# ---------------------------------------------------------------------------

if bash "${LAUNCHER}" --format json -- "${FIXTURE}" >/dev/null 2>&1; then
  fail "launcher must reject --format json"
fi
if bash "${LAUNCHER}" --format binary -- "${FIXTURE}" >/dev/null 2>&1; then
  fail "launcher must reject --format binary"
fi
pass "--format {json,binary}: rejected with non-zero exit"

# ---------------------------------------------------------------------------
# T4. CODETRACER_BASH_RECORDER_OUT_DIR fallback.
# ---------------------------------------------------------------------------

OUT_DIR_T4="${WORK_DIR}/t4-env-out"
mkdir -p "${OUT_DIR_T4}"
RUN_OUT="$(CODETRACER_BASH_RECORDER_OUT_DIR="${OUT_DIR_T4}" \
  bash "${LAUNCHER}" "${FIXTURE}")"
grep -qF "fixture-marker" <<< "${RUN_OUT}" \
  || fail "_OUT_DIR fallback: target script's stdout missing"
[[ -f "${OUT_DIR_T4}/fixture.ct" ]] \
  || fail "_OUT_DIR fallback: ${OUT_DIR_T4}/fixture.ct not produced"
pass "CODETRACER_BASH_RECORDER_OUT_DIR honoured when --out-dir omitted"

# CLI flag wins over the env var — record into a *different* dir.
OUT_DIR_T4B="${WORK_DIR}/t4-cli-out"
mkdir -p "${OUT_DIR_T4B}"
CODETRACER_BASH_RECORDER_OUT_DIR="${OUT_DIR_T4}" \
  bash "${LAUNCHER}" --out-dir "${OUT_DIR_T4B}" "${FIXTURE}" >/dev/null
[[ -f "${OUT_DIR_T4B}/fixture.ct" ]] \
  || fail "--out-dir flag must override _OUT_DIR env var"
pass "--out-dir takes precedence over CODETRACER_BASH_RECORDER_OUT_DIR"

# ---------------------------------------------------------------------------
# T5. CODETRACER_BASH_RECORDER_DISABLED short-circuits without recording.
# ---------------------------------------------------------------------------

OUT_DIR_T5="${WORK_DIR}/t5-disabled-out"
RUN_OUT_T5="$(CODETRACER_BASH_RECORDER_DISABLED=1 \
  bash "${LAUNCHER}" --out-dir "${OUT_DIR_T5}" "${FIXTURE}")"
grep -qF "fixture-marker" <<< "${RUN_OUT_T5}" \
  || fail "_DISABLED=1: target script must still run"
[[ ! -e "${OUT_DIR_T5}" || -z "$(ls -A "${OUT_DIR_T5}" 2>/dev/null)" ]] \
  || fail "_DISABLED=1: must NOT produce trace artifacts in ${OUT_DIR_T5}"
pass "CODETRACER_BASH_RECORDER_DISABLED=1 runs target without recording"

# Even with --out-dir omitted entirely, _DISABLED must still work.
RUN_OUT_T5B="$(CODETRACER_BASH_RECORDER_DISABLED=true \
  bash "${LAUNCHER}" "${FIXTURE}")"
grep -qF "fixture-marker" <<< "${RUN_OUT_T5B}" \
  || fail "_DISABLED=true: target script must still run without --out-dir"
pass "CODETRACER_BASH_RECORDER_DISABLED=true works without --out-dir"

# ---------------------------------------------------------------------------
# T6. ct-print --json round-trip (Layer 1 — legacy substring presence).
#
# The recorded .ct bundle decodes via `ct print --json` to a structure
# that contains the program path and at least one step on
# `fixture-marker`'s line.  This replaces the old `--format json`
# content assertion (per the cardano/circom/flow precedent — recorders
# emit CTFS, `ct print` produces JSON for downstream tools).
#
# Kept as a safety net so a regression in the textual rendering is
# caught even if the `--full` JSON shape evolves.
# ---------------------------------------------------------------------------

# `ct-print` links zstd via an absolute Nix-store path, so it normally
# runs without LD_LIBRARY_PATH.  We still wire one up if the user has
# nix available, matching the conventional invocation documented for
# this test suite — that way any future build of `ct-print` that drops
# its rpath continues to work.
CT_PRINT_LD_LIBRARY_PATH="${CT_PRINT_LD_LIBRARY_PATH:-}"
if [[ -z "${CT_PRINT_LD_LIBRARY_PATH}" ]] && command -v nix >/dev/null 2>&1; then
  CT_PRINT_LD_LIBRARY_PATH="$(nix eval --raw nixpkgs#zstd.out 2>/dev/null)/lib" || \
    CT_PRINT_LD_LIBRARY_PATH=""
fi

run_ct_print() {
  # run_ct_print <ct-print-flags...> -- captures stdout.
  if [[ -n "${CT_PRINT_LD_LIBRARY_PATH}" ]]; then
    LD_LIBRARY_PATH="${CT_PRINT_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}" \
      "${CT_PRINT}" "$@"
  else
    "${CT_PRINT}" "$@"
  fi
}

if [[ -x "${CT_PRINT}" ]]; then
  CT_JSON="$(run_ct_print --json "${OUT_DIR_T4}/fixture.ct")"
  # Cheap structural assertions: the JSON must reference our fixture path
  # at least once in the metadata block, in the paths array, and in the
  # steps array (each as a `"path": "..."` field).  This deliberately
  # parallels the cardano/circom/flow precedent — we no longer assert on
  # JSON written by the recorder, we assert on JSON produced by
  # `ct print` from the canonical CTFS bundle.
  grep -qF "\"program\": \"${FIXTURE}\"" <<< "${CT_JSON}" \
    || fail "ct-print --json: metadata.program missing ${FIXTURE}: ${CT_JSON}"
  grep -qF "\"${FIXTURE}\"" <<< "${CT_JSON}" \
    || fail "ct-print --json: paths/steps do not reference ${FIXTURE}: ${CT_JSON}"
  # `<toplevel>` is the implicit top-level call we always stage on START
  # — confirm the call frame survived the round-trip.
  grep -qF '<toplevel>' <<< "${CT_JSON}" \
    || fail "ct-print --json: <toplevel> call missing: ${CT_JSON}"
  pass "ct print --json round-trips the recorded .ct bundle"
else
  fail "ct-print round-trip: ${CT_PRINT} not executable; this test must not silently skip"
fi

# ---------------------------------------------------------------------------
# T7. ct-print --full --strip-paths: exact decoded values (Layer 2).
#
# Mirrors the cairo / cardano / circom / flow / fuel / leo / miden /
# move / polkavm / solana / ton (Int round-trip), evm (Raw byte), js
# (String / Raw), python (String / None) and ruby precedents — record
# a real program, then convert the produced CTFS bundle through
# `ct-print --full --strip-paths` and assert on the decoded
# representation.
#
# Why exact-value assertions matter: the legacy `ct-print --json` layer
# only checks for substring presence ("does the trace mention `greet`
# somewhere"), so a recorder regression that silently dropped or
# corrupted a value would not be caught.  The `--full` layer pins:
#
#   - **Strict `value.kind` invariant** — every step var, call arg,
#     and return value must decode to one of the known ValueRecord
#     variants (Int / Float / String / Bool / Raw / None / Void /
#     Sequence / Struct / Tuple).  A new variant fires the test
#     loudly so the next maintainer can extend the assertion rather
#     than silently weakening it.
#   - **Exact (varname, value) pair assertions** — `greet`'s `$1`
#     positional arg decodes to ValueRecord::String { text: "world" };
#     the `$1` step-var snapshot inside greet's body decodes to
#     ValueRecord::Raw { r: "world" } (the bash recorder uses the
#     textual `Raw` form for step-var snapshots and the typed
#     `String` form for call args — both are valid current
#     behaviour, captured exactly).
#   - **Exact return value** — `greet`'s call_exit return_value
#     decodes to ValueRecord::Int { i: 0 } (the bash recorder uses
#     the function exit status as the typed return value).
#   - **Function / path / counts / call-sequence anchors** —
#     5 steps, 1 call, 2 io_events; the call sequence's only
#     user-visible entry is `greet`; path table contains
#     `fixture_full.sh`; function table contains `<toplevel>` and
#     `greet` (`ends_with` checks for tolerance to future
#     namespacing).
#
# The bash recorder also stages an implicit `source` synthetic call
# for the script-load operation (with `$1` = absolute script path);
# that's a recorder-private wrapper distinct from the user-visible
# `<toplevel>` we assert on.
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  fail "T7 requires jq for JSON parsing — install jq to run this test"
fi

OUT_DIR_T7="${WORK_DIR}/t7-full-out"
mkdir -p "${OUT_DIR_T7}"
bash "${LAUNCHER}" --out-dir "${OUT_DIR_T7}" "${FIXTURE_FULL}" >/dev/null

CT_FULL="$(run_ct_print --full --strip-paths "${OUT_DIR_T7}/fixture_full.ct")"

# Sanity: ct-print --full must produce parseable JSON.
echo "${CT_FULL}" | jq . >/dev/null 2>&1 \
  || fail "ct-print --full produced invalid JSON: ${CT_FULL}"

# ----- Function table: <toplevel> + greet ---------------------------
# `ends_with` checks (jq's `endswith`) stay tolerant of any future
# namespacing prefix the recorder might add (e.g. `Object#greet`).
HAS_TOPLEVEL="$(jq -r '[.functions[] | select(endswith("<toplevel>"))] | length' <<< "${CT_FULL}")"
[[ "${HAS_TOPLEVEL}" -ge 1 ]] \
  || fail "T7: missing <toplevel> in functions: $(jq -c .functions <<< "${CT_FULL}")"
HAS_GREET="$(jq -r '[.functions[] | select(endswith("greet"))] | length' <<< "${CT_FULL}")"
[[ "${HAS_GREET}" -ge 1 ]] \
  || fail "T7: missing greet in functions: $(jq -c .functions <<< "${CT_FULL}")"
pass "T7 function table: <toplevel> + greet present"

# ----- Path table: the canonical fixture path must appear -----------
# `--strip-paths` rewrites absolute /tmp prefixes; only the trailing
# component is stable.
HAS_PATH="$(jq -r '[.paths[] | select(endswith("fixture_full.sh"))] | length' <<< "${CT_FULL}")"
[[ "${HAS_PATH}" -ge 1 ]] \
  || fail "T7: missing fixture_full.sh in paths: $(jq -c .paths <<< "${CT_FULL}")"
pass "T7 path table: fixture_full.sh present"

# ----- Counts — stable for the canonical fixture --------------------
# The bash recorder produces a deterministic event count for this
# fixture under DEBUG-trap instrumentation:
#   - 5 step events (absolute step on the source-load line,
#     delta step inside greet's body for the echo line, delta
#     steps on closing `}` / post-call positions)
#   - 3 calls: writer-owned <toplevel>, the <script> entry carrying
#     script argv, and greet. The canonical root is never opened twice.
#   - 2 io_events (the DEBUG-trap path emits an ioStdout event for
#     the source rendering of each echo; the fixture's single
#     `echo` surfaces as two events because the trap fires both
#     before and after the builtin)
# If these change, that's a real regression to investigate, not
# a flake — pin the values strictly.
STEPS="$(jq -r .counts.steps <<< "${CT_FULL}")"
[[ "${STEPS}" == "5" ]] \
  || fail "T7: expected 5 steps, got ${STEPS}; counts=$(jq -c .counts <<< "${CT_FULL}")"
CALLS="$(jq -r .counts.calls <<< "${CT_FULL}")"
[[ "${CALLS}" == "3" ]] \
  || fail "T7: expected 3 calls (<toplevel> + <script> + greet), got ${CALLS}; counts=$(jq -c .counts <<< "${CT_FULL}")"
IO_EVENTS="$(jq -r .counts.io_events <<< "${CT_FULL}")"
[[ "${IO_EVENTS}" == "2" ]] \
  || fail "T7: expected 2 io_events, got ${IO_EVENTS}; counts=$(jq -c .counts <<< "${CT_FULL}")"
pass "T7 counts: 5 steps / 3 calls / 2 io_events"

# Assert identities and parentage, not only the number of frames: accepting
# three anonymous calls would also accept the old duplicated-root defect.
CALL_TREE="$(jq -c '[.events[] | select(.kind == "call_entry") | [.function, .depth, .parent_call_key]]' <<< "${CT_FULL}")"
[[ "${CALL_TREE}" == '[["<toplevel>",0,-1],["<script>",1,0],["greet",2,1]]' ]] \
  || fail "T7: unexpected call hierarchy: ${CALL_TREE}"
ROOT_ARG_COUNT="$(jq '[.events[] | select(.kind == "call_entry" and .function == "<toplevel>") | .args[]] | length' <<< "${CT_FULL}")"
[[ "${ROOT_ARG_COUNT}" == "0" ]] || fail "T7: canonical root has arguments"
pass "T7 call sequence: unique root, script entry, greet"

# ----- Strict ValueRecord variant invariant -------------------------
# Every step var / call arg / return value that surfaces must carry a
# `value.kind` field belonging to the expected, finite set of known
# ValueRecord variants.  If a brand-new variant appears (e.g. BigInt
# support lands), this fires loudly so the next maintainer extends
# the exact-value layer rather than silently accepting it.  The check
# also recurses through Sequence.elements and Struct.field_values so
# nested values are validated.
#
# Implementation: emit every observed kind on a separate line, then
# assert each one is in the allowed set.  This keeps the failure
# message readable when a new variant slips in.
ALLOWED_KINDS=(Int Float String Bool Raw None Void Sequence Struct Tuple)
is_allowed_kind() {
  local k="$1"
  for allowed in "${ALLOWED_KINDS[@]}"; do
    [[ "${k}" == "${allowed}" ]] && return 0
  done
  return 1
}

# Recursively gather every `kind` field appearing under `value.kind`,
# `value.elements[].kind`, `value.field_values[].kind`, and so on.
# We use jq's `..` (recurse) operator to walk the entire JSON tree
# and select every object that has a `.kind` key — this catches both
# top-level values and nested Sequence/Struct elements.
mapfile -t OBSERVED_KINDS < <(jq -r '
  [
    (.events[] | select(.kind == "step") | .vars[]?.value),
    (.events[] | select(.kind == "call_entry") | .args[]?.value),
    (.events[] | select(.kind == "call_exit") | .return_value)
  ]
  | .. | objects
  | select(has("kind"))
  | .kind
' <<< "${CT_FULL}" | sort -u)

[[ "${#OBSERVED_KINDS[@]}" -ge 1 ]] \
  || fail "T7: no value.kind fields observed — recorder produced no values?"

for k in "${OBSERVED_KINDS[@]}"; do
  is_allowed_kind "${k}" \
    || fail "T7: unknown ValueRecord kind=${k}; observed=${OBSERVED_KINDS[*]}; if a new variant has landed for the bash recorder, extend this test to assert on it explicitly rather than weakening the check"
done
pass "T7 ValueRecord variant invariant: observed kinds ${OBSERVED_KINDS[*]} ⊂ {${ALLOWED_KINDS[*]}}"

# ----- Exact decoded call-arg values: greet($1="world") -------------
# The bash recorder uses ValueRecord::String for typed positional-arg
# values — ct-print --full decodes it to
# `{"kind":"String","text":"world",...}`.  This is the bash analogue
# of cairo's `(a, 10)` Int round-trip.  We pick the FIRST greet
# call_entry (filtering by function-name suffix) so the synthetic
# `source` wrapper that also carries `$1` is excluded.
GREET_ARG_KIND="$(jq -r '
  [.events[]
   | select(.kind == "call_entry")
   | select(.args | length > 0)
   | .args[]
   | select(.varname == "$1" and .value.text == "world")]
   | first
   | .value.kind' <<< "${CT_FULL}")"
[[ "${GREET_ARG_KIND}" == "String" ]] \
  || fail "T7: greet(\$1=\"world\") arg should decode as String, got kind=${GREET_ARG_KIND}; bundle=${CT_FULL}"
GREET_ARG_TEXT="$(jq -r '
  [.events[]
   | select(.kind == "call_entry")
   | select(.args | length > 0)
   | .args[]
   | select(.varname == "$1" and .value.text == "world")]
   | first
   | .value.text' <<< "${CT_FULL}")"
[[ "${GREET_ARG_TEXT}" == "world" ]] \
  || fail "T7: greet(\$1=...) text payload should be \"world\", got ${GREET_ARG_TEXT}"
pass "T7 exact call-arg: greet(\$1=String(\"world\"))"

# ----- Exact decoded step-var: $1 = "world" inside greet's body -----
# The bash recorder snapshots positional-arg step-vars through the SAME
# wire-protocol path as call args: `handle_var` → `value_record_for_flag`
# in ct-shell-trace-writer/src/trace_bridge.rs, which maps the `s`
# (string) type flag to `ValueRecord::String { text }`.  There is no
# `ValueRecord::Raw` code path in the shell writer at all, so the decoded
# step-var is `{"kind":"String","text":"world"}` — exactly the same
# variant asserted for the call_entry arg above (they share the helper).
# This is the bash analogue of the cairo `a=10, b=32, ...` round-trip:
# every binding that surfaces is asserted exactly.  If a future recorder
# upgrade emits a different variant here, the strict `value.kind`
# invariant above (and this assertion) fires loudly.
STEP_VAR_KIND="$(jq -r '
  [.events[]
   | select(.kind == "step")
   | .vars[]?
   | select(.varname == "$1" and .value.text == "world")]
   | first
   | .value.kind' <<< "${CT_FULL}")"
[[ "${STEP_VAR_KIND}" == "String" ]] \
  || fail "T7: step var \$1=\"world\" should decode as String, got kind=${STEP_VAR_KIND}"
STEP_VAR_TEXT="$(jq -r '
  [.events[]
   | select(.kind == "step")
   | .vars[]?
   | select(.varname == "$1" and .value.text == "world")]
   | first
   | .value.text' <<< "${CT_FULL}")"
[[ "${STEP_VAR_TEXT}" == "world" ]] \
  || fail "T7: step var \$1 should snapshot \"world\", got ${STEP_VAR_TEXT}"
pass "T7 exact step-var: \$1=String(\"world\")"

# ----- Exact decoded return value: greet returns Int(0) -------------
# Bash function exit status surfaces as ValueRecord::Int { i: 0 } via
# the recorder's RETURN-event handler.  The strict `kind == "Int"`
# invariant means: if a future recorder upgrade emits a different
# variant, this fails loudly and the next maintainer extends the
# assertion to the new variant rather than silently accepting it.
RETURN_KIND="$(jq -r '
  [.events[]
   | select(.kind == "call_exit")
   | .return_value]
   | first
   | .kind' <<< "${CT_FULL}")"
[[ "${RETURN_KIND}" == "Int" ]] \
  || fail "T7: call_exit return_value should decode as Int, got kind=${RETURN_KIND}"
RETURN_I="$(jq -r '
  [.events[]
   | select(.kind == "call_exit")
   | .return_value]
   | first
   | .i' <<< "${CT_FULL}")"
[[ "${RETURN_I}" == "0" ]] \
  || fail "T7: call_exit return_value should be 0 (success), got ${RETURN_I}"
pass "T7 exact return: call_exit → Int(0)"

# ---------------------------------------------------------------------------
# T8. A script recorded with no arguments, under the oldest supported Bash.
#
# The Shell Recorder specification (`Recording-Backends/Shell-Recorder.md`,
# "Supported Shells") supports Bash 4.0 and newer. The launcher runs under
# `set -u`, and before Bash 4.4 expanding an array with no elements under
# `nounset` is an "unbound variable" error (Bash CHANGES, bash-4.4-rc2, "New
# Features in Bash"); on 4.0 `"$@"` with no positional parameters is one too.
# The dev shell's own Bash 5 cannot fail for that reason, so the floor
# release is named by CT_TEST_BASH_4_0, which the Linux dev shell exports
# (see `oldBashEnv` in flake.nix). CT_TEST_BASH_3_2 names a Bash below the
# floor, which the launcher must refuse by name before it runs anything.
#
# Each Bash under test is selected through PATH: a directory holding only a
# `bash` symlink is put first, so the entry point's `#!/usr/bin/env bash`,
# the launcher's own shebang, and its `bash recorder.sh` all resolve to it.
# ---------------------------------------------------------------------------

NOARG_FIXTURE="${WORK_DIR}/noarg.sh"
# Prints its argument count and each argument in brackets, so an empty
# argument, or one with spaces, that the launcher drops or splits shows up.
cat > "${NOARG_FIXTURE}" <<'EOF'
_seen=""
for _a in "$@"; do _seen="${_seen}[${_a}]"; done
echo "noarg-marker argc=$# args=${_seen}"
EOF

[[ -x "${BIN}" ]] || fail "T8: entry point ${BIN} is not executable"

# bash_path_dir <label> <bash-binary> -- prints a fresh directory that holds
# only a `bash` symlink to <bash-binary>.
bash_path_dir() {
  local dir="${WORK_DIR}/path-$1"
  mkdir -p "${dir}"
  ln -sfn "$2" "${dir}/bash"
  printf '%s\n' "${dir}"
}

# run_entry <path-prefix> <out-dir> [env-assignments...] -- [launcher-args...]
# Runs the `codetracer-bash-recorder` entry point as
# `--out-dir <out-dir> <launcher-args...>` (the script and its arguments,
# optionally after `--`) with <path-prefix> (may be empty) prepended to
# PATH. Sets RUN_RC, RUN_STDOUT and RUN_STDERR; never aborts the test on a
# non-zero exit.
run_entry() {
  local prefix="$1" out_dir="$2"
  shift 2
  local -a env_vars=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    env_vars+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  local run_path="${PATH}"
  [[ -n "${prefix}" ]] && run_path="${prefix}:${PATH}"
  RUN_RC=0
  env ${env_vars[@]+"${env_vars[@]}"} PATH="${run_path}" \
    "${BIN}" --out-dir "${out_dir}" "$@" \
    >"${WORK_DIR}/run.out" 2>"${WORK_DIR}/run.err" || RUN_RC=$?
  RUN_STDOUT="$(cat "${WORK_DIR}/run.out")"
  RUN_STDERR="$(cat "${WORK_DIR}/run.err")"
}

# expect_recorded <label> <out-dir> <expected-script-line> <expected-args-json>
expect_recorded() {
  local label="$1" out_dir="$2" line="$3" args_json="$4"
  local -a cts=()
  [[ "${RUN_RC}" == "0" ]] \
    || fail "${label}: launcher exited ${RUN_RC}; stderr: ${RUN_STDERR}"
  if grep -qF "unbound variable" <<< "${RUN_STDERR}"; then
    fail "${label}: stderr reports an unbound variable: ${RUN_STDERR}"
  fi
  grep -qxF "${line}" <<< "${RUN_STDOUT}" \
    || fail "${label}: script output '${line}' missing; stdout: ${RUN_STDOUT}"
  shopt -s nullglob
  cts=("${out_dir}"/*.ct)
  shopt -u nullglob
  [[ "${#cts[@]}" == "1" ]] \
    || fail "${label}: expected exactly one *.ct in ${out_dir}, found ${#cts[@]}: $(ls -A "${out_dir}" 2>/dev/null)"
  jq -e --argjson want "${args_json}" '.args == $want' \
    "${out_dir}/trace_db_metadata.json" >/dev/null \
    || fail "${label}: trace_db_metadata.json args is not ${args_json} (or the file is not valid JSON): $(cat "${out_dir}/trace_db_metadata.json" 2>&1)"
  pass "${label}: exit 0, one .ct, script ran, args ${args_json}"
}

# expect_ran_unrecorded <label> -- the _DISABLED short-circuit with no argument.
expect_ran_unrecorded() {
  local label="$1"
  [[ "${RUN_RC}" == "0" ]] \
    || fail "${label}: launcher exited ${RUN_RC}; stderr: ${RUN_STDERR}"
  if grep -qF "unbound variable" <<< "${RUN_STDERR}"; then
    fail "${label}: stderr reports an unbound variable: ${RUN_STDERR}"
  fi
  grep -qxF "noarg-marker argc=0 args=" <<< "${RUN_STDOUT}" \
    || fail "${label}: the script did not run; stdout: ${RUN_STDOUT}; stderr: ${RUN_STDERR}"
  pass "${label}: script ran, exit 0"
}

# check_no_arg_cases <label> <path-prefix> -- the no-argument recording
# (with the script given plainly and after `--`, the two places the launcher
# reads `"$@"`), the no-argument _DISABLED run, the one-argument control, and
# an empty argument plus arguments with spaces, which the guarded array
# expansions must pass through unchanged.
check_no_arg_cases() {
  local label="$1" prefix="$2"
  local out="${WORK_DIR}/t8-${label}"
  run_entry "${prefix}" "${out}-noarg" -- "${NOARG_FIXTURE}"
  expect_recorded "T8 ${label} no argument" "${out}-noarg" \
    "noarg-marker argc=0 args=" '[]'
  run_entry "${prefix}" "${out}-dashdash" -- -- "${NOARG_FIXTURE}"
  expect_recorded "T8 ${label} no argument after --" "${out}-dashdash" \
    "noarg-marker argc=0 args=" '[]'
  run_entry "${prefix}" "${out}-disabled" CODETRACER_BASH_RECORDER_DISABLED=1 \
    -- "${NOARG_FIXTURE}"
  expect_ran_unrecorded "T8 ${label} _DISABLED=1, no argument"
  run_entry "${prefix}" "${out}-onearg" -- "${NOARG_FIXTURE}" one
  expect_recorded "T8 ${label} one argument (control)" "${out}-onearg" \
    "noarg-marker argc=1 args=[one]" '["one"]'
  run_entry "${prefix}" "${out}-quoted" -- "${NOARG_FIXTURE}" "" "a b" "  c  "
  expect_recorded "T8 ${label} empty and spaced arguments" "${out}-quoted" \
    "noarg-marker argc=3 args=[][a b][  c  ]" '["","a b","  c  "]'
}

# The Bash the dev shell installs (5.x): the same cases must pass there too.
check_no_arg_cases "installed-bash-$(bash -c 'echo "${BASH_VERSION}"')" ""

if [[ -n "${CT_TEST_BASH_4_0:-}" ]]; then
  [[ -x "${CT_TEST_BASH_4_0}" ]] \
    || fail "T8: CT_TEST_BASH_4_0=${CT_TEST_BASH_4_0} is not executable"
  BASH40_DIR="$(bash_path_dir bash40 "${CT_TEST_BASH_4_0}")"
  # Positive control: through this PATH, `bash` really is 4.0. Without it a
  # misconfigured fixture would silently test the installed Bash 5 instead.
  BASH40_SEEN="$(PATH="${BASH40_DIR}:${PATH}" bash -c 'echo "${BASH_VERSION}"')"
  [[ "${BASH40_SEEN}" == 4.0.* ]] \
    || fail "T8: bash through ${BASH40_DIR} reports ${BASH40_SEEN}, expected 4.0.*"
  # shellcheck disable=SC2016 # expanded by the Bash under test, not here
  BASH40_ENV_SEEN="$(PATH="${BASH40_DIR}:${PATH}" env bash -c 'echo "${BASH_VERSION}"')"
  [[ "${BASH40_ENV_SEEN}" == 4.0.* ]] \
    || fail "T8: 'env bash' through ${BASH40_DIR} reports ${BASH40_ENV_SEEN}, expected 4.0.*"
  pass "T8 control: PATH selects Bash ${BASH40_SEEN}"
  check_no_arg_cases "bash-4.0" "${BASH40_DIR}"
  # The launcher records the `bash --version` it ran with; it must be 4.0.
  jq -e '.bash_version | startswith("4.0.")' \
    "${WORK_DIR}/t8-bash-4.0-noarg/trace_db_metadata.json" >/dev/null \
    || fail "T8: the Bash 4.0 recording names another Bash: $(cat "${WORK_DIR}/t8-bash-4.0-noarg/trace_db_metadata.json")"
  pass "T8 bash-4.0: the recording's bash_version is 4.0"
elif [[ "$(uname -s)" == Linux ]]; then
  fail "T8: CT_TEST_BASH_4_0 is unset; run this test in the dev shell (nix develop), which exports it on Linux — it must not silently skip"
else
  echo "skipped: T8 under Bash 4.0 — CT_TEST_BASH_4_0 is unset (Linux dev shell only)"
fi

# T9. A Bash older than 4.0 is refused by name, before the script runs.
if [[ -n "${CT_TEST_BASH_3_2:-}" ]]; then
  [[ -x "${CT_TEST_BASH_3_2}" ]] \
    || fail "T9: CT_TEST_BASH_3_2=${CT_TEST_BASH_3_2} is not executable"
  BASH32_DIR="$(bash_path_dir bash32 "${CT_TEST_BASH_3_2}")"
  BASH32_SEEN="$(PATH="${BASH32_DIR}:${PATH}" bash -c 'echo "${BASH_VERSION}"')"
  [[ "${BASH32_SEEN}" == 3.2.* ]] \
    || fail "T9: bash through ${BASH32_DIR} reports ${BASH32_SEEN}, expected 3.2.*"
  OUT_DIR_T9="${WORK_DIR}/t9-bash32"
  run_entry "${BASH32_DIR}" "${OUT_DIR_T9}" -- "${NOARG_FIXTURE}" one
  [[ "${RUN_RC}" == "1" ]] \
    || fail "T9: launcher under Bash ${BASH32_SEEN} must exit 1, got ${RUN_RC}; stdout: ${RUN_STDOUT}"
  grep -qF "Bash ${BASH32_SEEN} (${BASH32_DIR}/bash)" <<< "${RUN_STDERR}" \
    || fail "T9: error must name the Bash found (${BASH32_SEEN}, ${BASH32_DIR}/bash); stderr: ${RUN_STDERR}"
  grep -qF "4.0 or newer" <<< "${RUN_STDERR}" \
    || fail "T9: error must say Bash 4.0 or newer is required; stderr: ${RUN_STDERR}"
  if grep -qF "noarg-marker" <<< "${RUN_STDOUT}"; then
    fail "T9: the script must not run under an unsupported Bash; stdout: ${RUN_STDOUT}"
  fi
  [[ ! -e "${OUT_DIR_T9}" ]] \
    || fail "T9: an unsupported Bash must not create ${OUT_DIR_T9}"
  pass "T9 Bash ${BASH32_SEEN} refused (exit ${RUN_RC}), script not run"

  # Started as `<bash-3.2> launcher.sh` with the installed Bash first on
  # PATH, the error must name the interpreter running the launcher, not the
  # `bash` on PATH.
  OUT_DIR_T9_DIRECT="${WORK_DIR}/t9-bash32-direct"
  RUN_RC=0
  "${CT_TEST_BASH_3_2}" "${LAUNCHER}" --out-dir "${OUT_DIR_T9_DIRECT}" \
    "${NOARG_FIXTURE}" >"${WORK_DIR}/run.out" 2>"${WORK_DIR}/run.err" || RUN_RC=$?
  RUN_STDOUT="$(cat "${WORK_DIR}/run.out")"
  RUN_STDERR="$(cat "${WORK_DIR}/run.err")"
  [[ "${RUN_RC}" == "1" ]] \
    || fail "T9: '${CT_TEST_BASH_3_2} launcher.sh' must exit 1, got ${RUN_RC}; stdout: ${RUN_STDOUT}"
  grep -qF "Bash ${BASH32_SEEN} (${CT_TEST_BASH_3_2})" <<< "${RUN_STDERR}" \
    || fail "T9: error must name the interpreter running the launcher (${CT_TEST_BASH_3_2}); stderr: ${RUN_STDERR}"
  if grep -qF "noarg-marker" <<< "${RUN_STDOUT}"; then
    fail "T9: the script must not run under an unsupported Bash; stdout: ${RUN_STDOUT}"
  fi
  [[ ! -e "${OUT_DIR_T9_DIRECT}" ]] \
    || fail "T9: an unsupported Bash must not create ${OUT_DIR_T9_DIRECT}"
  pass "T9 '<bash-3.2> launcher.sh' refused, naming ${CT_TEST_BASH_3_2}"
elif [[ "$(uname -s)" == Linux ]]; then
  fail "T9: CT_TEST_BASH_3_2 is unset; run this test in the dev shell (nix develop), which exports it on Linux — it must not silently skip"
else
  echo "skipped: T9 under Bash 3.2 — CT_TEST_BASH_3_2 is unset (Linux dev shell only)"
fi

# ---------------------------------------------------------------------------
# T10. A script argument that is one of the recorder's or the writer's own
# flags (`-h`, `--help`, `-V`, `--version`) belongs to the script.
#
# Spec `CLI/recorders/shell.md`, "Options": after the script, everything is
# the script's arguments. The launcher hands them to `ct-shell-trace-writer`
# after `--args`, so the writer must not answer them with its own usage or
# version: the recording must exit 0 with exactly one trace, print only the
# script's output, and record the flag as the `<script>` call's `$1`
# (`Recorder-CLI-Conventions.md` §6: exit 0 means "trace written").
# Each flag is given both plainly after the script and after `--`.
# ---------------------------------------------------------------------------

ARGS_FIXTURE="${WORK_DIR}/args.sh"
cat > "${ARGS_FIXTURE}" <<'EOF'
echo "args: $*"
EOF

for flag in -h --help -V --version; do
  for form in plain dashdash; do
    label="T10 script argument ${flag} (${form})"
    out="${WORK_DIR}/t10-${flag#--}-${form}"
    if [[ "${form}" == dashdash ]]; then
      run_entry "" "${out}" -- -- "${ARGS_FIXTURE}" "${flag}"
    else
      run_entry "" "${out}" -- "${ARGS_FIXTURE}" "${flag}"
    fi
    [[ "${RUN_RC}" == "0" ]] \
      || fail "${label}: launcher exited ${RUN_RC}; stdout: ${RUN_STDOUT}; stderr: ${RUN_STDERR}"
    [[ "${RUN_STDOUT}" == "args: ${flag}" ]] \
      || fail "${label}: stdout must be exactly the script's 'args: ${flag}'; got: ${RUN_STDOUT}"
    shopt -s nullglob
    cts=("${out}"/*.ct)
    shopt -u nullglob
    [[ "${#cts[@]}" == "1" && -f "${out}/args.ct" ]] \
      || fail "${label}: expected exactly one *.ct (args.ct) in ${out}, found ${#cts[@]}: $(ls -A "${out}" 2>/dev/null)"
    SCRIPT_ARGS="$(run_ct_print --full --strip-paths "${out}/args.ct" | jq -c '
      [.events[] | select(.kind == "call_entry" and .function == "<script>")
       | [.args[] | [.varname, .value.kind, .value.text]]]')"
    [[ "${SCRIPT_ARGS}" == "[[[\"\$1\",\"String\",\"${flag}\"]]]" ]] \
      || fail "${label}: the <script> call must carry \$1=String(\"${flag}\") and nothing else; got: ${SCRIPT_ARGS}"
    pass "${label}: exit 0, one .ct, stdout is the script's, <script>(\$1=\"${flag}\")"
  done
done

# ---------------------------------------------------------------------------
# T11. A recording whose trace writer finishes without writing `<script>.ct`
# fails: a message on stderr naming the missing trace, and exit 1.
#
# Spec `CLI/ct/record.md`, "Corner Cases": a recorder that produced no trace
# but exited 0 is the silent-incompleteness pattern. `Recorder-CLI-
# Conventions.md` §6 gives a recorder error exit 1 "regardless of the target
# program's exit code", so a script that itself failed still makes the
# launcher exit 1; the message carries the script's status instead.
#
# Real ways for the writer to end with no trace, none of them a stub; the
# writer exits 1 for each, and the launcher must still say why:
#   * `<out-dir>/args.ct` is already a directory, so the writer cannot create
#     the container.
#   * A read-only `args.ct` left by a previous run sits in a read-only output
#     directory: the writer cannot create the container, and the old file
#     must not pass for this run's trace.
#   * The recorder cannot move the event channel to a descriptor of 10 or
#     above (an open-files limit of 12), so no START event reaches the writer
#     and `TraceBridge::finish` reports that no trace was written. Here the
#     recorder must also stop before the script runs, and say which
#     descriptor it could not open.
#   * The recorder cannot write START (FD 3 on /dev/full): it must likewise
#     stop before the script runs.
# ---------------------------------------------------------------------------

FAIL3_FIXTURE="${WORK_DIR}/args3.sh"
cat > "${FAIL3_FIXTURE}" <<'EOF'
echo "args: $*"
exit 3
EOF

# expect_no_trace_failure <label> <trace-path> <script-stdout> [status-phrase]
expect_no_trace_failure() {
  local label="$1" trace="$2" stdout="$3" status_phrase="${4:-}"
  [[ "${RUN_RC}" == "1" ]] \
    || fail "${label}: launcher must exit 1, got ${RUN_RC}; stdout: ${RUN_STDOUT}; stderr: ${RUN_STDERR}"
  [[ "${RUN_STDOUT}" == "${stdout}" ]] \
    || fail "${label}: the script must still run; stdout: ${RUN_STDOUT}"
  grep -qF "recording failed" <<< "${RUN_STDERR}" \
    || fail "${label}: stderr must say the recording failed; stderr: ${RUN_STDERR}"
  grep -qF "${trace}" <<< "${RUN_STDERR}" \
    || fail "${label}: stderr must name the missing trace ${trace}; stderr: ${RUN_STDERR}"
  if [[ -n "${status_phrase}" ]]; then
    grep -qF "${status_phrase}" <<< "${RUN_STDERR}" \
      || fail "${label}: stderr must report '${status_phrase}'; stderr: ${RUN_STDERR}"
  fi
  pass "${label}: exit 1, stderr names ${trace##*/}"
}

OUT_DIR_T11="${WORK_DIR}/t11-ct-is-dir"
mkdir -p "${OUT_DIR_T11}/args.ct"
run_entry "" "${OUT_DIR_T11}" -- "${ARGS_FIXTURE}" one
expect_no_trace_failure "T11 args.ct is a directory" \
  "${OUT_DIR_T11}/args.ct" "args: one"

OUT_DIR_T11B="${WORK_DIR}/t11-ct-is-dir-status3"
mkdir -p "${OUT_DIR_T11B}/args3.ct"
run_entry "" "${OUT_DIR_T11B}" -- "${FAIL3_FIXTURE}" one
expect_no_trace_failure "T11 args3.ct is a directory, script exits 3" \
  "${OUT_DIR_T11B}/args3.ct" "args: one" "status 3"

OUT_DIR_T11C="${WORK_DIR}/t11-no-start"
RUN_RC=0
( ulimit -n 12 && exec "${BIN}" --out-dir "${OUT_DIR_T11C}" "${ARGS_FIXTURE}" one ) \
  >"${WORK_DIR}/run.out" 2>"${WORK_DIR}/run.err" || RUN_RC=$?
RUN_STDOUT="$(cat "${WORK_DIR}/run.out")"
RUN_STDERR="$(cat "${WORK_DIR}/run.err")"
# Positive control: the writer really received no START event.
grep -qF "EOF reached without EXIT event" <<< "${RUN_STDERR}" \
  || fail "T11 control: under 'ulimit -n 12' the writer should see an empty stream; stderr: ${RUN_STDERR}"
# The recorder cannot move the event channel here (issue
# `2026-11-16-bash-recorder-ignores-a-failed-move-of-its-event-channel`).
# Bash does not exit when a redirection on `exec` fails, so the recorder
# must check the move itself: the script must not run unrecorded, and
# stderr must name the descriptor that could not be opened rather than
# leave the missing-trace message as the only explanation. The launcher
# must not then report the recorder's status as the script's.
[[ "${RUN_RC}" == "1" ]] \
  || fail "T11 failed FD move: launcher must exit 1, got ${RUN_RC}; stderr: ${RUN_STDERR}"
[[ -z "${RUN_STDOUT}" ]] \
  || fail "T11 failed FD move: the script must not run unrecorded; stdout: ${RUN_STDOUT}"
grep -qE "recorder\.sh: cannot move the event stream from FD 3 to FD [0-9]+ \(open-files limit: 12\)" <<< "${RUN_STDERR}" \
  || fail "T11 failed FD move: stderr must name the descriptor it could not open; stderr: ${RUN_STDERR}"
grep -qF "recording failed" <<< "${RUN_STDERR}" \
  || fail "T11 failed FD move: stderr must say the recording failed; stderr: ${RUN_STDERR}"
grep -qF "${OUT_DIR_T11C}/args.ct" <<< "${RUN_STDERR}" \
  || fail "T11 failed FD move: stderr must name the missing trace; stderr: ${RUN_STDERR}"
grep -qF "before the script ran" <<< "${RUN_STDERR}" \
  || fail "T11 failed FD move: stderr must say the script never ran; stderr: ${RUN_STDERR}"
! grep -qF "the script exited with status" <<< "${RUN_STDERR}" \
  || fail "T11 failed FD move: the recorder's status must not be reported as the script's; stderr: ${RUN_STDERR}"
pass "T11 failed FD move (ulimit -n 12): script not run, stderr names the descriptor"

# A `<script>.ct` left in the output directory by a previous run is not this
# run's trace. The writer fails here because it cannot create the container
# (the old `args.ct` and its directory are read-only), and the launcher must
# take the writer's exit status as the verdict rather than find the old file
# and report success (issue
# `2026-11-16-shell-trace-writer-exits-0-when-it-cannot-create-the-trace-container`).
# The old file must be left as it was. Permissions do not bind root, so the
# case is skipped by name when the file stays writable.
OUT_DIR_T11S="${WORK_DIR}/t11-stale-trace"
mkdir -p "${OUT_DIR_T11S}"
printf 'stale trace from a previous run' > "${OUT_DIR_T11S}/args.ct"
chmod 444 "${OUT_DIR_T11S}/args.ct"
chmod 555 "${OUT_DIR_T11S}"
if [[ -w "${OUT_DIR_T11S}/args.ct" || -w "${OUT_DIR_T11S}" ]]; then
  echo "skipped: T11 stale args.ct — read-only permissions do not bind this user"
else
  run_entry "" "${OUT_DIR_T11S}" -- "${ARGS_FIXTURE}" one
  grep -qF "failed to create streaming CTFS container" <<< "${RUN_STDERR}" \
    || fail "T11 stale args.ct control: the writer must fail to create the container; stderr: ${RUN_STDERR}"
  expect_no_trace_failure "T11 stale args.ct, writer fails" \
    "${OUT_DIR_T11S}/args.ct" "args: one" "trace writer exited with status 1"
  [[ "$(cat "${OUT_DIR_T11S}/args.ct")" == "stale trace from a previous run" ]] \
    || fail "T11 stale args.ct: the old file must be left as it was"
  [[ ! -e "${OUT_DIR_T11S}/trace_db_metadata.json" ]] \
    || fail "T11 stale args.ct: a failed recording must not write the launcher's sidecars"
fi
chmod 755 "${OUT_DIR_T11S}"
chmod 644 "${OUT_DIR_T11S}/args.ct"

# The launcher reads an empty event file as "the recorder stopped before the
# script ran", so the recorder must not run the script when its START write
# fails either (an event file on a full filesystem). The launcher always
# hands it a fresh file from `mktemp`, so the recorder is run directly here,
# with FD 3 on /dev/full, where every write fails with ENOSPC.
# /dev/full is Linux-only; elsewhere this case is skipped by name.
if [[ -c /dev/full ]]; then
  RUN_RC=0
  bash "${REPO_ROOT}/bash-recorder/recorder.sh" "${ARGS_FIXTURE}" one \
    3>/dev/full >"${WORK_DIR}/run.out" 2>"${WORK_DIR}/run.err" || RUN_RC=$?
  RUN_STDOUT="$(cat "${WORK_DIR}/run.out")"
  RUN_STDERR="$(cat "${WORK_DIR}/run.err")"
  [[ "${RUN_RC}" == "1" ]] \
    || fail "T11 failed START write: recorder must exit 1, got ${RUN_RC}; stderr: ${RUN_STDERR}"
  [[ -z "${RUN_STDOUT}" ]] \
    || fail "T11 failed START write: the script must not run unrecorded; stdout: ${RUN_STDOUT}"
  grep -qE "recorder\.sh: cannot write the START event to FD [0-9]+; the script was not run" <<< "${RUN_STDERR}" \
    || fail "T11 failed START write: stderr must say the START write failed; stderr: ${RUN_STDERR}"
  pass "T11 failed START write (FD 3 on /dev/full): script not run"
elif [[ "$(uname -s)" == Linux ]]; then
  fail "T11 failed START write: /dev/full is missing on Linux"
else
  echo "skipped: T11 failed START write — no /dev/full on $(uname -s)"
fi

# ---------------------------------------------------------------------------
# T12. The recorded script sees its own path as `$0`, on the installed Bash
# and on Bash 4.0.
#
# The recorder sources the script, where `$0` would be `recorder.sh`; spec
# `Recording-Backends/Shell-Recorder.md`, "Interactive Preservation", makes
# `$0` the script's absolute path, equal to `${BASH_SOURCE[0]}` at its top
# level. Bash 5.0 and later get it from `BASH_ARGV0`; Bash 4 has no such
# variable, and the recorder re-enters itself under `bash -c` instead, which
# only the Bash 4.0 leg exercises (CT_TEST_BASH_4_0, checked by T8 above).
#   * `main_guard.sh` runs `main` only when `${BASH_SOURCE[0]} == $0`: its
#     output must be the direct run's, and the trace must call `main`.
#   * `print_dollar0.sh` prints `$0`: the absolute path, also when the
#     script is given by a relative path (`bash ./x.sh` gives `./x.sh`, but
#     `${BASH_SOURCE[0]}` is absolute under the recorder, and the guard
#     compares the two).
#   * The `-c` shell of the Bash 4 path must not show: no
#     `BASH_EXECUTION_STRING`, which a script run directly does not have.
# ---------------------------------------------------------------------------

FIXTURES_BASH="${REPO_ROOT}/tests/fixtures/bash"
EXECSTR_FIXTURE="${WORK_DIR}/execstr.sh"
cat > "${EXECSTR_FIXTURE}" <<'EOF'
echo "execstr=${BASH_EXECUTION_STRING-unset}"
EOF

# check_dollar_zero_cases <label> <path-prefix>
check_dollar_zero_cases() {
  local label="$1" prefix="$2" out="${WORK_DIR}/t12-$1" calls
  run_entry "${prefix}" "${out}-guard" -- "${FIXTURES_BASH}/main_guard.sh" a b
  [[ "${RUN_RC}" == "0" ]] \
    || fail "T12 ${label} guard: launcher exited ${RUN_RC}; stderr: ${RUN_STDERR}"
  [[ "${RUN_STDOUT}" == "main ran with 2 args" ]] \
    || fail "T12 ${label} guard: the BASH_SOURCE[0] == \$0 guard must hold; stdout: '${RUN_STDOUT}'; stderr: ${RUN_STDERR}"
  calls="$(run_ct_print --full --strip-paths "${out}-guard/main_guard.ct" | jq -c '
    [.events[] | select(.kind == "call_entry") | .function]')"
  [[ "${calls}" == '["<toplevel>","<script>","main"]' ]] \
    || fail "T12 ${label} guard: the trace must call main from <script>; calls: ${calls}"
  pass "T12 ${label}: guarded main runs and is recorded"

  run_entry "${prefix}" "${out}-d0" -- "${FIXTURES_BASH}/print_dollar0.sh"
  [[ "${RUN_RC}" == "0" && "${RUN_STDOUT}" == "dollar0=${FIXTURES_BASH}/print_dollar0.sh" ]] \
    || fail "T12 ${label} \$0: expected dollar0=${FIXTURES_BASH}/print_dollar0.sh (exit 0), got '${RUN_STDOUT}' (exit ${RUN_RC}); stderr: ${RUN_STDERR}"
  pass "T12 ${label}: \$0 is the script's path"

  pushd "${FIXTURES_BASH}" >/dev/null
  run_entry "${prefix}" "${out}-d0-rel" -- ./print_dollar0.sh
  popd >/dev/null
  [[ "${RUN_RC}" == "0" && "${RUN_STDOUT}" == "dollar0=${FIXTURES_BASH}/print_dollar0.sh" ]] \
    || fail "T12 ${label} relative \$0: expected the absolute path, got '${RUN_STDOUT}' (exit ${RUN_RC}); stderr: ${RUN_STDERR}"
  pass "T12 ${label}: \$0 of a script given by a relative path is absolute"

  run_entry "${prefix}" "${out}-execstr" -- "${EXECSTR_FIXTURE}"
  [[ "${RUN_RC}" == "0" && "${RUN_STDOUT}" == "execstr=unset" ]] \
    || fail "T12 ${label}: BASH_EXECUTION_STRING must be unset, as in a direct run; got '${RUN_STDOUT}' (exit ${RUN_RC}); stderr: ${RUN_STDERR}"
  pass "T12 ${label}: no BASH_EXECUTION_STRING"
}

check_dollar_zero_cases "installed-bash" ""
if [[ -n "${BASH40_DIR:-}" ]]; then
  check_dollar_zero_cases "bash-4.0" "${BASH40_DIR}"
elif [[ "$(uname -s)" == Linux ]]; then
  fail "T12: no Bash 4.0 (CT_TEST_BASH_4_0) to run under; run this test in the dev shell"
else
  echo "skipped: T12 under Bash 4.0 — CT_TEST_BASH_4_0 is unset (Linux dev shell only)"
fi

# ---------------------------------------------------------------------------
# T13. The EXIT event carries the status the process exits with when the
# script's EXIT action changes it, on the installed Bash and on Bash 4.0.
#
# codetracer-pm issue
# `2026-11-16-bash-recorder-exit-event-keeps-the-old-code-when-the-scripts-exit-trap-calls-exit.md`;
# spec `Recording-Backends/Shell-Recorder.md`, "Script Exit". What an
# `exit` in a trap action exits with differs between Bash releases (Bash
# before 5.1 forgets it runs the EXIT trap once another trap has run in it;
# Bash 4.0 exits on `exit foo` where later releases go on), so each fixture is
# compared with its own run without the recorder under the same Bash:
# the recorder must exit with that status and end its event stream with
# exactly one `EXIT code=<that status>`. The cargo tests check the rest of
# the recording, on the installed Bash only.
# ---------------------------------------------------------------------------

# check_exit_action_fixtures <label> <bash>
check_exit_action_fixtures() {
  local label="$1" shell="$2" fixture name native_rc rec_rc events exits last
  for fixture in "${FIXTURES_BASH}"/trap_exit_*.sh; do
    name="$(basename "${fixture}" .sh)"
    native_rc=0
    # shellcheck disable=SC2016 # $1 is the inner shell's first argument
    "${shell}" -c 'set -o functrace -o errtrace; shopt -s extdebug; source "$1"' \
      bash "${fixture}" >/dev/null 2>&1 || native_rc=$?
    events="${WORK_DIR}/t13-${label}-${name}.events"
    rec_rc=0
    "${shell}" "${REPO_ROOT}/bash-recorder/recorder.sh" "${fixture}" \
      >/dev/null 2>&1 3>"${events}" || rec_rc=$?
    [[ "${rec_rc}" == "${native_rc}" ]] \
      || fail "T13 ${label} ${name}: the recorder exited ${rec_rc}, the script exits ${native_rc} without it"
    exits="$(grep -c '^EXIT ' "${events}" || true)"
    last="$(tail -n 1 "${events}")"
    [[ "${exits}" == 1 && "${last}" == "EXIT code=${native_rc}" ]] \
      || fail "T13 ${label} ${name}: expected one EXIT event, code=${native_rc}, last; got ${exits}, last event '${last}'"
    pass "T13 ${label} ${name}: exit ${native_rc}, EXIT code=${native_rc}"
  done
}

check_exit_action_fixtures "installed-bash" "$(command -v bash)"
if [[ -n "${CT_TEST_BASH_4_0:-}" ]]; then
  check_exit_action_fixtures "bash-4.0" "${CT_TEST_BASH_4_0}"
elif [[ "$(uname -s)" == Linux ]]; then
  fail "T13: no Bash 4.0 (CT_TEST_BASH_4_0) to run under; run this test in the dev shell"
else
  echo "skipped: T13 under Bash 4.0 — CT_TEST_BASH_4_0 is unset (Linux dev shell only)"
fi

echo ""
echo "test_bash_recorder_cli: ${PASS_COUNT} assertions passed"

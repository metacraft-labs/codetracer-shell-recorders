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
#   - 1 user-visible call event (`greet`); the recorder also stages
#     a synthetic `source` wrapper for script-load that surfaces in
#     the function table but not in the `calls` count
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
[[ "${CALLS}" == "1" ]] \
  || fail "T7: expected 1 call, got ${CALLS}; counts=$(jq -c .counts <<< "${CT_FULL}")"
IO_EVENTS="$(jq -r .counts.io_events <<< "${CT_FULL}")"
[[ "${IO_EVENTS}" == "2" ]] \
  || fail "T7: expected 2 io_events, got ${IO_EVENTS}; counts=$(jq -c .counts <<< "${CT_FULL}")"
pass "T7 counts: 5 steps / 1 call / 2 io_events"

# ----- Call sequence: exactly one user-visible call_entry -----------
# The fixture issues exactly one user call (`greet`).  The bash
# recorder's `function` field on call_entry is currently null for
# this code path (function_id-only) — so we anchor the call by its
# args instead (the typed String "world" arg uniquely identifies it,
# distinguishing it from any synthetic wrapper that might surface).
TOTAL_ENTRIES="$(jq -r '[.events[] | select(.kind == "call_entry")] | length' <<< "${CT_FULL}")"
[[ "${TOTAL_ENTRIES}" == "1" ]] \
  || fail "T7: expected exactly 1 call_entry, got ${TOTAL_ENTRIES}: $(jq -c '[.events[] | select(.kind == "call_entry")]' <<< "${CT_FULL}")"
pass "T7 call sequence: ${TOTAL_ENTRIES} call_entry event"

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
# The bash recorder snapshots positional-arg locals via
# ValueRecord::Raw (textual rendering — distinct from the typed
# `String` form used for call_entry args).  This is the bash
# analogue of the cairo `a=10, b=32, sum_val=42, ...` round-trip:
# every binding that surfaces is asserted exactly.  If a future
# recorder upgrade emits ValueRecord::String here instead, the
# strict kind invariant above (and this assertion) fires loudly.
STEP_VAR_KIND="$(jq -r '
  [.events[]
   | select(.kind == "step")
   | .vars[]?
   | select(.varname == "$1" and .value.r == "world")]
   | first
   | .value.kind' <<< "${CT_FULL}")"
[[ "${STEP_VAR_KIND}" == "Raw" ]] \
  || fail "T7: step var \$1=\"world\" should decode as Raw, got kind=${STEP_VAR_KIND}"
STEP_VAR_TEXT="$(jq -r '
  [.events[]
   | select(.kind == "step")
   | .vars[]?
   | select(.varname == "$1" and .value.r == "world")]
   | first
   | .value.r' <<< "${CT_FULL}")"
[[ "${STEP_VAR_TEXT}" == "world" ]] \
  || fail "T7: step var \$1 should snapshot \"world\", got ${STEP_VAR_TEXT}"
pass "T7 exact step-var: \$1=Raw(\"world\")"

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

echo ""
echo "test_bash_recorder_cli: ${PASS_COUNT} assertions passed"

#!/usr/bin/env bash
# End-to-end CLI convention tests for codetracer-zsh-recorder.
#
# Mirrors tests/test_bash_recorder_cli.sh — see that file for the
# rationale.  We run the zsh launcher under `zsh` directly (since it
# relies on zsh-specific syntax for path resolution), but the test
# runner itself stays in bash for portability with the rest of the
# verifier suite.
#
# T6 covers the legacy `ct-print --json` substring presence layer.
# T7 mirrors the cairo / cardano / ... / js / python / ruby
# `ct-print --full` upgrade — exact decoded values for every step
# var, call arg, and return value, plus a strict ValueRecord variant
# invariant so any future format additions surface loudly.
#
# Usage: bash tests/test_zsh_recorder_cli.sh
#
# Exit codes: 0 on success, 1 on first failed assertion.  If `zsh` is
# not available the runner exits 0 with a single "skipped" line —
# matching the cargo zsh tests' `require_zsh!` policy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if ! command -v zsh >/dev/null 2>&1; then
  echo "ok: zsh not available — skipping test_zsh_recorder_cli"
  exit 0
fi

LAUNCHER="${REPO_ROOT}/zsh-recorder/launcher.zsh"
BIN="${REPO_ROOT}/zsh-recorder/codetracer-zsh-recorder"
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

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ct-zsh-cli-XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

( cd "${REPO_ROOT}" && cargo build --quiet )

FIXTURE="${WORK_DIR}/fixture.zsh"
cat > "${FIXTURE}" <<'EOF'
#!/usr/bin/env zsh
echo "fixture-marker"
EOF
chmod +x "${FIXTURE}"

# Richer fixture — used by T7 (`ct-print --full` exact-value layer).
# Surfaces a positional-arg call so we can assert on a decoded
# (varname, value) pair (`$1 = "world"`) and a function-table entry.
# The shape mirrors the cairo / cardano / ... / js / python / ruby
# precedents: a small program with one user function called with
# literal arguments, asserted on the decoded ValueRecord.
FIXTURE_FULL="${WORK_DIR}/fixture_full.zsh"
cat > "${FIXTURE_FULL}" <<'EOF'
#!/usr/bin/env zsh
greet() {
    echo "hello $1"
}
greet "world"
EOF
chmod +x "${FIXTURE_FULL}"

# ---------------------------------------------------------------------------
# T1. --help: --format absent, --out-dir + --version + `ct print` present.
# ---------------------------------------------------------------------------

HELP_OUT="$(zsh "${LAUNCHER}" --help)"
grep -qF -- "--format" <<< "${HELP_OUT}" && fail "--help must NOT mention --format"
grep -qF -- "--out-dir" <<< "${HELP_OUT}" || fail "--help missing --out-dir"
grep -qF -- "--version" <<< "${HELP_OUT}" || fail "--help missing --version"
grep -qF -- "ct print" <<< "${HELP_OUT}" || fail "--help missing 'ct print'"
grep -qF -- "CODETRACER_ZSH_RECORDER_OUT_DIR" <<< "${HELP_OUT}" \
  || fail "--help missing CODETRACER_ZSH_RECORDER_OUT_DIR"
grep -qF -- "CODETRACER_ZSH_RECORDER_DISABLED" <<< "${HELP_OUT}" \
  || fail "--help missing CODETRACER_ZSH_RECORDER_DISABLED"
pass "--help: --format absent, --out-dir/--version/ct print present"

# ---------------------------------------------------------------------------
# T2. --version: canonical binary-name + version line.
# ---------------------------------------------------------------------------

VERSION_OUT="$(zsh "${LAUNCHER}" --version)"
grep -qE '^codetracer-zsh-recorder [0-9]+\.[0-9]+\.[0-9]+$' <<< "${VERSION_OUT}" \
  || fail "--version output not in 'codetracer-zsh-recorder X.Y.Z' form: ${VERSION_OUT}"
WRAPPER_VERSION_OUT="$(bash "${BIN}" --version)"
[[ "${WRAPPER_VERSION_OUT}" == "${VERSION_OUT}" ]] \
  || fail "wrapper --version mismatch: '${WRAPPER_VERSION_OUT}' vs '${VERSION_OUT}'"
pass "--version: canonical 'codetracer-zsh-recorder X.Y.Z' line"

# ---------------------------------------------------------------------------
# T3. --format json must be rejected with a non-zero exit.
# ---------------------------------------------------------------------------

if zsh "${LAUNCHER}" --format json -- "${FIXTURE}" >/dev/null 2>&1; then
  fail "launcher must reject --format json"
fi
if zsh "${LAUNCHER}" --format binary -- "${FIXTURE}" >/dev/null 2>&1; then
  fail "launcher must reject --format binary"
fi
pass "--format {json,binary}: rejected with non-zero exit"

# ---------------------------------------------------------------------------
# T4. CODETRACER_ZSH_RECORDER_OUT_DIR fallback.
# ---------------------------------------------------------------------------

OUT_DIR_T4="${WORK_DIR}/t4-env-out"
mkdir -p "${OUT_DIR_T4}"
RUN_OUT="$(CODETRACER_ZSH_RECORDER_OUT_DIR="${OUT_DIR_T4}" \
  zsh "${LAUNCHER}" "${FIXTURE}")"
grep -qF "fixture-marker" <<< "${RUN_OUT}" \
  || fail "_OUT_DIR fallback: target script's stdout missing"
[[ -f "${OUT_DIR_T4}/fixture.ct" ]] \
  || fail "_OUT_DIR fallback: ${OUT_DIR_T4}/fixture.ct not produced"
pass "CODETRACER_ZSH_RECORDER_OUT_DIR honoured when --out-dir omitted"

OUT_DIR_T4B="${WORK_DIR}/t4-cli-out"
mkdir -p "${OUT_DIR_T4B}"
CODETRACER_ZSH_RECORDER_OUT_DIR="${OUT_DIR_T4}" \
  zsh "${LAUNCHER}" --out-dir "${OUT_DIR_T4B}" "${FIXTURE}" >/dev/null
[[ -f "${OUT_DIR_T4B}/fixture.ct" ]] \
  || fail "--out-dir flag must override _OUT_DIR env var"
pass "--out-dir takes precedence over CODETRACER_ZSH_RECORDER_OUT_DIR"

# ---------------------------------------------------------------------------
# T5. CODETRACER_ZSH_RECORDER_DISABLED short-circuits without recording.
# ---------------------------------------------------------------------------

OUT_DIR_T5="${WORK_DIR}/t5-disabled-out"
RUN_OUT_T5="$(CODETRACER_ZSH_RECORDER_DISABLED=1 \
  zsh "${LAUNCHER}" --out-dir "${OUT_DIR_T5}" "${FIXTURE}")"
grep -qF "fixture-marker" <<< "${RUN_OUT_T5}" \
  || fail "_DISABLED=1: target script must still run"
[[ ! -e "${OUT_DIR_T5}" || -z "$(ls -A "${OUT_DIR_T5}" 2>/dev/null)" ]] \
  || fail "_DISABLED=1: must NOT produce trace artifacts in ${OUT_DIR_T5}"
pass "CODETRACER_ZSH_RECORDER_DISABLED=1 runs target without recording"

RUN_OUT_T5B="$(CODETRACER_ZSH_RECORDER_DISABLED=true \
  zsh "${LAUNCHER}" "${FIXTURE}")"
grep -qF "fixture-marker" <<< "${RUN_OUT_T5B}" \
  || fail "_DISABLED=true: target script must still run without --out-dir"
pass "CODETRACER_ZSH_RECORDER_DISABLED=true works without --out-dir"

# ---------------------------------------------------------------------------
# T6. ct-print --json round-trip on the recorded .ct bundle (Layer 1 —
# legacy substring presence).  Kept as a safety net even after the
# `--full` upgrade lands in T7, so a regression in the textual rendering
# is caught even if the `--full` JSON shape evolves.
# ---------------------------------------------------------------------------

# `ct-print` links zstd via an absolute Nix-store path, so it normally
# runs without LD_LIBRARY_PATH.  We still wire one up if the user has
# nix available, matching the conventional invocation documented for
# this test suite.
CT_PRINT_LD_LIBRARY_PATH="${CT_PRINT_LD_LIBRARY_PATH:-}"
if [[ -z "${CT_PRINT_LD_LIBRARY_PATH}" ]] && command -v nix >/dev/null 2>&1; then
  CT_PRINT_LD_LIBRARY_PATH="$(nix eval --raw nixpkgs#zstd.out 2>/dev/null)/lib" || \
    CT_PRINT_LD_LIBRARY_PATH=""
fi

run_ct_print() {
  if [[ -n "${CT_PRINT_LD_LIBRARY_PATH}" ]]; then
    LD_LIBRARY_PATH="${CT_PRINT_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}" \
      "${CT_PRINT}" "$@"
  else
    "${CT_PRINT}" "$@"
  fi
}

if [[ -x "${CT_PRINT}" ]]; then
  CT_JSON="$(run_ct_print --json "${OUT_DIR_T4}/fixture.ct")"
  grep -qF "\"program\": \"${FIXTURE}\"" <<< "${CT_JSON}" \
    || fail "ct-print --json: metadata.program missing ${FIXTURE}: ${CT_JSON}"
  grep -qF "\"${FIXTURE}\"" <<< "${CT_JSON}" \
    || fail "ct-print --json: paths/steps do not reference ${FIXTURE}: ${CT_JSON}"
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
# (String / Raw), python (String / None) and ruby precedents.
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
#     ValueRecord::Raw { r: "world" } (the zsh recorder uses the
#     textual `Raw` form for step-var snapshots and the typed
#     `String` form for call args — both are valid current
#     behaviour, captured exactly).
#   - **Exact return value** — `greet`'s call_exit return_value
#     decodes to ValueRecord::Int { i: 0 } (the zsh recorder uses
#     the function exit status as the typed return value).
#   - **Function / path / counts / call-sequence anchors** —
#     4 steps, 1 call, 1 io_event; the call sequence's only
#     entry is `greet`; path table contains `fixture_full.zsh`;
#     function table contains `<toplevel>` and `greet` (`ends_with`
#     checks for tolerance to future namespacing).  Note that the
#     zsh recorder does NOT stage a synthetic `source` wrapper the
#     way the bash recorder does — that's an intentional difference
#     between the two backends.
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  fail "T7 requires jq for JSON parsing — install jq to run this test"
fi

OUT_DIR_T7="${WORK_DIR}/t7-full-out"
mkdir -p "${OUT_DIR_T7}"
zsh "${LAUNCHER}" --out-dir "${OUT_DIR_T7}" "${FIXTURE_FULL}" >/dev/null

CT_FULL="$(run_ct_print --full --strip-paths "${OUT_DIR_T7}/fixture_full.ct")"

# Sanity: ct-print --full must produce parseable JSON.
echo "${CT_FULL}" | jq . >/dev/null 2>&1 \
  || fail "ct-print --full produced invalid JSON: ${CT_FULL}"

# ----- Function table: <toplevel> + greet ---------------------------
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
HAS_PATH="$(jq -r '[.paths[] | select(endswith("fixture_full.zsh"))] | length' <<< "${CT_FULL}")"
[[ "${HAS_PATH}" -ge 1 ]] \
  || fail "T7: missing fixture_full.zsh in paths: $(jq -c .paths <<< "${CT_FULL}")"
pass "T7 path table: fixture_full.zsh present"

# ----- Counts — stable for the canonical fixture --------------------
# The zsh recorder produces a deterministic event count for this
# fixture under DEBUG-trap instrumentation:
#   - 4 step events (absolute step on the source-load line, delta
#     step inside greet's body for the echo line, delta steps on
#     closing `}` / post-call positions)
#   - 1 user-visible call event (`greet`); the zsh recorder does
#     NOT stage a synthetic `source` wrapper the way bash does
#   - 1 io_event (the DEBUG-trap path emits a single ioStdout for
#     the `echo` source rendering — fewer than bash because zsh's
#     trap fires once rather than wrapping the builtin)
# If these change, that's a real regression to investigate, not
# a flake — pin the values strictly.
STEPS="$(jq -r .counts.steps <<< "${CT_FULL}")"
[[ "${STEPS}" == "4" ]] \
  || fail "T7: expected 4 steps, got ${STEPS}; counts=$(jq -c .counts <<< "${CT_FULL}")"
CALLS="$(jq -r .counts.calls <<< "${CT_FULL}")"
[[ "${CALLS}" == "1" ]] \
  || fail "T7: expected 1 call, got ${CALLS}; counts=$(jq -c .counts <<< "${CT_FULL}")"
IO_EVENTS="$(jq -r .counts.io_events <<< "${CT_FULL}")"
[[ "${IO_EVENTS}" == "1" ]] \
  || fail "T7: expected 1 io_event, got ${IO_EVENTS}; counts=$(jq -c .counts <<< "${CT_FULL}")"
pass "T7 counts: 4 steps / 1 call / 1 io_event"

# ----- Call sequence: exactly one user-visible call_entry -----------
# The fixture issues exactly one user call (`greet`).  We anchor the
# call by its args (the typed String "world" arg uniquely identifies
# it).  The zsh recorder DOES populate the `function` field on
# call_entry for this code path, so we can also assert on it.
TOTAL_ENTRIES="$(jq -r '[.events[] | select(.kind == "call_entry")] | length' <<< "${CT_FULL}")"
[[ "${TOTAL_ENTRIES}" == "1" ]] \
  || fail "T7: expected exactly 1 call_entry, got ${TOTAL_ENTRIES}: $(jq -c '[.events[] | select(.kind == "call_entry")]' <<< "${CT_FULL}")"
pass "T7 call sequence: ${TOTAL_ENTRIES} call_entry event"

# ----- Strict ValueRecord variant invariant -------------------------
# Every step var / call arg / return value must carry a `value.kind`
# field belonging to the expected, finite set of known ValueRecord
# variants.  Recurses through Sequence.elements and
# Struct.field_values too via jq's `..` operator.
ALLOWED_KINDS=(Int Float String Bool Raw None Void Sequence Struct Tuple)
is_allowed_kind() {
  local k="$1"
  for allowed in "${ALLOWED_KINDS[@]}"; do
    [[ "${k}" == "${allowed}" ]] && return 0
  done
  return 1
}

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
    || fail "T7: unknown ValueRecord kind=${k}; observed=${OBSERVED_KINDS[*]}; if a new variant has landed for the zsh recorder, extend this test to assert on it explicitly rather than weakening the check"
done
pass "T7 ValueRecord variant invariant: observed kinds ${OBSERVED_KINDS[*]} ⊂ {${ALLOWED_KINDS[*]}}"

# ----- Exact decoded call-arg values: greet($1="world") -------------
# The zsh recorder uses ValueRecord::String for typed positional-arg
# values (mirrors the bash recorder's call_entry path).
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
# The zsh recorder snapshots positional-arg locals via
# ValueRecord::Raw (textual rendering — distinct from the typed
# `String` form used for call_entry args).
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
# Zsh function exit status surfaces as ValueRecord::Int { i: 0 } via
# the recorder's RETURN-event handler.
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
echo "test_zsh_recorder_cli: ${PASS_COUNT} assertions passed"

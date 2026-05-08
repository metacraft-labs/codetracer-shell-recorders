#!/usr/bin/env bash
# End-to-end CLI convention tests for codetracer-zsh-recorder.
#
# Mirrors tests/test_bash_recorder_cli.sh — see that file for the rationale.
# We run the zsh launcher under `zsh` directly (since it relies on
# zsh-specific syntax for path resolution), but the test runner itself
# stays in bash for portability with the rest of the verifier suite.
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
# T6. ct-print round-trip on the recorded .ct bundle.
# ---------------------------------------------------------------------------

if [[ -x "${CT_PRINT}" ]]; then
  CT_JSON="$("${CT_PRINT}" --json "${OUT_DIR_T4}/fixture.ct")"
  grep -qF "\"program\": \"${FIXTURE}\"" <<< "${CT_JSON}" \
    || fail "ct-print --json: metadata.program missing ${FIXTURE}: ${CT_JSON}"
  grep -qF "\"${FIXTURE}\"" <<< "${CT_JSON}" \
    || fail "ct-print --json: paths/steps do not reference ${FIXTURE}: ${CT_JSON}"
  grep -qF '<toplevel>' <<< "${CT_JSON}" \
    || fail "ct-print --json: <toplevel> call missing: ${CT_JSON}"
  pass "ct print --json round-trips the recorded .ct bundle"
else
  pass "ct-print round-trip: skipped (binary at ${CT_PRINT} not available)"
fi

echo ""
echo "test_zsh_recorder_cli: ${PASS_COUNT} assertions passed"

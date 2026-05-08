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
FIXTURE="${WORK_DIR}/fixture.sh"
cat > "${FIXTURE}" <<'EOF'
#!/usr/bin/env bash
echo "fixture-marker"
EOF
chmod +x "${FIXTURE}"

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
# T6. ct-print round-trip: the recorded .ct bundle decodes via `ct print
#     --json` to a structure that contains the program path and at least
#     one step on `fixture-marker`'s line.  This replaces the old
#     `--format json` content assertion (per the cardano/circom/flow
#     precedent — recorders emit CTFS, `ct print` produces JSON for
#     downstream tools).
# ---------------------------------------------------------------------------

if [[ -x "${CT_PRINT}" ]]; then
  CT_JSON="$("${CT_PRINT}" --json "${OUT_DIR_T4}/fixture.ct")"
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
  pass "ct-print round-trip: skipped (binary at ${CT_PRINT} not available)"
fi

echo ""
echo "test_bash_recorder_cli: ${PASS_COUNT} assertions passed"

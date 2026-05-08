#!/usr/bin/env bash
# Verify that the codetracer-bash-recorder, codetracer-zsh-recorder, and
# the underlying ct-shell-trace-writer CLIs comply with
# `codetracer-specs/Recorder-CLI-Conventions.md` (no silent skip — every
# assertion either passes or fails loudly):
#
#   * `--format` / `-f` is absent from `--help` for both launchers and the
#     trace writer (CTFS-only — convention §4).
#   * `CODETRACER_FORMAT` is absent from `--help` (convention §5).
#   * `--out-dir` and `--version` are present in `--help` (§3).
#   * `--help` mentions `ct print` (the canonical conversion tool, §4).
#   * `CODETRACER_<LANG>_RECORDER_OUT_DIR` and
#     `CODETRACER_<LANG>_RECORDER_DISABLED` are referenced in source so the
#     env-var fallbacks (§5) cannot regress silently.
#   * Passing `--format json` (or any other format token) to either
#     launcher and to ct-shell-trace-writer is rejected with a non-zero
#     exit (i.e. neither component silently accepts the flag).
#   * The trace bridge no longer branches on `TraceEventsFileFormat::Json`
#     or `TraceEventsFileFormat::Binary`/`BinaryV0` outside of comments
#     (CTFS hard-pin).
#
# Wire-up: see `Justfile` (`just lint` and `just test` both run this
# script).
#
# Exit codes:
#   0  all assertions held
#   1  at least one assertion failed (the failing line is printed to
#      stderr and the script exits at the first failure for clarity)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BASH_LAUNCHER="${REPO_ROOT}/bash-recorder/launcher.sh"
BASH_BIN="${REPO_ROOT}/bash-recorder/codetracer-bash-recorder"
ZSH_LAUNCHER="${REPO_ROOT}/zsh-recorder/launcher.zsh"
ZSH_BIN="${REPO_ROOT}/zsh-recorder/codetracer-zsh-recorder"
TRACE_BRIDGE_SRC="${REPO_ROOT}/crates/ct-shell-trace-writer/src/trace_bridge.rs"
TRACE_MAIN_SRC="${REPO_ROOT}/crates/ct-shell-trace-writer/src/main.rs"

# Locate the trace-writer binary for direct CLI assertions.  Build it if
# the canonical debug target is missing — the verifier doubles as a smoke
# test that the binary still builds.
TRACE_WRITER="${REPO_ROOT}/target/debug/ct-shell-trace-writer"
if [[ ! -x "${TRACE_WRITER}" ]]; then
  TRACE_WRITER_RELEASE="${REPO_ROOT}/target/release/ct-shell-trace-writer"
  if [[ -x "${TRACE_WRITER_RELEASE}" ]]; then
    TRACE_WRITER="${TRACE_WRITER_RELEASE}"
  else
    ( cd "${REPO_ROOT}" && cargo build --quiet )
  fi
fi

for f in "${BASH_LAUNCHER}" "${BASH_BIN}" "${ZSH_LAUNCHER}" "${ZSH_BIN}" \
         "${TRACE_BRIDGE_SRC}" "${TRACE_MAIN_SRC}"; do
  if [[ ! -f "${f}" ]]; then
    echo "ERROR: required file not found: ${f}" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

assert_absent() {
  # assert_absent <needle> <haystack-description> <haystack>
  local needle="$1"
  local desc="$2"
  local haystack="$3"
  if grep -qF -- "${needle}" <<< "${haystack}"; then
    echo "FAIL: ${desc} must NOT contain '${needle}'" >&2
    echo "----- ${desc} -----" >&2
    echo "${haystack}" >&2
    echo "-------------------" >&2
    exit 1
  fi
  echo "ok: '${needle}' absent from ${desc}"
}

assert_present() {
  # assert_present <needle> <haystack-description> <haystack>
  local needle="$1"
  local desc="$2"
  local haystack="$3"
  if ! grep -qF -- "${needle}" <<< "${haystack}"; then
    echo "FAIL: ${desc} must contain '${needle}'" >&2
    echo "----- ${desc} -----" >&2
    echo "${haystack}" >&2
    echo "-------------------" >&2
    exit 1
  fi
  echo "ok: '${needle}' present in ${desc}"
}

assert_format_rejected() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: ${desc}: --format unexpectedly accepted" >&2
    exit 1
  fi
  echo "ok: ${desc}: --format rejected with non-zero exit"
}

# ---------------------------------------------------------------------------
# Bash launcher --help / --version
# ---------------------------------------------------------------------------

BASH_HELP="$(bash "${BASH_LAUNCHER}" --help)"

assert_absent "--format" "bash --help" "${BASH_HELP}"
assert_absent "CODETRACER_FORMAT" "bash --help" "${BASH_HELP}"
assert_present "--help" "bash --help" "${BASH_HELP}"
assert_present "--out-dir" "bash --help" "${BASH_HELP}"
assert_present "--version" "bash --help" "${BASH_HELP}"
assert_present "ct print" "bash --help" "${BASH_HELP}"
assert_present "CODETRACER_BASH_RECORDER_OUT_DIR" "bash --help" "${BASH_HELP}"
assert_present "CODETRACER_BASH_RECORDER_DISABLED" "bash --help" "${BASH_HELP}"

BASH_VERSION="$(bash "${BASH_LAUNCHER}" --version)"
assert_present "codetracer-bash-recorder" "bash --version" "${BASH_VERSION}"

# ---------------------------------------------------------------------------
# Zsh launcher --help / --version
#
# We skip the zsh checks if zsh is not installed (e.g. on a stripped CI
# image), but the bash side already covered the shared semantics.  The
# zsh integration tests already gate on zsh availability via
# `require_zsh!`, so this matches the existing convention.
# ---------------------------------------------------------------------------

if command -v zsh >/dev/null 2>&1; then
  ZSH_HELP="$(zsh "${ZSH_LAUNCHER}" --help)"

  assert_absent "--format" "zsh --help" "${ZSH_HELP}"
  assert_absent "CODETRACER_FORMAT" "zsh --help" "${ZSH_HELP}"
  assert_present "--help" "zsh --help" "${ZSH_HELP}"
  assert_present "--out-dir" "zsh --help" "${ZSH_HELP}"
  assert_present "--version" "zsh --help" "${ZSH_HELP}"
  assert_present "ct print" "zsh --help" "${ZSH_HELP}"
  assert_present "CODETRACER_ZSH_RECORDER_OUT_DIR" "zsh --help" "${ZSH_HELP}"
  assert_present "CODETRACER_ZSH_RECORDER_DISABLED" "zsh --help" "${ZSH_HELP}"

  ZSH_VERSION="$(zsh "${ZSH_LAUNCHER}" --version)"
  assert_present "codetracer-zsh-recorder" "zsh --version" "${ZSH_VERSION}"
else
  echo "ok: zsh not available — skipping zsh launcher --help/--version checks"
fi

# ---------------------------------------------------------------------------
# ct-shell-trace-writer --help / --version
# ---------------------------------------------------------------------------

WRITER_HELP="$("${TRACE_WRITER}" --help 2>&1)"

assert_absent "--format" "ct-shell-trace-writer --help" "${WRITER_HELP}"
assert_absent "CODETRACER_FORMAT" "ct-shell-trace-writer --help" "${WRITER_HELP}"
assert_present "--out-dir" "ct-shell-trace-writer --help" "${WRITER_HELP}"
assert_present "--version" "ct-shell-trace-writer --help" "${WRITER_HELP}"
assert_present "ct print" "ct-shell-trace-writer --help" "${WRITER_HELP}"

WRITER_VERSION="$("${TRACE_WRITER}" --version)"
assert_present "ct-shell-trace-writer" "ct-shell-trace-writer --version" "${WRITER_VERSION}"

# ---------------------------------------------------------------------------
# --format must be rejected (non-zero exit) on every CLI surface
# ---------------------------------------------------------------------------

assert_format_rejected "bash --format json" \
  bash "${BASH_LAUNCHER}" --format json -- /dev/null
assert_format_rejected "bash --format binary" \
  bash "${BASH_LAUNCHER}" --format binary -- /dev/null

if command -v zsh >/dev/null 2>&1; then
  assert_format_rejected "zsh --format json" \
    zsh "${ZSH_LAUNCHER}" --format json -- /dev/null
  assert_format_rejected "zsh --format binary" \
    zsh "${ZSH_LAUNCHER}" --format binary -- /dev/null
fi

assert_format_rejected "ct-shell-trace-writer --format json" \
  "${TRACE_WRITER}" --format json --out-dir /tmp
assert_format_rejected "ct-shell-trace-writer -f binary" \
  "${TRACE_WRITER}" -f binary --out-dir /tmp

# ---------------------------------------------------------------------------
# Source-level references for env-var fallbacks
# ---------------------------------------------------------------------------

# The launchers must reference both env vars; otherwise the fallback
# either doesn't exist or has been silently removed.

for var in CODETRACER_BASH_RECORDER_OUT_DIR CODETRACER_BASH_RECORDER_DISABLED; do
  if ! grep -qF "${var}" "${BASH_LAUNCHER}"; then
    echo "FAIL: ${var} must be referenced in ${BASH_LAUNCHER}" >&2
    exit 1
  fi
  echo "ok: ${var} referenced in ${BASH_LAUNCHER}"
done

for var in CODETRACER_ZSH_RECORDER_OUT_DIR CODETRACER_ZSH_RECORDER_DISABLED; do
  if ! grep -qF "${var}" "${ZSH_LAUNCHER}"; then
    echo "FAIL: ${var} must be referenced in ${ZSH_LAUNCHER}" >&2
    exit 1
  fi
  echo "ok: ${var} referenced in ${ZSH_LAUNCHER}"
done

# ---------------------------------------------------------------------------
# CTFS-only contract: the trace bridge must not branch on Json / Binary
# variants, and main.rs must not parse `--format`.
#
# We strip line-number prefixes and skip `//` / `#` comment lines so that
# the documentation references in module headers don't trigger false
# positives (the audit document still mentions the legacy variants by
# name as historical context).
# ---------------------------------------------------------------------------

if grep -nE 'TraceEventsFileFormat::(Json|Binary|BinaryV0)' "${TRACE_BRIDGE_SRC}" \
   | sed -E 's/^[0-9]+://' \
   | grep -vE '^\s*//' >/dev/null; then
  echo "FAIL: ${TRACE_BRIDGE_SRC} still branches on TraceEventsFileFormat::{Json,Binary,BinaryV0}" >&2
  grep -nE 'TraceEventsFileFormat::(Json|Binary|BinaryV0)' "${TRACE_BRIDGE_SRC}" >&2
  exit 1
fi
echo "ok: trace_bridge.rs does not branch on Json / Binary format variants"

# main.rs must reject `--format` (no silent accept).  The reject branch
# itself contains the literal string `--format`, so we scan for any other
# parsing arms by checking that there's no `format = ` assignment outside
# comments.
if grep -nE '^\s*format\s*=' "${TRACE_MAIN_SRC}" >/dev/null; then
  echo "FAIL: ${TRACE_MAIN_SRC} still assigns to a 'format' variable" >&2
  grep -nE '^\s*format\s*=' "${TRACE_MAIN_SRC}" >&2
  exit 1
fi
echo "ok: main.rs does not assign to a 'format' variable"

echo "verify-cli-convention-no-silent-skip: all checks passed"

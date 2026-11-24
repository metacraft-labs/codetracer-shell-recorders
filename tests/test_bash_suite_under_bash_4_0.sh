#!/usr/bin/env bash
# Run the Bash recorder's cargo suite (crates/ct-shell-trace-writer/tests/
# bash_recording_test.rs) under Bash 4.0.
#
# The Shell Recorder specification (`Recording-Backends/Shell-Recorder.md`,
# "Supported Shells") supports Bash 4.0 and newer. The recorder depends on
# trap behaviour that changed between 4.0 and 5.1 (the line numbers of an
# ERR action, BASH_COMMAND inside trap actions, pipelines and the DEBUG
# trap; see bash-recorder/recorder.sh), so the suite that checks recordings
# runs on the floor release too, not only on the dev shell's Bash 5.
#
# The release is named by CT_TEST_BASH_4_0, which the Linux dev shell
# exports (`oldBashEnv` in flake.nix). As in tests/test_bash_recorder_cli.sh
# (T8), it is selected through PATH: a directory holding only a `bash`
# symlink is put first, so the recorder, the launcher, the launcher's
# `bash recorder.sh` and the tests' own `bash` all resolve to it. The test
# binary is built first with the unchanged PATH, so that no build script
# runs under the old Bash, and then run directly with the new one.
#
# Positive controls: `bash` and `env bash` through that PATH report 4.0
# here, and the suite's `test_bash_suite_runs_on_the_expected_bash` checks,
# with CT_TEST_EXPECT_BASH_VERSION, that the recorder and the launcher
# really ran on it.
#
# Without CT_TEST_BASH_4_0 the run fails on Linux, where the dev shell
# provides it, rather than skipping silently; elsewhere it is skipped by
# name.
#
# Usage: bash tests/test_bash_suite_under_bash_4_0.sh [test-binary args...]
# (for example a test name filter, or `--test-threads=4`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

if [[ -z "${CT_TEST_BASH_4_0:-}" ]]; then
  if [[ "$(uname -s)" == Linux ]]; then
    fail "CT_TEST_BASH_4_0 is unset; run this test in the dev shell (nix develop), which exports it on Linux — it must not silently skip"
  fi
  echo "skipped: the Bash cargo suite under Bash 4.0 — CT_TEST_BASH_4_0 is unset (Linux dev shell only)"
  exit 0
fi
[[ -x "${CT_TEST_BASH_4_0}" ]] \
  || fail "CT_TEST_BASH_4_0=${CT_TEST_BASH_4_0} is not executable"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ct-bash40-suite-XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT
mkdir -p "${WORK_DIR}/bin"
ln -s "${CT_TEST_BASH_4_0}" "${WORK_DIR}/bin/bash"
BASH40_PATH="${WORK_DIR}/bin:${PATH}"

# shellcheck disable=SC2016 # expanded by the Bash under test, not here
seen="$(PATH="${BASH40_PATH}" bash -c 'echo "${BASH_VERSION}"')"
[[ "${seen}" == 4.0.* ]] \
  || fail "bash through ${WORK_DIR}/bin reports ${seen}, expected 4.0.*"
# shellcheck disable=SC2016 # expanded by the Bash under test, not here
seen_env="$(PATH="${BASH40_PATH}" env bash -c 'echo "${BASH_VERSION}"')"
[[ "${seen_env}" == 4.0.* ]] \
  || fail "'env bash' through ${WORK_DIR}/bin reports ${seen_env}, expected 4.0.*"
echo "ok: PATH selects Bash ${seen}"

# Build the test binary (and the writer it runs) with the unchanged PATH,
# and find it in cargo's build report.
cd "${REPO_ROOT}"
test_bin="$(cargo test -p ct-shell-trace-writer --test bash_recording_test \
  --no-run --message-format=json \
  | jq -r 'select(.reason == "compiler-artifact" and .profile.test
                  and .target.name == "bash_recording_test") | .executable')"
[[ -n "${test_bin}" && -x "${test_bin}" ]] \
  || fail "cargo did not report an executable for bash_recording_test (got '${test_bin}')"

PATH="${BASH40_PATH}" CT_TEST_EXPECT_BASH_VERSION=4.0. "${test_bin}" "$@"
echo "ok: the Bash cargo suite passed under Bash ${seen}"

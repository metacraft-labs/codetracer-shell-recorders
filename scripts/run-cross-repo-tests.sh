#!/usr/bin/env bash
# run-cross-repo-tests.sh -- Build ct-shell-trace-writer from this repo and
# run integration tests defined in the sibling codetracer repo.
#
# The script expects a workspace layout where both repos live side-by-side:
#
#   <workspace-root>/
#     codetracer/                        (the main codetracer repo)
#     codetracer-shell-recorders/        (this repo)
#
# Usage:
#   ./scripts/run-cross-repo-tests.sh [test-selector ...]
#
# Test selectors:
#   bash-flow     Run the Bash flow integration test
#   zsh-flow      Run the Zsh flow integration test
#   all           Run all tests (default)
#
# Environment variables:
#   METACRAFT_WORKSPACE_ROOT
#       Path to the metacraft workspace root containing both repos.
#       Falls back to auto-detection via ../codetracer if unset.
#
# Examples:
#   ./scripts/run-cross-repo-tests.sh              # runs all tests
#   ./scripts/run-cross-repo-tests.sh bash-flow     # runs only Bash flow test
#   ./scripts/run-cross-repo-tests.sh zsh-flow      # runs only Zsh flow test

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

_log() { printf "[cross-test] %s\n" "$*"; }
_warn() { printf "[cross-test] WARN: %s\n" "$*" >&2; }
_err() { printf "[cross-test] ERROR: %s\n" "$*" >&2; }
_die() {
	_err "$@"
	exit 1
}

# ---------------------------------------------------------------------------
# Workspace detection
# ---------------------------------------------------------------------------

detect_codetracer_repo() {
	local candidate=""

	if [[ -n ${METACRAFT_WORKSPACE_ROOT:-} ]]; then
		candidate="${METACRAFT_WORKSPACE_ROOT}/codetracer"
		if [[ -d ${candidate} ]]; then
			printf "[cross-test] Detected codetracer repo via METACRAFT_WORKSPACE_ROOT: %s\n" "${candidate}" >&2
			echo "${candidate}"
			return 0
		fi
		_warn "METACRAFT_WORKSPACE_ROOT is set (${METACRAFT_WORKSPACE_ROOT}) but ${candidate} does not exist"
	fi

	# Fallback: sibling directory relative to this repo
	candidate="$(cd "${REPO_ROOT}/.." && pwd)/codetracer"
	if [[ -d ${candidate} ]]; then
		printf "[cross-test] Detected codetracer repo as sibling directory: %s\n" "${candidate}" >&2
		echo "${candidate}"
		return 0
	fi

	return 1
}

# ---------------------------------------------------------------------------
# Log file management
# ---------------------------------------------------------------------------

readonly LOG_DIR="${REPO_ROOT}/target/cross-test-logs"

ensure_log_dir() {
	mkdir -p "${LOG_DIR}"
}

log_path_for() {
	local test_name="$1"
	local timestamp
	timestamp="$(date +%Y%m%d-%H%M%S)"
	echo "${LOG_DIR}/${test_name}-${timestamp}.log"
}

print_log_on_failure() {
	local log_file="$1"
	if [[ -f ${log_file} ]]; then
		local file_size
		file_size="$(du -h "${log_file}" | cut -f1)"
		_err "Full log (${file_size}): ${log_file}"
		# Print last 50 lines for quick diagnosis
		_err "--- Last 50 lines ---"
		tail -50 "${log_file}" >&2
		_err "--- End of log snippet ---"
	fi
}

count_passed_tests_in_log() {
	local log_file="$1"
	awk '
		/test result:/ {
			for (i = 1; i <= NF; i++) {
				if ($i == "passed;") {
					n = $(i - 1)
					gsub(/[^0-9]/, "", n)
					if (n != "") {
						sum += n + 0
					}
				}
			}
		}
		END { print sum + 0 }
	' "${log_file}"
}

ensure_log_has_executed_tests() {
	local log_file="$1"
	local display_name="$2"
	local passed_count
	passed_count="$(count_passed_tests_in_log "${log_file}")"
	if [[ ${passed_count} -eq 0 ]]; then
		_err "${display_name} matched no tests; refusing to treat as success."
		print_log_on_failure "${log_file}"
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Build ct-shell-trace-writer
# ---------------------------------------------------------------------------

build_trace_writer() {
	_log "Building ct-shell-trace-writer from ${REPO_ROOT} ..."
	(cd "${REPO_ROOT}" && cargo build) || _die "cargo build failed in ${REPO_ROOT}"
	_log "ct-shell-trace-writer built successfully"
}

# ---------------------------------------------------------------------------
# Test runners
# ---------------------------------------------------------------------------

run_cargo_test() {
	local test_name="$1"
	local display_name="$2"
	local log_file="$3"

	_log "Running ${display_name} ..."
	_log "  cargo test --test ${test_name} -- --nocapture"
	_log "  cwd: ${DB_BACKEND_DIR}"
	_log "  log: ${log_file}"

	local exit_code=0
	(
		cd "${DB_BACKEND_DIR}"

		# The db-backend build needs capnproto, tree-sitter grammars, etc.
		# If capnp is on PATH (e.g. inside the codetracer nix shell), use it
		# directly. Otherwise, try wrapping with nix develop on the codetracer
		# flake.
		if command -v capnp >/dev/null 2>&1; then
			cargo test --test "${test_name}" -- --nocapture
		else
			nix develop "${CODETRACER_REPO}" --command \
				cargo test --test "${test_name}" -- --nocapture
		fi
	) >"${log_file}" 2>&1 || exit_code=$?

	if [[ ${exit_code} -ne 0 ]]; then
		_err "${display_name} FAILED (exit code ${exit_code})"
		print_log_on_failure "${log_file}"
		return "${exit_code}"
	fi

	if ! ensure_log_has_executed_tests "${log_file}" "${display_name}"; then
		return 1
	fi

	_log "${display_name} PASSED"
	return 0
}

run_bash_flow() {
	local log_file
	log_file="$(log_path_for bash-flow)"
	run_cargo_test "bash_flow_integration" "Bash flow integration test" "${log_file}"
}

run_zsh_flow() {
	local log_file
	log_file="$(log_path_for zsh-flow)"
	run_cargo_test "zsh_flow_integration" "Zsh flow integration test" "${log_file}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
	SELECTORS=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h)
			head -30 "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
			exit 0
			;;
		-*)
			_die "Unknown option: '$1'. Use --help for usage."
			;;
		*)
			SELECTORS+=("$1")
			shift
			;;
		esac
	done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	parse_args "$@"

	if [[ ${#SELECTORS[@]} -eq 0 ]]; then
		SELECTORS=("all")
	fi

	# Environment check
	if ! command -v cargo >/dev/null 2>&1; then
		_die "cargo is required but not found. Are you in the Nix dev shell?"
	fi
	if ! command -v zsh >/dev/null 2>&1; then
		_warn "zsh not found; zsh-flow tests will fail"
	fi

	# Detect workspace
	CODETRACER_REPO="$(detect_codetracer_repo)" ||
		_die "Cannot locate the codetracer repo. Set METACRAFT_WORKSPACE_ROOT or ensure ../codetracer exists."

	DB_BACKEND_DIR="${CODETRACER_REPO}/src/db-backend"
	if [[ ! -f "${DB_BACKEND_DIR}/Cargo.toml" ]]; then
		_die "Expected Cargo.toml at ${DB_BACKEND_DIR}/Cargo.toml -- is the codetracer repo intact?"
	fi

	ensure_log_dir

	# Build the trace writer first (the flow tests need it)
	build_trace_writer

	# Resolve selectors
	local run_bash=false
	local run_zsh=false

	for sel in "${SELECTORS[@]}"; do
		case "${sel}" in
		bash-flow) run_bash=true ;;
		zsh-flow) run_zsh=true ;;
		all)
			run_bash=true
			run_zsh=true
			;;
		*) _die "Unknown test selector: '${sel}'. Valid: bash-flow, zsh-flow, all" ;;
		esac
	done

	local failures=0

	if ${run_bash}; then
		run_bash_flow || ((failures++)) || true
	fi

	if ${run_zsh}; then
		run_zsh_flow || ((failures++)) || true
	fi

	echo ""
	if [[ ${failures} -gt 0 ]]; then
		_err "${failures} test suite(s) failed."
		exit 1
	fi

	_log "All cross-repo tests passed."
}

main "$@"

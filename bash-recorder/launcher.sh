#!/usr/bin/env bash
# codetracer-bash-recorder launcher: sets up the pipe between recorder.sh and
# the ct-shell-trace-writer trace writer.
#
# CTFS-only.  CodeTracer recorders always emit the canonical CTFS `.ct`
# container; there is no output-format choice to make.  Use
# `ct print` from `codetracer-trace-format-nim` to convert the recorded
# `.ct` bundle to JSON for debugging or golden-snapshot fixtures — the
# recorder itself never produces JSON.
#
# Usage:
#   codetracer-bash-recorder [--out-dir <dir>] [--] <script.sh> [script-args...]
#   codetracer-bash-recorder --help
#   codetracer-bash-recorder --version
#
# Environment variables:
#   CODETRACER_BASH_RECORDER_OUT_DIR
#       Output directory for the trace bundle (overridden by --out-dir).
#   CODETRACER_BASH_RECORDER_DISABLED
#       When set to `1` or `true`, run the target script directly without
#       recording — useful for short-circuiting the recorder in CI when
#       the binary is on PATH but tracing is undesired.

# ---------------------------------------------------------------------------
# Bash version floor.
#
# The Shell Recorder specification (`Recording-Backends/Shell-Recorder.md`,
# "Supported Shells") supports Bash 4.0 and newer; the recorder needs
# associative arrays and `shopt -s extdebug`. On an older Bash the launcher
# would otherwise fail somewhere in the middle (Bash 3.2 rejects
# `declare -A` in recorder.sh), so refuse it here, by name, before anything
# else runs. This block must stay parseable by Bash 3.x: no 4.x-only syntax
# above or in it.
#
# The message names `$BASH`, the interpreter running this script, rather
# than the `bash` on PATH: the two differ when the launcher is started as
# `/some/bash launcher.sh`. Through the `codetracer-bash-recorder` entry
# point (and this script's own `#!/usr/bin/env bash`) both are the `bash`
# found on PATH, which is also what runs `bash recorder.sh` below. Started
# any other way, the recording itself still runs under the `bash` on PATH.
# ---------------------------------------------------------------------------
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "Error: codetracer-bash-recorder requires Bash 4.0 or newer; found Bash ${BASH_VERSION:-unknown} (${BASH:-unknown path})" >&2
    exit 1
fi

set -euo pipefail

# A note on `set -u` and arrays, for every expansion of `_ct_script_args`
# below. Before Bash 4.4, expanding an array with no elements under
# `nounset` is an "unbound variable" error, and Bash 4.0 also treats `"$@"`
# with no positional parameters as unbound. Bash's CHANGES file, under
# bash-4.4-rc2, "New Features in Bash": "Using ${a[@]} or ${a[*]} with an
# array without any assigned elements when the nounset option is enabled
# no longer throws an unbound variable error."
# https://git.savannah.gnu.org/cgit/bash.git/tree/CHANGES
# So `"$@"` is only read when `$# > 0`, and the array is always expanded as
# `${_ct_script_args[@]+"${_ct_script_args[@]}"}`, which yields nothing for
# an empty array and the quoted elements otherwise. A script recorded with
# no arguments must work on every supported Bash (4.0+).

_ct_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ct_repo_root="$(cd "$_ct_script_dir/.." && pwd)"

# ---------------------------------------------------------------------------
# Version + help
#
# Single source of truth for the version is the top-level `VERSION` file so
# launcher, Cargo.toml, and the verifier all agree.  We fall back to
# `unknown` if VERSION is missing (defensive — should not happen in a
# correctly-built tree).
# ---------------------------------------------------------------------------

_ct_binary_name="codetracer-bash-recorder"

_ct_read_version() {
    local _ct_version_file="$_ct_repo_root/VERSION"
    if [[ -r "$_ct_version_file" ]]; then
        # Trim trailing whitespace/newlines so `--version` produces a single line.
        tr -d '\n\r' < "$_ct_version_file"
    else
        printf "unknown"
    fi
}

_ct_print_version() {
    printf "%s %s\n" "$_ct_binary_name" "$(_ct_read_version)"
}

_ct_print_help() {
    cat <<HELP
$_ct_binary_name $(_ct_read_version) — CodeTracer Bash Recorder

Record execution traces of Bash scripts in the canonical CTFS format.

Usage:
  $_ct_binary_name [OPTIONS] [--] <script.sh> [SCRIPT_ARGS...]

Arguments:
  <script.sh>     Path to the Bash script to record.
  [SCRIPT_ARGS]   Arguments forwarded to the recorded script.

Options:
  -o, --out-dir <PATH>    Directory where the CTFS trace bundle is written.
                          Falls back to \$CODETRACER_BASH_RECORDER_OUT_DIR when
                          omitted; one of the two must be provided.
  -h, --help              Print this help text and exit.
  -V, --version           Print the recorder version and exit.

Output:
  The recorder always writes a CTFS \`.ct\` bundle.
  To inspect or convert the trace to JSON for debugging, run
  \`ct print [--json|--summary|--follow] <out-dir>/<script>.ct\` from
  codetracer-trace-format-nim.  No output-format flag is exposed: the
  recorder is hard-pinned to CTFS so the toolchain has a single canonical
  on-disk representation.

Environment variables:
  CODETRACER_BASH_RECORDER_OUT_DIR    Default value for --out-dir.
  CODETRACER_BASH_RECORDER_DISABLED   When set to \`1\` or \`true\`, run the
                                      target script directly without recording.
HELP
}

# ---------------------------------------------------------------------------
# Argument parsing
#
# `--help` and `--version` short-circuit before we require --out-dir or a
# target script so the user can introspect the CLI without supplying a
# script (matches the pattern in every other CodeTracer recorder).
# ---------------------------------------------------------------------------

_ct_output_dir="${CODETRACER_BASH_RECORDER_OUT_DIR:-}"
_ct_script=""
_ct_script_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help | -h)
            _ct_print_help
            exit 0
            ;;
        --version | -V)
            _ct_print_version
            exit 0
            ;;
        --out-dir | -o)
            if [[ $# -lt 2 ]]; then
                echo "Error: ${1} requires a value" >&2
                exit 2
            fi
            _ct_output_dir="$2"
            shift 2
            ;;
        --)
            shift
            if [[ $# -lt 1 ]]; then
                echo "Error: no script specified after --" >&2
                exit 2
            fi
            _ct_script="$1"
            shift
            # `"$@"` is unbound on Bash 4.0 when empty; see the note above.
            if [[ $# -gt 0 ]]; then
                _ct_script_args=("$@")
            fi
            break
            ;;
        -*)
            echo "Error: unknown option: $1" >&2
            echo "Run '$_ct_binary_name --help' for usage." >&2
            exit 2
            ;;
        *)
            _ct_script="$1"
            shift
            # `"$@"` is unbound on Bash 4.0 when empty; see the note above.
            if [[ $# -gt 0 ]]; then
                _ct_script_args=("$@")
            fi
            break
            ;;
    esac
done

if [[ -z "$_ct_script" ]]; then
    echo "Error: no script specified" >&2
    echo "Run '$_ct_binary_name --help' for usage." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# CODETRACER_BASH_RECORDER_DISABLED short-circuit.
#
# When the user wants the binary on PATH but does not want recording for a
# given invocation (e.g. inside a CI step that exercises the program for
# functional reasons), we exec the target script directly.  This must
# happen *after* CLI parsing so `--help`/`--version` still work, and
# *before* we require --out-dir or touch the trace writer / FIFO so we
# don't reject the call for missing trace plumbing the user explicitly
# disabled.
# ---------------------------------------------------------------------------

_ct_disabled="${CODETRACER_BASH_RECORDER_DISABLED:-}"
case "$_ct_disabled" in
    1 | true | TRUE | yes | YES)
        exec bash "$_ct_script" ${_ct_script_args[@]+"${_ct_script_args[@]}"}
        ;;
esac

if [[ -z "$_ct_output_dir" ]]; then
    echo "Error: --out-dir is required (or set CODETRACER_BASH_RECORDER_OUT_DIR)" >&2
    exit 2
fi

# Resolve the script to an absolute path
_ct_script="$(cd "$(dirname "$_ct_script")" && pwd)/$(basename "$_ct_script")"

# Create output directory
mkdir -p "$_ct_output_dir"

# Find the trace-writer binary
# Look for it in: PATH, Cargo's configured target dir, then the workspace target dirs.
_ct_trace_writer=""
_ct_cargo_target_dir="${CARGO_TARGET_DIR:-}"
case "$_ct_cargo_target_dir" in
    "" | /* | [A-Za-z]:*) ;;
    *) _ct_cargo_target_dir="$_ct_script_dir/../$_ct_cargo_target_dir" ;;
esac

if command -v ct-shell-trace-writer >/dev/null 2>&1; then
    _ct_trace_writer="ct-shell-trace-writer"
elif [[ -n "$_ct_cargo_target_dir" && -x "$_ct_cargo_target_dir/release/ct-shell-trace-writer" ]]; then
    _ct_trace_writer="$_ct_cargo_target_dir/release/ct-shell-trace-writer"
elif [[ -n "$_ct_cargo_target_dir" && -x "$_ct_cargo_target_dir/debug/ct-shell-trace-writer" ]]; then
    _ct_trace_writer="$_ct_cargo_target_dir/debug/ct-shell-trace-writer"
elif [[ -x "$_ct_script_dir/../target/release/ct-shell-trace-writer" ]]; then
    _ct_trace_writer="$_ct_script_dir/../target/release/ct-shell-trace-writer"
elif [[ -x "$_ct_script_dir/../target/debug/ct-shell-trace-writer" ]]; then
    _ct_trace_writer="$_ct_script_dir/../target/debug/ct-shell-trace-writer"
else
    echo "Error: ct-shell-trace-writer not found in PATH, CARGO_TARGET_DIR, or target directories" >&2
    exit 1
fi

# Stage the FD 3 event stream through a temp file rather than a FIFO.
#
# A Unix FIFO would let `recorder.sh` and the trace writer run concurrently,
# but `ct-shell-trace-writer` is a *native* binary: on Windows the recorder
# runs under a Cygwin/MSYS bash whose `mkfifo` produces a Cygwin-emulated
# pipe that a non-Cygwin executable cannot read — it opens the FIFO path,
# sees an immediate EOF, and exits before any event arrives ("EOF reached
# without EXIT event"), which in turn delivers SIGPIPE (exit 141) to the
# recorder. Routing the events through a plain file is byte-identical from
# the writer's point of view (it consumes the whole stream from stdin) and
# works uniformly on every platform. The recorder still finishes long
# before the script of interest is large enough for streaming to matter.
_ct_events_file=$(mktemp "${TMPDIR:-/tmp}/ct-events-XXXXXX")

# Clean up on exit
trap 'rm -f "$_ct_events_file"' EXIT

# Run the recorder with FD 3 connected to the event file.
#
# The recorder exits with the recorded script's status, and that status is
# saved here to be returned by the launcher's last line, after the trace is
# written: spec `Recorder-CLI-Conventions.md` §6 "Exit Codes" makes the
# recorder's exit code a pass-through of the target's, and the trace must be
# written however the script ends (`Recording-Backends/Shell-Recorder.md`,
# "Invocation Flow" steps 10 and 11). The status is captured with `||`
# rather than read from `$?` on the next line, because this launcher runs
# under `set -euo pipefail`: a non-zero status from a plain command would end the
# launcher right here, before the trace writer runs, and the `EXIT` trap
# would delete the event file. A command on the left of `||` is exempt
# from `errexit`.
_ct_exit_code=0
bash "$_ct_script_dir/recorder.sh" "$_ct_script" ${_ct_script_args[@]+"${_ct_script_args[@]}"} 3>"$_ct_events_file" || _ct_exit_code=$?

# Feed the recorded event stream to the trace writer, passing the program
# name and its positional argv for metadata + top-level call-arg staging.
#
# `--args` MUST be the last flag because the trace writer treats every
# remaining token after `--args` as a positional argv element.
#
# The CTFS format is hard-pinned in the writer, which rejects `--format`;
# no such flag is forwarded here.
if (( ${#_ct_script_args[@]} > 0 )); then
    "$_ct_trace_writer" \
        --out-dir "$_ct_output_dir" \
        --program "$_ct_script" \
        --args ${_ct_script_args[@]+"${_ct_script_args[@]}"} \
        < "$_ct_events_file"
else
    "$_ct_trace_writer" \
        --out-dir "$_ct_output_dir" \
        --program "$_ct_script" \
        < "$_ct_events_file"
fi

# ============================================================================
# Post-recording steps: enrich the trace folder for self-containment
# ============================================================================
#
# Source files are copied into the trace folder's `files/` directory by the
# trace writer itself (see `crates/ct-shell-trace-writer/src/trace_bridge.rs`,
# `copy_source_files`).  The writer already holds the interned source paths
# from the CTFS container, so the launcher no longer reads any paths sidecar
# or copies source files.

# Write enhanced metadata with language-specific fields
_ct_write_enhanced_metadata() {
    local _ct_args_json="["
    local _ct_first=true
    for _ct_arg in ${_ct_script_args[@]+"${_ct_script_args[@]}"}; do
        if [[ "$_ct_first" == true ]]; then
            _ct_first=false
        else
            _ct_args_json+=","
        fi
        # Simple JSON string escaping
        _ct_arg="${_ct_arg//\\/\\\\}"
        _ct_arg="${_ct_arg//\"/\\\"}"
        _ct_args_json+="\"$_ct_arg\""
    done
    _ct_args_json+="]"

    # The version is the FIRST x.y.z on the `bash --version` banner. The
    # banner also names the host triple, which on macOS carries a version of
    # its own ("(aarch64-apple-darwin24.6.0)"); `grep -o` prints every match
    # on its own line, so without `head -n 1` that second number landed in
    # the JSON string as a raw newline and made the file unparseable. A
    # banner with no version leaves the field empty instead of aborting the
    # launcher under `set -e -o pipefail`.
    local _ct_bash_version
    _ct_bash_version=$(bash --version | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1) || true

    cat > "$_ct_output_dir/trace_db_metadata.json" <<METADATA
{
  "language": "bash",
  "program": "$_ct_script",
  "args": $_ct_args_json,
  "workdir": "$(pwd)",
  "recorder": "codetracer-bash-recorder",
  "bash_version": "$_ct_bash_version"
}
METADATA
}

_ct_write_enhanced_metadata

# The trace writer binary now writes symbols.json directly as a sidecar file
# alongside the .ct container. Only write an empty fallback if the trace writer
# did not produce one (e.g. if it crashed before finishing).
if [[ ! -f "$_ct_output_dir/symbols.json" ]]; then
    echo "[]" > "$_ct_output_dir/symbols.json"
fi

exit "$_ct_exit_code"

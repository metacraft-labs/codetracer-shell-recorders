#!/bin/bash
# ct-bash-recorder launcher: Sets up the pipe between recorder.sh and ct-shell-trace-writer.
#
# Usage: launcher.sh --output-dir <dir> [--format binary|json] <script.sh> [script-args...]

set -euo pipefail

_ct_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ct_output_dir=""
_ct_format="binary"
_ct_script=""
_ct_script_args=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            _ct_output_dir="$2"
            shift 2
            ;;
        --format)
            _ct_format="$2"
            shift 2
            ;;
        --)
            shift
            _ct_script="$1"
            shift
            _ct_script_args=("$@")
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            _ct_script="$1"
            shift
            _ct_script_args=("$@")
            break
            ;;
    esac
done

if [[ -z "$_ct_output_dir" ]]; then
    echo "Error: --output-dir is required" >&2
    exit 1
fi

if [[ -z "$_ct_script" ]]; then
    echo "Error: no script specified" >&2
    exit 1
fi

# Resolve the script to an absolute path
_ct_script="$(cd "$(dirname "$_ct_script")" && pwd)/$(basename "$_ct_script")"

# Create output directory
mkdir -p "$_ct_output_dir"

# Find the trace-writer binary
# Look for it in: PATH, same dir as launcher, workspace target/release, workspace target/debug
_ct_trace_writer=""
if command -v ct-shell-trace-writer >/dev/null 2>&1; then
    _ct_trace_writer="ct-shell-trace-writer"
elif [[ -x "$_ct_script_dir/../target/release/ct-shell-trace-writer" ]]; then
    _ct_trace_writer="$_ct_script_dir/../target/release/ct-shell-trace-writer"
elif [[ -x "$_ct_script_dir/../target/debug/ct-shell-trace-writer" ]]; then
    _ct_trace_writer="$_ct_script_dir/../target/debug/ct-shell-trace-writer"
else
    echo "Error: ct-shell-trace-writer not found in PATH or target directories" >&2
    exit 1
fi

# Set up a FIFO for the FD 3 pipe
_ct_fifo=$(mktemp -u "${TMPDIR:-/tmp}/ct-fifo-XXXXXX")
mkfifo "$_ct_fifo"

# Clean up on exit
trap 'rm -f "$_ct_fifo"' EXIT

# Start the trace writer reading from the FIFO, passing the program name for metadata
"$_ct_trace_writer" --output-dir "$_ct_output_dir" --format "$_ct_format" --program "$_ct_script" < "$_ct_fifo" &
_ct_writer_pid=$!

# Run the recorder with FD 3 connected to the FIFO
bash "$_ct_script_dir/recorder.sh" "$_ct_script" "${_ct_script_args[@]}" 3>"$_ct_fifo"
_ct_exit_code=$?

# Wait for the trace writer to finish processing
wait "$_ct_writer_pid" 2>/dev/null || true

exit "$_ct_exit_code"

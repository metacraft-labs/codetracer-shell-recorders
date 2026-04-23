#!/bin/zsh
# ct-zsh-recorder launcher: Sets up the pipe between recorder.zsh and ct-shell-trace-writer.
#
# Usage: launcher.zsh --out-dir <dir> [--format binary|json] <script.zsh> [script-args...]

set -eo pipefail

_ct_script_dir="${0:A:h}"
_ct_output_dir=""
_ct_format="ctfs"
_ct_script=""
_ct_script_args=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out-dir)
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
    echo "Error: --out-dir is required" >&2
    exit 1
fi

if [[ -z "$_ct_script" ]]; then
    echo "Error: no script specified" >&2
    exit 1
fi

# Resolve the script to an absolute path
_ct_script="${_ct_script:A}"

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
"$_ct_trace_writer" --out-dir "$_ct_output_dir" --format "$_ct_format" --program "$_ct_script" < "$_ct_fifo" &
_ct_writer_pid=$!

# Run the recorder with FD 3 connected to the FIFO
zsh "$_ct_script_dir/recorder.zsh" "$_ct_script" "${_ct_script_args[@]}" 3>"$_ct_fifo"
_ct_exit_code=$?

# Wait for the trace writer to finish processing
wait "$_ct_writer_pid" 2>/dev/null || true

# ============================================================================
# Post-recording steps: enrich the trace folder for self-containment
# ============================================================================

# Copy source files into the trace folder for self-containment
_ct_copy_source_files() {
    local _ct_paths_file="$_ct_output_dir/trace_paths.json"
    [[ -f "$_ct_paths_file" ]] || return 0

    # Parse the JSON array of paths using python3 (available on most systems)
    # Fallback: use simple grep if python3 not available
    local _ct_paths
    if command -v python3 >/dev/null 2>&1; then
        _ct_paths=$(python3 -c "
import json, sys
paths = json.load(open('$_ct_paths_file'))
for p in paths:
    # Convert Path objects to strings
    s = str(p) if isinstance(p, str) else p
    # Handle paths that might be serialized as objects
    if isinstance(p, dict):
        continue
    print(s)
" 2>/dev/null) || _ct_paths=""
    else
        _ct_paths=$(grep -oP '"[^"]*"' "$_ct_paths_file" | tr -d '"')
    fi

    local _ct_files_dir="$_ct_output_dir/files"

    local _ct_src
    while IFS= read -r _ct_src; do
        [[ -z "$_ct_src" ]] && continue
        [[ -f "$_ct_src" ]] || continue

        # Create the directory structure under files/
        local _ct_dest="$_ct_files_dir$_ct_src"
        mkdir -p "${_ct_dest:h}"
        cp "$_ct_src" "$_ct_dest" 2>/dev/null || true
    done <<< "$_ct_paths"
}

_ct_copy_source_files

# Write enhanced metadata with language-specific fields
_ct_write_enhanced_metadata() {
    local _ct_args_json="["
    local _ct_first=true
    for _ct_arg in "${_ct_script_args[@]}"; do
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

    local _ct_zsh_version
    _ct_zsh_version=$(zsh --version | head -1 | grep -oP '\d+\.\d+(\.\d+)?' || echo "$ZSH_VERSION")

    cat > "$_ct_output_dir/trace_db_metadata.json" <<METADATA
{
  "language": "zsh",
  "program": "$_ct_script",
  "args": $_ct_args_json,
  "workdir": "$(pwd)",
  "recorder": "codetracer-zsh-recorder",
  "zsh_version": "$_ct_zsh_version"
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

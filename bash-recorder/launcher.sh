#!/bin/bash
# ct-bash-recorder launcher: Sets up the pipe between recorder.sh and ct-shell-trace-writer.
#
# Usage: launcher.sh --out-dir <dir> [--format binary|json] <script.sh> [script-args...]

set -euo pipefail

_ct_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ct_output_dir=""
_ct_format="binary"
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
"$_ct_trace_writer" --out-dir "$_ct_output_dir" --format "$_ct_format" --program "$_ct_script" < "$_ct_fifo" &
_ct_writer_pid=$!

# Run the recorder with FD 3 connected to the FIFO
bash "$_ct_script_dir/recorder.sh" "$_ct_script" "${_ct_script_args[@]}" 3>"$_ct_fifo"
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

    while IFS= read -r _ct_src; do
        [[ -z "$_ct_src" ]] && continue
        [[ -f "$_ct_src" ]] || continue

        # Create the directory structure under files/
        local _ct_dest="$_ct_files_dir$_ct_src"
        mkdir -p "$(dirname "$_ct_dest")"
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

    cat > "$_ct_output_dir/trace_db_metadata.json" <<METADATA
{
  "language": "bash",
  "program": "$_ct_script",
  "args": $_ct_args_json,
  "workdir": "$(pwd)",
  "recorder": "codetracer-bash-recorder",
  "bash_version": "$(bash --version | head -1 | grep -oP '\d+\.\d+\.\d+')"
}
METADATA
}

_ct_write_enhanced_metadata

# Generate symbols.json from trace data
# Functions are already in the trace events, but we also write them separately
# for quick symbol search in the UI
_ct_write_symbols() {
    local _ct_trace_file
    if [[ "$_ct_format" == "json" ]]; then
        _ct_trace_file="$_ct_output_dir/trace.json"
    else
        _ct_trace_file="$_ct_output_dir/trace.bin"
    fi

    # For JSON format, extract function names from Function events.
    # We try python3 first for robust JSON parsing, then fall back to grep+sed
    # for environments where python3 is not available (e.g. Nix dev shells).
    if [[ "$_ct_format" == "json" ]] && [[ -f "$_ct_trace_file" ]]; then
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "
import json
data = json.load(open('$_ct_trace_file'))
funcs = []
seen = set()
for event in data:
    if isinstance(event, dict) and 'Function' in event:
        name = event['Function'].get('name', '')
        if name and name != '<toplevel>' and name not in seen:
            funcs.append(name)
            seen.add(name)
print(json.dumps(funcs))
" > "$_ct_output_dir/symbols.json" 2>/dev/null || echo "[]" > "$_ct_output_dir/symbols.json"
        else
            # Fallback: extract function names using grep and sed.
            # Matches {"Function":{"path_id":N,"line":N,"name":"NAME"}} patterns
            # and filters out the synthetic <toplevel> entry.
            local _ct_names
            _ct_names=$(grep -oP '"Function":\{[^}]*"name":"[^"]*"' "$_ct_trace_file" 2>/dev/null \
                | sed 's/.*"name":"\([^"]*\)"/\1/' \
                | grep -v '^<toplevel>$' \
                | awk '!seen[$0]++') || true

            if [[ -n "$_ct_names" ]]; then
                # Build a JSON array from the newline-separated names
                local _ct_json="["
                local _ct_first=true
                while IFS= read -r _ct_fname; do
                    [[ -z "$_ct_fname" ]] && continue
                    if [[ "$_ct_first" == true ]]; then
                        _ct_first=false
                    else
                        _ct_json+=","
                    fi
                    # Escape backslashes and quotes for JSON
                    _ct_fname="${_ct_fname//\\/\\\\}"
                    _ct_fname="${_ct_fname//\"/\\\"}"
                    _ct_json+="\"$_ct_fname\""
                done <<< "$_ct_names"
                _ct_json+="]"
                echo "$_ct_json" > "$_ct_output_dir/symbols.json"
            else
                echo "[]" > "$_ct_output_dir/symbols.json"
            fi
        fi
    else
        echo "[]" > "$_ct_output_dir/symbols.json"
    fi
}

_ct_write_symbols

exit "$_ct_exit_code"

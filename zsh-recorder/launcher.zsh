#!/usr/bin/env zsh
# codetracer-zsh-recorder launcher: sets up the pipe between recorder.zsh and
# the ct-shell-trace-writer trace writer.
#
# CTFS-only.  CodeTracer recorders always emit the canonical CTFS `.ct`
# container (see `codetracer-specs/Recorder-CLI-Conventions.md` §4).  Use
# `ct print` from `codetracer-trace-format-nim` to convert the recorded
# `.ct` bundle to JSON for debugging or golden-snapshot fixtures — the
# recorder itself never produces JSON.
#
# Usage:
#   codetracer-zsh-recorder [--out-dir <dir>] [--] <script.zsh> [script-args...]
#   codetracer-zsh-recorder --help
#   codetracer-zsh-recorder --version
#
# Environment variables:
#   CODETRACER_ZSH_RECORDER_OUT_DIR
#       Output directory for the trace bundle (overridden by --out-dir).
#   CODETRACER_ZSH_RECORDER_DISABLED
#       When set to `1` or `true`, run the target script directly without
#       recording — useful for short-circuiting the recorder in CI when
#       the binary is on PATH but tracing is undesired.

set -eo pipefail

_ct_script_dir="${0:A:h}"
_ct_repo_root="${_ct_script_dir:h}"

_ct_resolve_zsh() {
    if [[ -n "${CODETRACER_ZSH:-}" ]]; then
        printf '%s\n' "$CODETRACER_ZSH"
    elif (( ${+commands[zsh]} )); then
        printf '%s\n' "$commands[zsh]"
    elif [[ -x "/proc/$$/exe" ]]; then
        printf '%s\n' "/proc/$$/exe"
    elif [[ -n "${SHELL:-}" && "${SHELL:t}" == "zsh" && -x "$SHELL" ]]; then
        printf '%s\n' "$SHELL"
    else
        printf '%s\n' "zsh"
    fi
}

_ct_zsh="$(_ct_resolve_zsh)"

# ---------------------------------------------------------------------------
# Version + help
#
# Single source of truth for the version is the top-level `VERSION` file so
# launcher, Cargo.toml, and the verifier all agree.  We fall back to
# `unknown` if VERSION is missing (defensive — should not happen in a
# correctly-built tree).
# ---------------------------------------------------------------------------

_ct_binary_name="codetracer-zsh-recorder"

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
$_ct_binary_name $(_ct_read_version) — CodeTracer Zsh Recorder

Record execution traces of Zsh scripts in the canonical CTFS format.

Usage:
  $_ct_binary_name [OPTIONS] [--] <script.zsh> [SCRIPT_ARGS...]

Arguments:
  <script.zsh>    Path to the Zsh script to record.
  [SCRIPT_ARGS]   Arguments forwarded to the recorded script.

Options:
  -o, --out-dir <PATH>    Directory where the CTFS trace bundle is written.
                          Falls back to \$CODETRACER_ZSH_RECORDER_OUT_DIR when
                          omitted; one of the two must be provided.
  -h, --help              Print this help text and exit.
  -V, --version           Print the recorder version and exit.

Output:
  The recorder always writes a CTFS \`.ct\` bundle (Recorder-CLI-Conventions §4).
  To inspect or convert the trace to JSON for debugging, run
  \`ct print [--json|--summary|--follow] <out-dir>/<script>.ct\` from
  codetracer-trace-format-nim.  No output-format flag is exposed: the
  recorder is hard-pinned to CTFS so the toolchain has a single canonical
  on-disk representation.

Environment variables:
  CODETRACER_ZSH_RECORDER_OUT_DIR    Default value for --out-dir.
  CODETRACER_ZSH_RECORDER_DISABLED   When set to \`1\` or \`true\`, run the
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

_ct_output_dir="${CODETRACER_ZSH_RECORDER_OUT_DIR:-}"
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
            _ct_script_args=("$@")
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
            _ct_script_args=("$@")
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
# CODETRACER_ZSH_RECORDER_DISABLED short-circuit.
#
# When the user wants the binary on PATH but does not want recording for a
# given invocation (e.g. inside a CI step that exercises the program for
# functional reasons), we exec the target script directly.  This must
# happen *after* CLI parsing so `--help`/`--version` still work, and
# *before* we require --out-dir or touch the trace writer / FIFO so we
# don't reject the call for missing trace plumbing the user explicitly
# disabled.
# ---------------------------------------------------------------------------

_ct_disabled="${CODETRACER_ZSH_RECORDER_DISABLED:-}"
case "$_ct_disabled" in
    1 | true | TRUE | yes | YES)
        exec "$_ct_zsh" "$_ct_script" "${_ct_script_args[@]}"
        ;;
esac

if [[ -z "$_ct_output_dir" ]]; then
    echo "Error: --out-dir is required (or set CODETRACER_ZSH_RECORDER_OUT_DIR)" >&2
    exit 2
fi

# Resolve the script to an absolute path
_ct_script="${_ct_script:A}"

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
# A Unix FIFO would let `recorder.zsh` and the trace writer run concurrently,
# but `ct-shell-trace-writer` is a *native* binary: on Windows the recorder
# runs under a Cygwin/MSYS shell whose `mkfifo` produces a Cygwin-emulated
# pipe that a non-Cygwin executable cannot read — it opens the FIFO path,
# sees an immediate EOF, and exits before any event arrives ("EOF reached
# without EXIT event"), which in turn delivers SIGPIPE (exit 141) to the
# recorder. Routing the events through a plain file is byte-identical from
# the writer's point of view (it consumes the whole stream from stdin) and
# works uniformly on every platform.
_ct_events_file=$(mktemp "${TMPDIR:-/tmp}/ct-events-XXXXXX")

# Clean up on exit
trap 'rm -f "$_ct_events_file"' EXIT

# Run the recorder with FD 3 connected to the event file.
"$_ct_zsh" "$_ct_script_dir/recorder.zsh" "$_ct_script" "${_ct_script_args[@]}" 3>"$_ct_events_file"
_ct_exit_code=$?

# Feed the recorded event stream to the trace writer, passing the program
# name and its positional argv for metadata + top-level call-arg staging.
#
# `--args` MUST be the last flag because the trace writer treats every
# remaining token after `--args` as a positional argv element.
#
# The CTFS format is hard-pinned in the writer (see Recorder-CLI-Conventions
# §4); no `--format` flag is forwarded here.
if (( ${#_ct_script_args[@]} > 0 )); then
    "$_ct_trace_writer" \
        --out-dir "$_ct_output_dir" \
        --program "$_ct_script" \
        --args "${_ct_script_args[@]}" \
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
    _ct_zsh_version=$("$_ct_zsh" --version | head -1 | grep -oP '\d+\.\d+(\.\d+)?' || echo "$ZSH_VERSION")

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

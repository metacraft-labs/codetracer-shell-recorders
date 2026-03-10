#!/bin/bash
# ct-bash-recorder: Records a Bash script execution via trap-based instrumentation.
# FD 3 must be open and connected to ct-shell-trace-writer's stdin.

set -o functrace    # DEBUG trap inherited by functions
shopt -s extdebug   # Required for DEBUG trap in functions + RETURN trap

_ct_target_script="$1"
shift  # remaining args are the script's arguments

if [[ -z "$_ct_target_script" ]]; then
    echo "Usage: recorder.sh <script.sh> [args...]" >&2
    exit 1
fi

# Resolve absolute path
_ct_target_script="$(cd "$(dirname "$_ct_target_script")" && pwd)/$(basename "$_ct_target_script")"

# Emit START event
printf 'START program=%s shell=bash shell_version=%s\n' "$_ct_target_script" "$BASH_VERSION" >&3

# Register the main script path
printf 'PATH file=%s\n' "$_ct_target_script" >&3

# Track which files we've already registered
declare -A _ct_registered_paths
_ct_registered_paths["$_ct_target_script"]=1

# DEBUG trap handler — fires before each simple command
_ct_debug_trap() {
    # BASH_SOURCE[0] is the recorder itself when in the trap function
    # BASH_SOURCE[1] is the actual source file being executed
    local _ct_file="${BASH_SOURCE[1]}"
    local _ct_line="${BASH_LINENO[0]}"

    # Skip events from the recorder itself
    [[ "$_ct_file" == "$0" ]] && return 0
    [[ "$_ct_file" == "" ]] && return 0

    # Register new source files
    if [[ -z "${_ct_registered_paths[$_ct_file]+x}" ]]; then
        printf 'PATH file=%s\n' "$_ct_file" >&3
        _ct_registered_paths["$_ct_file"]=1
    fi

    # Emit step event
    printf 'STEP file=%s line=%d\n' "$_ct_file" "$_ct_line" >&3

    return 0  # Don't skip the command
}

trap '_ct_debug_trap' DEBUG

# Execute the target script by sourcing it so traps apply
# Set positional parameters for the script
set -- "$@"
source "$_ct_target_script"
_ct_exit_code=$?

# Disable traps before cleanup
trap '' DEBUG

# Emit EXIT event
printf 'EXIT code=%d\n' "$_ct_exit_code" >&3

exit "$_ct_exit_code"

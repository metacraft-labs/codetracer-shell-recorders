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

# Track which functions we've already registered
declare -A _ct_registered_funcs

# Previous FUNCNAME stack depth (initial depth is 1 for the top-level)
_ct_prev_depth=1

# Flag: set to 1 inside the RETURN trap so the DEBUG trap skips processing
_ct_in_return_trap=0

# Snapshot all variable names that exist BEFORE the target script runs.
# Any variable not in this set was created by the user script and should be captured.
declare -A _ct_baseline_vars
while IFS= read -r _ct_baseline_line; do
    if [[ "$_ct_baseline_line" =~ ^declare\ +[-[:alpha:]]+\ +([_[:alpha:]][_[:alnum:]]*)= ]] ||
       [[ "$_ct_baseline_line" =~ ^declare\ +[-[:alpha:]]+\ +([_[:alpha:]][_[:alnum:]]*) ]]; then
        _ct_baseline_vars["${BASH_REMATCH[1]}"]=1
    fi
done <<< "$(declare -p 2>/dev/null)"
# Also add BASH_REMATCH itself to baseline since the regex above created/modified it
_ct_baseline_vars["BASH_REMATCH"]=1

# Quote a value for the wire protocol: if it contains spaces or special chars, wrap in quotes
_ct_quote_value() {
    local val="$1"
    if [[ "$val" =~ [\ \"\\\n] ]]; then
        val="${val//\\/\\\\}"
        val="${val//\"/\\\"}"
        printf '"%s"' "$val"
    else
        printf '%s' "$val"
    fi
}

# Capture all user-visible variables and emit VAR events.
# Called after each STEP event to record variable state.
# Only captures variables NOT in the baseline snapshot (i.e., user-created variables).
_ct_capture_variables() {
    local _ct_decl_output
    _ct_decl_output=$(declare -p 2>/dev/null) || return

    local _ct_decl_line
    while IFS= read -r _ct_decl_line; do
        # Skip empty lines
        [[ -z "$_ct_decl_line" ]] && continue

        # Pattern: declare [-flags] name="value" or declare [-flags] name
        local _ct_flags=""
        local _ct_varname=""
        if [[ "$_ct_decl_line" =~ ^declare\ +([-[:alpha:]]+)\ +([_[:alpha:]][_[:alnum:]]*)= ]]; then
            _ct_flags="${BASH_REMATCH[1]}"
            _ct_varname="${BASH_REMATCH[2]}"
        elif [[ "$_ct_decl_line" =~ ^declare\ +([-[:alpha:]]+)\ +([_[:alpha:]][_[:alnum:]]*) ]]; then
            _ct_flags="${BASH_REMATCH[1]}"
            _ct_varname="${BASH_REMATCH[2]}"
        else
            continue
        fi

        # Skip internal recorder variables
        [[ "$_ct_varname" == _ct_* ]] && continue
        # Skip any variable that existed before the user script was sourced
        [[ -n "${_ct_baseline_vars[$_ct_varname]+x}" ]] && continue
        # Skip bash internals that may be created dynamically
        [[ "$_ct_varname" == BASH_* ]] && continue
        [[ "$_ct_varname" == COMP_* ]] && continue
        [[ "$_ct_varname" == READLINE_* ]] && continue

        # Determine type flag from declare flags
        local _ct_type_flag="s"
        if [[ "$_ct_flags" == *A* ]]; then
            _ct_type_flag="A"
        elif [[ "$_ct_flags" == *a* ]]; then
            _ct_type_flag="a"
        elif [[ "$_ct_flags" == *i* ]]; then
            _ct_type_flag="i"
        fi

        # Extract value: everything after the first =
        local _ct_value=""
        if [[ "$_ct_decl_line" =~ ^declare\ +[-[:alpha:]]+\ +[_[:alpha:]][_[:alnum:]]*=(.*) ]]; then
            _ct_value="${BASH_REMATCH[1]}"
            # Remove surrounding quotes if present
            if [[ "$_ct_value" == \"*\" ]]; then
                _ct_value="${_ct_value:1:${#_ct_value}-2}"
            elif [[ "$_ct_value" == \'*\' ]]; then
                _ct_value="${_ct_value:1:${#_ct_value}-2}"
            fi
        fi

        # Emit VAR event with quoted value
        local _ct_quoted_val
        _ct_quoted_val=$(_ct_quote_value "$_ct_value")
        printf 'VAR name=%s value=%s type=%s\n' "$_ct_varname" "$_ct_quoted_val" "$_ct_type_flag" >&3
    done <<< "$_ct_decl_output"
}

# DEBUG trap handler — fires before each simple command
_ct_debug_trap() {
    # Capture $? immediately — before any command can clobber it.
    # This is critical for detecting the return value of a function that just
    # returned: the DEBUG trap that fires for the next command in the *caller*
    # sees $? set to the function's exit status.
    local _ct_status=$?

    # BASH_SOURCE[0] is the recorder itself when in the trap function
    # BASH_SOURCE[1] is the actual source file being executed
    local _ct_file="${BASH_SOURCE[1]}"
    local _ct_line="${BASH_LINENO[0]}"
    local _ct_depth=${#FUNCNAME[@]}

    # Skip events from the recorder itself or when inside the RETURN trap
    [[ "$_ct_file" == "$0" ]] && return 0
    [[ "$_ct_file" == "" ]] && return 0
    (( _ct_in_return_trap )) && return 0

    # Register new source files
    if [[ -z "${_ct_registered_paths[$_ct_file]+x}" ]]; then
        printf 'PATH file=%s\n' "$_ct_file" >&3
        _ct_registered_paths["$_ct_file"]=1
    fi

    # Detect function return: depth decreased compared to previous trap invocation.
    # At this point, _ct_status holds the return value of the function that just
    # returned, because bash restores $? to the function's exit status for the
    # first command back in the caller's scope.
    if (( _ct_depth < _ct_prev_depth )); then
        printf 'RETURN status=%d\n' "$_ct_status" >&3
    fi

    # Detect function call: depth increased compared to previous trap invocation
    # FUNCNAME[0] is _ct_debug_trap, FUNCNAME[1] is the function we're inside
    if (( _ct_depth > _ct_prev_depth )); then
        local _ct_func_name="${FUNCNAME[1]}"

        # Register function if first time seen
        if [[ -z "${_ct_registered_funcs[$_ct_func_name]+x}" ]]; then
            printf 'FUNC name=%s file=%s line=%d\n' "$_ct_func_name" "$_ct_file" "$_ct_line" >&3
            _ct_registered_funcs["$_ct_func_name"]=1
        fi

        # Emit CALL event
        printf 'CALL name=%s\n' "$_ct_func_name" >&3
    fi

    _ct_prev_depth=$_ct_depth

    # Emit step event
    printf 'STEP file=%s line=%d\n' "$_ct_file" "$_ct_line" >&3

    # Capture variables at this step
    _ct_capture_variables

    return 0  # Don't skip the command
}

# RETURN trap handler — we keep this trap active so that the DEBUG trap in the
# caller correctly observes the depth decrease. However, the actual RETURN
# event emission is handled by the DEBUG trap (which can reliably capture $?).
# We use the _ct_in_return_trap flag to prevent the DEBUG trap from emitting
# spurious events for commands inside this handler.
_ct_return_trap() {
    _ct_in_return_trap=1
    _ct_in_return_trap=0
}

trap '_ct_debug_trap' DEBUG
trap '_ct_return_trap' RETURN

# Execute the target script by sourcing it so traps apply
# Set positional parameters for the script
set -- "$@"
source "$_ct_target_script"
_ct_exit_code=$?

# Disable traps before cleanup
trap '' DEBUG
trap '' RETURN

# Emit EXIT event
printf 'EXIT code=%d\n' "$_ct_exit_code" >&3

exit "$_ct_exit_code"

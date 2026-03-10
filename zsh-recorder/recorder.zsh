#!/bin/zsh
# ct-zsh-recorder: Records a Zsh script execution via trap-based instrumentation.
# FD 3 must be open and connected to ct-shell-trace-writer's stdin.

setopt DEBUG_BEFORE_CMD    # DEBUG trap fires BEFORE each command

_ct_target_script="$1"
shift  # remaining args are the script's arguments

if [[ -z "$_ct_target_script" ]]; then
    echo "Usage: recorder.zsh <script.zsh> [args...]" >&2
    exit 1
fi

# Resolve absolute path using Zsh's :A modifier
_ct_target_script="${_ct_target_script:A}"

# Emit START event
printf 'START program=%s shell=zsh shell_version=%s\n' "$_ct_target_script" "$ZSH_VERSION" >&3

# Register the main script path
printf 'PATH file=%s\n' "$_ct_target_script" >&3

# Track which files we've already registered
typeset -A _ct_registered_paths
_ct_registered_paths[$_ct_target_script]=1

# Track which functions we've already registered
typeset -A _ct_registered_funcs

# Previous funcstack depth.
# When we source the target script, funcstack will have the script as depth 1.
# At top-level (before source), depth is 0.
_ct_prev_depth=0

# Store the recorder script path so we can filter it out
_ct_recorder_path="${0:A}"

# Store the last command seen in the DEBUG trap, for use in the ZERR trap
_ct_last_cmd=""

# Guard to prevent recursion within trap
_ct_in_trap=0

# Store the error status from the ZERR trap so the DEBUG trap can use it
# when detecting function returns (ZERR runs before the next DEBUG trap
# and clobbers $?)
_ct_last_error_status=0
_ct_had_error=0

# Snapshot all variable names that exist BEFORE the target script runs.
# Any variable not in this set was created by the user script and should be captured.
typeset -A _ct_baseline_vars
{
    local _ct_baseline_line
    typeset -p 2>/dev/null | while IFS= read -r _ct_baseline_line; do
        # Match: typeset [optional flags] varname[=value]
        if [[ "$_ct_baseline_line" =~ "^typeset (([-][[:alpha:]]+ )*)([_[:alpha:]][_[:alnum:]]*)" ]]; then
            _ct_baseline_vars[${match[3]}]=1
        fi
    done
}

# Inline quoting: sets _ct_qv to the quoted version of $1.
# Avoids subshell $() which interacts badly with the DEBUG trap.
_ct_inline_quote() {
    _ct_qv="$1"
    if [[ "$_ct_qv" =~ [\ \"\\\n] ]]; then
        _ct_qv="${_ct_qv//\\/\\\\}"
        _ct_qv="${_ct_qv//\"/\\\"}"
        _ct_qv="\"$_ct_qv\""
    fi
}

# Capture all user-visible variables and emit VAR events.
# Called after each STEP event to record variable state.
# Only captures variables NOT in the baseline snapshot (i.e., user-created variables).
#
# Zsh typeset -p output format (may include -g flag when called from functions):
#   typeset name=value                    (string, no flags)
#   typeset -g name=value                 (global, string)
#   typeset -i name=value                 (integer)
#   typeset -g -i name=value              (global integer)
#   typeset -F name=value                 (float, fixed-point)
#   typeset -E name=value                 (float, scientific)
#   typeset -a name=( ... )              (indexed array)
#   typeset -A name=( [k]=v ... )        (associative array)
#   typeset -g -a name=( ... )           (global array)
#
# Regex: ^typeset ((-flag )*)name=value
_ct_capture_variables() {
    local _ct_decl_output
    _ct_decl_output=$(typeset -p 2>/dev/null) || return

    local _ct_decl_line
    while IFS= read -r _ct_decl_line; do
        # Skip empty lines
        [[ -z "$_ct_decl_line" ]] && continue

        local _ct_flags_raw=""
        local _ct_varname=""
        local _ct_has_value=0
        local _ct_raw_value=""

        # Match: typeset [optional flags] name=value
        if [[ "$_ct_decl_line" =~ "^typeset (([-][[:alpha:]]+ )*)([_[:alpha:]][_[:alnum:]]*)=(.*)" ]]; then
            _ct_flags_raw="${match[1]}"
            _ct_varname="${match[3]}"
            _ct_raw_value="${match[4]}"
            _ct_has_value=1
        elif [[ "$_ct_decl_line" =~ "^typeset (([-][[:alpha:]]+ )*)([_[:alpha:]][_[:alnum:]]*)" ]]; then
            _ct_flags_raw="${match[1]}"
            _ct_varname="${match[3]}"
        else
            continue
        fi

        # Skip internal recorder variables
        [[ "$_ct_varname" == _ct_* ]] && continue
        # Skip any variable that existed before the user script was sourced
        (( ${+_ct_baseline_vars[$_ct_varname]} )) && continue
        # Skip zsh special variables that may be created dynamically
        [[ "$_ct_varname" == ZSH_* ]] && continue
        [[ "$_ct_varname" == zsh_* ]] && continue
        [[ "$_ct_varname" == MATCH ]] && continue
        [[ "$_ct_varname" == match ]] && continue
        [[ "$_ct_varname" == MBEGIN ]] && continue
        [[ "$_ct_varname" == MEND ]] && continue
        [[ "$_ct_varname" == mbegin ]] && continue
        [[ "$_ct_varname" == mend ]] && continue

        # Determine type flag from the combined flags string
        # Flags string looks like "-g -i " or "-a " or "" etc.
        local _ct_type_flag="s"
        if [[ "$_ct_flags_raw" == *-A* ]]; then
            _ct_type_flag="A"
        elif [[ "$_ct_flags_raw" == *-a* ]]; then
            _ct_type_flag="a"
        elif [[ "$_ct_flags_raw" == *-i* ]]; then
            _ct_type_flag="i"
        elif [[ "$_ct_flags_raw" == *-F* ]] || [[ "$_ct_flags_raw" == *-E* ]]; then
            _ct_type_flag="F"
        fi

        # Extract and clean value
        local _ct_value=""
        if (( _ct_has_value )); then
            _ct_value="$_ct_raw_value"
            # Remove surrounding quotes if present
            if [[ "$_ct_value" == \'*\' ]]; then
                _ct_value="${_ct_value:1:${#_ct_value}-2}"
            elif [[ "$_ct_value" == \"*\" ]]; then
                _ct_value="${_ct_value:1:${#_ct_value}-2}"
            fi
        fi

        # Inline quoting (no subshell) - sets _ct_qv
        _ct_inline_quote "$_ct_value"
        printf 'VAR name=%s value=%s type=%s\n' "$_ct_varname" "$_ct_qv" "$_ct_type_flag" >&3
    done <<< "$_ct_decl_output"
}

# DEBUG trap (LIST FORM - critical for correct $LINENO)
#
# In Zsh's sourced-script context:
# - funcstack[1] = script path (when at top-level of sourced script)
# - funcstack[1] = function name, funcstack[2] = script path (inside a function)
# - funcfiletrace[N] = "file:line" of each call site
# - funcsourcetrace[N] = "file:line" where each function/script was defined
# - $LINENO = line number in current execution context
trap '
    # Guard against re-entry
    if (( _ct_in_trap )); then
        :
    else
        _ct_in_trap=1

        _ct_trap_status=$?
        _ct_depth=${#funcstack}
        _ct_line=$LINENO
        _ct_cmd="$ZSH_DEBUG_CMD"
        _ct_last_cmd="$_ct_cmd"

        # Determine the current source file and adjust line numbers
        _ct_file=""
        _ct_func_def_line=0
        if (( _ct_depth == 0 )); then
            # Top-level: this is in the recorder itself, skip
            _ct_in_trap=0
        else
            # depth >= 1: inside sourced script or function within it
            # funcsourcetrace[1] = "file:line" where the innermost entry was defined
            _ct_fsrc="${funcsourcetrace[1]}"
            _ct_file="${_ct_fsrc%%:*}"
            _ct_func_def_line="${_ct_fsrc##*:}"

            # When inside a function (depth >= 2), $LINENO is relative to
            # the function definition. Actual file line = def_line + LINENO.
            # When at top-level of sourced script (depth == 1), $LINENO
            # is the actual file line number.
            if (( _ct_depth >= 2 )); then
                _ct_line=$(( _ct_func_def_line + _ct_line ))
            fi

            # Skip events from the recorder itself
            if [[ "$_ct_file" == "$_ct_recorder_path" ]] || [[ -z "$_ct_file" ]]; then
                _ct_in_trap=0
            fi
        fi

        if (( _ct_in_trap )); then
            # Register new source files
            if [[ -n "$_ct_file" ]] && (( ! ${+_ct_registered_paths[$_ct_file]} )); then
                printf '\''PATH file=%s\n'\'' "$_ct_file" >&3
                _ct_registered_paths[$_ct_file]=1
            fi

            # Detect function return: depth decreased compared to previous trap invocation.
            # If the ZERR trap fired (for non-zero return), use its saved status
            # since $? may have been clobbered by ZERR trap commands.
            if (( _ct_depth < _ct_prev_depth )); then
                if (( _ct_had_error )); then
                    printf '\''RETURN status=%d\n'\'' "$_ct_last_error_status" >&3
                    _ct_had_error=0
                else
                    printf '\''RETURN status=%d\n'\'' "$_ct_trap_status" >&3
                fi
            fi

            # Detect function call: depth increased compared to previous trap invocation
            # At depth >= 2, funcstack[1] is a function name
            if (( _ct_depth > _ct_prev_depth && _ct_depth >= 2 )); then
                _ct_func_name="${funcstack[1]}"

                # Register function if first time seen
                # Use the definition line from funcsourcetrace
                if (( ! ${+_ct_registered_funcs[$_ct_func_name]} )); then
                    printf '\''FUNC name=%s file=%s line=%d\n'\'' "$_ct_func_name" "$_ct_file" "$_ct_func_def_line" >&3
                    _ct_registered_funcs[$_ct_func_name]=1
                fi

                # Emit CALL event
                printf '\''CALL name=%s\n'\'' "$_ct_func_name" >&3
            fi

            _ct_prev_depth=$_ct_depth

            # Detect output commands from ZSH_DEBUG_CMD
            if [[ "$_ct_cmd" == echo\ * ]] || [[ "$_ct_cmd" == printf\ * ]] || [[ "$_ct_cmd" == print\ * ]]; then
                _ct_inline_quote "$_ct_cmd"
                printf '\''WRITE content=%s\n'\'' "$_ct_qv" >&3
            fi

            # Emit step event
            printf '\''STEP file=%s line=%d\n'\'' "$_ct_file" "$_ct_line" >&3

            # Capture variables at this step
            _ct_capture_variables

            _ct_in_trap=0
        fi
    fi
' DEBUG

# ZERR trap for errors — fires when a command returns non-zero exit status
trap '
    _ct_zerr_status=$?
    if (( ! _ct_in_trap )); then
        _ct_in_trap=1
        _ct_zerr_depth=${#funcstack}

        # Skip errors at depth 0 (recorder level)
        if (( _ct_zerr_depth >= 1 )); then
            _ct_zerr_cmd="$_ct_last_cmd"
            _ct_inline_quote "$_ct_zerr_cmd"
            printf '\''ERROR cmd=%s status=%d\n'\'' "$_ct_qv" "$_ct_zerr_status" >&3
            # Save the error status for the next DEBUG trap (for RETURN detection)
            _ct_last_error_status=$_ct_zerr_status
            _ct_had_error=1
        fi

        _ct_in_trap=0
    fi
' ZERR

# Execute the target script by sourcing it so traps apply
source "$_ct_target_script" "$@"
_ct_exit_code=$?

# Disable traps before cleanup
trap - DEBUG
trap - ZERR

# Emit EXIT event
printf 'EXIT code=%d\n' "$_ct_exit_code" >&3

exit "$_ct_exit_code"

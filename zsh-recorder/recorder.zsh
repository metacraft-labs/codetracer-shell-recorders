#!/usr/bin/env zsh
# ct-zsh-recorder: Records a Zsh script execution via trap-based instrumentation.
# FD 3 must be open and connected to ct-shell-trace-writer's stdin.

setopt DEBUG_BEFORE_CMD    # DEBUG trap fires BEFORE each command

_ct_target_script="$1"
shift  # remaining args are the script's arguments

if [[ -z "$_ct_target_script" ]]; then
    echo "Usage: recorder.zsh <script.zsh> [args...]" >&2
    exit 1
fi

# Resolve to an absolute path without resolving symlinks: join a relative
# path to the logical $PWD (`:a` alone would use the physical working
# directory), then let `:a` fold `.`/`..`. This must match launcher.zsh,
# which passes the same path to the trace writer as `--program`; keeping
# symlinks matches the bash recorder's logical `cd && pwd` as well.
[[ "$_ct_target_script" == /* ]] || _ct_target_script="$PWD/$_ct_target_script"
_ct_target_script="${_ct_target_script:a}"

# Emit START event
printf 'START program=%s shell=zsh shell_version=%s\n' "$_ct_target_script" "$ZSH_VERSION" >&3

# Register the main script path
printf 'PATH file=%s\n' "$_ct_target_script" >&3

# Track which files we've already registered
typeset -A _ct_registered_paths
_ct_registered_paths[$_ct_target_script]=1

# Track which functions we've already registered
typeset -A _ct_registered_funcs

# Previous funcstack depth, or the caller's depth after a function's EXIT
# trap closed its frame. A DEBUG trap deeper than this is the first command
# of a new frame: a CALL.
# When we source the target script, funcstack will have the script as depth 1.
# At top-level (before source), depth is 0.
_ct_prev_depth=0

# ---------------------------------------------------------------------------
# Open frames
# ---------------------------------------------------------------------------
# One entry per frame the recorder wrote a CALL for and has not yet written
# the RETURN for, innermost last: its funcstack depth, and its kind, `f` for
# a function and `s` for a sourced file. Every RETURN pops one entry, so the
# event stream holds exactly one RETURN per CALL.
#
# Zsh has no RETURN trap. A function's frame is closed by an EXIT trap the
# DEBUG trap sets inside the function when it writes the CALL: "If sig is 0
# or EXIT and the trap statement is executed inside the body of a function,
# then the command arg is executed after the function completes", with `$?`
# the function's return status, in the function's own shell, subshell or
# not. So a function called in `$(...)` or used as a condition is closed
# with its own status. A sourced file's frame, and a function whose EXIT trap
# the script replaced, is closed by the first DEBUG trap shallower than it.
# See: https://zsh.sourceforge.io/Doc/Release/Shell-Builtin-Commands.html#index-trap
#      https://zsh.sourceforge.io/Doc/Release/Functions.html#Trap-Functions
typeset -a _ct_frame_depths _ct_frame_kinds

# A function's EXIT trap also runs when `exit` unwinds the function, with `$?`
# not yet the exit status. When the DEBUG trap saw an `exit` in the command
# it ran (`_ct_exit_suspect`), the trap's RETURN is held here, as
# "<frame position>:<status>", until it is known whether the shell exits:
# the next DEBUG or ZERR trap writes the held RETURNs (the shell went on),
# and the zshexit hook decides for an exit. `_ct_exit_suspect_size` is the
# number of frames open when the `exit` was seen: frames at or below that
# position are the ones `exit` unwinds.
typeset -a _ct_held_returns
_ct_exit_suspect=0
_ct_exit_suspect_size=0

# An `exit` among the commands of a list: at its start or after `;`, `&`,
# `|`, `(`, `{`, `then`, `else` or `do`, optionally spelled `builtin exit`
# or `command exit`. Zsh runs the DEBUG trap once for a whole list
# (`[[ $x ]] || exit 3`), so ZSH_DEBUG_CMD is the list.
_ct_exit_re='(^|[;&|({]|then|else|do)[[:space:]]*((builtin|command)[[:space:]]+)?exit([[:space:];)}]|$)'

# Whether the command $1 may run `exit`: it matches `_ct_exit_re` once its
# quoted strings are removed (`echo "done; exit"` runs no `exit`). Returns 0
# when it may.
_ct_mentions_exit() {
    setopt localoptions extendedglob
    local _ct_text="$1"
    _ct_text="${_ct_text//\'[^\']#\'/}"
    _ct_text="${_ct_text//\"[^\"]#\"/}"
    [[ "$_ct_text" =~ $_ct_exit_re ]]
}

# The subshell level the frame arrays belong to, and how many of their
# entries it inherited from its parent. Updated by the first DEBUG trap of a
# subshell. `_ct_subshell_closed` is set once a subshell that exits has
# closed its frames.
_ct_frames_subshell=0
_ct_subshell_base=0
_ct_subshell_closed=0

# Write a RETURN for the innermost open frame with status $1 and pop it.
_ct_pop_frame() {
    _ct_frame_depths[-1]=()
    _ct_frame_kinds[-1]=()
    printf 'RETURN status=%d\n' "$1" >&3
}

# Close every open frame deeper than funcstack depth $1 with status $2: the
# stack is shallower than they are, so they are gone.
_ct_close_frames_deeper_than() {
    while (( ${#_ct_frame_depths} > 0 && _ct_frame_depths[-1] > $1 )); do
        _ct_pop_frame "$2"
    done
}

# Write every held RETURN with its own status: the shell did not exit.
_ct_flush_held_returns() {
    local _ct_entry
    for _ct_entry in "${_ct_held_returns[@]}"; do
        printf 'RETURN status=%d\n' "${_ct_entry#*:}" >&3
    done
    _ct_held_returns=()
    _ct_exit_suspect=0
}

# The EXIT trap of a function frame: the function completed with status $1,
# and the caller is at funcstack depth $2. Set by the DEBUG trap with the
# CALL; runs in the function's own shell, after the function's frame left
# funcstack.
_ct_function_returned() {
    (( _ct_exit_emitted || _ct_subshell_closed )) && return 0
    local _ct_n=${#_ct_frame_depths}
    (( _ct_n > 0 )) || return 0
    [[ "${_ct_frame_kinds[-1]}" == f ]] || return 0
    (( _ct_frame_depths[-1] == $2 + 1 )) || return 0
    _ct_frame_depths[-1]=()
    _ct_frame_kinds[-1]=()
    _ct_prev_depth=$2
    # The status is the function's own: a ZERR status saved for the
    # depth-decrease fallback does not apply to it.
    _ct_had_error=0
    # Only a frame that was open when the `exit` was seen can be unwound by
    # it; one opened since has returned.
    if (( _ct_exit_suspect && _ct_n <= _ct_exit_suspect_size )); then
        _ct_held_returns+=("$_ct_n:$1")
    else
        printf 'RETURN status=%d\n' "$1" >&3
    fi
}

# Close, in a subshell that exits with status $1, the frames it opened: the
# RETURNs held while an `exit` was pending (the frames `exit` unwound get
# the exit status, frames that returned before it their own), then every
# frame still open above the subshell's base. The parent then goes on at
# the depth it had. Only a subshell whose DEBUG trap recorded its base owns
# the frames above it.
_ct_close_subshell_frames() {
    (( _ct_subshell_closed )) && return 0
    (( _ct_frames_subshell == ZSH_SUBSHELL )) || return 0
    _ct_subshell_closed=1
    local _ct_entry _ct_code=$(( $1 & 255 ))
    for _ct_entry in "${_ct_held_returns[@]}"; do
        if (( ${_ct_entry%%:*} <= _ct_exit_suspect_size )); then
            printf 'RETURN status=%d\n' "$_ct_code" >&3
        else
            printf 'RETURN status=%d\n' "${_ct_entry#*:}" >&3
        fi
    done
    _ct_held_returns=()
    while (( ${#_ct_frame_depths} > _ct_subshell_base )); do
        _ct_pop_frame "$_ct_code"
    done
}

# Before the EXIT event of the recorder's own shell: the held RETURNs of
# frames that returned before the `exit` are written; the frames `exit`
# unwound are left to the EXIT event, which closes every open frame with
# the exit status (spec "Script Exit").
_ct_flush_held_returns_before_exit() {
    local _ct_entry
    for _ct_entry in "${_ct_held_returns[@]}"; do
        if (( ${_ct_entry%%:*} > _ct_exit_suspect_size )); then
            printf 'RETURN status=%d\n' "${_ct_entry#*:}" >&3
        fi
    done
    _ct_held_returns=()
}

# Store the recorder script path so we can filter it out. funcsourcetrace
# names this file by the path it was run as, which is relative when the
# recorder is run by a relative path, so both spellings are kept.
_ct_recorder_path="${0:A}"
_ct_recorder_path_as_run="$0"

# Store the last command seen in the DEBUG trap, for use in the ZERR trap
_ct_last_cmd=""

# Guard to prevent recursion within trap
_ct_in_trap=0

# Store the error status from the ZERR trap so the DEBUG trap can use it
# when detecting function returns (ZERR runs before the next DEBUG trap
# and clobbers $?)
_ct_last_error_status=0
_ct_had_error=0

# Set once the EXIT event has been written, so it is written exactly once.
_ct_exit_emitted=0

# Emit the EXIT event for exit status $1: the event that closes the
# `<script>` frame and carries the script's exit code.
#
# It has three callers. The `zshexit` hook covers a script that calls `exit`,
# which ends this shell inside the `source` below, so no line after `source`
# runs. The ZERR trap covers an ERR_EXIT exit, which runs no zshexit hook.
# The call after `source` covers a script that runs off its end. Whichever
# runs first writes the event; the flag makes the others no-ops.
#
# Only the recorder's own shell writes it. zsh runs the zshexit hooks in a
# subshell that exits, too, so `( exit 2 )` or `$(exit 5)` would call it
# there with the subshell's status; ZSH_SUBSHELL is 0 only in the recorder's
# own shell.
# See: https://zsh.sourceforge.io/Doc/Release/Parameters.html#index-ZSH_005fSUBSHELL
_ct_emit_exit() {
    # zsh keeps the full argument of `exit` in `$?` (`exit 300` leaves 300,
    # `exit -1` leaves -1), while the process exit status the parent sees is
    # its low eight bits (44, 255). Record the status the process ends with,
    # as bash does.
    # See: https://pubs.opengroup.org/onlinepubs/9799919799/functions/_Exit.html
    local _ct_code=$(( $1 & 255 ))
    (( ZSH_SUBSHELL == 0 )) || return 0
    (( _ct_exit_emitted )) && return 0
    _ct_exit_emitted=1

    # Nothing after this point belongs to the script: stop recording before
    # writing the event, so it is the last one in the stream.
    trap - DEBUG
    trap - ZERR

    printf 'EXIT code=%d\n' "$_ct_code" >&3
}

# A zshexit hook rather than an EXIT trap. With a DEBUG trap set, as here,
# zsh (5.9, 5.9.1) runs the EXIT trap at the first command after any ZERR
# trap has run, with that command's status, and then not at the real exit.
# A script file holding these six lines
#
#   trap 'print EXIT $?' EXIT
#   trap : DEBUG
#   trap : ZERR
#   false
#   echo mid
#   exit 3
#
# prints "mid", then "EXIT 0", and exits 3. The zshexit hooks run once, at
# the exit, with `$?` set to the exit status. They also leave the EXIT trap
# free for the script's own use.
# See: https://zsh.sourceforge.io/Doc/Release/Functions.html#Hook-Functions
_ct_zshexit_hook() {
    local _ct_code=$?
    if (( ZSH_SUBSHELL > 0 )); then
        # `exit` in a subshell ends only the subshell, inside whatever
        # functions it was in.
        _ct_close_subshell_frames "$_ct_code"
    elif (( ! _ct_exit_emitted )); then
        _ct_flush_held_returns_before_exit
    fi
    _ct_emit_exit "$_ct_code"
}
# Registered before the variable baseline below, so that the recorder's own
# `zshexit_functions` entry is not reported as a variable of the script.
zshexit_functions+=(_ct_zshexit_hook)

# The start of one parameter's line in `typeset -p` output, up to and
# including its name: the declaration keyword, the option flags, the name.
# match[1] is the keyword, match[2] the flags ("-g -i " or ""), match[4] the
# name. Shared by the baseline snapshot and `_ct_capture_variables`, so that
# the two accept exactly the same lines: a line the capture accepts but the
# baseline skips would report an inherited parameter as one of the script's.
# See the `typeset -p` output format above `_ct_capture_variables`.
_ct_decl_prefix_re='^(typeset|export) (([-][[:alpha:]]+ )*)([_[:alpha:]][_[:alnum:]]*)'

# Snapshot all variable names that exist BEFORE the target script runs.
# Any variable not in this set was created by the user script and should be captured.
typeset -A _ct_baseline_vars
{
    local _ct_baseline_line
    typeset -p 2>/dev/null | while IFS= read -r _ct_baseline_line; do
        # Match: typeset|export [optional flags] varname[=value]
        if [[ "$_ct_baseline_line" =~ $_ct_decl_prefix_re ]]; then
            _ct_baseline_vars[${match[4]}]=1
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
# An exported scalar parameter is printed with the keyword `export` instead
# of `typeset`, and without the -x flag (zsh 5.9, 5.9.1):
#   export name=value                     (export name=value, or
#                                          typeset -gx name=value in a function)
#   export -i name=value                  (exported integer)
#   export -F name=value                  (exported float)
# An exported array keeps the keyword: `typeset -ax name=( ... )`.
# See `typeset -p` under "typeset" in
# https://zsh.sourceforge.io/Doc/Release/Shell-Builtin-Commands.html
#
# Regex: ^(typeset|export) ((-flag )*)name=value ($_ct_decl_prefix_re, then
# `=value`)
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

        # Match: typeset|export [optional flags] name=value
        if [[ "$_ct_decl_line" =~ "${_ct_decl_prefix_re}=(.*)" ]]; then
            _ct_flags_raw="${match[2]}"
            _ct_varname="${match[4]}"
            _ct_raw_value="${match[5]}"
            _ct_has_value=1
        elif [[ "$_ct_decl_line" =~ $_ct_decl_prefix_re ]]; then
            _ct_flags_raw="${match[2]}"
            _ct_varname="${match[4]}"
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
            if [[ "$_ct_file" == "$_ct_recorder_path" ]] ||
               [[ "$_ct_file" == "$_ct_recorder_path_as_run" ]] ||
               [[ -z "$_ct_file" ]]; then
                _ct_in_trap=0
            fi
        fi

        if (( _ct_in_trap )); then
            # Register new source files
            if [[ -n "$_ct_file" ]] && (( ! ${+_ct_registered_paths[$_ct_file]} )); then
                printf '\''PATH file=%s\n'\'' "$_ct_file" >&3
                _ct_registered_paths[$_ct_file]=1
            fi

            # The shell went on, so nothing held for a pending `exit` exits.
            if (( ${#_ct_held_returns} > 0 || _ct_exit_suspect )); then
                _ct_flush_held_returns
            fi

            # The first DEBUG trap of a subshell: the frames already open
            # belong to the parent, which closes them; this subshell closes
            # those it opens.
            if (( ZSH_SUBSHELL != _ct_frames_subshell )); then
                _ct_frames_subshell=$ZSH_SUBSHELL
                _ct_subshell_base=${#_ct_frame_depths}
                _ct_subshell_closed=0
            fi

            # Frames deeper than this command are gone: a sourced file that
            # finished, or a function whose EXIT trap the script replaced.
            # If the ZERR trap fired (for a non-zero return), use its saved
            # status since $? may have been clobbered by ZERR trap commands.
            if (( ${#_ct_frame_depths} > 0 && _ct_frame_depths[-1] > _ct_depth )); then
                if (( _ct_had_error )); then
                    _ct_close_frames_deeper_than "$_ct_depth" "$_ct_last_error_status"
                    _ct_had_error=0
                else
                    _ct_close_frames_deeper_than "$_ct_depth" "$_ct_trap_status"
                fi
            fi

            # Detect function call: depth increased compared to previous trap invocation
            # At depth >= 2, funcstack[1] is a function name
            if (( _ct_depth > _ct_prev_depth && _ct_depth >= 2 )); then
                _ct_func_name="${funcstack[1]}"

                # A frame still open at this depth or deeper is gone: its
                # EXIT trap never ran. Closed before the ARG events, which
                # belong to the CALL below.
                _ct_close_frames_deeper_than $(( _ct_depth - 1 )) "$_ct_trap_status"

                # Register function if first time seen
                # Use the definition line from funcsourcetrace
                if (( ! ${+_ct_registered_funcs[$_ct_func_name]} )); then
                    printf '\''FUNC name=%s file=%s line=%d\n'\'' "$_ct_func_name" "$_ct_file" "$_ct_func_def_line" >&3
                    _ct_registered_funcs[$_ct_func_name]=1
                fi

                # Stage positional parameters as ARG events BEFORE the CALL
                # event.  Zsh DEBUG traps inherit `$@` from the enclosing
                # function frame, so we can iterate `argv` directly.  Each
                # ARG line is consumed by the trace writers pending-call-args
                # buffer and drained on the next CALL.
                _ct_arg_count=${#argv}
                _ct_arg_idx=1
                while (( _ct_arg_idx <= _ct_arg_count )); do
                    _ct_arg_val="${argv[$_ct_arg_idx]}"
                    _ct_inline_quote "$_ct_arg_val"
                    printf '\''ARG name=$%d value=%s type=s\n'\'' "$_ct_arg_idx" "$_ct_qv" >&3
                    _ct_arg_idx=$(( _ct_arg_idx + 1 ))
                done

                # Emit CALL event (drains the ARG events staged above)
                printf '\''CALL name=%s\n'\'' "$_ct_func_name" >&3

                # Open the frame. A function frame gets the EXIT trap that
                # closes it (see "Open frames"); set here, before the
                # function runs its first command, and so before any EXIT
                # trap of the function itself, which replaces it. A sourced
                # file is not a function: an EXIT trap set there would be
                # the EXIT trap of the shell itself.
                if [[ "${zsh_eval_context[-2]}" == shfunc ]]; then
                    _ct_frame_depths+=($_ct_depth)
                    _ct_frame_kinds+=(f)
                    trap '\''_ct_function_returned $? ${#funcstack}'\'' EXIT
                else
                    _ct_frame_depths+=($_ct_depth)
                    _ct_frame_kinds+=(s)
                fi
            fi

            # An `exit` in this command may unwind functions: hold the
            # RETURNs their EXIT traps write until it is known whether the
            # shell exits. Counted after the CALL above, so that a function
            # whose first command is the `exit` (`f() { exit 3 }`) is among
            # the frames it unwinds.
            if _ct_mentions_exit "$_ct_cmd"; then
                _ct_exit_suspect=1
                _ct_exit_suspect_size=${#_ct_frame_depths}
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
            # The shell went on, so nothing held for a pending `exit` exits.
            if (( ${#_ct_held_returns} > 0 || _ct_exit_suspect )); then
                _ct_flush_held_returns
            fi
            _ct_zerr_cmd="$_ct_last_cmd"
            _ct_inline_quote "$_ct_zerr_cmd"
            printf '\''ERROR cmd=%s status=%d\n'\'' "$_ct_qv" "$_ct_zerr_status" >&3
            # Save the error status for the next DEBUG trap (for RETURN detection)
            _ct_last_error_status=$_ct_zerr_status
            _ct_had_error=1
            # With ERR_EXIT set, the shell exits right after this trap, and
            # does not run the zshexit hooks (an errexit exit is not a
            # "normal" exit), so this is the last point to write EXIT. ZERR
            # runs only where ERR_EXIT applies, so the exit is certain.
            # See: https://zsh.sourceforge.io/Doc/Release/Options.html#index-ERREXIT
            # A subshell ends there inside whatever functions it is in, and
            # runs no zshexit hook either: close the frames it opened.
            if [[ -o errexit ]]; then
                if (( ZSH_SUBSHELL > 0 )); then
                    _ct_close_subshell_frames "$_ct_zerr_status"
                fi
                _ct_emit_exit "$_ct_zerr_status"
            fi
        fi

        _ct_in_trap=0
    fi
' ZERR

# Execute the target script by sourcing it so traps apply
source "$_ct_target_script" "$@"
_ct_exit_code=$?

_ct_emit_exit "$_ct_exit_code"

exit "$_ct_exit_code"

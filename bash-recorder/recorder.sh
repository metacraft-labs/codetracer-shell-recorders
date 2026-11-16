#!/usr/bin/env bash
# ct-bash-recorder: Records a Bash script execution via trap-based instrumentation.
# FD 3 must be open and connected to ct-shell-trace-writer's stdin.

set -o functrace    # DEBUG trap inherited by functions
set -o errtrace     # ERR trap inherited by functions
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

# FUNCNAME stack depth at the previous DEBUG trap, or the caller's depth after
# the RETURN trap closed a frame (initial depth is 1 for the top-level). A
# DEBUG trap deeper than this is the first command of a new frame: a CALL.
_ct_prev_depth=1

# Flag: set to 1 inside the RETURN trap so the DEBUG trap skips processing
_ct_in_return_trap=0

# ---------------------------------------------------------------------------
# Open frames
# ---------------------------------------------------------------------------
# One entry per frame the recorder wrote a CALL for and has not yet written
# the RETURN for, innermost last: its FUNCNAME depth as the DEBUG trap counts
# it, its name, and its kind, `f` for a function and `s` for a sourced file
# (bash puts a `source` frame on FUNCNAME for `source` and `.`).
#
# Every RETURN the recorder writes pops one entry, so the event stream holds
# exactly one RETURN per CALL. A subshell (`( ... )`, `$( ... )`) inherits a
# copy of the arrays; the frames it opens are closed in the subshell, by
# the RETURN trap or, when it calls `exit`, by `_ct_close_subshell_frames`.
# See: https://www.gnu.org/software/bash/manual/html_node/Command-Execution-Environment.html
_ct_frame_depths=()
_ct_frame_names=()
_ct_frame_kinds=()

# Who closes a frame. A function's frame is closed by the RETURN trap, which
# bash runs in the returning function's own shell, subshell or not, before
# execution resumes in the caller. A sourced file's frame is closed by the
# DEBUG trap that first runs shallower than it (the RETURN trap that `source`
# runs comes after bash has already removed the file's FUNCNAME entry, in
# the caller's context, where it looks exactly like the caller's own return).
#
# Bash runs the DEBUG trap before the first command of every trap action,
# the RETURN trap's included, with BASH_COMMAND still naming the last command
# that ran ("the command executing at the time of the trap"). So every
# RETURN trap is preceded by a DEBUG trap that is not a script command. Two
# consequences are handled below:
#
# - When a sourced file returns, that extra DEBUG trap runs at the caller's
#   depth while the file's frame is still open. It is not taken as the
#   file's end: the RETURN trap that follows closes the frame. Only a second
#   DEBUG trap that still finds the frame open closes it (`_ct_deferred_pop`),
#   which covers a script that replaced the recorder's RETURN trap.
# - A command seen once, then once more as that extra DEBUG trap, is counted
#   twice before the RETURN trap. A command seen only once before the RETURN
#   trap is the stale BASH_COMMAND of a frame that returned earlier. See
#   `_ct_note_command`.
# See: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-trap
#      https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html#index-BASH_005fCOMMAND

# Set to the frame count when a DEBUG trap left a sourced file's frame open
# for the RETURN trap to close; -1 when no such frame is waiting.
_ct_deferred_pop=-1

# The last `return` or `source` command the DEBUG trap saw: its depth, its
# text and how many consecutive DEBUG traps saw it (see `_ct_note_command`).
_ct_cmd_depth=-1
_ct_cmd_text=""
_ct_cmd_hits=0

# The shell the frame arrays belong to, and how many of their entries it
# inherited from its parent. Updated by the first DEBUG trap of a subshell.
_ct_frames_pid=$BASHPID
_ct_subshell_base=0

# Set in a subshell that is about to exit (an `exit` command, or `errexit`):
# its frames are closed by its EXIT trap, and nothing after that is a script
# command to record.
_ct_subshell_exiting=0
_ct_subshell_status=0

# The recorder's own shell. `$BASHPID` differs from it in every subshell,
# `( ... )` and `$( ... )` included, while `$$` does not.
# See: https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html
_ct_recorder_pid=$BASHPID

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

# ---------------------------------------------------------------------------
# Frame bookkeeping (see "Open frames" above)
# ---------------------------------------------------------------------------

# Commands whose text the DEBUG trap remembers, and the parts read back.
# Kept in variables because `[[ =~ ]]` treats a quoted right-hand side as a
# literal string (bash 3.2 and later).
# See: https://www.gnu.org/software/bash/manual/html_node/Conditional-Constructs.html
_ct_return_re='^return([[:space:]]+(.*))?$'
_ct_exit_re='^((builtin|command)[[:space:]]+)?exit([[:space:]]|$)'
_ct_source_re='^((builtin|command)[[:space:]]+)?(source|\.)[[:space:]]'
_ct_int_re='^[[:space:]]*(-?)([0-9]+)[[:space:]]*$'

# Set `$?` to $1 for the next command.
_ct_set_status() {
    return "$1"
}

# Evaluate $1, the argument of a `return` command, to the status it returns,
# into `_ct_evaluated_status`; $2 is the `$?` the argument saw and the rest
# are the positional parameters it saw. Returns non-zero when the value
# cannot be obtained safely, and the caller then keeps the status it has.
#
# A decimal literal (`return 7`) is read directly. Anything else is expanded
# again in a subshell, so that what the expansion assigns (`${x:=1}`,
# `$((i++))`) never reaches the script. An argument with a command or process
# substitution is not expanded again: that would run its command twice. The
# status is the low eight bits of the value, as bash's `return` takes it.
# See: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-return
_ct_eval_status() {
    local _ct_et="$1" _ct_es="$2"
    shift 2
    if [[ "$_ct_et" =~ $_ct_int_re ]]; then
        _ct_evaluated_status=$(( 10#${BASH_REMATCH[2]} ))
        if [[ -n "${BASH_REMATCH[1]}" ]]; then
            _ct_evaluated_status=$(( -_ct_evaluated_status ))
        fi
        _ct_evaluated_status=$(( _ct_evaluated_status & 255 ))
        return 0
    fi
    # `$((` opens an arithmetic expansion; any other `$(` is a command
    # substitution. The pattern is in a variable: bash 5.2 fails to parse
    # `${var//'$(('/}` ("bad substitution: no closing `)'").
    # shellcheck disable=SC2016 # the literal text `$((` is the pattern
    local _ct_arith='$(('
    local _ct_scan="${_ct_et//"$_ct_arith"/}"
    # shellcheck disable=SC2016 # literal `$(`, not an expansion
    case "$_ct_scan" in
        *'$('* | *'`'* | *'<('* | *'>('*) return 1 ;;
    esac
    local _ct_ev
    _ct_ev=$(_ct_set_status "$_ct_es"; eval "printf '%s' $_ct_et" 2>/dev/null) || return 1
    if [[ "$_ct_ev" =~ $_ct_int_re ]]; then
        _ct_evaluated_status=$(( 10#${BASH_REMATCH[2]} ))
        if [[ -n "${BASH_REMATCH[1]}" ]]; then
            _ct_evaluated_status=$(( -_ct_evaluated_status ))
        fi
        _ct_evaluated_status=$(( _ct_evaluated_status & 255 ))
        return 0
    fi
    return 1
}

# Remember the command the DEBUG trap at depth $1 is about to run, $2, when
# it is a `return` or a `source`, and count how many consecutive DEBUG traps
# saw it. A genuine command is seen twice before the RETURN trap that ends
# its frame: once for itself and once more as the DEBUG trap bash runs for
# the RETURN trap's action, with BASH_COMMAND unchanged. A count of one
# means the text was BASH_COMMAND left over from a frame that has already
# returned (`outer() { inner; }` ends with inner's last command). The DEBUG
# trap bash runs for the ERR trap's action is taken back by `_ct_err_trap`.
_ct_note_command() {
    if [[ "$2" =~ $_ct_return_re ]] || [[ "$2" =~ $_ct_source_re ]]; then
        if (( _ct_cmd_depth == $1 )) && [[ "$_ct_cmd_text" == "$2" ]]; then
            _ct_cmd_hits=$(( _ct_cmd_hits + 1 ))
        else
            _ct_cmd_depth=$1
            _ct_cmd_text="$2"
            _ct_cmd_hits=1
        fi
    else
        _ct_cmd_depth=-1
        _ct_cmd_text=""
        _ct_cmd_hits=0
    fi
}

# The status a frame at depth $1 of kind $2 returns, into
# `_ct_frame_status_result`: the value of the `return` command that ended it
# when there was one, otherwise $3. The rest are the positional parameters
# the `return` saw. A function's `return` must have been seen twice (see
# `_ct_note_command`); a sourced file's once, because the DEBUG trap before
# the RETURN trap of `source` runs at the caller's depth.
_ct_frame_status() {
    local _ct_fd="$1" _ct_need=2
    [[ "$2" == s ]] && _ct_need=1
    _ct_frame_status_result="$3"
    shift 3
    if (( _ct_cmd_depth == _ct_fd && _ct_cmd_hits >= _ct_need )) &&
       [[ "$_ct_cmd_text" =~ $_ct_return_re ]]; then
        local _ct_arg="${BASH_REMATCH[2]}"
        if [[ -n "$_ct_arg" ]] && _ct_eval_status "$_ct_arg" "$_ct_frame_status_result" ${1+"$@"}; then
            _ct_frame_status_result=$_ct_evaluated_status
        fi
    fi
}

# Open a frame: depth $1, name $2, kind $3 (`f` or `s`).
_ct_push_frame() {
    _ct_frame_depths+=("$1")
    _ct_frame_names+=("$2")
    _ct_frame_kinds+=("$3")
}

# Close the innermost open frame with status $1.
_ct_pop_frame() {
    local _ct_last=$(( ${#_ct_frame_depths[@]} - 1 ))
    unset "_ct_frame_depths[$_ct_last]" "_ct_frame_names[$_ct_last]" "_ct_frame_kinds[$_ct_last]"
    _ct_deferred_pop=-1
    printf 'RETURN status=%d\n' "$1" >&3
}

# Close every open frame deeper than depth $1, innermost first; $2 is the
# status of a frame whose own status is not known. The frames are gone: the
# stack is shallower than they are.
_ct_close_frames_deeper_than() {
    local _ct_i
    while (( ${#_ct_frame_depths[@]} > 0 )); do
        _ct_i=$(( ${#_ct_frame_depths[@]} - 1 ))
        (( _ct_frame_depths[_ct_i] > $1 )) || break
        _ct_frame_status "${_ct_frame_depths[_ct_i]}" "${_ct_frame_kinds[_ct_i]}" "$2"
        _ct_pop_frame "$_ct_frame_status_result"
    done
}

# The EXIT trap of a subshell that is exiting: close the frames this subshell
# opened with its exit status $1, and leave `$?` at $1 for an EXIT trap of
# the script's that runs after it.
_ct_subshell_exit_trap() {
    local _ct_code=$(( $1 & 255 ))
    while (( ${#_ct_frame_depths[@]} > _ct_subshell_base )); do
        _ct_pop_frame "$_ct_code"
    done
    return "$1"
}

# Called in a subshell that is about to exit, by `exit` or by `errexit`,
# possibly from inside functions. Those frames will never return, so the
# subshell's EXIT trap closes them, with the status the subshell exits with
# (`$?` in an EXIT trap). The parent then goes on at the depth it had, as
# for any other subshell. An EXIT trap the subshell already has runs after.
# See: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-trap
_ct_begin_subshell_exit() {
    (( _ct_subshell_exiting )) && return 0
    # The frame arrays describe this shell only once a DEBUG trap ran in it.
    (( _ct_frames_pid == BASHPID )) || return 0
    _ct_subshell_exiting=1
    local _ct_prev_trap _ct_chain=""
    local -a _ct_words
    _ct_prev_trap=$(trap -p EXIT)
    if [[ -n "$_ct_prev_trap" ]]; then
        # `trap -p` prints `trap -- 'action' EXIT`, quoted for reuse as input.
        eval "_ct_words=($_ct_prev_trap)"
        _ct_chain="; ${_ct_words[2]}"
    fi
    # shellcheck disable=SC2064 # the chained action is expanded on purpose
    trap -- "_ct_subshell_exit_trap \"\$?\"${_ct_chain}" EXIT
}

# DEBUG trap handler — fires before each simple command
_ct_debug_trap() {
    # Capture $? immediately — before any command can clobber it. It is the
    # status given to a frame this trap finds gone without its RETURN trap
    # having closed it (see "Open frames").
    local _ct_status=$?

    # A subshell that is exiting runs no more script commands.
    (( _ct_subshell_exiting )) && return 0

    # BASH_SOURCE[0] is the recorder itself when in the trap function
    # BASH_SOURCE[1] is the actual source file being executed
    local _ct_file="${BASH_SOURCE[1]}"
    local _ct_line="${BASH_LINENO[0]}"
    local _ct_depth=${#FUNCNAME[@]}

    # A trap action is not a script command. Bash runs the DEBUG trap before
    # each command of the EXIT trap's action too, with BASH_SOURCE naming the
    # script and LINENO counting lines of the action string, which would add
    # a STEP at a line the script never ran (and a RETURN, when `exit` in a
    # sourced file has already unwound that file's frame). While a trap
    # action runs, BASH_COMMAND is "the command executing at the time of the
    # trap", which is the recorder's own script-load command below: it is
    # never a command of the script itself.
    # See: https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html#index-BASH_005fCOMMAND
    [[ "$BASH_COMMAND" == "$_ct_load_command" ]] && return 0

    # Skip events from the recorder itself or when inside the RETURN trap
    [[ "$_ct_file" == "$0" ]] && return 0
    [[ "$_ct_file" == "" ]] && return 0
    (( _ct_in_return_trap )) && return 0

    # Register new source files
    if [[ -z "${_ct_registered_paths[$_ct_file]+x}" ]]; then
        printf 'PATH file=%s\n' "$_ct_file" >&3
        _ct_registered_paths["$_ct_file"]=1
    fi

    # The first DEBUG trap of a subshell: the frames already open belong to
    # the parent, which closes them; this subshell closes those it opens.
    if (( BASHPID != _ct_frames_pid )); then
        _ct_frames_pid=$BASHPID
        _ct_subshell_base=${#_ct_frame_depths[@]}
    fi

    # Frames deeper than this command are gone. A function's frame has
    # already been closed by the RETURN trap; what is left is a sourced
    # file's frame, or a frame whose RETURN trap the script replaced. The
    # first DEBUG trap shallower than a sourced file is the one bash runs
    # for the action of the RETURN trap `source` is about to run, so it
    # leaves the frame for that trap (see "Open frames").
    local _ct_deferred=0
    local _ct_n=${#_ct_frame_depths[@]}
    if (( _ct_n > 0 )) && (( _ct_frame_depths[_ct_n - 1] > _ct_depth )); then
        if [[ "${_ct_frame_kinds[_ct_n - 1]}" == s ]] &&
           (( _ct_frame_depths[_ct_n - 1] == _ct_depth + 1 && _ct_deferred_pop != _ct_n )); then
            _ct_deferred_pop=$_ct_n
            _ct_deferred=1
        else
            _ct_close_frames_deeper_than "$_ct_depth" "$_ct_status"
        fi
    fi

    if (( ! _ct_deferred )); then
        _ct_note_command "$_ct_depth" "$BASH_COMMAND"
        # `exit` in a subshell ends it inside whatever functions it is in.
        if (( BASHPID != _ct_recorder_pid )) && [[ "$BASH_COMMAND" =~ $_ct_exit_re ]]; then
            _ct_begin_subshell_exit
        fi
    fi

    # Detect function call: depth increased compared to previous trap invocation
    # FUNCNAME[0] is _ct_debug_trap, FUNCNAME[1] is the function we're inside
    if (( _ct_depth > _ct_prev_depth )); then
        local _ct_func_name="${FUNCNAME[1]}"

        # Structural frames that are always present in FUNCNAME but are NOT
        # user-visible function calls:
        #   FUNCNAME[N-1] = main   — the recorder's own top-level frame
        #   FUNCNAME[N-2] = source — the recorder's synthetic script-load
        #                            wrapper (`source "$_ct_target_script"`)
        #   FUNCNAME[0]   = _ct_debug_trap — this DEBUG-trap frame itself
        # A genuine user-visible function entry therefore only exists once
        # FUNCNAME contains at least one frame *between* the trap frame and
        # the script-load `source` frame, i.e. _ct_depth >= 4.
        #
        # This mirrors the zsh recorder's guard (`_ct_depth >= 2`), which
        # excludes the script-load transition (zsh depth 0 -> 1) so that
        # only real user-frame entries (zsh depth >= 2) are counted. In bash
        # the same three non-user frames (main, script-load source, trap)
        # shift the equivalent threshold to 4. We deliberately use this
        # stack-depth invariant rather than a `!= "source"` name check: a
        # user is free to define a function literally named `source`, and
        # such a call would (correctly) appear at _ct_depth >= 4 and be
        # counted, while the synthetic script-load wrapper at _ct_depth == 3
        # is suppressed regardless of its name.
        local _ct_is_user_call=0
        if (( _ct_depth >= 4 )); then
            _ct_is_user_call=1
        fi

        # Register function if first time seen.  Registration is intentionally
        # NOT gated by _ct_is_user_call: the script-load `source` wrapper must
        # still appear in the function table (FUNC event), it just must not
        # surface as a counted CALL below.
        if [[ -z "${_ct_registered_funcs[$_ct_func_name]+x}" ]]; then
            printf 'FUNC name=%s file=%s line=%d\n' "$_ct_func_name" "$_ct_file" "$_ct_line" >&3
            _ct_registered_funcs["$_ct_func_name"]=1
        fi

        # The synthetic script-load `source` wrapper (_ct_depth == 3) is
        # registered in the function table above but must NOT surface as a
        # counted CALL — nor stage its ARG events (the wrapper carries the
        # script's own $1..$N, which would otherwise be misattributed to a
        # phantom call).  Only emit ARG + CALL for genuine user-visible
        # function entries.  This matches the zsh recorder, whose
        # `_ct_depth >= 2` guard likewise suppresses the script-load call
        # while keeping later user-function calls.
        if (( _ct_is_user_call )); then
            # A frame still open at this depth or deeper is gone: its
            # RETURN trap never ran. Closed before the ARG events, which
            # belong to the CALL below.
            _ct_close_frames_deeper_than "$(( _ct_depth - 1 ))" "$_ct_status"

            # Stage positional parameters as ARG events BEFORE the CALL event.
            #
            # When `extdebug` is on, bash maintains `BASH_ARGC` (per-frame argv
            # count, top-of-stack = current frame) and `BASH_ARGV` (flat stack
            # of all positional parameters, reversed: BASH_ARGV[0] is the LAST
            # positional parameter of the innermost frame).
            # See: https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html
            #
            # Inside this DEBUG trap, FUNCNAME[0] = `_ct_debug_trap` and
            # FUNCNAME[1] is the user function we are inside.  Since we read
            # `_ct_func_name` from FUNCNAME[1], we likewise need BASH_ARGC[1]
            # (the user-function frame's argc) — BASH_ARGC[0] would be the
            # arg count of `_ct_debug_trap` itself, which is 0.  We also need
            # to skip BASH_ARGV[0..BASH_ARGC[0]-1] (the trap-frame argv slots,
            # if any) before reading the user-function frame's argv.
            local _ct_trap_argc=0
            if (( ${#BASH_ARGC[@]} > 0 )); then
                _ct_trap_argc="${BASH_ARGC[0]}"
            fi
            if (( ${#BASH_ARGC[@]} > 1 )); then
                local _ct_argc="${BASH_ARGC[1]}"
                local _ct_argv_base=$_ct_trap_argc
                local _ct_arg_idx
                # BASH_ARGV is reversed: the user-function frame's $1 lives at
                # index (argv_base + argc - 1), $2 at (argv_base + argc - 2),
                # and so on.  We walk forward 1..argc to emit ARG name=$1,
                # name=$2, ... in canonical order.
                for (( _ct_arg_idx = 1; _ct_arg_idx <= _ct_argc; _ct_arg_idx++ )); do
                    local _ct_arg_slot=$(( _ct_argv_base + _ct_argc - _ct_arg_idx ))
                    local _ct_arg_val="${BASH_ARGV[$_ct_arg_slot]:-}"
                    local _ct_arg_quoted
                    _ct_arg_quoted=$(_ct_quote_value "$_ct_arg_val")
                    printf 'ARG name=$%d value=%s type=s\n' "$_ct_arg_idx" "$_ct_arg_quoted" >&3
                done
            fi

            # Emit CALL event (drains the ARG events staged above)
            printf 'CALL name=%s\n' "$_ct_func_name" >&3
            if [[ "$_ct_func_name" == source ]]; then
                _ct_push_frame "$_ct_depth" "$_ct_func_name" s
            else
                _ct_push_frame "$_ct_depth" "$_ct_func_name" f
            fi
        fi
    fi

    _ct_prev_depth=$_ct_depth

    # Detect output commands from BASH_COMMAND
    local _ct_cmd="$BASH_COMMAND"
    if [[ "$_ct_cmd" == echo\ * ]] || [[ "$_ct_cmd" == printf\ * ]] || [[ "$_ct_cmd" == print\ * ]]; then
        # Extract the content (approximate — just use the full command)
        local _ct_write_content
        _ct_write_content=$(_ct_quote_value "$_ct_cmd")
        printf 'WRITE content=%s\n' "$_ct_write_content" >&3
    fi

    # Emit step event
    printf 'STEP file=%s line=%d\n' "$_ct_file" "$_ct_line" >&3

    # Capture variables at this step
    _ct_capture_variables

    return 0  # Don't skip the command
}

# ERR trap handler — fires when a command returns non-zero exit status.
# BASH_SOURCE[0] is this file (recorder.sh, where the function is defined).
# BASH_SOURCE[1] is the file where the failing command was executed.
_ct_err_trap() {
    local _ct_status=$?
    local _ct_cmd="$BASH_COMMAND"
    local _ct_file="${BASH_SOURCE[1]}"

    # Skip errors from recorder internals
    [[ "$_ct_file" == "$0" ]] && return
    [[ -z "$_ct_file" ]] && return

    # Bash ran the DEBUG trap for this trap's action just before it, with
    # BASH_COMMAND unchanged, and `_ct_note_command` counted that as one more
    # sighting of the remembered command. Take it back, so that only the
    # sighting before the RETURN trap's action is counted (`outer() { inner; }`
    # with a failing `inner` would otherwise count inner's `return $x` twice
    # in outer and evaluate it against outer's variables).
    if (( _ct_cmd_hits > 0 )); then
        _ct_cmd_hits=$(( _ct_cmd_hits - 1 ))
    fi

    local _ct_quoted_cmd
    _ct_quoted_cmd=$(_ct_quote_value "$_ct_cmd")
    printf 'ERROR cmd=%s status=%d\n' "$_ct_quoted_cmd" "$_ct_status" >&3

    # With `errexit` on, the shell exits right after this trap: bash runs the
    # ERR trap under exactly the conditions under which `set -e` exits. In a
    # subshell that ends it inside whatever functions it is in.
    # See: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
    if (( BASHPID != _ct_recorder_pid )) && [[ "$-" == *e* ]]; then
        _ct_begin_subshell_exit
    fi
    return 0
}

# RETURN trap handler: closes the frame of a function that returns.
#
# Bash runs the RETURN trap "each time a shell function or a script executed
# with the . or source builtins finishes executing", in the returning
# function's own shell, with the function still on FUNCNAME, before
# execution resumes in the caller. That is the one point that sees every
# return, including that of a function called in a subshell (`$(f)`,
# `(f)`), which ends before any later command could show the stack
# shrinking, and that of a function used as a condition (`if f`), whose
# status no later command reads. It is inherited by functions and subshells
# because `functrace` is set.
# See: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-trap
#      https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html (-T)
#
# `$?` here is the status of the last command the function ran, which is the
# function's status unless it ended with `return N`: bash runs the trap
# before `$?` takes N. That case is taken from the `return` command the DEBUG
# trap saw (`_ct_frame_status`), evaluated against the function's positional
# parameters, which the trap action passes as its arguments.
#
# The trap also runs when a sourced file finishes, after bash has removed the
# file's FUNCNAME entry, so FUNCNAME and the depth then describe the caller.
# Three cases are told apart:
#   - a sourced file whose frame is open (it ran a command, so it got a
#     CALL) sits one level below the trap: close it;
#   - a sourced file that ran no command (only definitions) has no frame;
#     its `source` command was seen twice at this depth: nothing to close;
#   - otherwise, an open function frame at this depth with this name is the
#     function returning: close it.
_ct_return_trap() {
    local _ct_status=$?
    # A recorder function returned (the recorder's own script-load `source`
    # also ends here, with the recorder as the file).
    [[ "${BASH_SOURCE[1]}" == "$0" ]] && return 0
    (( _ct_in_return_trap || _ct_subshell_exiting || _ct_exit_emitted )) && return 0
    _ct_in_return_trap=1

    local _ct_depth=${#FUNCNAME[@]}
    local _ct_n=${#_ct_frame_depths[@]}
    local _ct_top_depth=-1 _ct_top_kind="" _ct_top_name=""
    if (( _ct_n > 0 )); then
        _ct_top_depth=${_ct_frame_depths[_ct_n - 1]}
        _ct_top_kind=${_ct_frame_kinds[_ct_n - 1]}
        _ct_top_name=${_ct_frame_names[_ct_n - 1]}
    fi

    if [[ "$_ct_top_kind" == s ]] && (( _ct_top_depth == _ct_depth + 1 )); then
        _ct_frame_status "$_ct_top_depth" s "$_ct_status" ${1+"$@"}
        _ct_pop_frame "$_ct_frame_status_result"
        _ct_prev_depth=$_ct_depth
    elif (( _ct_cmd_depth == _ct_depth && _ct_cmd_hits >= 2 )) &&
         [[ "$_ct_cmd_text" =~ $_ct_source_re ]]; then
        _ct_prev_depth=$_ct_depth
    elif [[ "$_ct_top_kind" == f && "$_ct_top_name" == "${FUNCNAME[1]}" ]] &&
         (( _ct_top_depth == _ct_depth )); then
        _ct_frame_status "$_ct_depth" f "$_ct_status" ${1+"$@"}
        _ct_pop_frame "$_ct_frame_status_result"
        _ct_prev_depth=$(( _ct_depth - 1 ))
    fi

    # The remembered command belonged to the frame that just ended.
    _ct_cmd_depth=-1
    _ct_cmd_text=""
    _ct_cmd_hits=0
    _ct_deferred_pop=-1
    _ct_in_return_trap=0
    return 0
}

# Set once the EXIT event has been written, so it is written exactly once.
_ct_exit_emitted=0

# Emit the EXIT event for exit status $1: the event that closes the
# `<script>` frame and carries the script's exit code.
#
# It has two callers. The EXIT trap covers a script that calls `exit`, which
# ends this shell inside the `source` below, so no line after `source` runs.
# The call after `source` covers a script that runs off its end, and is the
# fallback for a script that replaced the EXIT trap with its own (the trap
# chaining limitation in the Shell Recorder spec). Whichever runs first
# writes the event; the flag makes the other a no-op.
#
# Only the recorder's own shell writes it. The EXIT trap is not run by a
# subshell in bash, but the PID test keeps a subshell's `exit` from ever
# being mistaken for the script's exit.
# See: https://www.gnu.org/software/bash/manual/html_node/Command-Execution-Environment.html
_ct_emit_exit() {
    local _ct_code="$1"
    (( BASHPID == _ct_recorder_pid )) || return 0
    (( _ct_exit_emitted )) && return 0
    _ct_exit_emitted=1

    # Nothing after this point belongs to the script: stop recording before
    # writing the event, so it is the last one in the stream.
    trap - DEBUG
    trap - RETURN
    trap - ERR

    printf 'EXIT code=%d\n' "$_ct_code" >&3
}

trap '_ct_debug_trap' DEBUG
# "$@" hands the returning function's positional parameters to the handler,
# for a `return` whose argument refers to them. It is spelled ${1+"$@"}
# because bash before 4.4 reports an empty "$@" as an unbound variable under
# `set -u`, which would end a script that uses `set -u` at its first return
# (bash 4.0 prints "$@: unbound variable"; 4.4 and later expand it to nothing).
# See: https://tiswww.case.edu/php/chet/bash/CHANGES (bash-4.4, nounset)
trap '_ct_return_trap ${1+"$@"}' RETURN
trap '_ct_err_trap' ERR
# `$?` in an EXIT trap is the status the shell is exiting with: the argument
# of `exit`, or the status of the last command when it is omitted.
# See: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-trap
trap '_ct_emit_exit "$?"' EXIT

# Execute the target script by sourcing it so traps apply
# Set positional parameters for the script
set -- "$@"
# `_ct_load_command` must be the exact text of the `source` command below:
# the DEBUG trap compares BASH_COMMAND against it to recognise trap actions.
# shellcheck disable=SC2016 # the unexpanded command text is the point
_ct_load_command='source "$_ct_target_script"'
source "$_ct_target_script"
_ct_exit_code=$?

_ct_emit_exit "$_ct_exit_code"

exit "$_ct_exit_code"

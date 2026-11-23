#!/usr/bin/env bash
# ct-bash-recorder: Records a Bash script execution via trap-based instrumentation.
# FD 3 must be open and connected to ct-shell-trace-writer's stdin. The
# recorder moves that channel to a free descriptor of 10 or above before the
# script runs (see `_ct_events_fd` below).

set -o functrace    # DEBUG trap inherited by functions
set -o errtrace     # ERR trap inherited by functions
shopt -s extdebug   # Required for DEBUG trap in functions + RETURN trap

# The path of this file, by which the traps tell the recorder's own commands
# from the script's. `$0` cannot serve: it is set to the script's path below.
_ct_recorder_file=${BASH_SOURCE[0]}

_ct_target_script="$1"
shift  # remaining args are the script's arguments

if [[ -z "$_ct_target_script" ]]; then
    echo "Usage: recorder.sh <script.sh> [args...]" >&2
    exit 1
fi

# Resolve absolute path (already done when Bash 4 re-entered the recorder
# below, and done again it could come out different, e.g. under CDPATH).
if [[ -z "${_ct_reentered_with_argv0:-}" ]]; then
    _ct_target_script="$(cd "$(dirname "$_ct_target_script")" && pwd)/$(basename "$_ct_target_script")"
fi

# Give the script its own `$0`.
#
# The script is sourced into this shell, where `$0` is this file. A script
# that runs its entry point only when executed
# (`[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"`) would then do nothing,
# and one that finds files beside itself (`$(dirname "$0")`) would look
# beside the recorder. Spec `Recording-Backends/Shell-Recorder.md`,
# "Interactive Preservation": the script behaves as when run directly.
# `$0` is set to the absolute path the script is sourced by, so that it
# equals `${BASH_SOURCE[0]}` in the script's top level, as in a direct run
# (`bash ./x.sh` gives both as `./x.sh`; here both are absolute).
#
# Bash 5.0 and later set `$0` by assignment to `BASH_ARGV0`, done just
# before the script is sourced (at the end of this file). Bash 4 has no
# such variable, and the only way to choose `$0` there is the name argument
# of `bash -c <string> <name>`, so the recorder re-enters itself once, as a
# file sourced by `bash -c` with the script's path as that name, before it
# does anything else (FD 3 is inherited unchanged). The script sees the
# same stack depth either way: the recorder's bottom frame is then `source`
# instead of `main`, and the traps count frames, not names. The marker
# variable is a shell variable, not exported, and exists before the
# variable baseline is taken, so it is never recorded as the script's.
# `BASH_EXECUTION_STRING`, which only a `-c` shell has, is removed, as a
# direct run has none.
# See: https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html#index-BASH_005fARGV0
# See: https://www.gnu.org/software/bash/manual/html_node/Invoking-Bash.html (-c)
if (( BASH_VERSINFO[0] < 5 )); then
    if [[ -z "${_ct_reentered_with_argv0:-}" ]]; then
        # shellcheck disable=SC2016 # expanded by the re-entered shell
        exec "$BASH" -c '_ct_reentered_with_argv0=1; source "$1" "$0" "${@:2}"' \
            "$_ct_target_script" "$_ct_recorder_file" "$@"
    fi
    unset BASH_EXECUTION_STRING
fi

# Move the event channel off FD 3 before the script runs.
#
# The script is sourced into this shell, so it shares our descriptors. FD 3
# is one scripts take for themselves (`exec 3>&1` keeps a handle on the
# original standard output; `exec 3>&-` closes it), and every event written
# to `>&3` would then go wherever the script pointed it -- onto the user's
# terminal, or nowhere -- and the trace would end at that line. Spec
# `Recording-Backends/Shell-Recorder.md`, "Interactive Preservation": the
# trace channel is invisible to the script and the user.
#
# The channel is duplicated onto the lowest free descriptor of 10 or above
# and FD 3 is closed, leaving the script the descriptors a script normally
# uses (0-9) and the state it would have without the recorder. A script can
# still redirect or close a descriptor of 10 or above by number; that is
# the residual risk the spec names. Bash's `exec {var}>&3`, which picks the
# descriptor the same way, needs Bash 4.1, and the recorder supports 4.0,
# so the free descriptor is found by probing: `: >&N` fails exactly when N
# is not open. A descriptor Bash itself holds during the probe (its saved
# copy of FD 2) reads as open and is skipped, which only moves the choice up.
# See: https://www.gnu.org/software/bash/manual/html_node/Redirections.html
if ! { : >&3; } 2>/dev/null; then
    echo "recorder.sh: FD 3 is not open; run the recorder through launcher.sh" >&2
    exit 1
fi
_ct_events_fd=10
while { : >&"$_ct_events_fd"; } 2>/dev/null; do
    if (( ++_ct_events_fd > 255 )); then
        echo "recorder.sh: no free file descriptor between 10 and 255 for the event stream" >&2
        exit 1
    fi
done
eval "exec $_ct_events_fd>&3 3>&-"

# Quote a value for the wire protocol, without a subshell: sets `_ct_qv`.
#
# The writer ends an unquoted value at the first whitespace and reads a
# double-quoted value with `\"` and `\\` escapes (`parse_key_values` in
# crates/ct-shell-trace-writer/src/wire_protocol.rs). Every free-form value
# an event carries goes through here: variable and argument values, command
# texts, and every path and function name, which may hold a space, a tab, a
# `"` or a `\` like any other string. A newline cannot be carried by this
# line protocol at all, quoted or not.
#
# It runs inside the DEBUG trap, so it sets a variable instead of printing
# into a `$(...)` that would fork each time; and a path or a function name,
# which every STEP and CALL repeats, is quoted once, when it is registered,
# and read back from `_ct_registered_paths` / `_ct_registered_funcs`. A
# glob rather than `=~`, so that quoting never touches the script's
# BASH_REMATCH. Kept the same as `_ct_inline_quote` in recorder.zsh.
_ct_inline_quote() {
    _ct_qv="$1"
    if [[ "$_ct_qv" == *[[:space:]\"\\]* ]]; then
        _ct_qv="${_ct_qv//\\/\\\\}"
        _ct_qv="${_ct_qv//\"/\\\"}"
        _ct_qv="\"$_ct_qv\""
    fi
}

# Print the quoted form of a value (see `_ct_inline_quote`).
_ct_quote_value() {
    local _ct_qv
    _ct_inline_quote "$1"
    printf '%s' "$_ct_qv"
}

# Make a source file's path absolute, without a subshell: sets `_ct_ap`.
#
# Bash reports a sourced file in BASH_SOURCE by the path it was opened by:
# `./helpers.sh` for `source ./helpers.sh`, `../bin/h.sh` for `source h.sh`
# found through a `PATH` entry `../bin`. Such a path names the file only in
# the working directory the script had at that moment, and the trace writer
# copies sources after the script has ended, from its own directory. So
# the DEBUG trap resolves a file the first time it sees it, against the
# directory the path is relative to (`_ct_resolve_source_file`), and every
# event carries the result (spec `Recording-Backends/Shell-Recorder.md`, "Wire
# Protocol (FD 3)"; codetracer-pm issue
# `2026-11-15-shell-recorders-record-a-relatively-sourced-file-by-its-relative-path-and-may-not-copy-it`).
#
# The path is joined to the logical `$PWD` and normalised lexically: empty
# and `.` components are dropped and `..` removes the component before it
# (and nothing at `/`). That is the form the main script gets from the
# logical `cd "$(dirname ...)" && pwd` above, so the same file reached both
# ways is one path; it is also what `cd` does to `..`.
# See: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-cd
#
# The system resolves a `..` that follows a symlinked directory from the
# link's target instead, so there the folded path names another file than
# the one Bash opened, or none (`$(dirname "$0")/../lib/x.sh` for a script
# in a symlinked `bin`). When the joined path names an existing file that
# the folded one is not (`-ef`, a stat of each, no fork), the joined path
# is kept as it is: absolute, and naming the file Bash opened.
#
# It runs inside the DEBUG trap, so it forks nothing (no `$(...)`, which
# `functrace` would also trace), uses only quoted parameter expansions and
# `case` (unaffected by the script's IFS, `noglob`, `extglob` or
# `nocasematch`), and reads `$PWD` with a default for a script under
# `set -u` that unset it; without a working directory a relative path is
# left as it is.
_ct_absolute_path() {
    local _ct_rest="$1" _ct_comp="" _ct_out="" _ct_joined
    if [[ "$_ct_rest" != /* ]]; then
        if [[ -z "${PWD:-}" ]]; then
            _ct_ap="$_ct_rest"
            return 0
        fi
        _ct_rest="$PWD/$_ct_rest"
    fi
    _ct_joined="$_ct_rest"
    while [[ -n "$_ct_rest" ]]; do
        _ct_comp="${_ct_rest%%/*}"
        if [[ "$_ct_rest" == */* ]]; then
            _ct_rest="${_ct_rest#*/}"
        else
            _ct_rest=""
        fi
        case "$_ct_comp" in
            "" | .) ;;
            ..) _ct_out="${_ct_out%/*}" ;;
            *) _ct_out="$_ct_out/$_ct_comp" ;;
        esac
    done
    _ct_ap="${_ct_out:-/}"
    if [[ -e "$_ct_joined" && ! "$_ct_ap" -ef "$_ct_joined" ]]; then
        _ct_ap="$_ct_joined"
    fi
}

# The working directories `source` and `.` commands ran in, newest last,
# each once: `_ct_source_dirs` holds them by the order they were last used
# (a sparse array; `_ct_source_dir_index` maps a directory to its index,
# and `_ct_source_dir_next` is the next index to use).
#
# Bash runs no DEBUG trap for a function definition, so a sourced file that
# only defines functions is first seen when one of them is called, and by
# then the script may have changed directory again. Its relative path is
# then resolved against the directory of the newest `source` command it
# names a file from (`_ct_resolve_source_file`).
_ct_source_dirs=()
declare -A _ct_source_dir_index
_ct_source_dir_next=0

# Remember `$PWD` as the directory of a `source` or `.` command the DEBUG
# trap is about to run. A glob, not `=~`, which would change the script's
# BASH_REMATCH; one that also matches a command that only starts with one
# of these words just adds a directory to try.
_ct_note_source_dir() {
    case "$1" in
        source[[:space:]]* | .[[:space:]]* | builtin[[:space:]]* | command[[:space:]]*) ;;
        *) return 0 ;;
    esac
    local _ct_dir="${PWD:-}"
    [[ -n "$_ct_dir" ]] || return 0
    local _ct_old="${_ct_source_dir_index[$_ct_dir]:-}"
    if [[ -n "$_ct_old" ]]; then
        (( _ct_old == _ct_source_dir_next - 1 )) && return 0
        unset "_ct_source_dirs[$_ct_old]"
    fi
    _ct_source_dirs[_ct_source_dir_next]=$_ct_dir
    _ct_source_dir_index["$_ct_dir"]=$_ct_source_dir_next
    _ct_source_dir_next=$(( _ct_source_dir_next + 1 ))
}

# The absolute path of the source file BASH_SOURCE reports as $1, seen for
# the first time in a frame named $2: sets `_ct_ap`.
#
# In the file's own `source` frame its first command has not run yet, so
# `$PWD` is the directory `source` opened it in. Anywhere else (a function
# of a file that only defines functions) the file was opened by an earlier
# `source`, and the newest directory of one in which the path names a
# regular file is taken; when there is none, `$PWD`.
_ct_resolve_source_file() {
    if [[ "$1" != /* && "$2" != source ]]; then
        local _ct_i
        for (( _ct_i = _ct_source_dir_next - 1; _ct_i >= 0; _ct_i-- )); do
            [[ -n "${_ct_source_dirs[_ct_i]+x}" ]] || continue
            if [[ -f "${_ct_source_dirs[_ct_i]}/$1" ]]; then
                _ct_absolute_path "${_ct_source_dirs[_ct_i]}/$1"
                return 0
            fi
        done
    fi
    _ct_absolute_path "$1"
}

# Emit START event
_ct_inline_quote "$_ct_target_script"
_ct_target_script_q=$_ct_qv
_ct_inline_quote "$BASH_VERSION"
printf 'START program=%s shell=bash shell_version=%s\n' "$_ct_target_script_q" "$_ct_qv" >&"$_ct_events_fd"

# Register the main script path
printf 'PATH file=%s\n' "$_ct_target_script_q" >&"$_ct_events_fd"

# The source files already registered, by the path BASH_SOURCE reports,
# each mapped to the quoted form of its absolute path for the PATH, FUNC
# and STEP events (see `_ct_resolve_source_file`). Keyed by the reported
# string because that is all a later step offers: a function keeps the
# BASH_SOURCE it was defined with, and a step in it after another `cd`
# must map to the path fixed when the file was first seen. The same key
# makes one limit inherent: two different files reported by the same
# relative string from different directories cannot be told apart, and
# both are recorded as the first one resolved. A file that only defines
# functions has a second, narrower one: it is resolved against the newest
# `source` directory that has a file by that relative path, which is
# another file when a newer `source` ran where one by that name exists.
declare -A _ct_registered_paths
_ct_registered_paths["$_ct_target_script"]=$_ct_target_script_q

# The absolute paths a PATH event has registered: two reported strings for
# one file (`./h.sh`, and `h.sh` after a `cd`) register it once.
declare -A _ct_emitted_paths
_ct_emitted_paths["$_ct_target_script"]=1

# The functions already registered, each mapped to its quoted name for the
# FUNC and CALL events
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
        printf 'VAR name=%s value=%s type=%s\n' "$_ct_varname" "$_ct_quoted_val" "$_ct_type_flag" >&"$_ct_events_fd"
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
    printf 'RETURN status=%d\n' "$1" >&"$_ct_events_fd"
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
# the script's that runs after it. Called as `_ct_subshell_exit_trap "$?" &&
# :`: a failing command that is not the last of an AND list neither runs the
# ERR trap nor ends a `set -e` shell, and the list leaves `$?` at $1.
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
    local _ct_chain=""
    # Only an EXIT action this subshell set itself: Bash goes on showing the
    # parent's EXIT trap in a subshell that has not set one, but does not run
    # it there, and neither may the recorder (`_ct_exit_trap_pid`).
    if (( _ct_exit_trap_pid == BASHPID )) && _ct_trap_action_of EXIT; then
        _ct_chain="; $_ct_reply"
    fi
    # `builtin`: the script's view of `trap` is the shadow function below.
    # shellcheck disable=SC2064 # the chained action is expanded on purpose
    builtin trap -- "_ct_subshell_exit_trap \"\$?\" && :${_ct_chain}" EXIT
}

# DEBUG trap handler — fires before each simple command
_ct_debug_trap() {
    # Capture $? immediately — before any command can clobber it. It is the
    # status given to a frame this trap finds gone without its RETURN trap
    # having closed it (see "Open frames"), and the `$?` the script's own
    # DEBUG action sees (see "Traps set by the script").
    local _ct_status=$?

    # The script's DEBUG action runs only for a command this trap records;
    # every early return below leaves it off.
    _ct_run_script_DEBUG=0
    _ct_in_script_debug=0

    # A subshell that is exiting runs no more script commands.
    (( _ct_subshell_exiting )) && return 0

    # A command of one of the script's own ERR or RETURN actions: Bash runs
    # the DEBUG trap before each of them, with BASH_COMMAND still the command
    # that triggered the trap. They are not script commands to record (nor
    # to hand to the script's DEBUG action: see `_ct_begin_script_action`).
    _ct_in_script_action_command && return 0

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
    [[ "$_ct_file" == "$_ct_recorder_file" ]] && return 0
    [[ "$_ct_file" == "" ]] && return 0
    (( _ct_in_return_trap )) && return 0

    # Register new source files by their absolute path, resolved against
    # the working directory the file was opened in (see
    # `_ct_resolve_source_file`), and keep the quoted path for the events
    # below (see `_ct_inline_quote`). The filters above compare the raw
    # string.
    _ct_note_source_dir "$BASH_COMMAND"
    local _ct_qv _ct_ap
    if [[ -z "${_ct_registered_paths[$_ct_file]+x}" ]]; then
        _ct_resolve_source_file "$_ct_file" "${FUNCNAME[1]}"
        _ct_inline_quote "$_ct_ap"
        _ct_registered_paths["$_ct_file"]=$_ct_qv
        if [[ -z "${_ct_emitted_paths[$_ct_ap]+x}" ]]; then
            _ct_emitted_paths["$_ct_ap"]=1
            printf 'PATH file=%s\n' "$_ct_qv" >&"$_ct_events_fd"
        fi
    fi
    local _ct_file_q="${_ct_registered_paths[$_ct_file]}"

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
            _ct_inline_quote "$_ct_func_name"
            _ct_registered_funcs["$_ct_func_name"]=$_ct_qv
            printf 'FUNC name=%s file=%s line=%d\n' "$_ct_qv" "$_ct_file_q" "$_ct_line" >&"$_ct_events_fd"
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
                    printf 'ARG name=$%d value=%s type=s\n' "$_ct_arg_idx" "$_ct_arg_quoted" >&"$_ct_events_fd"
                done
            fi

            # Emit CALL event (drains the ARG events staged above)
            printf 'CALL name=%s\n' "${_ct_registered_funcs[$_ct_func_name]}" >&"$_ct_events_fd"
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
        printf 'WRITE content=%s\n' "$_ct_write_content" >&"$_ct_events_fd"
    fi

    # Emit step event
    printf 'STEP file=%s line=%d\n' "$_ct_file_q" "$_ct_line" >&"$_ct_events_fd"

    # Capture variables at this step
    _ct_capture_variables

    # A command the script's own DEBUG action runs for too. It runs after
    # this function returns, as the rest of the trap action, with `$?` set
    # back to `_ct_status` (see `_ct_compose_trap_action`).
    if [[ -n "${_ct_script_traps[DEBUG]:-}" ]]; then
        _ct_run_script_DEBUG=1
        _ct_script_status_DEBUG=$_ct_status
        _ct_in_script_debug=1
    fi

    # Don't skip the command: under `extdebug` a non-zero status of the
    # DEBUG trap's action would.
    return 0
}

# ERR trap handler — fires when a command returns non-zero exit status.
# BASH_SOURCE[0] is this file (recorder.sh, where the function is defined).
# BASH_SOURCE[1] is the file where the failing command was executed.
_ct_err_trap() {
    local _ct_status=$?
    local _ct_cmd="$BASH_COMMAND"
    local _ct_file="${BASH_SOURCE[1]}"
    _ct_run_script_ERR=0

    # Skip errors from recorder internals
    [[ "$_ct_file" == "$_ct_recorder_file" ]] && return 0
    [[ -z "$_ct_file" ]] && return 0

    # From here on the failing command is the script's, so the script's own
    # ERR action runs, after this function returns, as the rest of the trap
    # action, with `$?` set back to the failing status.
    local _ct_has_script_action=0
    if [[ -n "${_ct_script_traps[ERR]:-}" ]]; then
        _ct_has_script_action=1
    fi
    _ct_script_status_ERR=$_ct_status

    # A command failing inside one of the script's own trap actions (Bash
    # runs the ERR trap inside the DEBUG and RETURN trap actions, too) is a
    # command of that action, not one of the script's commands to record.
    # The script's ERR action still runs for it, as it does without the
    # recorder.
    if (( _ct_in_script_action || _ct_in_script_debug )); then
        _ct_run_script_ERR=$_ct_has_script_action
        return 0
    fi

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
    printf 'ERROR cmd=%s status=%d\n' "$_ct_quoted_cmd" "$_ct_status" >&"$_ct_events_fd"

    # With `errexit` on, the shell exits right after this trap: bash runs the
    # ERR trap under exactly the conditions under which `set -e` exits. In a
    # subshell that ends it inside whatever functions it is in.
    # See: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html
    if (( BASHPID != _ct_recorder_pid )) && [[ "$-" == *e* ]]; then
        _ct_begin_subshell_exit
    fi

    if (( _ct_has_script_action )); then
        _ct_run_script_ERR=1
        _ct_begin_script_action ERR
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
    # The script's RETURN action runs only for a return this function
    # accepts below; every early return leaves it off.
    _ct_run_script_RETURN=0
    # A recorder function returned (the recorder's own script-load `source`
    # also ends here, with the recorder as the file).
    [[ "${BASH_SOURCE[1]}" == "$_ct_recorder_file" ]] && return 0
    (( _ct_exit_emitted )) && return 0

    # A `return` run by the script's ERR action (`trap '...; return 1' ERR`)
    # ends the action together with the function the error happened in; this
    # is that function returning. Its RETURN is recorded as any other.
    if (( _ct_in_script_action && BASHPID == _ct_script_action_pid &&
          ${#FUNCNAME[@]} <= _ct_script_action_depth )) &&
       [[ "$_ct_script_action_owner" == ERR ]]; then
        _ct_end_script_action
    fi

    # The script's RETURN action runs for every return of a script function
    # or sourced file, recorded or not, with `$?` set back to `_ct_status`.
    local _ct_has_script_action=0
    if [[ -n "${_ct_script_traps[RETURN]:-}" ]]; then
        _ct_has_script_action=1
    fi
    _ct_script_status_RETURN=$_ct_status

    # A function called by one of the script's own trap actions returning, a
    # function returning in a subshell that is exiting: not recorded.
    if (( _ct_in_script_action || _ct_in_script_debug || _ct_subshell_exiting )); then
        _ct_run_script_RETURN=$_ct_has_script_action
        return 0
    fi
    (( _ct_in_return_trap )) && return 0
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

    if (( _ct_has_script_action )); then
        _ct_run_script_RETURN=1
        _ct_begin_script_action RETURN
    fi
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
# fallback for a script that replaced the EXIT trap where the shadow `trap`
# cannot see it (see "Traps set by the script"). Whichever runs first
# writes the event; the flag makes the other a no-op.
#
# Only the recorder's own shell writes it. The EXIT trap is not run by a
# subshell in bash, but the PID test keeps a subshell's `exit` from ever
# being mistaken for the script's exit.
# See: https://www.gnu.org/software/bash/manual/html_node/Command-Execution-Environment.html
_ct_emit_exit() {
    local _ct_code="$1"
    # The script's own EXIT action, chained after this in the EXIT trap (see
    # "Traps set by the script"), runs whether or not the event is written
    # here, with `$?` the status the shell exits with.
    _ct_run_script_EXIT=1
    _ct_script_status_EXIT=$_ct_code
    (( BASHPID == _ct_recorder_pid )) || return 0
    (( _ct_exit_emitted )) && return 0
    _ct_exit_emitted=1

    # Before the traps are removed: a trap of the recorder's that the script
    # replaced behind its back leaves a partial recording, which is said here.
    _ct_report_replaced_traps

    # Nothing after this point belongs to the script: stop recording before
    # writing the event, so it is the last one in the stream. `builtin`
    # bypasses the shadow `trap` below, which would keep them.
    builtin trap - DEBUG
    builtin trap - RETURN
    builtin trap - ERR

    printf 'EXIT code=%d\n' "$_ct_code" >&"$_ct_events_fd"
}

# ---------------------------------------------------------------------------
# Traps set by the script
# ---------------------------------------------------------------------------
# The recorder works through its DEBUG, ERR and RETURN traps, and Bash has
# one trap per condition: a `trap` command of the script would replace the
# recorder's, and the recording would go on silently without the events it
# produces (spec "Limitations", "Signal Handler Conflicts"). So the recorder
# shadows the `trap` builtin with the function `trap` below.
#
# For DEBUG, ERR and RETURN the function does not replace the recorder's
# trap: it keeps the script's action in `_ct_script_traps` and installs a
# trap action that runs the recorder's handler and then the script's action
# (`_ct_compose_trap_action`). The script's action is part of the trap
# action itself rather than called from a function, so that it runs exactly
# where Bash would run it: `$LINENO` is the line of the triggering command,
# FUNCNAME and the positional parameters are the interrupted function's,
# and `return` returns from that function, as in the common
# `trap 'echo "failed at $LINENO"; return 1' ERR`.
#
# EXIT is kept the same way in the recorder's own shell, where the
# recorder's EXIT trap writes the EXIT event of a script that calls `exit`:
# the script's EXIT action runs after the event is written, unrecorded, as
# the rest of the script's EXIT trap always was. A subshell has no EXIT trap
# of the recorder's (Bash resets it there), so its EXIT goes to the builtin;
# the subshell's PID is noted in `_ct_exit_trap_pid`, for
# `_ct_begin_subshell_exit`. Every other condition goes to the builtin
# unchanged.
#
# Listing (`trap`, `trap -p`, `trap -P`) shows the script its own actions
# for DEBUG, ERR, RETURN and EXIT and hides the recorder's, so that
# `saved=$(trap -p ERR)` ... `eval "$saved"` behaves as without the
# recorder.
#
# What the script can still tell apart, and the recorder's answer to each:
#
# - `builtin trap` and `command trap` bypass a shell function, and so does
#   `trap` in POSIX mode (`set -o posix`), where special builtins are found
#   before functions. A trap of the recorder's replaced that way is reported
#   at exit (`_ct_report_replaced_traps`).
# - The script's actions run under the recorder's `functrace`, `errtrace`
#   and `extdebug`, so they are inherited by functions and subshells as if
#   the script had run `set -E -T` itself.
# - Bash runs the DEBUG trap before the action of every RETURN trap, and
#   the recorder always has one: the script's DEBUG action also runs once
#   when each function or sourced file returns.
# - The status of the script's DEBUG action is not the status of the DEBUG
#   trap: under `extdebug` a non-zero status skips the next command, which
#   the script did not ask for unless it enabled `extdebug` itself. A
#   `return` in the action still ends the trap with its status, as Bash's
#   `extdebug` documents.
# See: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-trap
#      https://www.gnu.org/software/bash/manual/html_node/The-Shopt-Builtin.html (extdebug)
#      https://www.gnu.org/software/bash/manual/html_node/Bash-POSIX-Mode.html

# The result of the helper functions below that return a string.
_ct_reply=""

# Whether this Bash's `trap` has `-P` (print the action only; Bash 5.3).
# Asked before the recorder installs any trap: there is none to print yet.
_ct_trap_has_print_only=0
if builtin trap -P EXIT >/dev/null 2>&1; then
    _ct_trap_has_print_only=1
fi

# The script's own action for each condition the recorder virtualises, by
# condition name; a condition the script has not trapped has no entry, and
# one it ignores (`trap '' ERR`) has an empty action.
declare -A _ct_script_traps=()

# The recorder's handler for each condition it traps, and the full action it
# installed last (handler plus the script's action), for comparing with what
# Bash has at exit.
# shellcheck disable=SC2016 # the actions are expanded when the traps run
declare -A _ct_recorder_handlers=(
    [DEBUG]='_ct_debug_trap'
    # "$@" hands the returning function's positional parameters to the
    # handler, for a `return` whose argument refers to them. It is spelled
    # ${1+"$@"} because bash before 4.4 reports an empty "$@" as an unbound
    # variable under `set -u`, which would end a script that uses `set -u` at
    # its first return (bash 4.0 prints "$@: unbound variable"; 4.4 and later
    # expand it to nothing).
    # See: https://tiswww.case.edu/php/chet/bash/CHANGES (bash-4.4, nounset)
    [RETURN]='_ct_return_trap ${1+"$@"}'
    [ERR]='_ct_err_trap'
    # `$?` in an EXIT trap is the status the shell is exiting with: the
    # argument of `exit`, or the status of the last command when omitted.
    [EXIT]='_ct_emit_exit "$?"'
)
declare -A _ct_installed_traps=()

# Set by each handler: whether the script's action for its condition runs
# this time (1) or not (0), and the `$?` it runs with. One pair per
# condition, because the handlers of one condition run inside the trap
# action of another (Bash runs ERR inside a DEBUG or RETURN action, and
# RETURN when a function called by an ERR action returns).
_ct_run_script_DEBUG=0
_ct_run_script_ERR=0
_ct_run_script_RETURN=0
_ct_run_script_EXIT=0
_ct_script_status_DEBUG=0
_ct_script_status_ERR=0
_ct_script_status_RETURN=0
_ct_script_status_EXIT=0

# The PID of the shell in which the script last set or reset an EXIT trap
# through `trap`, a subshell's included; 0 for none. Bash shows a subshell
# the EXIT trap of its parent until the subshell sets its own, but does not
# run the parent's there, so `trap -p EXIT` alone cannot tell
# `_ct_begin_subshell_exit` whether the subshell has an EXIT action.
_ct_exit_trap_pid=0

# Set while the script's ERR or RETURN action runs: Bash runs the DEBUG
# trap before each of its commands and the ERR and RETURN traps inside it,
# and none of those is a script command to record. `_ct_script_action_owner`
# is the condition whose action set it, `_ct_script_action_depth` the
# FUNCNAME depth its handler ran at, `_ct_script_action_cmd` BASH_COMMAND
# then (the command that triggered the trap, which Bash keeps for the whole
# action) and `_ct_script_action_pid` the shell it runs in.
_ct_in_script_action=0
_ct_script_action_owner=""
_ct_script_action_depth=-1
_ct_script_action_cmd=""
_ct_script_action_pid=0

# Set while the script's DEBUG action runs. Bash runs no DEBUG or RETURN
# trap inside a DEBUG action, but it runs the ERR trap.
_ct_in_script_debug=0

# Start the script's action for condition $1: what runs until it ends is not
# recorded. A nested action (ERR inside a RETURN action) leaves the outer
# one in charge.
_ct_begin_script_action() {
    (( _ct_in_script_action )) && return 0
    _ct_in_script_action=1
    _ct_script_action_owner="$1"
    # The caller's depth: this function's own frame is not counted.
    _ct_script_action_depth=$(( ${#FUNCNAME[@]} - 1 ))
    _ct_script_action_cmd="$BASH_COMMAND"
    _ct_script_action_pid=$BASHPID
}

_ct_end_script_action() {
    _ct_in_script_action=0
    _ct_script_action_owner=""
    _ct_script_action_depth=-1
    _ct_script_action_cmd=""
}

# The last command of every composed trap action: the script's action for
# condition $1 ran to its end. An action can also end without reaching it,
# by `return` (see `_ct_return_trap`), `break`, `continue` or `exit`; see
# `_ct_in_script_action_command` for the rest. Returns 0, so that a DEBUG
# action that falls off its end never skips a command.
_ct_script_action_end() {
    if [[ "$1" == DEBUG ]]; then
        _ct_in_script_debug=0
    elif [[ "$_ct_script_action_owner" == "$1" ]]; then
        _ct_end_script_action
    fi
    return 0
}

# Whether the DEBUG trap that calls this runs for a command of the script's
# ERR or RETURN action (status 0) rather than for a script command (1).
#
# Inside an action BASH_COMMAND stays the command that triggered it. A
# different BASH_COMMAND in the action's own shell therefore means the
# action ended without reaching `_ct_script_action_end` (a `break` or
# `continue` in it): the flag is stale, and the command is the script's. A
# subshell the action started keeps the flag, and its commands are the
# action's.
# See: https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html#index-BASH_005fCOMMAND
_ct_in_script_action_command() {
    (( _ct_in_script_action )) || return 1
    if (( BASHPID == _ct_script_action_pid )) &&
       [[ "$BASH_COMMAND" != "$_ct_script_action_cmd" ]]; then
        _ct_end_script_action
        return 1
    fi
    return 0
}

# Set _ct_reply to $1 quoted for reuse as shell input, the way `trap -p` quotes
# an action: in single quotes, with each `'` written `'\''`. The pattern and
# its replacement are variables because Bash before 4.3 and after it treat
# quotes inside a `${var//pattern/string}` replacement differently.
# See: https://tiswww.case.edu/php/chet/bash/COMPAT (compat42)
_ct_sh_single_quote() {
    local _ct_quote="'" _ct_escaped="'\\''"
    _ct_reply="'${1//$_ct_quote/$_ct_escaped}'"
}

# The trap action to install for condition $1: the recorder's handler, and,
# when the script has an action for it, that action, run only when the
# handler says so (`_ct_run_script_<cond>`).
#
# The script's action starts on the handler's line, so that `$LINENO` in its
# first line is what Bash gives a trap action of its own. Before it, `$?` is
# set back to the status the trap was entered with, by a function call
# followed by `&& :`: a failing command that is not the last of an AND list
# neither runs the ERR trap nor ends a `set -e` shell, and the list leaves
# `$?` at that command's status.
# See: https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html (-e)
#
# An action that does not parse would make the whole trap action fail to
# parse when it runs, the recorder's handler with it. Such an action is run
# through `eval` instead, which reports the same syntax error, each time,
# without taking the handler down.
_ct_compose_trap_action() {
    local _ct_sig="$1"
    local _ct_handler="${_ct_recorder_handlers[$_ct_sig]}"
    _ct_reply="$_ct_handler"
    [[ -n "${_ct_script_traps[$_ct_sig]:-}" ]] || return 0
    local _ct_prologue="case \$_ct_run_script_${_ct_sig} in 1) _ct_set_status \"\$_ct_script_status_${_ct_sig}\" && :;"
    local _ct_epilogue=$'\n;; esac\n'"_ct_script_action_end ${_ct_sig}"
    local _ct_composed="${_ct_handler}; ${_ct_prologue} ${_ct_script_traps[$_ct_sig]}${_ct_epilogue}"
    if ( builtin eval "_ct_parse_probe() { ${_ct_composed}"$'\n}' ) >/dev/null 2>&1; then
        _ct_reply="$_ct_composed"
    else
        _ct_reply="${_ct_handler}; ${_ct_prologue} builtin eval \"\${_ct_script_traps[${_ct_sig}]}\"${_ct_epilogue}"
    fi
}

# Install the recorder's trap for condition $1, with the script's action
# for it if it has one.
_ct_install_trap() {
    _ct_compose_trap_action "$1"
    _ct_installed_traps[$1]="$_ct_reply"
    builtin trap -- "$_ct_reply" "$1"
}

# Set _ct_reply to the action Bash has for condition $1 and return 0, or return
# 1 when it has none. Bash shows a parent's traps in a command
# substitution, the DEBUG, ERR and RETURN traps because they are inherited
# here (`functrace`, `errtrace`).
_ct_trap_action_of() {
    local _ct_line
    _ct_line=$(builtin trap -p "$1")
    [[ -n "$_ct_line" ]] || return 1
    # `trap -p` prints `trap -- 'action' NAME`, quoted for reuse as input.
    local -a _ct_words
    eval "_ct_words=($_ct_line)"
    _ct_reply="${_ct_words[2]}"
}

# Whether Bash's trap for condition $1 is the one the recorder installed.
_ct_trap_is_recorders() {
    _ct_trap_action_of "$1" && [[ "$_ct_reply" == "${_ct_installed_traps[$1]-}" ]]
}

# Set _ct_reply to the name of condition $1 when it is one the recorder keeps
# for itself (DEBUG, ERR, RETURN or EXIT, any case, as Bash accepts them, or
# EXIT's number 0, which Bash accepts with leading zeros and surrounding
# blanks) and return 0; return 1 for any other. Whether EXIT is the
# recorder's depends on the shell it is set in (see the `trap` function).
_ct_virtual_condition() {
    local _ct_upper="${1^^}"
    case "$_ct_upper" in
        DEBUG | ERR | RETURN | EXIT) _ct_reply="$_ct_upper"; return 0 ;;
    esac
    local _ct_zero_re='^[[:space:]]*[+-]?0+[[:space:]]*$'
    if [[ "$1" =~ $_ct_zero_re ]]; then
        _ct_reply=EXIT
        return 0
    fi
    return 1
}

# Print what `trap -p` ($2 = -p) or `trap -P` ($2 = -P) prints for
# condition $1, one the recorder keeps: the script's own action. Should the
# recorder's trap have been replaced behind its back, what Bash really has.
_ct_print_script_trap() {
    if ! _ct_trap_is_recorders "$1"; then
        # shellcheck disable=SC2064 # $2 is the -p or -P option, not an action
        builtin trap "$2" "$1"
        return
    fi
    [[ -n "${_ct_script_traps[$1]+x}" ]] || return 0
    if [[ "$2" == -P ]]; then
        printf '%s\n' "${_ct_script_traps[$1]}"
    else
        _ct_sh_single_quote "${_ct_script_traps[$1]}"
        printf 'trap -- %s %s\n' "$_ct_reply" "$1"
    fi
}

# `trap` and `trap -p` with no condition: every trap, as Bash prints them,
# with the recorder's replaced by the script's own. Bash lists EXIT first
# and DEBUG, ERR and RETURN last, after the signals, so the recorder's
# lines are cut from the two ends; the script's are printed in their place.
_ct_print_all_traps() {
    local _ct_all _ct_line
    _ct_all=$(builtin trap -p)
    if _ct_trap_is_recorders EXIT; then
        _ct_line=$(builtin trap -p EXIT)
        _ct_all="${_ct_all#"$_ct_line"}"
        _ct_all="${_ct_all#$'\n'}"
        _ct_print_script_trap EXIT -p
    fi
    _ct_line=$(builtin trap -p DEBUG ERR RETURN)
    if [[ -n "$_ct_line" && "$_ct_all" == *"$_ct_line" ]]; then
        _ct_all="${_ct_all%"$_ct_line"}"
        _ct_all="${_ct_all%$'\n'}"
    fi
    [[ -n "$_ct_all" ]] && printf '%s\n' "$_ct_all"
    local _ct_sig
    for _ct_sig in DEBUG ERR RETURN; do
        _ct_print_script_trap "$_ct_sig" -p
    done
    return 0
}

# Run the `trap` builtin with "$@" for the script's `trap` (called from it
# directly). When it fails, its message is printed as the builtin prints it
# for a command of the script, naming the script's file and line, not this
# file's: the builtin runs again in a subshell to capture the message (it
# has no effect there), and the location prefix
# ("<file>: line <n>: ") of each line is replaced.
_ct_builtin_trap() {
    # shellcheck disable=SC2064 # the script's own `trap` arguments
    builtin trap "$@" 2>/dev/null && return 0
    local _ct_rc=$? _ct_messages _ct_message
    # shellcheck disable=SC2064 # the same arguments, for the message
    _ct_messages=$(builtin trap "$@" 2>&1 >/dev/null)
    local _ct_here="${BASH_SOURCE[0]}: line "
    local _ct_there="${BASH_SOURCE[2]}: line ${BASH_LINENO[1]}: "
    local _ct_rest_re='^[0-9]+: (.*)$'
    while IFS= read -r _ct_message; do
        if [[ "$_ct_message" == "$_ct_here"* ]] &&
           [[ "${_ct_message#"$_ct_here"}" =~ $_ct_rest_re ]]; then
            _ct_message="${_ct_there}${BASH_REMATCH[1]}"
        fi
        printf '%s\n' "$_ct_message" >&2
    done <<< "$_ct_messages"
    return "$_ct_rc"
}

# Whether the options among "$@" (before `--` or the first operand) include
# both `p` and `P`, which the builtin refuses.
_ct_has_both_listing_options() {
    local _ct_arg _ct_opts=""
    for _ct_arg in "$@"; do
        case "$_ct_arg" in
            --) break ;;
            -?*) _ct_opts+="${_ct_arg#-}" ;;
            *) break ;;
        esac
    done
    [[ "$_ct_opts" == *p* && "$_ct_opts" == *P* ]]
}

# The script's view of the `trap` builtin; see "Traps set by the script".
# It takes the builtin's arguments and returns its status: options `-p`
# and `-P` list, `--` ends the options, a lone condition or `-` resets, an
# empty action ignores. Anything it does not handle itself (`-l`, an
# unknown option, a usage error) goes to the builtin as it was given, so
# that the script sees the builtin's own messages.
# See: https://www.gnu.org/software/bash/manual/html_node/Bourne-Shell-Builtins.html#index-trap
trap() {
    local -a _ct_args=("$@")
    local _ct_list=0 _ct_popt=-p _ct_opt
    while (( $# > 0 )); do
        case "$1" in
            --) shift; break ;;
            -) break ;;
            -?*)
                _ct_opt="${1#-}"
                while [[ -n "$_ct_opt" ]]; do
                    case "${_ct_opt:0:1}" in
                        p) _ct_list=1 ;;
                        P)
                            # `-P` is Bash 5.3's; older ones refuse it.
                            (( _ct_trap_has_print_only )) || { _ct_builtin_trap "${_ct_args[@]}" || return; return 0; }
                            _ct_list=1; _ct_popt=-P
                            ;;
                        *) _ct_builtin_trap "${_ct_args[@]}" || return; return 0 ;;
                    esac
                    _ct_opt="${_ct_opt:1}"
                done
                shift
                ;;
            *) break ;;
        esac
    done

    # `-p` and `-P` together: the builtin's usage error.
    if _ct_has_both_listing_options "${_ct_args[@]}"; then
        _ct_builtin_trap "${_ct_args[@]}" || return
        return 0
    fi

    # Listing.
    if (( _ct_list || $# == 0 )); then
        if (( $# == 0 )); then
            if [[ "$_ct_popt" == -P ]]; then
                _ct_builtin_trap "${_ct_args[@]}" || return
                return 0
            fi
            _ct_print_all_traps
            return
        fi
        local _ct_rc=0 _ct_spec
        for _ct_spec in "$@"; do
            if _ct_virtual_condition "$_ct_spec"; then
                _ct_print_script_trap "$_ct_reply" "$_ct_popt" || _ct_rc=$?
            else
                _ct_builtin_trap "$_ct_popt" "$_ct_spec" || _ct_rc=$?
            fi
        done
        return "$_ct_rc"
    fi

    # Setting, resetting or ignoring. `trap NAME` alone resets NAME when it
    # names a condition (not in POSIX mode, where this function is not
    # called anyway).
    local _ct_action _ct_mode
    local -a _ct_specs
    if (( $# == 1 )) && { _ct_virtual_condition "$1" || builtin trap -p "$1" >/dev/null 2>&1; }; then
        _ct_mode=reset
        _ct_specs=("$1")
    elif [[ "$1" == - ]]; then
        _ct_mode=reset
        _ct_specs=("${@:2}")
    else
        _ct_mode=assign
        _ct_action="$1"
        _ct_specs=("${@:2}")
    fi
    if (( ${#_ct_specs[@]} == 0 )); then
        _ct_builtin_trap "${_ct_args[@]}" || return
        return 0
    fi

    local -a _ct_mine=() _ct_others=()
    local _ct_spec
    for _ct_spec in "${_ct_specs[@]}"; do
        if _ct_virtual_condition "$_ct_spec"; then
            if [[ "$_ct_reply" != EXIT ]] || (( BASHPID == _ct_recorder_pid )); then
                _ct_mine+=("$_ct_reply")
                continue
            fi
            # A subshell's EXIT goes to the builtin; note whose it is.
            _ct_exit_trap_pid=$BASHPID
        fi
        _ct_others+=("$_ct_spec")
    done

    # The builtin handles the others, and reports the invalid ones; the
    # conditions the recorder keeps are set even then, as the builtin sets
    # the valid conditions of a list with an invalid one.
    local _ct_rc=0
    if (( ${#_ct_others[@]} > 0 )); then
        if [[ "$_ct_mode" == reset ]]; then
            _ct_builtin_trap - "${_ct_others[@]}" || _ct_rc=$?
        else
            _ct_builtin_trap -- "$_ct_action" "${_ct_others[@]}" || _ct_rc=$?
        fi
    fi
    for _ct_spec in ${_ct_mine[@]+"${_ct_mine[@]}"}; do
        if [[ "$_ct_mode" == reset ]]; then
            unset "_ct_script_traps[$_ct_spec]"
        else
            _ct_script_traps[$_ct_spec]="$_ct_action"
        fi
        _ct_install_trap "$_ct_spec"
    done
    return "$_ct_rc"
}

# Defense in depth: the shadow `trap` cannot see `builtin trap`, `command
# trap`, or `trap` in POSIX mode, and a trap of the recorder's replaced that
# way stops the events it produces (every step, after DEBUG; every error,
# after ERR; every function return, after RETURN). Checked once, when the
# recording ends, against what the recorder installed last.
#
# A recording known to be partial must not look complete, so the
# replacement is reported in both places it can be seen: on standard error,
# for whoever runs the recorder, and in the trace, as an `Error` event (the
# one kind of event the trace writer already has for "something went
# wrong"), for whoever reads it later. The event's status is 0: no command
# of the script failed. Ending the recording without its EXIT event would
# also make the writer warn, but would lose the script's exit code, and
# changing the wire protocol for this would make the recorders and the
# writer move together; neither is warranted.
_ct_report_replaced_traps() {
    local _ct_sig _ct_replaced=""
    for _ct_sig in DEBUG ERR RETURN; do
        _ct_trap_is_recorders "$_ct_sig" || _ct_replaced+="${_ct_replaced:+, }$_ct_sig"
    done
    [[ -n "$_ct_replaced" ]] || return 0
    local _ct_message="the script replaced the recorder's ${_ct_replaced} trap without going through \`trap\` (\`builtin trap\`, \`command trap\` or POSIX mode); events recorded through it are missing after that point"
    printf 'codetracer-bash-recorder: warning: %s\n' "$_ct_message" >&2
    printf 'ERROR cmd=%s status=0\n' "$(_ct_quote_value "$_ct_message")" >&"$_ct_events_fd"
}

# The script's `$0` (see "Give the script its own `$0`" at the top). Set
# before the traps, so the assignment is not a step of the recording.
if (( BASH_VERSINFO[0] >= 5 )); then
    BASH_ARGV0=$_ct_target_script
fi

_ct_install_trap DEBUG
_ct_install_trap RETURN
_ct_install_trap ERR
_ct_install_trap EXIT

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

#!/usr/bin/env zsh
# ct-zsh-recorder: Records a Zsh script execution via trap-based instrumentation.
# FD 3 must be open and connected to ct-shell-trace-writer's stdin. The
# recorder moves that channel to a free descriptor of 10 or above before the
# script runs (see `_ct_events_fd` below).

setopt DEBUG_BEFORE_CMD    # DEBUG trap fires BEFORE each command

# Two builtins the trap listing needs (see `_ct_trap_listing_open`): only
# those features of their modules, so that no parameter of theirs appears
# among the script's variables. Without them, the listing falls back.
zmodload -F zsh/system b:sysopen 2>/dev/null
zmodload -F zsh/files b:zf_rm 2>/dev/null
# The DEBUG trap reads $functions (zsh/parameter), which zsh creates the
# first time it is used: create it now, before the variable baseline below,
# so that it is not reported as a variable of the script.
: ${+functions}

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
# `{var}>&3` has zsh open the lowest free descriptor of 10 or above and
# store its number in the variable; FD 3 is then closed, leaving the script
# the descriptors a script normally uses (0-9). A script can still redirect
# or close a descriptor of 10 or above by number; that is the residual risk
# the spec names. The variable carries the `_ct_` prefix, so the variable
# capture skips it like the recorder's other state.
# See: https://zsh.sourceforge.io/Doc/Release/Redirection.html (Opening file descriptors in variables)
if ! { : >&3 } 2>/dev/null; then
    echo "recorder.zsh: FD 3 is not open; run the recorder through launcher.zsh" >&2
    exit 1
fi
typeset -i _ct_events_fd
exec {_ct_events_fd}>&3 3>&-

# Quote a value for the wire protocol: sets `_ct_qv` to the quoted form of
# $1. Avoids subshell $() which interacts badly with the DEBUG trap.
#
# The writer ends an unquoted value at the first whitespace and reads a
# double-quoted value with `\"` and `\\` escapes (`parse_key_values` in
# crates/ct-shell-trace-writer/src/wire_protocol.rs). Every free-form value
# an event carries goes through here: variable and argument values, command
# texts, and every path and function name, which may hold a space, a tab, a
# `"` or a `\` like any other string (zsh accepts any function name, and
# names a sourced file's frame after its path). A newline cannot be carried
# by this line protocol at all, quoted or not.
#
# A path or a function name, which every STEP and CALL repeats, is quoted
# once, when it is registered, and read back from `_ct_registered_paths` /
# `_ct_registered_funcs`. A glob rather than `=~`, which the script's
# RE_MATCH_PCRE would change. Kept the same as `_ct_inline_quote` in
# recorder.sh.
_ct_inline_quote() {
    _ct_qv="$1"
    if [[ "$_ct_qv" == *[[:space:]\"\\]* ]]; then
        _ct_qv="${_ct_qv//\\/\\\\}"
        _ct_qv="${_ct_qv//\"/\\\"}"
        _ct_qv="\"$_ct_qv\""
    fi
}

# Make a source file's path absolute: sets `_ct_ap`.
#
# zsh reports a sourced file in funcsourcetrace by the path it was opened
# by: `./helpers.zsh` for `source ./helpers.zsh`, `../bin/h.zsh` for
# `source h.zsh` found through a `path` entry `../bin`. Such a path names
# the file only in the working directory the script had at that moment,
# and the trace writer copies sources after the script has ended, from its
# own directory. So the DEBUG trap calls this for a file the first time it
# sees it, while `$PWD` is still the directory the path is relative to,
# and every event carries the result (spec
# `Recording-Backends/Shell-Recorder.md`, "Wire Protocol (FD 3)";
# codetracer-pm issue
# `2026-11-15-shell-recorders-record-a-relatively-sourced-file-by-its-relative-path-and-may-not-copy-it`).
#
# The same form as the main script's above: joined to the logical `$PWD`,
# then normalised lexically by `:a`, which drops empty and `.` components
# and lets `..` remove the component before it. `:a` leaves a `..` above
# `/` as a leading `//` (`/a/../../x` becomes `//x`), which a second `:a`
# folds, so the result matches the bash recorder's `_ct_absolute_path`.
# See: https://zsh.sourceforge.io/Doc/Release/Expansion.html#Modifiers
#
# The system resolves a `..` that follows a symlinked directory from the
# link's target instead, so there the folded path names another file than
# the one zsh opened, or none (`${0:h}/../lib/x.zsh` for a script in a
# symlinked `bin`). When the joined path names an existing file that the
# folded one is not (`-ef`), the joined path is kept as it is, as the bash
# recorder does.
_ct_absolute_path() {
    local _ct_joined="$1"
    [[ "$_ct_joined" == /* ]] || _ct_joined="${PWD-}/$_ct_joined"
    _ct_ap="${${_ct_joined:a}:a}"
    if [[ -e "$_ct_joined" && ! "$_ct_ap" -ef "$_ct_joined" ]]; then
        _ct_ap="$_ct_joined"
    fi
}
# Declared here, global, so that setting it in the DEBUG trap, which runs in
# the scope of whatever function the script is in, creates no global there
# (and draws no warning under WARN_CREATE_GLOBAL).
_ct_ap=""

# The trace writer is a native executable. On Windows this recorder runs
# under an MSYS2 or Cygwin zsh, whose paths (`/c/...`, `/tmp/...`) only
# that runtime can resolve, and MSYS rewrites command-line arguments but not
# the events stream. Every path sent to the writer is therefore converted
# once to Windows mixed form: drive letter, forward slashes and long names
# (`C:/Users/...`), which both the writer and the trace readers open.
# Everywhere else the path is sent unchanged.
# https://www.msys2.org/docs/filesystem-paths/
# https://cygwin.com/cygwin-ug-net/cygpath.html
_ct_use_cygpath=0
case "$OSTYPE" in
    msys* | cygwin*)
        (( ${+commands[cygpath]} )) && _ct_use_cygpath=1
        ;;
esac

# Sets _ct_np to the writer's form of the path in $1. Like _ct_inline_quote
# it returns through a variable, so no subshell is spawned off Windows.
_ct_native_path() {
    _ct_np="$1"
    if (( _ct_use_cygpath )); then
        _ct_np="$(cygpath -m -l -- "$1")" || {
            echo "ct-zsh-recorder: cygpath could not convert '$1'" >&2
            _ct_np="$1"
        }
    fi
}

_ct_native_path "$_ct_target_script"
_ct_target_script_native="$_ct_np"

# Emit START event
_ct_inline_quote "$_ct_target_script_native"
_ct_target_script_q=$_ct_qv
_ct_inline_quote "$ZSH_VERSION"
printf 'START program=%s shell=zsh shell_version=%s\n' "$_ct_target_script_q" "$_ct_qv" >&$_ct_events_fd

# Register the main script path
printf 'PATH file=%s\n' "$_ct_target_script_q" >&$_ct_events_fd

# The source files already registered, by the path funcsourcetrace
# reports, each mapped to the quoted writer form (see `_ct_native_path`) of
# its absolute path for the PATH, FUNC and STEP events (see
# `_ct_absolute_path`). Keyed by the reported string because that is all a
# later step offers: a function keeps the funcsourcetrace entry it was
# defined with, and a step in it after another `cd` must map to the path
# fixed when the file was first seen. The same key makes one limit
# inherent: two different files reported by the same relative string from
# different directories cannot be told apart, and both are recorded as the
# first one.
typeset -A _ct_registered_paths
_ct_registered_paths[$_ct_target_script]=$_ct_target_script_q

# The absolute paths a PATH event has registered: two reported strings for
# one file (`./h.zsh`, and `h.zsh` after a `cd`) register it once.
typeset -A _ct_emitted_paths
_ct_emitted_paths[$_ct_target_script]=1

# The functions already registered, each mapped to its quoted name for the
# FUNC and CALL events
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
    printf 'RETURN status=%d\n' "$1" >&$_ct_events_fd
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
        printf 'RETURN status=%d\n' "${_ct_entry#*:}" >&$_ct_events_fd
    done
    _ct_held_returns=()
    _ct_exit_suspect=0
}

# The EXIT trap of a function frame: the function completed with status $1,
# and the caller is at funcstack depth $2. Set by the DEBUG trap with the
# CALL; runs in the function's own shell, after the function's frame left
# funcstack.
_ct_function_returned() {
    # The script's own EXIT trap for this function, if it set one, runs
    # after this (see "Traps set by the script"), with the function's status.
    _ct_run_script_EXIT=1
    _ct_script_status_EXIT=$1
    # zsh runs the ZERR trap once more, in the caller, for a function that
    # returns non-zero and has an EXIT trap; every function has the
    # recorder's. Without a script EXIT action for it (whose part of the
    # trap resets this), that ZERR would not happen without the recorder.
    if (( $1 != 0 )); then
        _ct_zerr_echo_depth=$2
    fi
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
        printf 'RETURN status=%d\n' "$1" >&$_ct_events_fd
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
            printf 'RETURN status=%d\n' "$_ct_code" >&$_ct_events_fd
        else
            printf 'RETURN status=%d\n' "${_ct_entry#*:}" >&$_ct_events_fd
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
            printf 'RETURN status=%d\n' "${_ct_entry#*:}" >&$_ct_events_fd
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

    # Before the traps are removed: a trap of the recorder's that the script
    # replaced behind its back leaves a partial recording, which is said here.
    _ct_report_replaced_traps

    # Nothing after this point belongs to the script: stop recording before
    # writing the event, so it is the last one in the stream. `builtin`
    # bypasses the script's `trap` alias, and without LOCAL_TRAPS the reset
    # is not undone when this function returns.
    setopt localoptions nolocaltraps
    builtin trap - DEBUG
    builtin trap - ZERR

    printf 'EXIT code=%d\n' "$_ct_code" >&$_ct_events_fd
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
# match[1] is the keyword, match[2] the flags ("-g -i ", "-i16 ", "-Z3 -r "
# or ""), match[4] the name. A flag word is letters followed by an optional
# number: the integer base of `-i` (`-i16`) or the field width of `-Z`, `-L`
# and `-R` (`-Z5`). The type is read from the letters alone. Shared by the
# baseline snapshot and `_ct_capture_variables`, so that the two accept
# exactly the same lines: a line the capture accepts but the baseline skips
# would report an inherited parameter (such as `typeset -i10 COLUMNS=0`) as
# one of the script's.
# See the `typeset -p` output format above `_ct_capture_variables`.
_ct_decl_prefix_re='^(typeset|export) (([-][[:alpha:]]+[[:digit:]]* )*)([_[:alpha:]][_[:alnum:]]*)'

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
# A flag word may end in a number, the integer base of -i or the field width
# of -Z, -L and -R; other flags follow as separate words (zsh 5.9.1):
#   typeset -i16 name=255                 (integer, base 16; value in decimal)
#   typeset -i10 name=value               (integer, how zsh's own are printed)
#   typeset -Z5 name=42                   (zero-filled string; the value as
#                                          assigned, though $name is 00042)
#   typeset -L3 name=value                (left-justified string)
#   typeset -R4 name=value                (right-justified string)
#   typeset -Z3 -r name=value             (typeset -rZ3)
#   typeset -L4 -Z4 name=value            (typeset -L4 -Z4)
#   typeset -i2 name=value                (typeset -gi2 in a function)
#
# An exported scalar parameter is printed with the keyword `export` instead
# of `typeset`, and without the -x flag (zsh 5.9, 5.9.1):
#   export name=value                     (export name=value, or
#                                          typeset -gx name=value in a function)
#   export -i name=value                  (exported integer)
#   export -F name=value                  (exported float)
#   export -i16 name=value                (exported integer, base 16)
#   export -Z4 name=value                 (typeset -gxZ4 in a function)
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
        # Flags string looks like "-g -i ", "-a ", "-i16 ", "-Z3 -r " or "".
        # Each pattern anchors on the dash, so a width or base after the
        # letter does not change the match: "-i16 " is integer, "-Z5 " is
        # none of these and stays a string.
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
        printf 'VAR name=%s value=%s type=%s\n' "$_ct_varname" "$_ct_qv" "$_ct_type_flag" >&$_ct_events_fd
    done <<< "$_ct_decl_output"
}

# ---------------------------------------------------------------------------
# Traps set by the script
# ---------------------------------------------------------------------------
# The recorder works through its DEBUG and ZERR traps and the EXIT trap it
# sets in every function it records, and zsh has one trap per condition (and
# per function, for EXIT): a `trap` command of the script would replace the
# recorder's, and the recording would go on silently without the events it
# produces (spec "Limitations", "Signal Handler Conflicts").
#
# So `trap` is an alias, defined just before the script is sourced, for
# `source trap-shim.zsh --ct-trap`. Sourcing, unlike calling a function,
# does not open a function scope, so the shim's `builtin trap` commands set
# their traps exactly where the script's `trap` would: an EXIT trap in a
# function is that function's, and LOCAL_TRAPS restores a trap set in a
# function when it returns, natively. (A shell function cannot do this:
# the EXIT trap it set would be its own.)
# See: https://zsh.sourceforge.io/Doc/Release/Shell-Builtin-Commands.html#index-trap
#      https://zsh.sourceforge.io/Doc/Release/Options.html#index-LOCALTRAPS
#
# For DEBUG, ZERR (and its alias ERR) and the EXIT trap of a function the
# recorder records, the shim does not replace the recorder's trap: it
# installs the recorder's action followed by the script's
# (`_ct_compose_trap`). The script's action is part of the trap's list
# itself, so it runs in the environment of the interrupted command, as a
# list trap does: LINENO, the positional parameters, `return` and the
# DEBUG trap's `setopt errexit` (skip the command) all mean what they mean
# without the recorder. Every other trap goes to the builtin unchanged.
#
# A function-form trap (`TRAPZERR() { ... }`) replaces a trap by being
# defined, which no alias can see. A TRAPZERR or TRAPERR is adopted by the
# next DEBUG trap: moved to another name, which the recorder's ZERR trap
# then calls (`_ct_adopt_defined_trap_function`). A TRAPDEBUG would replace
# the DEBUG trap itself, and a TRAPEXIT the function's EXIT trap, before
# that: the DEBUG trap sees the definition coming in ZSH_DEBUG_CMD, skips it
# (`setopt errexit` in a DEBUG trap skips the command) and defines the same
# function under another name instead (`_ct_adopt_trap_function`).
#
# Listing (`trap`) shows the script its own actions and functions, and
# hides the recorder's. Each composed action carries the line
# `: ct-script-trap <id>`, which names the script's action in
# `_ct_script_trap_src` (or its function in `_ct_script_trap_fn`), so the
# listing works from what zsh really has, even after LOCAL_TRAPS restored
# an older trap.
#
# What the script can still tell apart:
#
# - `builtin trap`, `command trap`, a quoted `\trap`, `unalias trap`, or a
#   function or alias of its own named `trap` bypass the alias, as does a
#   function-form trap defined in a way the DEBUG trap does not see
#   (`eval 'TRAPZERR() { ... }'`). A trap of the recorder's replaced that
#   way is reported at exit (`_ct_report_replaced_traps`).
# - `alias` lists the `trap` alias. The script's function-form traps have
#   other names, so `functions TRAPZERR` finds nothing; `unfunction` of
#   such names only (`unfunction TRAPZERR`) is recognised and resets the
#   script's trap, any other form removes the recorder's and is reported.
# - Skipping a definition (TRAPDEBUG, TRAPEXIT) or an `unfunction` leaves
#   `$?` at the status before it, where zsh would give 0.
# - A function-form trap that returns non-zero no longer makes zsh "behave
#   as interrupted": the recorder's list trap calls it, and its status is
#   only a status.
# - zsh lists a trap's action as it reconstructs it from the parsed code;
#   the shim lists the script's action reconstructed the same way.
# See: https://zsh.sourceforge.io/Doc/Release/Functions.html#Trap-Functions

# The result of the helper functions below that return a string.
#
# The helpers run in the script's shell, outside any trap when the shim
# calls them, so under the script's ERR_EXIT a failing command in one of
# them would end the script: they test with conditions and `||` / `&&`
# lists, count with `x=$(( x + 1 ))` (an `(( ))` that evaluates to 0
# fails), and end with a command that succeeds.
_ct_reply=""

# The `trap` shim, beside this file, and the alias text that runs it.
_ct_shim_path="${_ct_recorder_path:h}/trap-shim.zsh"
_ct_trap_alias_text="source ${(q)_ct_shim_path} --ct-trap"

# The script's trap actions, by the id their composed action carries: the
# action as zsh reconstructs it (`_ct_script_trap_src`) or, for a
# function-form trap, the name the script defined (`_ct_script_trap_fn`;
# the function itself is `_ct_script_trapfn_<id>`).
typeset -A _ct_script_trap_src _ct_script_trap_fn
_ct_script_trap_next=0

# The number zsh passes a function-form trap as `$1`, by condition. For
# ZERR and DEBUG it is zsh's own numbering past the real signals, not their
# position in $signals (zsh 5.9 on Linux passes 32 and 33), so it is
# measured here, by two trap functions run once before the recorder installs
# its own traps: no subshell, and no trap runs inside another.
typeset -A _ct_trap_signal_numbers
_ct_trap_signal_numbers[EXIT]=0
TRAPZERR() { _ct_trap_signal_numbers[ZERR]=$1; }
false
unfunction TRAPZERR
TRAPDEBUG() { _ct_trap_signal_numbers[DEBUG]=$1; unfunction TRAPDEBUG; }
:

# Set by the recorder's part of each trap: whether the script's action runs
# this time (1) or not (0), and the `$?` it runs with.
_ct_run_script_DEBUG=0
_ct_run_script_ZERR=0
_ct_run_script_EXIT=0
_ct_script_status_DEBUG=0
_ct_script_status_ZERR=0
_ct_script_status_EXIT=0
_ct_debug_entry_status=0

# Set by the DEBUG trap when it adopted a function-form trap: the end of the
# DEBUG action skips the definition, and the condition it was for.
_ct_skip_next_command=0
_ct_adopted_condition=""

# The ZERR trap found the shell about to exit under ERR_EXIT.
_ct_zerr_exits=0

# Set by the DEBUG trap when the definition it skips will make zsh run the
# ZERR trap.
_ct_ignore_next_zerr=0
_ct_unfunction_name=""

# The funcstack depth of a caller whose next ZERR is caused only by the
# recorder's per-function EXIT trap (see `_ct_function_returned`), or -1.
_ct_zerr_echo_depth=-1
_ct_zerr_echo=0

# State of the shim and of the trap listing. Declared here, global, so that
# the shim's assignments, which run in the scope of whatever function the
# script called `trap` from, neither create nor warn about globals
# (WARN_CREATE_GLOBAL).
typeset -ga _ct_trap_ops _ct_trap_listing
_ct_trap_mode=""
_ct_shim_i=0
_ct_shim_n=0
_ct_shim_rc=0
_ct_trap_tmp=""
_ct_trap_tmp_count=0
_ct_trap_fd=""

# The per-function EXIT trap the DEBUG trap sets with each CALL (see "Open
# frames"). Its first word is how the recorder recognises it as its own.
_ct_fn_exit_action='_ct_function_returned $? ${#funcstack}'

# Whether file $1 is the recorder's own, the shim, or no file at all: no
# command there is a script command.
_ct_is_recorder_file() {
    [[ -z "$1" || "$1" == "$_ct_recorder_path" ||
       "$1" == "$_ct_recorder_path_as_run" || "$1" == "$_ct_shim_path" ]]
}

# Set `$?` to $1 for the next command. Called as `_ct_set_status N && :`:
# a failing command that is not the last of an AND list neither runs the
# ZERR trap nor ends an ERR_EXIT shell, and the list leaves `$?` at N.
# See: https://zsh.sourceforge.io/Doc/Release/Options.html#index-ERREXIT
_ct_set_status() {
    return "$1"
}

# Whether the innermost frame the recorder has open is a function at
# funcstack depth $1 opened in this shell: one that has the recorder's
# per-function EXIT trap. A subshell inherits the frame but not the trap
# (zsh resets EXIT in subshells).
_ct_in_tracked_function() {
    (( _ct_frames_subshell == ZSH_SUBSHELL &&
       ${#_ct_frame_depths} > _ct_subshell_base &&
       _ct_frame_depths[-1] == $1 )) && [[ "${_ct_frame_kinds[-1]}" == f ]]
}

# The condition name the recorder keeps for itself that spec $1 names
# (DEBUG, ZERR, ERR or EXIT, with or without SIG, or 0 for EXIT), in _ct_reply;
# returns 1 for any other. Whether EXIT is the recorder's depends on where
# the trap is set (`_ct_in_tracked_function`).
_ct_trap_condition() {
    local _ct_t_name="${1#SIG}"
    [[ "$1" == 0 ]] && _ct_t_name=EXIT
    case "$_ct_t_name" in
        DEBUG | ZERR | ERR | EXIT) _ct_reply="$_ct_t_name"; return 0 ;;
    esac
    return 1
}

# Whether $1 is a signal spec zsh accepts: a number, or a name in $signals
# (or ERR, or one of the alternative names `kill` lists), with or without SIG.
_ct_is_signal_spec() {
    [[ "$1" == <-> ]] && (( $1 < ${#signals} )) && return 0
    local _ct_t_name="${1#SIG}"
    (( ${signals[(Ie)$_ct_t_name]} )) && return 0
    [[ "$_ct_t_name" == (ERR|CLD|POLL|IOT) ]]
}

# The recorder's own part of the trap for condition $1, in _ct_reply: the
# action that runs before the script's (`_ct_recorder_trap_prefix`) and the
# commands that end every composed action (`_ct_recorder_trap_suffix`).
_ct_recorder_trap_prefix() {
    case "$1" in
        DEBUG) _ct_reply="$_ct_debug_action" ;;
        ZERR | ERR) _ct_reply="$_ct_zerr_action" ;;
        EXIT) _ct_reply="$_ct_fn_exit_action" ;;
    esac
}
_ct_recorder_trap_suffix() {
    case "$1" in
        # Skip a function-form trap definition the DEBUG trap adopted. In
        # the list itself: `setopt` in a function would be undone by a
        # script that runs with LOCAL_OPTIONS.
        DEBUG) _ct_reply=$'\n(( _ct_skip_next_command )) && { _ct_skip_next_command=0; setopt errexit; }' ;;
        ZERR | ERR) _ct_reply=$'\n_ct_zerr_finish' ;;
        *) _ct_reply="" ;;
    esac
}

# Whether action $2, as zsh lists it for condition $1, is one the recorder
# installed: its first command is the recorder's (see `_ct_debug_action`).
_ct_is_recorder_action() {
    case "$1" in
        DEBUG) [[ "$2" == '_ct_debug_entry_status=$?'* ]] ;;
        ZERR | ERR) [[ "$2" == '_ct_zerr_status=$?'* ]] ;;
        EXIT) [[ "$2" == '_ct_function_returned '* ]] ;;
        *) return 1 ;;
    esac
}

# The trap action to install for condition $1, in _ct_reply: the recorder's
# part and, when $2 names a script action (an id), that action, run only
# when the recorder's part says so (`_ct_run_script_<cond>`), with `$?` set
# back to the status the trap was entered with.
_ct_compose_trap() {
    local _ct_t_cond="$1" _ct_t_id="${2:-}" _ct_t_key="$1" _ct_t_body _ct_t_prefix
    [[ "$_ct_t_key" == ERR ]] && _ct_t_key=ZERR
    _ct_recorder_trap_prefix "$_ct_t_cond"
    _ct_t_prefix="$_ct_reply"
    _ct_recorder_trap_suffix "$_ct_t_cond"
    if [[ -z "$_ct_t_id" ]]; then
        _ct_reply="${_ct_t_prefix}${_ct_reply}"
        return 0
    fi
    if (( ${+_ct_script_trap_fn[$_ct_t_id]} )); then
        _ct_trap_signal_number "$_ct_t_key"
        _ct_t_body="_ct_script_trapfn_${_ct_t_id} ${_ct_reply}"
        _ct_recorder_trap_suffix "$_ct_t_cond"
    else
        _ct_t_body="${_ct_script_trap_src[$_ct_t_id]}"
    fi
    # A script EXIT action makes the extra ZERR in the caller genuine.
    [[ "$_ct_t_key" == EXIT ]] && _ct_t_prefix+=$'\n_ct_zerr_echo_depth=-1'
    _ct_reply="${_ct_t_prefix}
: ct-script-trap ${_ct_t_id}
case \$_ct_run_script_${_ct_t_key} in
(1) _ct_set_status \"\$_ct_script_status_${_ct_t_key}\" && :
${_ct_t_body}
;;
esac${_ct_reply}"
}

# Register the script's list action $1, as zsh reconstructs it, and set
# _ct_reply to its id. The reconstruction is the body of a function defined
# with it, less the one tab zsh indents a body with (the same text `trap`
# lists). An action that does not parse is kept as it is: the builtin then
# refuses the composed action with zsh's own message.
_ct_register_script_trap() {
    local _ct_t_text="$1"
    if { functions[_ct_trap_reconstruct]="$1" } 2>/dev/null; then
        local -a _ct_t_lines
        _ct_t_lines=("${(@f)functions[_ct_trap_reconstruct]}")
        _ct_t_text="${(F)${(@)_ct_t_lines#$'\t'}}"
        unfunction _ct_trap_reconstruct
    fi
    _ct_script_trap_next=$(( _ct_script_trap_next + 1 ))
    _ct_script_trap_src[$_ct_script_trap_next]="$_ct_t_text"
    _ct_reply=$_ct_script_trap_next
}

# Adopt the function-form trap TRAP$1 whose definition, as zsh reconstructs
# it, is $2: define it as `_ct_script_trapfn_<id>` and set _ct_reply to the
# composed action for its condition, and `_ct_adopted_condition` to that
# condition. TRAPERR is TRAPZERR's alias.
_ct_adopt_trap_function() {
    local _ct_t_name="TRAP$1" _ct_t_cond="$1"
    [[ "$_ct_t_cond" == ERR ]] && _ct_t_cond=ZERR
    local _ct_t_id=$(( _ct_script_trap_next + 1 ))
    eval "_ct_script_trapfn_${_ct_t_id}${2#$_ct_t_name}" 2>/dev/null || return 1
    _ct_script_trap_next=$_ct_t_id
    _ct_script_trap_fn[$_ct_t_id]="$_ct_t_name"
    _ct_adopted_condition="$_ct_t_cond"
    _ct_compose_trap "$_ct_t_cond" "$_ct_t_id"
}

# Adopt the TRAPZERR or TRAPERR the script has defined: move it to
# `_ct_script_trapfn_<id>` (removing the function removes the trap it set)
# and set `_ct_reply` to the composed ZERR action that calls it.
_ct_adopt_defined_trap_function() {
    local _ct_t_name
    for _ct_t_name in TRAPZERR TRAPERR; do
        (( ${+functions[$_ct_t_name]} )) || continue
        _ct_script_trap_next=$(( _ct_script_trap_next + 1 ))
        functions[_ct_script_trapfn_${_ct_script_trap_next}]="${functions[$_ct_t_name]}"
        unfunction "$_ct_t_name"
        _ct_script_trap_fn[$_ct_script_trap_next]="$_ct_t_name"
        _ct_compose_trap ZERR "$_ct_script_trap_next"
        return 0
    done
    return 1
}

# The number zsh passes a function-form trap for condition $1 as `$1`, in
# `_ct_reply` (see `_ct_trap_signal_numbers`).
_ct_trap_signal_number() {
    _ct_reply="${_ct_trap_signal_numbers[$1]:-0}"
}


# Open a temporary file for `builtin trap`'s listing, which must be written
# by the shell itself: a command substitution is a subshell, where zsh
# resets the traps. The file is created exclusively and readable only by
# its owner, with `sysopen`, so no external command runs. Returns 1 when it
# cannot be created.
# See: https://zsh.sourceforge.io/Doc/Release/Zsh-Modules.html#The-zsh_002fsystem-Module
_ct_trap_listing_open() {
    (( ${+builtins[sysopen]} )) || return 1
    local _ct_t_try
    for _ct_t_try in 1 2 3 4 5 6 7 8; do
        _ct_trap_tmp_count=$(( _ct_trap_tmp_count + 1 ))
        _ct_trap_tmp="${TMPDIR:-/tmp}/ct-zsh-trap.$$.${_ct_trap_tmp_count}"
        sysopen -w -o creat,excl -m 600 -u _ct_trap_fd "$_ct_trap_tmp" 2>/dev/null && return 0
    done
    _ct_trap_tmp=""
    return 1
}

# Set `_ct_trap_listing` to the lines of listing $1: none for an empty one.
_ct_trap_set_listing() {
    _ct_trap_listing=()
    [[ -z "$1" ]] || _ct_trap_listing=("${(@f)1}")
}

# Close the listing file and read it into `_ct_trap_listing`, one line per
# element, and remove it.
_ct_trap_listing_read() {
    exec {_ct_trap_fd}>&-
    _ct_trap_set_listing "$(<"$_ct_trap_tmp")"
    if (( ${+builtins[zf_rm]} )); then
        zf_rm -f -- "$_ct_trap_tmp"
    else
        command rm -f -- "$_ct_trap_tmp"
    fi
    _ct_trap_tmp=""
}

# Print `_ct_trap_listing`, zsh's own listing, as the script would see it
# without the recorder: each trap of the recorder's is left out, or replaced
# by the script's action it carries.
_ct_trap_print_listing() {
    local _ct_t_line _ct_t_action _ct_t_id
    local -a _ct_t_words
    local _ct_t_id_re=$'(^|\n)[[:space:]]*: ct-script-trap ([0-9]+)'
    for _ct_t_line in "${_ct_trap_listing[@]}"; do
        if [[ "$_ct_t_line" == "trap -- "*" "(DEBUG|ZERR|ERR|EXIT) ]]; then
            _ct_t_words=(${(z)_ct_t_line})
            _ct_t_action="${(Q)_ct_t_words[3]}"
            if _ct_is_recorder_action "${_ct_t_words[-1]}" "$_ct_t_action"; then
                if [[ "$_ct_t_action" =~ $_ct_t_id_re ]]; then
                    _ct_print_script_trap "${match[2]}" "${_ct_t_words[-1]}"
                fi
                continue
            fi
        fi
        print -r -- "$_ct_t_line"
    done
}

# Print the script's trap with id $1 for condition $2 the way zsh lists it:
# a list action as `trap -- <action> <cond>`, a function-form trap as its
# definition under the name the script gave it.
_ct_print_script_trap() {
    if (( ${+_ct_script_trap_fn[$1]} )); then
        print -r -- "${_ct_script_trap_fn[$1]} () {"
        print -r -- "${functions[_ct_script_trapfn_$1]}"
        print -r -- "}"
    else
        print -r -- "trap -- ${(q+)_ct_script_trap_src[$1]} $2"
    fi
}

# Plan what the shim does for the script's `trap "$@"`: sets `_ct_trap_mode`
# to `list`, `passthrough` (the builtin, as given: everything this does not
# handle, so that the script sees the builtin's own messages) or `apply`,
# and for `apply` fills `_ct_trap_ops` with the `builtin trap` calls to
# make, each as its argument count followed by its arguments. Runs one
# function level below the shim, so the script's scope is `$1` levels up.
#
# The builtin's rules: no argument lists; `-` with no condition resets all
# traps; a first argument that is a signal means `-`; an empty action
# ignores.
# See: https://zsh.sourceforge.io/Doc/Release/Shell-Builtin-Commands.html#index-trap
_ct_trap_plan() {
    _ct_trap_ops=()
    _ct_trap_mode=passthrough
    # The script's funcstack depth: this function and the shim are above it.
    local _ct_t_depth=$(( ${#funcstack} - 2 ))
    [[ "${1-}" == -- ]] && shift
    if (( $# == 0 )); then
        _ct_trap_mode=list
        return 0
    fi

    local _ct_t_mode _ct_t_action=""
    local -a _ct_t_specs
    if _ct_is_signal_spec "$1"; then
        _ct_t_mode=reset
        _ct_t_specs=("$@")
    elif [[ "$1" == - ]]; then
        _ct_t_mode=reset
        _ct_t_specs=("${@[2,-1]}")
        if (( ${#_ct_t_specs} == 0 )); then
            # Reset every trap, then put the recorder's back.
            _ct_trap_ops=(1 -)
            _ct_t_specs=(DEBUG ZERR)
            _ct_in_tracked_function "$_ct_t_depth" && _ct_t_specs+=(EXIT)
        fi
    else
        _ct_t_mode=set
        _ct_t_action="$1"
        _ct_t_specs=("${@[2,-1]}")
    fi
    (( ${#_ct_t_specs} > 0 )) || return 0

    local _ct_t_spec _ct_t_id
    local -a _ct_t_others _ct_t_mine
    for _ct_t_spec in "${_ct_t_specs[@]}"; do
        if _ct_trap_condition "$_ct_t_spec" &&
           { [[ "$_ct_reply" != EXIT ]] || _ct_in_tracked_function "$_ct_t_depth"; }; then
            _ct_t_mine+=("$_ct_reply")
        else
            _ct_t_others+=("$_ct_t_spec")
        fi
    done
    if (( ${#_ct_t_others} > 0 )); then
        if [[ "$_ct_t_mode" == reset ]]; then
            _ct_trap_ops+=($(( ${#_ct_t_others} + 1 )) - "${_ct_t_others[@]}")
        else
            _ct_trap_ops+=($(( ${#_ct_t_others} + 2 )) -- "$_ct_t_action" "${_ct_t_others[@]}")
        fi
    fi
    if (( ${#_ct_t_mine} > 0 )) && [[ "$_ct_t_mode" == set ]]; then
        _ct_register_script_trap "$_ct_t_action"
        _ct_t_id="$_ct_reply"
    fi
    for _ct_t_spec in "${_ct_t_mine[@]}"; do
        _ct_compose_trap "$_ct_t_spec" "${_ct_t_id:-}"
        _ct_trap_ops+=(3 -- "$_ct_reply" "$_ct_t_spec")
    done
    _ct_trap_mode=apply
}

# A `builtin trap` call of the shim, with arguments "${@[2,-1]}", failed:
# print the builtin's message as the builtin prints it for a command of the
# script, at $1, the script's "<function or file>:<line>", rather than at
# the shim's line, and return the builtin's status. The builtin runs again
# in a subshell to capture the message (it has no effect there).
_ct_trap_report_error() {
    local _ct_t_caller="$1" _ct_t_messages _ct_t_message _ct_t_rc
    shift
    _ct_t_messages=$(builtin trap "$@" 2>&1 >/dev/null)
    _ct_t_rc=$?
    (( _ct_t_rc != 0 )) || _ct_t_rc=1
    local _ct_t_re='^.*:trap:[0-9]+: (.*)$'
    for _ct_t_message in "${(@f)_ct_t_messages}"; do
        if [[ "$_ct_t_message" =~ $_ct_t_re ]]; then
            _ct_t_message="${_ct_t_caller%:*}:trap:${_ct_t_caller##*:}: ${match[1]}"
        fi
        print -r -u2 -- "$_ct_t_message"
    done
    return $_ct_t_rc
}

# Defense in depth: the alias cannot see `builtin trap` and the other ways
# around it listed above, and a trap of the recorder's replaced that way
# stops the events it produces (every step, after DEBUG; every error, after
# ZERR). Checked once, when the recording ends, in zsh's own listing.
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
    # DEBUG and ZERR are the two traps zsh keeps in a subshell, so without
    # a temporary file a command substitution can list them, for a fork.
    if _ct_trap_listing_open; then
        builtin trap >&$_ct_trap_fd
        _ct_trap_listing_read
    else
        _ct_trap_set_listing "$(builtin trap)"
    fi
    local _ct_t_line _ct_t_cond _ct_t_replaced="" _ct_t_debug_ok=0 _ct_t_zerr_ok=0
    local -a _ct_t_words
    for _ct_t_line in "${_ct_trap_listing[@]}"; do
        [[ "$_ct_t_line" == "trap -- "*" "(DEBUG|ZERR|ERR) ]] || continue
        _ct_t_words=(${(z)_ct_t_line})
        _ct_t_cond="${_ct_t_words[-1]}"
        _ct_is_recorder_action "$_ct_t_cond" "${(Q)_ct_t_words[3]}" || continue
        if [[ "$_ct_t_cond" == DEBUG ]]; then
            _ct_t_debug_ok=1
        else
            _ct_t_zerr_ok=1
        fi
    done
    (( _ct_t_debug_ok )) || _ct_t_replaced="DEBUG"
    (( _ct_t_zerr_ok )) || _ct_t_replaced+="${_ct_t_replaced:+, }ZERR"
    [[ -n "$_ct_t_replaced" ]] || return 0
    local _ct_t_message="the script replaced the recorder's ${_ct_t_replaced} trap without going through \`trap\` (\`builtin trap\`, \`command trap\` or a function-form trap the recorder did not see defined); events recorded through it are missing after that point"
    print -r -u2 -- "codetracer-zsh-recorder: warning: $_ct_t_message"
    _ct_inline_quote "$_ct_t_message"
    printf 'ERROR cmd=%s status=0\n' "$_ct_qv" >&$_ct_events_fd
}

# DEBUG trap (LIST FORM - critical for correct $LINENO)
#
# In Zsh's sourced-script context:
# - funcstack[1] = script path (when at top-level of sourced script)
# - funcstack[1] = function name, funcstack[2] = script path (inside a function)
# - funcfiletrace[N] = "file:line" of each call site
# - funcsourcetrace[N] = "file:line" where each function/script was defined
# - $LINENO = line number in current execution context
#
# The action is kept in `_ct_debug_action` and installed by
# the recorder's top-level code below (see "Traps set by the script"). Its first command
# saves the `$?` the trap was entered with, for the script's own DEBUG
# action, and is also how the recorder recognises the action as its own in
# `trap`'s listing (zsh lists a trap's action as it reconstructs it from
# the parsed code, and this command reconstructs as itself).
_ct_debug_action='
    _ct_debug_entry_status=$?
    _ct_run_script_DEBUG=0
    # Guard against re-entry
    if (( _ct_in_trap )); then
        :
    else
        _ct_in_trap=1

        _ct_trap_status=$?
        _ct_depth=${#funcstack}
        _ct_line=$LINENO
        _ct_cmd="$ZSH_DEBUG_CMD"
        _ct_ignore_next_zerr=0
        # A ZERR at the call site that only the recorder'\''s per-function
        # EXIT trap causes is the one right after the return, before this.
        _ct_zerr_echo_depth=-1
        # zsh reconstructs the script'\''s `trap` as the alias expanded it:
        # show it as the `trap` the script wrote, here, in the ZERR trap'\''s
        # report and to the script'\''s own DEBUG action.
        if [[ "$_ct_cmd" == *"$_ct_trap_alias_text"* ]]; then
            _ct_cmd="${_ct_cmd//"$_ct_trap_alias_text"/trap}"
            ZSH_DEBUG_CMD="$_ct_cmd"
        fi

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

            # Skip events from the recorder itself, and from the `trap`
            # shim, which runs as a sourced file
            if _ct_is_recorder_file "$_ct_file"; then
                _ct_in_trap=0
            fi
        fi

        if (( _ct_in_trap )); then
            # The command the ZERR trap reports if it fails: only a command
            # of the script, never one of the recorder or the shim.
            _ct_last_cmd="$_ct_cmd"

            # Register new source files by their absolute path, resolved
            # now, while the working directory is the one a relative path
            # is relative to (and keep the quoted writer form of it for the
            # events below; see `_ct_absolute_path`, `_ct_native_path` and
            # `_ct_inline_quote`; `-`
            # keeps an unknown, empty file from failing when the script
            # sets NO_UNSET). The recorder-file filter above compares the
            # raw string.
            if [[ -n "$_ct_file" ]] && (( ! ${+_ct_registered_paths[$_ct_file]} )); then
                _ct_absolute_path "$_ct_file"
                _ct_native_path "$_ct_ap"
                _ct_inline_quote "$_ct_np"
                _ct_registered_paths[$_ct_file]=$_ct_qv
                if (( ! ${+_ct_emitted_paths[$_ct_ap]} )); then
                    _ct_emitted_paths[$_ct_ap]=1
                    printf '\''PATH file=%s\n'\'' "$_ct_qv" >&$_ct_events_fd
                fi
            fi
            _ct_file_q="${_ct_registered_paths[$_ct_file]-}"

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
                    _ct_inline_quote "$_ct_func_name"
                    _ct_registered_funcs[$_ct_func_name]=$_ct_qv
                    printf '\''FUNC name=%s file=%s line=%d\n'\'' "$_ct_qv" "$_ct_file_q" "$_ct_func_def_line" >&$_ct_events_fd
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
                    printf '\''ARG name=$%d value=%s type=s\n'\'' "$_ct_arg_idx" "$_ct_qv" >&$_ct_events_fd
                    _ct_arg_idx=$(( _ct_arg_idx + 1 ))
                done

                # Emit CALL event (drains the ARG events staged above)
                printf '\''CALL name=%s\n'\'' "${_ct_registered_funcs[$_ct_func_name]}" >&$_ct_events_fd

                # Open the frame. A function frame gets the EXIT trap that
                # closes it (see "Open frames"); set here, before the
                # function runs its first command, and so before any EXIT
                # trap of the function itself, which replaces it. A sourced
                # file is not a function: an EXIT trap set there would be
                # the EXIT trap of the shell itself.
                if [[ "${zsh_eval_context[-2]}" == shfunc ]]; then
                    _ct_frame_depths+=($_ct_depth)
                    _ct_frame_kinds+=(f)
                    builtin trap -- "$_ct_fn_exit_action" EXIT
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
                printf '\''WRITE content=%s\n'\'' "$_ct_qv" >&$_ct_events_fd
            fi

            # Emit step event
            printf '\''STEP file=%s line=%d\n'\'' "$_ct_file_q" "$_ct_line" >&$_ct_events_fd

            # Capture variables at this step
            _ct_capture_variables

            # Function-form traps (see "Traps set by the script"). The
            # traps are set here, in the environment of the command, so
            # that they are local to a function where zsh makes them local.
            #
            # A TRAPZERR (or TRAPERR) the script defined since the last
            # command replaced the recorder'\''s ZERR trap, and no ZERR has
            # run since (a definition does not fail): adopt it now.
            if (( ${+functions[TRAPZERR]} || ${+functions[TRAPERR]} )) &&
               _ct_adopt_defined_trap_function; then
                builtin trap -- "$_ct_reply" ZERR
            fi
            # A TRAPDEBUG would replace this very trap, and a TRAPEXIT the
            # function'\''s EXIT trap that closes its frame, before the
            # recorder could see them: the definition about to run is
            # skipped instead, by the `setopt errexit` the end of this action
            # runs, and adopted under another name.
            if [[ "$_ct_cmd" =~ "^TRAP(DEBUG|EXIT) \(\) \{" ]] &&
               { [[ "${match[1]}" != EXIT ]] || _ct_in_tracked_function "$_ct_depth"; } &&
               _ct_adopt_trap_function "${match[1]}" "$_ct_cmd"; then
                builtin trap -- "$_ct_reply" "${_ct_adopted_condition}"
                _ct_skip_next_command=1
                # zsh runs the ZERR trap after a skipped function
                # definition when `$?` was non-zero before it; that ZERR
                # would not happen without the recorder.
                if (( _ct_debug_entry_status != 0 )); then
                    _ct_ignore_next_zerr=1
                fi
            fi

            # `unfunction TRAPZERR` removes the ZERR trap whether or not
            # the function exists, and the script'\''s function-form traps
            # have other names here: `unfunction` of nothing but those
            # names is skipped, and the script'\''s traps they name are
            # reset instead, keeping the recorder'\''s.
            if [[ "$_ct_cmd" =~ "^unfunction( +TRAP(DEBUG|ZERR|ERR|EXIT))+ *\$" ]]; then
                for _ct_unfunction_name in ${=_ct_cmd#unfunction}; do
                    _ct_unfunction_name="${_ct_unfunction_name#TRAP}"
                    [[ "$_ct_unfunction_name" == ERR ]] && _ct_unfunction_name=ZERR
                    if [[ "$_ct_unfunction_name" != EXIT ]] ||
                       _ct_in_tracked_function "$_ct_depth"; then
                        _ct_compose_trap "$_ct_unfunction_name"
                        builtin trap -- "$_ct_reply" "$_ct_unfunction_name"
                    fi
                done
                _ct_skip_next_command=1
                if (( _ct_debug_entry_status != 0 )); then
                    _ct_ignore_next_zerr=1
                fi
            fi

            # A command the script'\''s own DEBUG action runs for too.
            _ct_run_script_DEBUG=1
            _ct_script_status_DEBUG=$_ct_debug_entry_status

            _ct_in_trap=0
        fi
    fi
'

# ZERR trap for errors — fires when a command returns non-zero exit status.
# Installed like the DEBUG trap; its first command is
# how the recorder recognises it as its own.
_ct_zerr_action='
    _ct_zerr_status=$?
    _ct_run_script_ZERR=0
    _ct_zerr_exits=0
    # See `_ct_zerr_echo_depth`: this ZERR exists only because of the
    # recorder, so the script'\''s ZERR action does not run for it.
    _ct_zerr_echo=0
    if (( _ct_zerr_echo_depth == ${#funcstack} )); then
        _ct_zerr_echo=1
    fi
    _ct_zerr_echo_depth=-1
    # The ZERR a skipped definition causes: neither recorded nor the
    # script'\''s (see the DEBUG trap).
    if (( _ct_ignore_next_zerr )); then
        _ct_ignore_next_zerr=0
        _ct_zerr_echo=2
    fi
    if (( ! _ct_in_trap && _ct_zerr_echo != 2 )); then
        _ct_in_trap=1
        _ct_zerr_depth=${#funcstack}

        # Skip errors at depth 0 (recorder level), and from the recorder'\''s
        # functions and the `trap` shim at any depth
        if (( _ct_zerr_depth >= 1 )) &&
           ! _ct_is_recorder_file "${funcsourcetrace[1]%%:*}"; then
            # The shell went on, so nothing held for a pending `exit` exits.
            if (( ${#_ct_held_returns} > 0 || _ct_exit_suspect )); then
                _ct_flush_held_returns
            fi
            _ct_zerr_cmd="$_ct_last_cmd"
            _ct_inline_quote "$_ct_zerr_cmd"
            printf '\''ERROR cmd=%s status=%d\n'\'' "$_ct_qv" "$_ct_zerr_status" >&$_ct_events_fd
            # Save the error status for the next DEBUG trap (for RETURN detection)
            _ct_last_error_status=$_ct_zerr_status
            _ct_had_error=1
            # A failure of the script: its own ZERR action runs for it.
            (( _ct_zerr_echo )) || _ct_run_script_ZERR=1
            _ct_script_status_ZERR=$_ct_zerr_status
            # With ERR_EXIT set, the shell exits right after this trap, and
            # does not run the zshexit hooks (an errexit exit is not a
            # "normal" exit), so this trap is the last point to write EXIT.
            # ZERR runs only where ERR_EXIT applies, so the exit is certain.
            # See: https://zsh.sourceforge.io/Doc/Release/Options.html#index-ERREXIT
            # It is written by `_ct_zerr_finish`, the last command of the
            # action, after the script'\''s own ZERR action: that action may
            # `exit` with another status, which the zshexit hook then writes.
            if [[ -o errexit ]]; then
                _ct_zerr_exits=1
            fi
        fi

        _ct_in_trap=0
    fi
'

# The end of the ZERR action, after the script's own action: with ERR_EXIT
# set the shell exits now, so write the EXIT event. A subshell ends there
# inside whatever functions it is in, and runs no zshexit hook either:
# close the frames it opened.
#
# Not reached when the script's action ends with `return`, after which zsh
# still exits under ERR_EXIT: that recording then ends without its EXIT
# event, and the writer says so ("EOF reached without EXIT event").
_ct_zerr_finish() {
    (( _ct_zerr_exits )) || return 0
    _ct_zerr_exits=0
    if (( ZSH_SUBSHELL > 0 )); then
        _ct_close_subshell_frames "$_ct_zerr_status"
    fi
    _ct_emit_exit "$_ct_zerr_status"
}

# The recorder's own traps, without a script action, set here at the top
# level and not from a function: zsh remembers the function depth a trap
# was set at, and LOCAL_TRAPS saves (and restores when the function
# returns) only a trap set at a shallower depth than the function changing
# it. Set from a function, these would count as set at depth 1, and a
# script function at that depth that sets its own DEBUG or ZERR trap with
# LOCAL_TRAPS would keep it after it returns.
# See: https://zsh.sourceforge.io/Doc/Release/Options.html#index-LOCALTRAPS
_ct_compose_trap DEBUG
builtin trap -- "$_ct_reply" DEBUG
_ct_compose_trap ZERR
builtin trap -- "$_ct_reply" ZERR

# The script's `trap` (see "Traps set by the script"). Aliases are
# expanded as the script is read, so this applies to all of it, its
# functions and `eval`ed code included.
# See: https://zsh.sourceforge.io/Doc/Release/Shell-Grammar.html#Aliasing
alias trap="$_ct_trap_alias_text"

# Execute the target script by sourcing it so traps apply
source "$_ct_target_script" "$@"
_ct_exit_code=$?

_ct_emit_exit "$_ct_exit_code"

exit "$_ct_exit_code"

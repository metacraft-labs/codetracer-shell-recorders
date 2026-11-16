# ct-zsh-recorder: the script's `trap`.
#
# recorder.zsh defines `alias trap="source <this file> --ct-trap"` before it
# sources the recorded script, so every `trap ...` of the script runs this
# file with `--ct-trap` and the `trap` arguments as its positional
# parameters. (The marker keeps a bare `trap`, which passes no arguments,
# from seeing the caller's positional parameters instead.) See "Traps set
# by the script" in recorder.zsh.
#
# This file is sourced, not called, so its `builtin trap` commands run in
# the scope of the command that called `trap`: an EXIT trap set in a
# function is that function's, and LOCAL_TRAPS behaves natively. The work
# that needs no particular scope is done by recorder.zsh's functions; only
# the `builtin trap` calls themselves are made here, at this file's top
# level. Its variables are globals the recorder declared, so that nothing
# here creates a variable in the script's scope.
#
# Its commands are not recorded: the recorder's DEBUG and ZERR traps leave
# this file out (`_ct_is_recorder_file`). Its status is the `trap` status.
# See: https://zsh.sourceforge.io/Doc/Release/Shell-Builtin-Commands.html#index-trap

[[ "$1" == --ct-trap ]] && shift
# Where the script called `trap` ("<function or file>:<line>"), for the
# builtin's error messages (`_ct_trap_report_error`).
_ct_shim_caller="${functrace[1]}"
_ct_trap_plan "$@"
_ct_shim_rc=0
case "$_ct_trap_mode" in
    list)
        # The listing must be written by this shell, at the script's scope
        # (it includes a function's own EXIT trap); without a temporary
        # file for it, zsh's listing is shown as it is.
        if _ct_trap_listing_open; then
            builtin trap >&$_ct_trap_fd
            _ct_trap_listing_read
            _ct_trap_print_listing
        else
            builtin trap || _ct_shim_rc=$?
        fi
        ;;
    apply)
        # Each operation is its argument count followed by its arguments.
        _ct_shim_i=1
        while (( _ct_shim_i <= ${#_ct_trap_ops} )); do
            _ct_shim_n=${_ct_trap_ops[_ct_shim_i]}
            builtin trap "${(@)_ct_trap_ops[_ct_shim_i+1,_ct_shim_i+_ct_shim_n]}" 2>/dev/null ||
                _ct_trap_report_error "$_ct_shim_caller" "${(@)_ct_trap_ops[_ct_shim_i+1,_ct_shim_i+_ct_shim_n]}" ||
                _ct_shim_rc=$?
            _ct_shim_i=$(( _ct_shim_i + _ct_shim_n + 1 ))
        done
        ;;
    *)
        builtin trap "$@" 2>/dev/null || _ct_trap_report_error "$_ct_shim_caller" "$@" || _ct_shim_rc=$?
        ;;
esac
return $_ct_shim_rc

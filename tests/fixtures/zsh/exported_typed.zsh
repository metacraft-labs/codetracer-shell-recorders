#!/usr/bin/env zsh
# Exported parameters of each type, each beside a non-exported one of the
# same type, and one exported from inside a function. `typeset -p` prints
# every exported one but the array with the keyword `export`.
export -i COUNT=3
typeset -i plain_count=4
export -F RATIO=1.5
typeset -F plain_ratio=2.5
typeset -ax LIST=( 1 2 )
typeset -a plain_list=( 3 4 )
set_global() {
    typeset -gx FROM_FN=fn
}
set_global
plain_str=s
echo done

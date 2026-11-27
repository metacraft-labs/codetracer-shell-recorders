#!/usr/bin/env bash
# The common `trap '... $LINENO ...' ERR` idiom, with a `return` that ends
# the function the error happened in: `$LINENO` is the line of the failing
# command, and the recording goes on after the function returns.
trap 'echo "caught at line $LINENO with status $?"; [[ ${FUNCNAME[0]-} == f ]] && return 1' ERR
f() {
    false
    echo "not reached"
}
f
echo "f -> $?"
trap - ERR
echo end

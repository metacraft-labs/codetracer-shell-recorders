#!/usr/bin/env bash
# The script exits 3 from inside a function; its EXIT action calls a
# function that exits with 3 + 300, so the process exits 47 (the low eight
# bits of 303), after a subshell and a command substitution of the action
# have called `exit` of their own, which end only themselves.
# shellcheck disable=SC2329 # called by the EXIT action
finish() {
    echo "finish $1"
    ( exit 9 )
    echo "sub $? $(exit 8; echo unreached)"
    exit $(( $1 + 300 ))
}
trap 'finish "$?"' EXIT
die() { exit 3; }
die
# shellcheck disable=SC2317 # the point: `die` exits
echo "not reached"

#!/usr/bin/env bash
# Functions that return the value of an expanded argument, called in $(...)
# and as an `if` condition, where no later command reads their status.
rc_of() {
    local rc=$1
    # shellcheck disable=SC2086 # unquoted on purpose: the recorder reads `return $x`
    return $rc
}
plus_one() {
    local x=$1
    return "$((x + 1))"
}
out=$(rc_of 42)
if rc_of 3; then echo unexpected; fi
if plus_one 199; then echo unexpected; fi
r=$(plus_one 6)
echo "done${out}${r}"

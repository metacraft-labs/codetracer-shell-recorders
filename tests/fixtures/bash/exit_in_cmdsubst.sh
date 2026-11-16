#!/usr/bin/env bash
# `exit` inside a function in $(...), directly, one call deeper and as the
# function's first command, and a subshell that `set -e` ends inside a
# function. Each ends only its subshell.
bail() {
    echo "bailing"
    exit 3
}
wrap() {
    bail
}
fails() {
    false
    echo unreachable
}
# `exit` as the function's first command, spelled as a builtin.
quick() { builtin exit 5; }
x=$(bail)
y=$(wrap)
z=$(set -e; fails)
q=$(quick)
echo "after: $x $y $z$q"

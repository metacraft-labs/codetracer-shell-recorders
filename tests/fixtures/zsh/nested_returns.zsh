#!/usr/bin/env zsh
# `outer` and `outer1` end with a call of `inner`, so they return its status.
# All three have a local `x`; `inner` returns its own.
inner() {
    local x=$1
    return $x
}
outer() {
    local x=9
    inner "$1"
}
# The same on one line, so the call of `inner` is on outer's first line.
outer1() { local x=9; inner "$1"; }
outer 5
v=$(outer 6)
if outer 7; then echo unexpected; fi
outer1 8
echo "end${v}"

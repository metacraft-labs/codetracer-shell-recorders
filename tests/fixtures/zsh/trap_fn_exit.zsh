#!/usr/bin/env zsh
# An EXIT trap set inside a function runs when that function returns, with
# `$?` its status, and the recorder still closes the function's frame.
f() {
    trap 'echo "f done with $?"' EXIT
    x=1
    return 2
}
f
echo "f -> $?"
g() {
    trap 'echo "g never says this"' EXIT
    trap - EXIT
    return 3
}
g
echo "g -> $?"

#!/usr/bin/env zsh
HERE="${0:A:h}"
source "$HERE/source_returns_lib.zsh"
echo "lib status $?"
main() {
    source "$HERE/defs_only_lib.zsh"
    libf
    echo "main end"
}
main
echo "top end"

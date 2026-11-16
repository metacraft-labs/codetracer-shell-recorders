#!/usr/bin/env bash
# Recursion through command substitution: each level runs in a subshell.
fact() {
    local n=$1
    if (( n <= 1 )); then
        echo 1
        return 0
    fi
    local sub
    sub=$(fact $(( n - 1 )))
    echo $(( n * sub ))
}
r=$(fact 4)
echo "fact: $r"

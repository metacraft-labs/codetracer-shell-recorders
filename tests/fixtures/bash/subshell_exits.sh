#!/usr/bin/env bash
# Runs `exit` in a subshell and in a command substitution, then runs off its
# last line. Only the top-level shell's exit may produce an EXIT event.
( exit 2 )
x=$(exit 5)
echo "after subshells${x}"

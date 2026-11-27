#!/usr/bin/env zsh
# Calls `exit` from inside a function, so the shell ends with a user frame open.
die() {
    echo "dying"
    exit 4
}
echo start
die
echo unreachable

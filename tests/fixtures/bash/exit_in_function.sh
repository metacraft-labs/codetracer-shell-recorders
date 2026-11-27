#!/usr/bin/env bash
# Calls `exit` from inside a function, so the shell ends with a user frame open.
die() {
    echo "dying"
    exit 4
}
echo start
die
# shellcheck disable=SC2317 # reaching this line would be the defect
echo unreachable

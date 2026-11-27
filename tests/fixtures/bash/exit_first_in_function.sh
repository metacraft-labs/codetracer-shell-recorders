#!/usr/bin/env bash
# Calls `exit` as the first command of a function, so the shell ends with a
# user frame open that ran no other command.
die() { exit 4; }
echo start
die
# shellcheck disable=SC2317 # reaching this line would be the defect
echo unreachable

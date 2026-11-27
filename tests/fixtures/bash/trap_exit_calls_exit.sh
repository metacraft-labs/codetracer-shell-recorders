#!/usr/bin/env bash
# The script's EXIT action ends with `exit 7`: the process exits 7, so the
# EXIT event must carry 7, not the 0 the script ran off its end with.
trap 'echo "bye $?"; exit 7' EXIT
echo hi

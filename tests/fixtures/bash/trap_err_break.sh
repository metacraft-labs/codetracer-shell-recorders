#!/usr/bin/env bash
# An ERR action that leaves a loop with `break`: the action ends without
# running to its end, and the commands after the loop are the script's own,
# to be recorded (lines 11 and 12).
trap 'echo caught; break' ERR
f() {
    for i in 1 2; do
        false
        echo "in loop $i"
    done
    echo "after loop"
    echo "leaving f"
}
f
echo end

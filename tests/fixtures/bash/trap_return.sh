#!/usr/bin/env bash
# A RETURN action set by the script runs in the returning function's own
# context: FUNCNAME and the positional parameters are the function's.
f() {
    x=1
    return 3
}
trap 'echo "ret from ${FUNCNAME[0]} args=$*"' RETURN
f one two
echo "f -> $?"
trap - RETURN
f
echo "f -> $?"

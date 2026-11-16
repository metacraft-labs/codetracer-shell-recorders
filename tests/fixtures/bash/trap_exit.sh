#!/usr/bin/env bash
# The script's own EXIT trap runs, with the exit status, after the recorder
# writes its EXIT event; a subshell that exits under `set -e` runs its own
# EXIT trap but never its parent's, which Bash shows it without running.
trap 'echo "bye $?"' EXIT
trap -p EXIT
f() { false; }
( set -e; f; echo "not reached" )
echo "sub -> $?"
( set -e; trap 'echo "sub bye $?"' EXIT; f; echo "not reached" )
echo "sub -> $?"
exit 0

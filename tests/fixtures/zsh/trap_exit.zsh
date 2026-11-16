#!/usr/bin/env zsh
# The script's own EXIT trap runs, with the exit status, and the recorder
# still writes its EXIT event; a subshell that exits under `set -e` never
# runs its parent's EXIT trap. (No ZERR in this shell, and no EXIT trap in
# a subshell: with any DEBUG trap set, zsh runs the EXIT trap at the first
# command after a ZERR, and never runs a subshell's EXIT trap.)
trap 'echo "bye $?"' EXIT
trap
f() { false; }
( set -e; f; echo "not reached" ) || echo "sub failed"
exit 0

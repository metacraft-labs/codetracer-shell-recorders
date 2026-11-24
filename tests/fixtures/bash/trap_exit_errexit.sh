#!/usr/bin/env bash
# Under `set -e`, a failing command of the EXIT action ends the shell with
# that command's status (4), after the failures `set -e` ignores (an `if`
# condition, the left side of `||`) have not.
set -e
trap 'if false; then :; fi; false || echo "ignored"; (exit 4); echo "not reached"' EXIT
echo hi

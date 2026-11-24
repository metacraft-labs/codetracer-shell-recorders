#!/usr/bin/env bash
# An EXIT action that turns `set -e` off goes on past a failing command, and
# its `exit` without an argument still exits with the status the trap was
# entered with (3), not the failing command's.
set -e
trap 'set +e; false; echo "went on"; exit' EXIT
exit 3

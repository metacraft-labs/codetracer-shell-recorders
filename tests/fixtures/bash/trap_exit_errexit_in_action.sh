#!/usr/bin/env bash
# An EXIT action that turns `set -e` on itself: its failing command ends the
# shell with that command's status (6), although `set -e` was off when the
# script exited with 2.
trap 'set -e; echo "on"; (exit 6); echo "not reached"' EXIT
exit 2

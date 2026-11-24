#!/usr/bin/env bash
# `exit` with no argument in an EXIT action exits with the status the trap
# was entered with (5), not the status of the action's last command; an
# `exit` with a non-numeric argument fails and the action goes on (Bash
# 4.0 exits there instead, with 255).
trap 'exit nonsense 2>/dev/null; echo "after $?"; false; exit' EXIT
exit 5

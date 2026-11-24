#!/usr/bin/env bash
# `exit` with too many arguments in an EXIT action reports them and still
# exits, with the status the trap was entered with (6): the action does not
# go on.
trap 'exit 1 2 2>/dev/null; echo "not reached"' EXIT
exit 6

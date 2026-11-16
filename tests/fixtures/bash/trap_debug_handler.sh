#!/usr/bin/env bash
# The script's own DEBUG action must still run, before each command, with
# BASH_COMMAND naming that command and `$?` the status before it.
seen=""
trap 'seen+="[$BASH_COMMAND:$?]"' DEBUG
a=1
false || b=2
trap - DEBUG
echo "seen: $seen"

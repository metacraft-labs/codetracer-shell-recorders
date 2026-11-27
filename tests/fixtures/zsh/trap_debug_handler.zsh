#!/usr/bin/env zsh
# The script's own DEBUG action must still run before each command, with
# ZSH_DEBUG_CMD naming that command and `$?` the status before it.
seen=""
trap 'seen+="[$ZSH_DEBUG_CMD:$?]"' DEBUG
a=1
false || b=2
trap - DEBUG
echo "seen: $seen"

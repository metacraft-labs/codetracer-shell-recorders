#!/usr/bin/env zsh
# `trap - ZERR` and `trap '' ZERR` reset and ignore the script's action only.
trap 'echo "handled"' ZERR
false
trap - ZERR
false
trap '' ZERR
false
echo end

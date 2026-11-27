#!/usr/bin/env bash
# `trap - ERR` and `trap '' ERR` reset and ignore the script's action only.
trap 'echo "handled"' ERR
false
trap - ERR
false
trap '' ERR
false
echo end

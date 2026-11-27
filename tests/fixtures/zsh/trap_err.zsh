#!/usr/bin/env zsh
false
trap 'echo "handled"' ZERR
false
echo end

#!/usr/bin/env zsh
# `builtin trap` bypasses the recorder: its DEBUG trap is replaced, and the
# recording must say that it is incomplete.
a=1
builtin trap ':' DEBUG
b=2
echo end

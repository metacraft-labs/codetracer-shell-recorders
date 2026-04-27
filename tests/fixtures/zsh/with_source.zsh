#!/usr/bin/env zsh
# Script that sources another file
SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/zsh_sourced_lib.zsh"
x=10
lib_func "hello"
y=$((x + 5))
print "y=$y, LIB_VAR=$LIB_VAR"

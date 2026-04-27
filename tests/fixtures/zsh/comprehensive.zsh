#!/usr/bin/env zsh
# Comprehensive test: functions, arrays, float, sourced files
SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/zsh_sourced_lib.zsh"

integer count=0
float pi=3.14159
typeset -a items=(alpha beta gamma)
typeset -A config=([host]="localhost" [port]="8080")

process() {
    local input=$1
    count=$((count + 1))
    print "Processing: $input (#$count)"
    return 0
}

for item in "${items[@]}"; do
    process "$item"
done

lib_func "done"
result="count=$count pi=$pi"
print "$result"

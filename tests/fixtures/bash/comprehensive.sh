#!/bin/bash
# Comprehensive test: loops, conditionals, functions, arrays, sourced files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source a helper
source "$SCRIPT_DIR/sourced_lib.sh"

# Function with loop
count_to() {
    local n=$1
    local i
    for (( i=1; i<=n; i++ )); do
        echo "  $i"
    done
}

# Function with conditional
classify() {
    local val=$1
    if (( val > 0 )); then
        echo "positive"
    elif (( val < 0 )); then
        echo "negative"
    else
        echo "zero"
    fi
}

# Arrays
declare -a numbers=(1 2 3 4 5)
declare -A config=([host]="localhost" [port]="8080")

# Main logic
echo "Starting comprehensive test"
lib_func
count_to 3
classify 42
classify -1
classify 0
echo "Numbers: ${numbers[*]}"
echo "Host: ${config[host]}:${config[port]}"
echo "Done"

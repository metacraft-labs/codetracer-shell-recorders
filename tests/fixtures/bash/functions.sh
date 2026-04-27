#!/usr/bin/env bash
greet() {
    local name="$1"
    echo "Hello, $name!"
}

add() {
    local a=$1
    local b=$2
    echo $(( a + b ))
}

greet "World"
result=$(add 3 4)
echo "Sum: $result"

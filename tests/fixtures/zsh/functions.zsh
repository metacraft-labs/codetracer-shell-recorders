#!/usr/bin/env zsh
greet() {
    local name=$1
    print "Hello, $name!"
}

add() {
    local a=$1
    local b=$2
    local sum=$((a + b))
    return $sum
}

greet "World"
add 3 4
result=$?
print "Sum: $result"

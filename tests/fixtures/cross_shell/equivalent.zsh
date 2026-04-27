#!/usr/bin/env zsh
# Cross-shell test: identical logic in Zsh
x=10
y=20
z=$((x + y))

greet() {
    local name=$1
    echo "Hello, $name!"
}

greet "World"
result=$z
echo "result=$result"

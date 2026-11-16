#!/usr/bin/env zsh
double() {
    echo $(( $1 * 2 ))
}
for i in 1 2 3; do
    r=$(double "$i")
done
echo "last: $r"

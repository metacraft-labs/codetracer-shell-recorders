#!/usr/bin/env bash
double() {
    echo $(( $1 * 2 ))
}
seven() {
    return 7
}
for i in 1 2 3; do
    double "$i" > /dev/null
done
seven
rc=$?
echo "last: $rc"

#!/usr/bin/env bash
inner() {
    echo "inner called"
    return 0
}

outer() {
    echo "outer start"
    inner
    echo "outer end"
    return 42
}

outer
echo "done"

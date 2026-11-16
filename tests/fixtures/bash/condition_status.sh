#!/usr/bin/env bash
check() {
    [[ "$1" == yes ]]
}
if check no; then echo matched; fi
check yes && echo ok

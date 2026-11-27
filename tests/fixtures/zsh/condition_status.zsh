#!/usr/bin/env zsh
check() {
    [[ "$1" == yes ]]
}
if check no; then echo matched; fi
check yes && echo ok

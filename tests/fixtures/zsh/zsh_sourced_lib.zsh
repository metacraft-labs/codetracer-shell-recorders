#!/bin/zsh
# Library file to be sourced
lib_func() {
    local msg=$1
    print "lib: $msg"
}
LIB_VAR="from_zsh_lib"

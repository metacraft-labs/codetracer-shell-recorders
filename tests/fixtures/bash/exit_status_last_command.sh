#!/usr/bin/env bash
# Ends with a failing command and no `exit`: the script's status is that
# command's status, 1.
echo before
false

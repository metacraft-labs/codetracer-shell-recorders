#!/usr/bin/env bash
a=1
b=2
if [[ $a -lt $b ]]; then
    c="less"
else
    c="greater or equal"
fi
echo "$c"

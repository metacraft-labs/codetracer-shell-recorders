#!/usr/bin/env bash
# Calls `exit` with a status above 255: the process exits with its low eight
# bits (300 & 255 = 44), and that is the exit code the trace must carry.
echo working
# shellcheck disable=SC2242 # the out-of-range status is the point
exit 300

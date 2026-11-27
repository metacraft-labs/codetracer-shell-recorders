#!/usr/bin/env zsh
# Calls `exit` with a status above 255: the process exits with its low eight
# bits (300 & 255 = 44), and that is the exit code the trace must carry.
echo working
exit 300

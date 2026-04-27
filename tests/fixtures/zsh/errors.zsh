#!/usr/bin/env zsh
x=1
# This command will fail (non-zero exit)
false
y=2
# This will also fail
ls /nonexistent_path_12345 2>/dev/null
z=3
print "done"

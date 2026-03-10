#!/bin/bash
x=1
# This command will fail (non-zero exit)
false
y=2
# This will also fail
ls /nonexistent/path 2>/dev/null
z=3
echo "done"

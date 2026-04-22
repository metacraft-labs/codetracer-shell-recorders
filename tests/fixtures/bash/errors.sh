#!/bin/bash
x=1
# This command will fail (non-zero exit)
false
y=2
# This will also fail
ls /ct_recorder_test_nonexistent_path_xyzzy 2>/dev/null
z=3
echo "done"

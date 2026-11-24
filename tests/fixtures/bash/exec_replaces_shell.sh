#!/usr/bin/env bash
# Replaces the recording shell with another program: no command of the
# script runs after `exec`, nor does any EXIT trap. Prints whether the
# launcher's scratch-directory variable reached the script (it must not).
echo "scratch=${_CT_BASH_RECORDER_SCRATCH_DIR-unset}"
exec true

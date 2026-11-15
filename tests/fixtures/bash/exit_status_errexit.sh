#!/usr/bin/env bash
# Stops at a failing pipeline under `set -euo pipefail`. `pipefail` gives
# the pipeline the status of `false`, 1, and `errexit` ends the script there,
# so the line after it never runs.
set -euo pipefail
echo before
false | true
echo "not reached"

#!/usr/bin/env bash
# `trap` and `trap -p` show the script its own actions, not the recorder's.
echo "none: [$(trap -p DEBUG ERR RETURN)]"
trap 'echo "it'\''s handled"' ERR
trap 'echo int' INT
trap -p ERR
trap -p
trap
saved=$(trap -p ERR)
trap - ERR
echo "after reset: [$(trap -p ERR)]"
eval "$saved"
trap -p ERR
trap '' DEBUG
trap -p DEBUG
trap DEBUG
echo "after single-arg reset: [$(trap -p DEBUG)]"

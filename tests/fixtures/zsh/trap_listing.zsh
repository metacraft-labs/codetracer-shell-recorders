#!/usr/bin/env zsh
# `trap` shows the script its own actions, not the recorder's.
trap 'echo "it'\''s handled"' ZERR
trap 'echo int' INT
trap
trap - ZERR
trap
trap 'echo err' ERR
trap
trap '' DEBUG
trap
trap DEBUG
trap ZERR
trap
f() {
    trap 'echo bye' EXIT
    trap
}
f

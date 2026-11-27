#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/source_returns_lib.sh"
echo "lib status $?"
main() {
    source "$HERE/defs_only_lib.sh"
    libf
    echo "main end"
}
main
echo "top end"

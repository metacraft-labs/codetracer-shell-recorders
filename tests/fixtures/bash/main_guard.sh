#!/usr/bin/env bash
# Runs main only when executed, not when sourced (the usual guard).
main() {
    echo "main ran with $# args"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

#!/usr/bin/env zsh
# LOCAL_TRAPS: a ZERR trap set in a function with localtraps is restored
# when the function returns.
trap 'echo outer' ZERR
f() {
    setopt localtraps
    trap 'echo inner' ZERR
    false
}
f
false
echo end

#!/usr/bin/env zsh
# LOCAL_TRAPS in a function, with no DEBUG or ZERR trap of the script's
# outside it: the traps the function sets are its own, and gone once it
# returns, as without the recorder.
h() {
    setopt localtraps
    trap 'echo "h debug"' DEBUG
    trap 'echo "h zerr"' ZERR
    x=1
    false
}
h
y=2
false
echo end

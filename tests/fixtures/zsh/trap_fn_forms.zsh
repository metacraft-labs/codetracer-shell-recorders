#!/usr/bin/env zsh
# Function-form traps (TRAPZERR, TRAPDEBUG, `unfunction TRAPZERR`) keep
# working, and the recorder keeps capturing.
dbg=0
TRAPZERR() {
    echo "zerr handled"
}
false
TRAPDEBUG() {
    dbg=$(( dbg + 1 ))
}
x=1
y=2
trap - DEBUG
echo "debug ran $dbg times"
false
echo end
unfunction TRAPZERR
false
echo end2

#!/usr/bin/env zsh
# Parameters whose `typeset -p` flag word carries a number: an integer base
# (-i16, -i2), a zero-fill or justification width (-Z5, -L3, -R4), and
# those combined with other flags or exported. zsh 5.9.1 prints them as
#   typeset -i16 h=255        typeset -Z3 -r rz=7
#   typeset -Z5 z=42          typeset -L4 -Z4 lz=9
#   typeset -L3 l=abcdef      export -i16 xh=17
#   typeset -R4 r=ab          typeset -i2 gb=5
#                             export -Z4 gx=1
# The value is printed as assigned, not as `$name` expands (`$z` is 00042).
typeset -i16 h=255
typeset -Z5 z=42
typeset -L3 l=abcdef
typeset -R4 r=ab
typeset -rZ3 rz=7
typeset -L4 -Z4 lz=9
export -i16 xh=17
set_globals() {
    typeset -gi2 gb=5
    typeset -gxZ4 gx=1
}
set_globals
plain_str=s
echo done

#!/usr/bin/env zsh
g() { return 0; }
h() { echo h; }
g && h
echo end

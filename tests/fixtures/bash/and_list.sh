#!/usr/bin/env bash
g() { return 0; }
h() { echo h; }
g && h
echo end

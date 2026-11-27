#!/usr/bin/env bash
false
trap 'echo "handled"' ERR
false
echo end

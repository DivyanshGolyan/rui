#!/bin/sh
set -eu

output=$(/usr/bin/leaks --atExit -- "$1" 2>&1)
printf '%s\n' "$output"
printf '%s\n' "$output" | grep -Eq '0 leaks for 0 total leaked bytes|0 leaks for 0 total leaked bytes\.'

#!/bin/sh
set -eu
# Build the exact generated evaluator QuickJS translation unit with its private
# extension, not the older research copy. ASan disables pin-specific arenas so
# injected backing failures reach individual JS allocations.
generated=$1
quickjs=$(dirname "$2")
probe=$3
source_dir=$(dirname "$4")
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
zig cc -O1 -g -std=gnu11 -D_GNU_SOURCE -DQUICKJS_NG_BUILD=1 \
    -D__SANITIZE_ADDRESS__=1 -fsanitize=address,undefined \
    -fno-sanitize-recover=all -I "$quickjs" -I "$source_dir" \
    "$generated" "$quickjs/dtoa.c" "$quickjs/libregexp.c" \
    "$quickjs/libunicode.c" "$probe" -lm -o "$temporary/probe"
"$temporary/probe"
printf '%s\n' 'current QuickJS reader: individual allocation faults and ASan/UBSan passed'

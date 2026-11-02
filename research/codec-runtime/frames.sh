#!/bin/sh
# Native stack frames of WAMR's call path in a ReleaseSafe x86-64 binary that
# links it: frames.sh BINARY (e.g. zig-out of `zig build codec-runtime-bench`).
set -eu
for fn in wasm_runtime_call_wasm wasm_interp_call_wasm wasm_interp_call_func_bytecode \
    wasm_runtime_load_ex load_from_sections wasm_loader_prepare_bytecode wasm_instantiate; do
    address=$(nm "$1" | awk -v f="$fn" '$3 == f && ($2 == "t" || $2 == "T") { print $1 }')
    if [ -z "$address" ]; then echo "$fn: inlined"; continue; fi
    frame=$(objdump -d --start-address="0x$address" --stop-address="$(printf '0x%x' $((0x$address + 200)))" "$1" |
        grep -m1 -oE 'sub +\$0x[0-9a-f]+,%rsp' | grep -oE '0x[0-9a-f]+' || true)
    echo "$fn: $(printf '%d' "${frame:-0}") B below pushed registers"
done

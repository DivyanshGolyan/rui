#!/bin/sh
# Usage: run-counts.sh LABEL PLAIN_RUI SQL_RUI
# Sequential count-only runs on the same exported harness: STREAM100 fsync (strace -c),
# HOLD100 idle SQL counts, STREAM100 SQL statement counts.
set -u
label=$1 plain=$2 sql=$3
root=/home/user/workspace/repo/.amp/sqlv2
out=$root/raw/$label
mkdir -m 700 -p "$out"
log=$root/attempts.md
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha256sum "$plain" "$sql" "$root/bin/model-output" "$root/bin/hold-test" "$root/bin/rui-strace-launch" > "$out/identity.sha256"

echo "- $(stamp) $label stream100-strace start" >> "$log"
env -u LD_PRELOAD SQLV2_RUI="$plain" P2_SYSCALL_OUTPUT="$out/stream100-strace.txt" \
  "$root/bin/model-output" --capacity 100 --output "$out/stream100-strace.json" "$root/bin/rui-strace-launch" \
  > "$out/stream100-strace-controller.log" 2>&1
echo "- $(stamp) $label stream100-strace exit=$?" >> "$log"

mkdir -m 700 "$out/hold100"
echo "- $(stamp) $label hold100-sql start" >> "$log"
env -u LD_PRELOAD P2_SQL_BINARY="$sql" P2_SQL_DIRECTORY="$out/hold100" \
  "$root/bin/hold-test" -test.run '^TestP2PostfixHold$' -test.v -test.timeout 4m \
  > "$out/hold100-controller.log" 2>&1
echo "- $(stamp) $label hold100-sql exit=$?" >> "$log"

echo "- $(stamp) $label stream100-sql start" >> "$log"
env -u LD_PRELOAD "$root/bin/model-output" --capacity 100 --output "$out/stream100-sql.json" "$sql" \
  > "$out/stream100-sql-controller.log" 2>&1
echo "- $(stamp) $label stream100-sql exit=$?" >> "$log"

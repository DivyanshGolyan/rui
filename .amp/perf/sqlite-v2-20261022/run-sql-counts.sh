#!/bin/sh
# Usage: run-sql-counts.sh LABEL SQL_RUI — HOLD100 idle SQL counts, then STREAM100 SQL statement counts.
set -u
label=$1 sql=$2
root=/home/user/workspace/repo/.amp/sqlv2
out=$root/raw/$label
mkdir -m 700 -p "$out"
log=$root/attempts.md
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha256sum "$sql" "$root/bin/model-output" "$root/bin/hold-test" > "$out/identity.sha256"
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
artifacts=$(jq -r .artifacts "$out/stream100-sql.json")
gzip -cn "$artifacts/capacity-100/host-stderr.log" > "$out/stream100-sql-host-stderr.log.gz"
gzip -kn "$out/hold100/host-stderr.log"

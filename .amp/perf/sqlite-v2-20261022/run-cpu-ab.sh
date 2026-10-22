#!/bin/sh
# Matched uninstrumented Host CPU A/B: same model-output harness binary, actual Rui
# binaries passed directly (no launcher), LD_PRELOAD unset, order A B B A A B.
set -u
root=/home/user/workspace/repo/.amp/sqlv2
out=$root/raw/cpu-ab
mkdir -m 700 -p "$out"
log=$root/attempts.md
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sha256sum "$root/bin/rui-baseline" "$root/bin/rui-cand2" "$root/bin/model-output" > "$out/identity.sha256"
i=0
for label in baseline cand2 cand2 baseline baseline cand2; do
  i=$((i + 1))
  echo "- $(stamp) cpu-ab run $i $label stream100 start" >> "$log"
  env -u LD_PRELOAD "$root/bin/model-output" --capacity 100 --output "$out/$i-$label.json" "$root/bin/rui-$label" \
    > "$out/$i-$label-controller.log" 2>&1
  echo "- $(stamp) cpu-ab run $i $label stream100 exit=$?" >> "$log"
done
touch /tmp/cpu-ab-done

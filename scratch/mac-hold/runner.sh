#!/bin/bash
# 3 rounds; tool order rotates each round. Private_Dirty summed over each process tree.
H=/opt/hm; export FX_BIN=/opt/fx/zig-out/bin/fx
TOOLS=(rui codex-app-server pi-sdk opencode-serve fx)
for r in 1 2 3; do
  k=${#TOOLS[@]}
  for j in $(seq 0 $((k-1))); do
    t=${TOOLS[$(( (j + r - 1) % k ))]}
    if [ $t = rui ]; then
      python3 -I $H/rui_hold.py --repo /home/user/rui --build main=/opt/rui-intro/bin/rui --out $H/runs/r$r/rui --reps 1 >> $H/rui.log 2>&1
      continue
    fi
    for n in 0 1 10 100; do
      [ $t = fx ] && [ $n = 0 ] && continue
      line=$(timeout 600 python3 -I $H/hold.py $t $n $H/runs/r$r/$t-$n 10)
      echo "{\"round\": $r, \"t\": \"$(date -u +%FT%TZ)\", \"res\": ${line:-null}}" >> $H/results.jsonl
      sleep 3
    done
  done
done
echo DONE >> $H/results.jsonl

#!/bin/bash
cd /tmp/claude-0/-home-user/ca23beed-8da3-504e-a003-77f636af7c40/scratchpad/h
for r in 1 2 3; do
 for t in codex-sdk claude-sdk; do
  for n in 0 1 10 50 100; do
   [ $t = claude-sdk ] && [ $n = 100 ] && continue
   line=$(timeout 600 python3 -I hold.py $t $n /tmp/claude-0/-home-user/ca23beed-8da3-504e-a003-77f636af7c40/scratchpad/h/runs/r$r/$t-$n 10)
   echo "{\"round\": $r, \"res\": ${line:-null}}" >> /tmp/claude-0/-home-user/ca23beed-8da3-504e-a003-77f636af7c40/scratchpad/h/results.jsonl
   sleep 3
  done
 done
done
echo DONE >> /tmp/claude-0/-home-user/ca23beed-8da3-504e-a003-77f636af7c40/scratchpad/h/results.jsonl

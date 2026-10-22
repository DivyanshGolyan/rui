#!/bin/sh
cd /home/user/workspace/repo/.amp/sqlv2/strace-pair-bbabd879
for n in base cand; do
  echo "$(date -u +%FT%TZ) build $n start" >> log.txt
  (cd $n-source && zig build -Doptimize=ReleaseFast) > build-$n.log 2>&1
  echo "$(date -u +%FT%TZ) build $n exit=$?" >> log.txt
done
touch built

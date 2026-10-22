#!/bin/sh
# One pre-spawn memory probe per arm, order base, cand, same CPU load (4 busy loops on 2 vCPU).
set -u
d=/home/user/workspace/repo/.amp/sqlv2/launch-mem
p=/home/user/workspace/repo/.amp/sqlv2/strace-pair-bbabd879
export PYTHONPATH=$p/base-source/tests/integration
sha256sum $p/base-source/zig-out/bin/rui $p/cand-source/zig-out/bin/rui $d/mem_probe.py "$0" > $d/identity.sha256
for arm in base cand; do
  loads=; for i in 1 2 3 4; do sh -c 'while :; do :; done' & loads="$loads $!"; done; sleep 1
  echo "$(date -u +%FT%TZ) mem $arm start" >> $d/log.txt
  timeout 300 python3 $d/mem_probe.py $p/$arm-source/zig-out/bin/rui $d/$arm.json > $d/$arm.log 2>&1
  echo "$(date -u +%FT%TZ) mem $arm exit=$?" >> $d/log.txt
  kill $loads; for x in $loads; do wait $x 2>/dev/null; done
done

#!/bin/sh
# Same method as ../strace-pair/run-pair.sh: one Bash launch per arm, exact fixture command (timeout_ms=100) via
# control/same_group_control_v2.py, 4 busy loops on 2 vCPU, Host traced with strace -D -f -tt -T -y.
# Harness modules come from the bbabd879 export for both arms.
set -u
d=/home/user/workspace/repo/.amp/sqlv2/strace-pair-bbabd879
export PYTHONPATH=$d/base-source/tests/integration
sha256sum $d/base-source/zig-out/bin/rui $d/cand-source/zig-out/bin/rui $d/strace-launch.py "$0" \
  $d/../control/same_group_control_v2.py $PYTHONPATH/bash_integration.py $PYTHONPATH/model_fixture.py \
  $PYTHONPATH/host_process.py /usr/bin/strace > $d/identity.sha256
for arm in base cand; do
  loads=
  for i in 1 2 3 4; do sh -c 'while :; do :; done' & loads="$loads $!"; done
  sleep 1
  echo "$(date -u +%FT%TZ) pair $arm start" >> $d/log.txt
  PAIR_RUI=$d/$arm-source/zig-out/bin/rui PAIR_STRACE_OUTPUT=$d/$arm.strace \
    timeout 300 python3 $d/../control/same_group_control_v2.py $d/strace-launch.py $d/$arm.json 1 > $d/$arm.log 2>&1
  echo "$(date -u +%FT%TZ) pair $arm exit=$?" >> $d/log.txt
  kill $loads; for p in $loads; do wait $p 2>/dev/null; done
done
touch $d/done

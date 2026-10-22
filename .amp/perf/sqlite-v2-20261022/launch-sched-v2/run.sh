#!/bin/sh
set -u
d=/home/user/workspace/repo/.amp/sqlv2/launch-sched-v2
p=/home/user/workspace/repo/.amp/sqlv2/strace-pair-bbabd879
export PYTHONPATH=$p/base-source/tests/integration
sha256sum $p/base-source/zig-out/bin/rui $p/cand-source/zig-out/bin/rui "$0" $d/PREDECLARED.md \
  $d/../control/same_group_control_v2.py /usr/bin/perf > $d/identity.sha256
n=0
for r in 1 2 3; do for arm in base cand cand base; do
  n=$((n+1)); name=$(printf '%02d-%s' $n $arm)
  loads=; for i in 1 2 3 4; do sh -c 'while :; do :; done' & loads="$loads $!"; done
  sudo perf record -q -a -k mono -o $d/$name.perf.data \
    -e sched:sched_switch -e sched:sched_wakeup_new -e sched:sched_process_fork -e sched:sched_process_exec \
    -e sched:sched_migrate_task -e exceptions:page_fault_user \
    -e raw_syscalls:sys_enter --filter 'id == 56 || id == 435' \
    -e raw_syscalls:sys_exit --filter 'id == 56 || id == 435' > $d/$name.perf.log 2>&1 &
  pp=$!; sleep 1
  echo "$(date -u +%FT%TZ) $name start" >> $d/log.txt
  timeout 600 python3 $d/../control/same_group_control_v2.py $p/$arm-source/zig-out/bin/rui $d/$name.json 10 > $d/$name.log 2>&1
  echo "$(date -u +%FT%TZ) $name exit=$?" >> $d/log.txt
  sudo kill -INT $pp; wait $pp 2>/dev/null; sudo chown user $d/$name.perf.data
  kill $loads; for x in $loads; do wait $x 2>/dev/null; done
done; done
touch $d/done

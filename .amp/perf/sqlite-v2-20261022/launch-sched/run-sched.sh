#!/bin/sh
# One Bash launch per arm and observer: perf-only (Host untraced by ptrace), then perf + the same strace -f launcher
# as the strace pairs. Exact fixture command (timeout_ms=100) via control/same_group_control_v2.py, 4 busy loops on
# 2 vCPU. System-wide perf records the child from fork. Order: perf base, perf cand, strace base, strace cand.
set -u
d=/home/user/workspace/repo/.amp/sqlv2/launch-sched
p=/home/user/workspace/repo/.amp/sqlv2/strace-pair-bbabd879
export PYTHONPATH=$p/base-source/tests/integration
sha256sum $p/base-source/zig-out/bin/rui $p/cand-source/zig-out/bin/rui $p/strace-launch.py "$0" \
  $d/../control/same_group_control_v2.py /usr/bin/perf /usr/bin/strace > $d/identity.sha256
for run in perf-base perf-cand strace-base strace-cand; do
  arm=${run#*-}; mode=${run%-*}
  bin=$p/$arm-source/zig-out/bin/rui; [ $mode = strace ] && bin=$p/strace-launch.py
  loads=; for i in 1 2 3 4; do sh -c 'while :; do :; done' & loads="$loads $!"; done
  sudo perf record -q -a -k mono -o $d/$run.perf.data \
    -e sched:sched_switch -e sched:sched_wakeup_new -e sched:sched_waking -e sched:sched_migrate_task \
    -e sched:sched_process_fork -e sched:sched_process_exec -e exceptions:page_fault_user \
    -e raw_syscalls:sys_enter -e raw_syscalls:sys_exit > $d/$run.perf.log 2>&1 &
  pp=$!; sleep 1
  echo "$(date -u +%FT%TZ) $run start" >> $d/log.txt
  PAIR_RUI=$p/$arm-source/zig-out/bin/rui PAIR_STRACE_OUTPUT=$d/$run.strace \
    timeout 300 python3 $d/../control/same_group_control_v2.py $bin $d/$run.json 1 > $d/$run.log 2>&1
  echo "$(date -u +%FT%TZ) $run exit=$?" >> $d/log.txt
  sudo kill -INT $pp; wait $pp 2>/dev/null; sudo chown user $d/$run.perf.data
  kill $loads; for x in $loads; do wait $x 2>/dev/null; done
done

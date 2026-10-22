#!/bin/sh
# Predeclared bounded diagnostic v2 (see attempts.md): CPU load, (B C C B) x REPEATS, 30 trials/block,
# system-wide perf tracepoints recorded over every block.
set -u
root=/home/user/workspace/repo/.amp/sqlv2
out=$root/raw/control-v2
mkdir -m 700 -p "$out"
log=$root/attempts.md
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
export PYTHONPATH=/home/user/workspace/repo/tests/integration
sha256sum "$root/bin/rui-baseline" "$root/bin/rui-cand2" "$root/control/same_group_control_v2.py" "$0" \
  /home/user/workspace/repo/tests/integration/bash_integration.py /usr/bin/perf > "$out/identity.sha256"
n=0
for repeat in $(seq 1 "${REPEATS:-5}"); do
  for label in baseline cand2 cand2 baseline; do
    n=$((n + 1))
    name=$(printf '%02d-%s' "$n" "$label")
    loads=
    for i in 1 2 3 4; do sh -c 'while :; do :; done' & loads="$loads $!"; done
    sudo perf record -q -a -k mono -o "$out/$name.perf.data" \
      -e ext4:ext4_sync_file_enter -e ext4:ext4_sync_file_exit \
      -e jbd2:jbd2_start_commit -e jbd2:jbd2_end_commit \
      -e sched:sched_switch -e sched:sched_process_exec > "$out/$name.perf.log" 2>&1 &
    perf_pid=$!
    sleep 1
    echo "- $(stamp) control-v2 block $name start" >> "$log"
    timeout 900 python3 "$root/control/same_group_control_v2.py" "$root/bin/rui-$label" "$out/$name.json" 30 \
      > "$out/$name.log" 2>&1
    echo "- $(stamp) control-v2 block $name exit=$?" >> "$log"
    sudo kill -INT "$perf_pid" 2>/dev/null; sudo pkill -INT -f "perf record -q -a -k mono -o $out/$name.perf.data"
    wait "$perf_pid" 2>/dev/null; sudo chown user "$out/$name.perf.data"
    kill $loads 2>/dev/null
    for p in $loads; do wait "$p" 2>/dev/null; done
  done
done
touch /tmp/control-v2-done

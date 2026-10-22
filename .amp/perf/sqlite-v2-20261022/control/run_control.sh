#!/bin/sh
# Interleaved matched control: baseline vs candidate, same fixture command,
# same load per block. Order per load: B C C B. 30 trials per block.
set -u
root=/home/user/workspace/repo/.amp/sqlv2
out=$root/raw/control
log=$root/attempts.md
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
export PYTHONPATH=/home/user/workspace/repo/tests/integration
sha256sum "$root/bin/rui-baseline" "$root/bin/rui-cand2" "$root/control/same_group_control.py" \
  /home/user/workspace/repo/tests/integration/bash_integration.py > "$out/identity.sha256"
start_load() {
  case $1 in
    none) ;;
    cpu) for i in 1 2 3 4; do sh -c 'while :; do :; done' & loads="$loads $!"; done ;;
    fsync) for i in 1 2; do python3 -c '
import os,sys
f=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT,0o600)
while True:
    os.write(f,b"x"*4096); os.fsync(f)' /tmp/rui-control-fsync-$i & loads="$loads $!"; done ;;
  esac
}
for load in ${LOADS:-none cpu fsync}; do
  n=0
  for label in baseline cand2 cand2 baseline; do
    n=$((n + 1))
    loads=
    start_load $load
    sleep 1
    echo "- $(stamp) control $load block $n $label start" >> "$log"
    timeout 900 python3 "$root/control/same_group_control.py" "$root/bin/rui-$label" "$out/$load-$n-$label.json" 30 \
      > "$out/$load-$n-$label.log" 2>&1
    echo "- $(stamp) control $load block $n $label exit=$?" >> "$log"
    [ -n "$loads" ] && kill $loads 2>/dev/null
    for p in $loads; do wait $p 2>/dev/null; done
  done
done
rm -f /tmp/rui-control-fsync-*
touch /tmp/control-done

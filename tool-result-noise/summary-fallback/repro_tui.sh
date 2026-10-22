#!/bin/bash
# Real running TUI in tmux: live summary, then a fresh `rui session resume`
# (reopened history). argv: LABEL RUI_BINARY OUTDIR
set -euo pipefail
label=$1 bin=$(realpath "$2") out=$(realpath "$3") repo=/home/user/workspace/repo
state=/tmp/repro-$label
rm -rf "$state"; mkdir -m 700 "$state"
python3 "$repo/.amp/evidence/repro_host.py" "$bin" "$state" > "$state.log" 2>&1 &
driver=$!
for _ in $(seq 1 60); do [ -f "$state/ready" ] && break; sleep 0.5; done
[ -f "$state/ready" ] || { cat "$state.log"; exit 1; }
run="cd $state/workspace && env HOME=$state $bin session resume --store $state/store demo/repro"
tmux -L repro kill-server 2>/dev/null || true
tmux -L repro -f /dev/null new-session -d -s tui -x 100 -y 20 "$run"
sleep 3
tmux -L repro send-keys -t tui -l "run the check"; tmux -L repro send-keys -t tui Enter; sleep 6
tmux -L repro capture-pane -p -t tui > "$out/$label-live.txt"
tmux -L repro send-keys -t tui -l "/exit"; tmux -L repro send-keys -t tui Enter; sleep 2
tmux -L repro kill-server 2>/dev/null || true
tmux -L repro -f /dev/null new-session -d -s tui -x 100 -y 20 "$run"
sleep 4
tmux -L repro capture-pane -p -t tui > "$out/$label-reopened.txt"
tmux -L repro send-keys -t tui -l "/exit"; tmux -L repro send-keys -t tui Enter; sleep 2
tmux -L repro kill-server 2>/dev/null || true
touch "$state/stop"; wait $driver || true
cp "$state/outputs.json" "$out/$label-model-outputs.json"

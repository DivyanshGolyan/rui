#!/bin/bash
# Real foot/Sway capture of one binary's running TUI. foot renders a tmux
# client in which `rui session resume` runs; tmux send-keys carries input
# (direct wtype input dropped keys and Return in two discarded attempts).
# argv: LABEL RUI_BINARY OUTDIR
set -euo pipefail
label=$1 bin=$(realpath "$2") out=$(realpath "$3") repo=/home/user/workspace/repo
export XDG_RUNTIME_DIR=/tmp/swayrt WAYLAND_DISPLAY=wayland-1
SWAYSOCK=$(ls /tmp/swayrt/sway-ipc.*.sock); export SWAYSOCK
state=/tmp/tui-$label
rm -rf "$state"; mkdir -m 700 "$state"
python3 "$repo/.amp/evidence/tui_host.py" "$bin" "$state" > "$state.log" 2>&1 &
host_driver=$!
for _ in $(seq 1 60); do [ -f "$state/ready" ] && break; sleep 0.5; done
[ -f "$state/ready" ] || { cat "$state.log"; exit 1; }
printf '#!/bin/bash\ncd %s/workspace\nexec env -u NO_COLOR HOME=%s %s session resume --store %s/store demo/tui\n' \
  "$state" "$state" "$bin" "$state" > "$state/tui.sh"
chmod +x "$state/tui.sh"
tmux -L cap kill-server 2>/dev/null || true
foot -a "rui-$label" -W 100x30 -o font=monospace:size=10 \
  tmux -L cap -f /dev/null new-session -s tui "$state/tui.sh" > "$state.foot.log" 2>&1 &
sleep 3
tmux -L cap set -g status off
swaymsg -q "[app_id=\"rui-$label\"] focus"
rect=$(swaymsg -t get_tree | python3 -c "
import json,sys
def walk(n):
    if n.get('app_id')=='rui-$label':
        r=n['rect']; print(f\"{r['x']},{r['y']} {r['width']}x{r['height']}\"); sys.exit()
    for c in n.get('nodes',[])+n.get('floating_nodes',[]): walk(c)
walk(json.load(sys.stdin))")
echo "rect $rect"
keys() { tmux -L cap send-keys -t tui "$@"; }
sleep 2
keys -l "list the workspace"; keys Enter; sleep 6
keys -l "now check missing-file"; keys Enter; sleep 6
grim -g "$rect" "$out/$label-live.png"
tmux -L cap capture-pane -p -t tui > "$out/$label-live.txt"
wf-recorder -g "$rect" -f "$out/$label-details.mp4" > "$state.wfr.log" 2>&1 &
rec=$!
sleep 2
keys -l "/details"; keys Enter; sleep 3
grim -g "$rect" "$out/$label-details.png"
tmux -L cap capture-pane -p -t tui > "$out/$label-details.txt"
keys Escape; sleep 3
grim -g "$rect" "$out/$label-returned.png"
kill -INT $rec; wait $rec || true
keys -l "/exit"; keys Enter; sleep 2
tmux -L cap kill-server 2>/dev/null || true
touch "$state/stop"
wait $host_driver || true
cp "$state/outputs.json" "$out/$label-model-outputs.json"

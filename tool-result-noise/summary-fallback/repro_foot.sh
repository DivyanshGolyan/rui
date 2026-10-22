#!/bin/bash
# Graphical capture of the failed-summary repro: foot under headless Sway renders
# a tmux client running `rui session resume`; grim screenshots the live state,
# then a fresh resume (reopened history). argv: LABEL RUI_BINARY OUTDIR
set -euo pipefail
label=$1 bin=$(realpath "$2") out=$(realpath "$3") repo=/home/user/workspace/repo
export XDG_RUNTIME_DIR=/tmp/swayrt WAYLAND_DISPLAY=wayland-1
SWAYSOCK=$(ls /tmp/swayrt/sway-ipc.*.sock); export SWAYSOCK
state=/tmp/repro-$label
rm -rf "$state"; mkdir -m 700 "$state"
python3 "$repo/.amp/evidence/repro_host.py" "$bin" "$state" > "$state.log" 2>&1 &
driver=$!
for _ in $(seq 1 60); do [ -f "$state/ready" ] && break; sleep 0.5; done
[ -f "$state/ready" ] || { cat "$state.log"; exit 1; }
printf '#!/bin/bash\ncd %s/workspace\nexec env -u NO_COLOR HOME=%s %s session resume --store %s/store demo/repro\n' \
  "$state" "$state" "$bin" "$state" > "$state/tui.sh"
chmod +x "$state/tui.sh"
keys() { tmux -L cap send-keys -t tui "$@"; }
shot() { # NAME: open foot on the tmux session, screenshot, close foot
  foot -a "rui-$label" -W 100x20 -o font=monospace:size=10 tmux -L cap attach -t tui > "$state.foot.log" 2>&1 &
  local foot_pid=$!
  sleep 3
  local rect
  rect=$(swaymsg -t get_tree | python3 -c "
import json,sys
def walk(n):
    if n.get('app_id')=='rui-$label':
        r=n['rect']; print(f\"{r['x']},{r['y']} {r['width']}x{r['height']}\"); sys.exit()
    for c in n.get('nodes',[])+n.get('floating_nodes',[]): walk(c)
walk(json.load(sys.stdin))")
  grim -g "$rect" "$out/$label-$1.png"
  tmux -L cap capture-pane -p -t tui > "$out/$label-$1.txt"
  kill $foot_pid; wait $foot_pid 2>/dev/null || true
}
tmux -L cap kill-server 2>/dev/null || true
tmux -L cap -f /dev/null new-session -d -s tui -x 100 -y 20 "$state/tui.sh"
tmux -L cap set -g status off
sleep 3
keys -l "run the check"; keys Enter; sleep 6
shot live
keys -l "/exit"; keys Enter; sleep 2
tmux -L cap kill-server 2>/dev/null || true
tmux -L cap -f /dev/null new-session -d -s tui -x 100 -y 20 "$state/tui.sh"
tmux -L cap set -g status off
sleep 4
shot reopened
keys -l "/exit"; keys Enter; sleep 2
tmux -L cap kill-server 2>/dev/null || true
touch "$state/stop"; wait $driver || true
cp "$state/outputs.json" "$out/$label-model-outputs.json"

#!/usr/bin/env bash
# One-shot tool-turn campaign. A supervisor restart must not rerun it.
set -u
C=/home/user/workspace/.perf-tool/campaign
if [ -e "$C/started" ]; then echo "campaign already started; refusing to rerun" >&2; sleep infinity; fi
mkdir -p "$C"
date -u +%FT%TZ > "$C/started"
H="$C/measure-model-output"
cp /home/user/workspace/.perf-tool/measure-model-output "$H"
sha256sum "$H" /home/user/workspace/.perf-tool/build-d4f87000/bin/rui > "$C/identities.txt"
RUI=/home/user/workspace/.perf-tool/build-d4f87000/bin/rui
cd /home/user/workspace/repo
declare -A EST=(
  [sleep-1]="Host PSS ~10.8 MB, tree peak ~18.3 MB (Host 10.8 + TUI 6.7 + bash/sleep 0.8); Host CPU ~0.4 s for 2 requests + 1 call (N=1 smoke)"
  [sleep-10]="tree peak ~23 MB (Host 11 + TUI 6.7 + 10 x ~0.5 MB shell+sleep); Host CPU ~0.6 s; 10 sleeps overlap"
  [sleep-100]="tree peak ~56 MB (Host 11.3 + ~97 shells x 0.3 MB + ~97 sleeps x 0.1 MB + TUI 6.7); Host CPU ~9.6 s = ~48 ms x 200 requests (N=100 smoke)"
  [read-1]="tree peak ~18 MB (cat lives ms, likely unobserved); Host CPU ~0.35 s"
  [read-10]="tree peak ~18-19 MB, few shells observed; Host CPU ~0.45 s"
  [read-100]="Host CPU ~9 s (~45 ms/request x 200, 400 KB history each); observed peak ~20-30 MB since reads are short"
)
run() { # label workload sessions [trace]
  local label=$1 workload=$2 sessions=$3 trace=${4:-}
  local estimate="${EST[$workload-$sessions]}"
  [ -n "$trace" ] && estimate="instrumented strace run, timings not comparable; fork-to-exec ~1 ms (smoke) / $estimate"
  printf '%s\t%s\t%s\n' "$(date -u +%FT%T.%NZ)" "$label" "estimated: $estimate" >> "$C/napkins.tsv"
  local start=$(date -u +%FT%T.%NZ)
  local extra=()
  [ -n "$trace" ] && extra=(--tool-trace-forks /usr/bin/strace)
  timeout 900 "$H" --tool-sessions "$sessions" --tool-workload "$workload" "${extra[@]}" --expectation "$estimate" --output "$C/$label.json" "$RUI" > "$C/$label.stdout" 2>&1
  local code=$?
  printf '%s\t%s\t%s\t%s\n' "$start" "$(date -u +%FT%T.%NZ)" "$label" "$code" >> "$C/attempts.tsv"
}
for repeat in 1 2 3; do
  for workload in sleep read; do
    for sessions in 1 10 100; do
      run "$workload-n$sessions-r$repeat" "$workload" "$sessions"
    done
  done
done
for sessions in 1 10 100; do
  run "strace-sleep-n$sessions" sleep "$sessions" trace
done
run "strace-read-n100" read 100 trace
date -u +%FT%TZ > "$C/finished"
sleep infinity

#!/usr/bin/env bash
# One-shot tool-turn campaign. A supervisor restart must not rerun it.
set -u
C=/home/user/workspace/.perf-tool/campaign-v2-v2
if [ -e "$C/started" ]; then echo "campaign already started; refusing to rerun" >&2; sleep infinity; fi
mkdir -p "$C"
date -u +%FT%TZ > "$C/started"
H="$C/measure-model-output"
cp /home/user/workspace/.perf-tool/measure-model-output-v2 "$H"
sha256sum "$H" /home/user/workspace/.perf-tool/build-d4f87000/bin/rui > "$C/identities.txt"
RUI=/home/user/workspace/.perf-tool/build-d4f87000/bin/rui
cd /home/user/workspace/repo
declare -A EST=(
  [sleep-1]="barrier: 1 in flight; tree peak ~18.4 MB (Host 10.8 + TUI 6.8 + shell/sleep 0.9); Host CPU ~0.4 s"
  [sleep-10]="barrier: 10 in flight; tree peak ~23 MB; Host CPU ~1.7 s"
  [sleep-100]="barrier: 100 in flight; tree peak ~58 MB (Host 11.4 + Bash ~40 + TUI 6.7); Host CPU ~10 s (v1 9.6 s plus parking)"
  [read-1]="barrier: 1 in flight; tree peak ~18 MB; Host CPU ~0.1 s"
  [read-10]="barrier: 10 cats in flight; tree peak ~22 MB; Host CPU ~0.5 s"
  [read-100]="barrier: 100 cats in flight (smoke 100); tree peak ~58 MB; Host CPU ~8.6 s (smoke)"
)
run() { # label workload sessions ms [trace]
  local label=$1 workload=$2 sessions=$3 ms=$4 trace=${5:-}
  local estimate="${EST[$workload-$sessions]}; sampler ${ms} ms"
  [ "$ms" = 25 ] && estimate="$estimate (observer ~0.23 s at N=1, ~1.5 s at N=100 per smoke; sends seen ~20%)"
  [ -n "$trace" ] && estimate="instrumented strace run, timings not comparable; fork-to-exec ~0.8 ms median (v1) / $estimate"
  printf '%s\t%s\t%s\n' "$(date -u +%FT%T.%NZ)" "$label" "estimated: $estimate" >> "$C/napkins.tsv"
  local start=$(date -u +%FT%T.%NZ)
  local extra=()
  [ -n "$trace" ] && extra=(--tool-trace-forks /usr/bin/strace)
  timeout 900 "$H" --tool-sessions "$sessions" --tool-workload "$workload" --tool-barrier --tool-sample-ms "$ms" "${extra[@]}" --expectation "$estimate" --output "$C/$label.json" "$RUI" > "$C/$label.stdout" 2>&1
  local code=$?
  printf '%s\t%s\t%s\t%s\n' "$start" "$(date -u +%FT%T.%NZ)" "$label" "$code" >> "$C/attempts.tsv"
}
for repeat in 1 2 3; do
  for ms in 200 25; do
    for workload in sleep read; do
      for sessions in 1 10 100; do
        run "$workload-n$sessions-ms$ms-r$repeat" "$workload" "$sessions" "$ms"
      done
    done
  done
done
run strace-read-n100 read 100 200 trace
run strace-sleep-n100 sleep 100 200 trace
date -u +%FT%TZ > "$C/finished"
sleep infinity

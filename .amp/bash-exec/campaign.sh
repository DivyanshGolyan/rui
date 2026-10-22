#!/usr/bin/env bash
# One-shot Bash launch A/B campaign. A supervisor restart must not rerun it.
set -u
P=/home/user/workspace/.perf-bash
C=$P/campaign
if [ -e "$C/started" ]; then echo "campaign already started; refusing to rerun" >&2; sleep infinity; fi
mkdir -p "$C"
date -u +%FT%TZ > "$C/started"
H="$C/measure-model-output"
cp "$P/measure-model-output" "$H"
declare -A RUI=([base]=$P/build-base-671c3c7d/bin/rui [cand]=$P/build-cand-6f2dd44c/bin/rui)
sha256sum "$H" "${RUI[base]}" "${RUI[cand]}" > "$C/identities.txt"
/bin/bash --version | head -1 >> "$C/identities.txt"
cd /home/user/workspace/wt-harness
git rev-parse HEAD HEAD:tests/qualification >> "$C/identities.txt"
# Napkin estimates written before each run (MB are Linux PSS, Bash column).
declare -A EST=(
  [base-sleep-1]="script mode, 1 parked shell then shell+sleep; Bash peak ~0.8 MB; Host CPU ~0.4 s"
  [cand-sleep-1]="-c, 1 parked shell then sleep alone (same PID); Bash peak ~0.6 MB (parked shell), post-release ~0.2 MB; Host CPU ~0.4 s"
  [base-sleep-10]="script mode; Bash peak ~5.4 MB (10 shells + 10 sleeps); Host CPU ~1.7 s"
  [cand-sleep-10]="-c; Bash peak ~4 MB while parked, post-release ~1.5 MB (10 sleeps); Host CPU ~1.7 s"
  [base-sleep-100]="script mode; Bash peak ~40 MB (100 shells 0.33 + 100 sleeps 0.1-0.17); Host CPU ~9 s"
  [cand-sleep-100]="-c; Bash peak ~33 MB while parked, post-release ~12-17 MB (100 sleeps); Host CPU ~9 s"
  [base-read-1]="script mode; Bash peak ~0.9 MB; Host CPU ~0.1 s"
  [cand-read-1]="-c; Bash peak ~0.6 MB parked; cat replaces shell for ~ms; Host CPU ~0.1 s"
  [base-read-10]="script mode; Bash peak ~3.5-5 MB; Host CPU ~0.6 s"
  [cand-read-10]="-c; Bash peak ~3-4 MB parked; Host CPU ~0.6 s"
  [base-read-100]="script mode; Bash peak ~30-46 MB (parked shells, then shells+cats); Host CPU ~8.6 s"
  [cand-read-100]="-c; Bash peak ~33 MB parked, post-release burst below baseline; Host CPU ~8.6 s"
)
run() { # arm workload sessions repeat
  local arm=$1 workload=$2 sessions=$3 repeat=$4
  local label="$arm-$workload-n$sessions-r$repeat"
  local estimate="${EST[$arm-$workload-$sessions]}; barrier; sampler 25 ms"
  printf '%s\t%s\t%s\n' "$(date -u +%FT%T.%NZ)" "$label" "estimated: $estimate" >> "$C/napkins.tsv"
  local start=$(date -u +%FT%T.%NZ)
  timeout 900 "$H" --tool-sessions "$sessions" --tool-workload "$workload" --tool-barrier --tool-sample-ms 25 --expectation "$estimate" --output "$C/$label.json" "${RUI[$arm]}" > "$C/$label.stdout" 2>&1
  local code=$?
  printf '%s\t%s\t%s\t%s\n' "$start" "$(date -u +%FT%T.%NZ)" "$label" "$code" >> "$C/attempts.tsv"
}
for repeat in 1 2 3; do
  for workload in sleep read; do
    for sessions in 1 10 100; do
      if [ "$repeat" = 2 ]; then order="cand base"; else order="base cand"; fi
      for arm in $order; do run "$arm" "$workload" "$sessions" "$repeat"; done
    done
  done
done
date -u +%FT%TZ > "$C/finished"
sleep infinity

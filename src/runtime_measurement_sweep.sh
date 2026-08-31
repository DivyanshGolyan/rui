#!/bin/sh
set -eu

if test "$#" -ne 5; then
  echo "usage: runtime_measurement_sweep.sh FIXTURE RAW_OUTPUT SUMMARIZER SUMMARY_OUTPUT REPETITIONS" >&2
  exit 2
fi

fixture=$1
output=$2
summarizer=$3
summary_output=$4
repetitions=$5

case "$repetitions" in
  ''|*[!0-9]*|0)
    echo "repetitions must be a positive integer" >&2
    exit 2
    ;;
esac
if test $((repetitions % 2)) -eq 0; then
  echo "repetitions must be odd so integer counter medians remain exact" >&2
  exit 2
fi

output_dir=$(dirname "$output")
mkdir -p "$output_dir"
temporary="$output.tmp.$$"
trap 'rm -f "$temporary"' EXIT HUP INT TERM

source_commit=$(git rev-parse HEAD)
platform=$(uname -srvmp | tr '"' "'")
source_dirty=false
if ! git diff --quiet || ! git diff --cached --quiet; then
  source_dirty=true
fi
printf '{"schema":"onepage.runtime-measurement-sweep.v1","source_commit":"%s","platform":"%s","repetitions":%s,"source_dirty":%s}\n' \
  "$source_commit" "$platform" "$repetitions" "$source_dirty" > "$temporary"

run_point() {
  scenario=$1
  count=$2
  repetition=$3
  capacity=$4
  # The fixture emits pretty JSON for one human-run point. Newlines are JSON
  # whitespace, so removing them makes one JSONL record without adding a JSON
  # processor to the measured path.
  "$fixture" "$scenario" "$count" "$capacity" | tr -d '\n' >> "$temporary"
  printf '\n' >> "$temporary"
  printf '%s count=%s active_capacity=%s repetition=%s/%s\n' \
    "$scenario" "$count" "$capacity" "$repetition" "$repetitions" >&2
}

repetition=1
while test "$repetition" -le "$repetitions"; do
  for count in 0 100 1000 10000; do
    run_point dormant "$count" "$repetition" 1
  done
  # This is the complete Harness -> SQLite -> provider -> semantic closure
  # path, intentionally not a parser or transport microbenchmark.
  # These sequential points measure the exact startup reservation slope. Their
  # reported occupied high-water remains one Slot; true concurrent occupancy is
  # a separate async-execution gate and must not be inferred from this sweep.
  for capacity in 1 10 100; do
    run_point completion 100 "$repetition" "$capacity"
  done
  repetition=$((repetition + 1))
done

mv "$temporary" "$output"
trap - EXIT HUP INT TERM
"$summarizer" "$output" "$summary_output"
printf 'Wrote raw runtime measurements to %s\n' "$output" >&2
printf 'Wrote runtime measurement summary to %s\n' "$summary_output" >&2

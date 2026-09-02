#!/bin/zsh
set -euo pipefail

artifact_dir="${0:A:h}"
source "$artifact_dir/probe_helpers.sh"
matrix_root="${OUTPUT_ROOT:-$(mktemp -d /tmp/onepage-rotated-matrix.XXXXXX)}"
seconds="${STREAM_SECONDS:-10}"
repetitions="${REPETITIONS:-4}"
binary="$matrix_root/integrated_capacity"
cert_file="$matrix_root/cert.pem"
key_file="$matrix_root/key.pem"
results_file="$matrix_root/results.jsonl"
mkdir -p "$matrix_root/spools"
: > "$results_file"

if (( repetitions < 1 || repetitions > 20 )); then
  print -u2 "REPETITIONS must be between 1 and 20"
  exit 2
fi

clang -O2 -std=c11 -Wall -Wextra -Werror \
  "$artifact_dir/integrated_capacity.c" -o "$binary" \
  -lcurl -lsqlite3 -lpthread
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$key_file" -out "$cert_file" -days 1 \
  -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost' \
  >/dev/null 2>&1

server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

model_count() {
  local capacity="$1"
  local bash_count=0
  local patch_count=0
  if (( capacity > 1 )); then bash_count=$((capacity / 4)); fi
  if (( capacity >= 10 )); then patch_count=1; fi
  echo $((capacity - bash_count - patch_count))
}

capacities=(1 10 50 100)
for (( repetition = 0; repetition < repetitions; repetition++ )); do
  for (( ordinal = 0; ordinal < 4; ordinal++ )); do
    index=$(((repetition + ordinal) % 4))
    capacity="${capacities[index + 1]}"
    models="$(model_count "$capacity")"
    port=$((19900 + repetition * 4 + ordinal))
    case_root="$matrix_root/r${repetition}-o${ordinal}-c${capacity}"
    mkdir -p "$case_root"
    python3 "$artifact_dir/tls_sse_load.py" \
      --cert "$cert_file" --key "$key_file" --port "$port" \
      --seconds "$seconds" --tokens-per-second 100 --terminal-bytes 4096 \
      --expected-connections "$models" \
      > "$case_root/server.jsonl" 2> "$case_root/server.stderr" &
    server_pid=$!
    wait_for_pattern '"ready": true' "$case_root/server.jsonl" 0.05 200 \
      "server readiness for repetition=$repetition ordinal=$ordinal capacity=$capacity"

    client_json="$("$binary" integrated "$capacity" \
      "https://localhost:$port/responses" "$cert_file" "$matrix_root/spools" \
      "$case_root/proof.sqlite3" lane 120)"
    jq -e --argjson capacity "$capacity" '
      .settled == $capacity and .resolution_rows == $capacity and
      .completion_classes.success == $capacity and .host_fatal == false and
      .scratch_logical_final == 0 and .closed.fds == .unopened.fds' \
      <<< "$client_json" >/dev/null
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
    jq -cn --argjson repetition "$repetition" --argjson ordinal "$ordinal" \
      --argjson client "$client_json" \
      '{repetition:$repetition,ordinal:$ordinal,client:$client}' >> "$results_file"
    print -u2 "completed repetition=$repetition ordinal=$ordinal capacity=$capacity"
  done
done

jq -s '
  def median:
    sort as $s | length as $n |
    if $n == 0 then null
    elif ($n % 2) == 1 then $s[($n / 2 | floor)]
    else (($s[$n / 2 - 1] + $s[$n / 2]) / 2) end;
  group_by(.client.capacity) |
  map({
    capacity: .[0].client.capacity,
    samples: length,
    active_minus_lanes_idle_physical_median:
      (map(.client.active.physical - .client.lanes_idle.physical) | median),
    active_physical_median: (map(.client.active.physical) | median),
    post_wave_idle_physical_median: (map(.client.final_cycle_idle.physical) | median),
    cpu_one_core_fraction_median: (map(.client.cpu_one_core_fraction) | median),
    max_callback_gap_ns_median: (map(.client.max_model_callback_gap_ns) | median),
    max_live_spool_allocated_median: (map(.client.max_live_spool_allocated) | median),
    fds_highwater: (map(.client.active.fds) | max)
  })
' "$results_file"
echo "results=$results_file"

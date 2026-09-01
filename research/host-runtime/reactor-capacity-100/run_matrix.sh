#!/bin/zsh
set -euo pipefail

artifact_dir="${0:A:h}"
matrix_profile="${MATRIX_PROFILE:-full}"
results_file="${RESULTS_FILE:-$artifact_dir/results.jsonl}"
raw_dir="${RAW_DIR:-$artifact_dir/raw}"
cert_file="${CERT_FILE:-$artifact_dir/cert.pem}"
key_file="${KEY_FILE:-$artifact_dir/key.pem}"
mkdir -p "$raw_dir"
: > "$results_file"

cc -O2 -Wall -Wextra "$artifact_dir/reactor_spool.c" \
  -o "$artifact_dir/reactor_spool" $(curl-config --cflags --libs)

server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

run_case() {
  local scenario="$1"
  local repetition="$2"
  local token_rate="$3"
  local batch_tokens="$4"
  local fragment="$5"
  local seconds="$6"
  local terminal_bytes="$7"
  local cancel_after="$8"
  local cancel_count="$9"
  local port=$((19000 + RUN_INDEX))
  local prefix="$raw_dir/${scenario}-${repetition}"

  vm_stat > "$prefix-vm-before.txt"
  python3 "$artifact_dir/tls_sse_load.py" \
    --cert "$cert_file" \
    --key "$key_file" \
    --port "$port" \
    --seconds "$seconds" \
    --tokens-per-second "$token_rate" \
    --batch-tokens "$batch_tokens" \
    --terminal-bytes "$terminal_bytes" \
    --fragment "$fragment" \
    --expected-connections 100 \
    > "$prefix-server.jsonl" 2> "$prefix-server.stderr" &
  server_pid=$!

  local attempts=0
  until rg -q '"ready": true' "$prefix-server.jsonl" 2>/dev/null; do
    sleep 0.05
    attempts=$((attempts + 1))
    if (( attempts > 200 )); then
      print -u2 "server failed to become ready for $scenario repetition $repetition"
      return 1
    fi
  done

  local client_json
  if (( cancel_count > 0 )); then
    client_json="$("$artifact_dir/reactor_spool" 100 "https://localhost:$port/responses" \
      "$cert_file" /tmp "$cancel_after" "$cancel_count")"
  else
    client_json="$("$artifact_dir/reactor_spool" 100 "https://localhost:$port/responses" \
      "$cert_file" /tmp)"
  fi

  kill -TERM "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
  vm_stat > "$prefix-vm-after.txt"

  local server_json
  server_json="$(tail -1 "$prefix-server.jsonl")"
  jq -cn \
    --arg scenario "$scenario" \
    --argjson repetition "$repetition" \
    --argjson token_rate "$token_rate" \
    --argjson batch_tokens "$batch_tokens" \
    --arg fragment "$fragment" \
    --argjson seconds "$seconds" \
    --argjson terminal_bytes "$terminal_bytes" \
    --argjson cancel_after "$cancel_after" \
    --argjson cancel_count "$cancel_count" \
    --argjson client "$client_json" \
    --argjson server "$server_json" \
    '{scenario:$scenario,repetition:$repetition,workload:{token_rate:$token_rate,batch_tokens:$batch_tokens,fragment:$fragment,seconds:$seconds,terminal_bytes:$terminal_bytes,cancel_after:$cancel_after,cancel_count:$cancel_count},client:$client,server:$server}' \
    | tee -a "$results_file"
  RUN_INDEX=$((RUN_INDEX + 1))
}

RUN_INDEX=0
if [[ "$matrix_profile" == "soak" ]]; then
  run_case clean_soak_100hz 1 100 1 none 60 65536 0 0
elif [[ "$matrix_profile" == "clean" ]]; then
  for repetition in {1..5}; do run_case clean_100hz "$repetition" 100 1 none 10 65536 0 0; done
  for repetition in {1..3}; do run_case clean_fragmented_100hz "$repetition" 100 1 split 5 65536 0 0; done
  for repetition in {1..3}; do run_case clean_overload_200hz "$repetition" 200 1 none 5 65536 0 0; done
else
  for repetition in {1..5}; do run_case continuous_50hz "$repetition" 50 1 none 10 65536 0 0; done
  for repetition in {1..5}; do run_case continuous_100hz "$repetition" 100 1 none 10 65536 0 0; done
  for repetition in {1..5}; do run_case batched_100hz "$repetition" 100 8 none 10 65536 0 0; done
  for repetition in {1..3}; do run_case fragmented_100hz "$repetition" 100 1 split 5 65536 0 0; done
  for repetition in {1..3}; do run_case cancel_50_at_2s "$repetition" 100 1 none 10 65536 2 50; done
  for repetition in {1..3}; do run_case overload_200hz "$repetition" 200 1 none 5 65536 0 0; done
fi

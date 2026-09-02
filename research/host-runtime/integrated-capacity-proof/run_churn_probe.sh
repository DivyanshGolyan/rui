#!/bin/zsh
set -euo pipefail

artifact_dir="${0:A:h}"
source "$artifact_dir/probe_helpers.sh"
probe_root="${OUTPUT_ROOT:-$(mktemp -d /tmp/onepage-churn-proof.XXXXXX)}"
cycles="${CYCLES:-10}"
seconds="${STREAM_SECONDS:-1}"
binary="$probe_root/integrated_capacity"
cert_file="$probe_root/cert.pem"
key_file="$probe_root/key.pem"
mkdir -p "$probe_root/spools"

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

run_probe() {
  local name="$1"
  local port="$2"
  local relief="$3"
  local case_root="$probe_root/$name"
  mkdir -p "$case_root"
  python3 "$artifact_dir/tls_sse_load.py" \
    --cert "$cert_file" --key "$key_file" --port "$port" \
    --seconds "$seconds" --tokens-per-second 50 --terminal-bytes 4096 \
    --expected-connections 74 \
    > "$case_root/server.jsonl" 2> "$case_root/server.stderr" &
  server_pid=$!
  wait_for_pattern '"ready": true' "$case_root/server.jsonl" 0.05 200 \
    "server readiness for $name"

  local client_json
  if [[ "$relief" == "yes" ]]; then
    client_json="$(ONEPAGE_PROOF_CYCLES="$cycles" ONEPAGE_PROOF_PRESSURE_RELIEF=1 \
      "$binary" integrated 100 "https://localhost:$port/responses" \
      "$cert_file" "$probe_root/spools" "$case_root/proof.sqlite3" lane 60)"
  else
    client_json="$(ONEPAGE_PROOF_CYCLES="$cycles" \
      "$binary" integrated 100 "https://localhost:$port/responses" \
      "$cert_file" "$probe_root/spools" "$case_root/proof.sqlite3" lane 60)"
  fi
  local expected=$((100 * cycles))
  jq -e --argjson expected "$expected" --argjson cycles "$cycles" '
    .cycles == $cycles and .completed_cycles == $cycles and
    .settled == $expected and .resolution_rows == $expected and
    .completion_classes.success == $expected and .host_fatal == false and
    .scratch_logical_final == 0 and .closed.fds == .unopened.fds' \
    <<< "$client_json" >/dev/null
  kill -TERM "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
  jq -cn --arg name "$name" --argjson client "$client_json" \
    '{scenario:$name,client:$client}'
}

run_probe churn_without_relief 19870 no
run_probe churn_with_zero_credit_relief 19871 yes
echo "results_root=$probe_root"

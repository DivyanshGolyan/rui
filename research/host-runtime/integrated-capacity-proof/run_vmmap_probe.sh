#!/bin/zsh
set -euo pipefail

artifact_dir="${0:A:h}"
source "$artifact_dir/probe_helpers.sh"
probe_root="${OUTPUT_ROOT:-$(mktemp -d /tmp/rui-vmmap-proof.XXXXXX)}"
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
client_pid=""
cleanup() {
  if [[ -n "$client_pid" ]] && kill -0 "$client_pid" 2>/dev/null; then
    kill -TERM "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
  fi
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

python3 "$artifact_dir/tls_sse_load.py" \
  --cert "$cert_file" --key "$key_file" --port 19850 \
  --seconds 1 --tokens-per-second 50 --terminal-bytes 4096 \
  --expected-connections 74 \
  > "$probe_root/server.jsonl" 2> "$probe_root/server.stderr" &
server_pid=$!
wait_for_pattern '"ready": true' "$probe_root/server.jsonl" 0.05 200 \
  "vmmap server readiness"

RUI_PROOF_IDLE_HOLD_SECONDS=10 \
  "$binary" integrated 100 https://localhost:19850/responses \
  "$cert_file" "$probe_root/spools" "$probe_root/proof.sqlite3" lane 30 \
  > "$probe_root/client.json" 2> "$probe_root/client.stderr" &
client_pid=$!
wait_for_pattern 'phase=idle' "$probe_root/client.stderr" 0.025 400 \
  "client idle phase"

vmmap -summary "$client_pid" > "$probe_root/vmmap-summary.txt"
total_dirty="$(awk '/^TOTAL / {print $4; exit}' "$probe_root/vmmap-summary.txt")"
stack_dirty="$(awk '/^Stack / {print $4; exit}' "$probe_root/vmmap-summary.txt")"

wait "$client_pid"
client_pid=""
kill -TERM "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=""

client_json="$(<"$probe_root/client.json")"
jq -e '
  .settled == 100 and .resolution_rows == 100 and
  .completion_classes.success == 100 and .host_fatal == false and
  .scratch_logical_final == 0 and .closed.fds == .unopened.fds' \
  <<< "$client_json" >/dev/null

jq -cn --argjson client "$client_json" --arg total_dirty "$total_dirty" \
  --arg stack_dirty "$stack_dirty" \
  --arg vmmap "$probe_root/vmmap-summary.txt" \
  '{client:$client,vmmap:{total_dirty:$total_dirty,stack_dirty:$stack_dirty,raw:$vmmap}}'

#!/bin/zsh
set -euo pipefail

artifact_dir="${0:A:h}"
source "$artifact_dir/probe_helpers.sh"
probe_root="${OUTPUT_ROOT:-$(mktemp -d /tmp/rui-duration-cache-proof.XXXXXX)}"
short_seconds="${SHORT_SECONDS:-10}"
long_seconds="${LONG_SECONDS:-60}"
binary="$probe_root/integrated_capacity"
cert_file="$probe_root/cert.pem"
key_file="$probe_root/key.pem"
results_file="$probe_root/results.jsonl"
mkdir -p "$probe_root/spools"
: > "$results_file"

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
  local seconds="$2"
  local port="$3"
  local nocache="$4"
  local case_root="$probe_root/$name"
  mkdir -p "$case_root"
  python3 "$artifact_dir/tls_sse_load.py" \
    --cert "$cert_file" --key "$key_file" --port "$port" \
    --seconds "$seconds" --tokens-per-second 100 --terminal-bytes 4096 \
    --expected-connections 74 \
    > "$case_root/server.jsonl" 2> "$case_root/server.stderr" &
  server_pid=$!
  wait_for_pattern '"ready": true' "$case_root/server.jsonl" 0.05 200 \
    "server readiness for $name"

  local client_json
  if [[ "$nocache" == "yes" ]]; then
    client_json="$(RUI_PROOF_SPOOL_NOCACHE=1 \
      "$binary" integrated 100 "https://localhost:$port/responses" \
      "$cert_file" "$probe_root/spools" "$case_root/proof.sqlite3" lane 120)"
  else
    client_json="$("$binary" integrated 100 "https://localhost:$port/responses" \
      "$cert_file" "$probe_root/spools" "$case_root/proof.sqlite3" lane 120)"
  fi
  jq -e '
    .settled == 100 and .resolution_rows == 100 and
    .completion_classes.success == 100 and .host_fatal == false and
    .scratch_logical_final == 0 and .closed.fds == .unopened.fds' \
    <<< "$client_json" >/dev/null
  kill -TERM "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
  jq -cn --arg name "$name" --argjson seconds "$seconds" \
    --argjson client "$client_json" \
    '{scenario:$name,stream_seconds:$seconds,client:$client}' | tee -a "$results_file"
}

run_probe short_cached "$short_seconds" 19880 no
run_probe short_nocache "$short_seconds" 19881 yes
run_probe long_nocache "$long_seconds" 19882 yes

jq -s '
  (map(select(.scenario == "short_cached"))[0]) as $cached |
  (map(select(.scenario == "short_nocache"))[0]) as $short |
  (map(select(.scenario == "long_nocache"))[0]) as $long |
  {
    cached_vs_nocache_active_physical:
      ($short.client.active.physical - $cached.client.active.physical),
    duration_active_physical:
      ($long.client.active.physical - $short.client.active.physical),
    duration_scratch_allocated:
      ($long.client.max_live_spool_allocated - $short.client.max_live_spool_allocated),
    raw: .
  }
' "$results_file"
echo "results=$results_file"

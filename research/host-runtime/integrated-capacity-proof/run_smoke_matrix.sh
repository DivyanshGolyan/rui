#!/bin/zsh
set -euo pipefail

artifact_dir="${0:A:h}"
source "$artifact_dir/probe_helpers.sh"
output_root="${OUTPUT_ROOT:-$(mktemp -d /tmp/rui-integrated-proof.XXXXXX)}"
seconds="${STREAM_SECONDS:-1}"
token_rate="${TOKEN_RATE:-50}"
terminal_bytes="${TERMINAL_BYTES:-4096}"
results_file="$output_root/results.jsonl"
binary="$output_root/integrated_capacity"
cert_file="$output_root/cert.pem"
key_file="$output_root/key.pem"
mkdir -p "$output_root/spools"
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

model_count() {
  local capacity="$1"
  local bash_count=0
  local patch_count=0
  if (( capacity > 1 )); then bash_count=$((capacity / 4)); fi
  if (( capacity >= 10 )); then patch_count=1; fi
  echo $((capacity - bash_count - patch_count))
}

run_case() {
  local name="$1"
  local capacity="$2"
  local patch_mode="$3"
  local omit_completed="$4"
  local port="$5"
  local cycles="${6:-1}"
  local models="$(model_count "$capacity")"
  local case_root="$output_root/$name"
  mkdir -p "$case_root"
  local omit_args=()
  if [[ "$omit_completed" == "yes" ]]; then omit_args+=(--omit-completed); fi

  python3 "$artifact_dir/tls_sse_load.py" \
    --cert "$cert_file" --key "$key_file" --port "$port" \
    --seconds "$seconds" --tokens-per-second "$token_rate" \
    --terminal-bytes "$terminal_bytes" --expected-connections "$models" \
    "${omit_args[@]}" \
    > "$case_root/server.jsonl" 2> "$case_root/server.stderr" &
  server_pid=$!
  wait_for_pattern '"ready": true' "$case_root/server.jsonl" 0.05 200 \
    "server readiness for $name"

  local client_json
  client_json="$(RUI_PROOF_CYCLES="$cycles" "$binary" integrated "$capacity" \
    "https://localhost:$port/responses" "$cert_file" "$output_root/spools" \
    "$case_root/proof.sqlite3" "$patch_mode" 60)"
  local expected_attempts=$((capacity * cycles))
  local expected_artifacts=$(((models + 2 * (capacity > 1 ? capacity / 4 : 0)) * cycles))
  if [[ "$omit_completed" == "yes" ]]; then
    jq -e --argjson attempts "$expected_attempts" --argjson cycles "$cycles" '
      .cycles == $cycles and .completed_cycles == $cycles and
      .settled == $attempts and .resolution_rows == $attempts and
      .completion_classes.protocol_error == $attempts and .artifact_rows == 0 and
      .validator_max == 1 and .scratch_logical_final == 0 and
      .closed.fds == .unopened.fds' <<< "$client_json" >/dev/null
  else
    jq -e --argjson attempts "$expected_attempts" --argjson artifacts "$expected_artifacts" \
      --argjson cycles "$cycles" '
      .cycles == $cycles and .completed_cycles == $cycles and
      .settled == $attempts and .resolution_rows == $attempts and
      .completion_classes.success == $attempts and .artifact_rows == $artifacts and
      .validator_max == 1 and .scratch_logical_final == 0 and
      .closed.fds == .unopened.fds' <<< "$client_json" >/dev/null
  fi
  kill -TERM "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
  local server_json="$(tail -1 "$case_root/server.jsonl")"
  jq -cn --arg name "$name" --argjson client "$client_json" \
    --argjson server "$server_json" \
    '{scenario:$name,client:$client,server:$server}' | tee -a "$results_file"
}

run_case capacity_1 1 lane no 19601
run_case capacity_10 10 lane no 19610
run_case capacity_50 50 lane no 19650
run_case capacity_100 100 lane no 19700
run_case churn_3x_capacity_100 100 lane no 19704 3
run_case patch_on_storage_owner_100 100 owner no 19703
run_case missing_terminal 1 lane yes 19701

# Attempt admission succeeds, then post-commit scratch preparation fails. The
# server is ready but receives no connection; the admitted Attempt must still
# settle as bounded evidence.
case_root="$output_root/postcommit_preparation_failure"
mkdir -p "$case_root"
python3 "$artifact_dir/tls_sse_load.py" \
  --cert "$cert_file" --key "$key_file" --port 19702 \
  --seconds "$seconds" --tokens-per-second "$token_rate" \
  --terminal-bytes "$terminal_bytes" --expected-connections 1 \
  > "$case_root/server.jsonl" 2> "$case_root/server.stderr" &
server_pid=$!
wait_for_pattern '"ready": true' "$case_root/server.jsonl" 0.05 200 \
  "server readiness for postcommit_preparation_failure"
client_json="$("$binary" integrated 1 https://localhost:19702/responses \
  "$cert_file" "$case_root/does-not-exist" "$case_root/proof.sqlite3" lane 10)"
jq -e '
  .settled == 1 and .completion_classes.preparation_failure == 1 and
  .artifact_rows == 0 and .scratch_logical_final == 0 and
  .closed.fds == .unopened.fds' <<< "$client_json" >/dev/null
kill -TERM "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=""
jq -cn --argjson client "$client_json" \
  '{scenario:"postcommit_preparation_failure",client:$client}' | tee -a "$results_file"

for fixture in normal term kill inherited escaped; do
  bash_root="$output_root/bash-$fixture"
  mkdir -p "$bash_root"
  client_json="$("$binary" integrated 1 unused unused "$output_root/spools" \
    "$bash_root/proof.sqlite3" lane 10 bash-only "$fixture")"
  jq -e --arg fixture "$fixture" '
    .settled == 1 and .resolution_rows == 1 and .bash_evidence.reaped == 1 and
    .artifact_rows == 2 and .scratch_logical_final == 0 and
    .closed.fds == .unopened.fds and
    (if ($fixture == "term" or $fixture == "kill")
      then .completion_classes.bash_cancelled == 1
      else .completion_classes.success == 1 end) and
    (if $fixture == "kill" then .bash_evidence.kill_sent == 1 else true end) and
    (if $fixture == "escaped" then .bash_evidence.pipe_grace_expired == 1 else true end)' \
    <<< "$client_json" >/dev/null
  jq -cn --arg fixture "$fixture" --argjson client "$client_json" \
    '{scenario:("bash_" + $fixture),client:$client}' | tee -a "$results_file"
done

fd_root="$output_root/descriptor-exhaustion"
mkdir -p "$fd_root"
client_json="$(ulimit -n 16; "$binary" integrated 10 unused unused \
  "$output_root/spools" "$fd_root/proof.sqlite3" lane 10 bash-only normal)"
jq -e '
  .settled == 10 and .resolution_rows == 10 and
  (.completion_classes.success + .completion_classes.preparation_failure) == 10 and
  .completion_classes.preparation_failure > 0 and .scratch_logical_final == 0 and
  .closed.fds == .unopened.fds' <<< "$client_json" >/dev/null
jq -cn --argjson client "$client_json" \
  '{scenario:"descriptor_exhaustion",client:$client}' | tee -a "$results_file"

limit_root="$output_root/output-limit"
mkdir -p "$limit_root"
client_json="$(RUI_PROOF_EFFECT_OUTPUT_LIMIT=4096 "$binary" integrated 1 \
  unused unused "$output_root/spools" "$limit_root/proof.sqlite3" lane 10 \
  bash-only normal)"
jq -e '
  .settled == 1 and .completion_classes.output_limit == 1 and
  .artifact_rows == 0 and .scratch_logical_highwater <= 4096 and
  .scratch_logical_final == 0 and .closed.fds == .unopened.fds' \
  <<< "$client_json" >/dev/null
jq -cn --argjson client "$client_json" \
  '{scenario:"output_limit",client:$client}' | tee -a "$results_file"

fatal_root="$output_root/reactor-fatal"
mkdir -p "$fatal_root"
set +e
RUI_PROOF_INJECT_REACTOR_FATAL_AFTER_LOOPS=1 "$binary" integrated 10 \
  unused unused "$output_root/spools" "$fatal_root/proof.sqlite3" lane 10 \
  bash-only normal > "$fatal_root/client.json"
fatal_exit=$?
set -e
client_json="$(<"$fatal_root/client.json")"
jq -e --argjson exit "$fatal_exit" '
  $exit != 0 and .host_fatal == true and .settled == 0 and
  .resolution_rows == 0 and .unresolved_attempts == 10 and
  .scratch_logical_final == 0 and .closed.fds == .unopened.fds' \
  <<< "$client_json" >/dev/null
jq -cn --argjson client "$client_json" \
  '{scenario:"reactor_fatal",client:$client}' | tee -a "$results_file"

for fixture in interfere-before interfere-during interfere-after; do
  race_root="$output_root/patch-$fixture"
  mkdir -p "$race_root"
  client_json="$("$binary" integrated 2 unused unused "$race_root" \
    "$race_root/proof.sqlite3" lane 10 patch-race "$fixture")"
  jq -e --arg fixture "$fixture" '
    .settled == 2 and .resolution_rows == 2 and .artifact_rows == 2 and
    .bash_evidence.reaped == 1 and .scratch_logical_final == 0 and
    .closed.fds == .unopened.fds and
    (if $fixture == "interfere-before"
      then .completion_classes.patch_conflict == 1 and .patch_final_relation == 3
      elif $fixture == "interfere-during"
      then .completion_classes.success == 2 and .patch_final_relation == 1
      else .completion_classes.success == 2 and .patch_final_relation == 3 end)' \
    <<< "$client_json" >/dev/null
  jq -cn --arg fixture "$fixture" --argjson client "$client_json" \
    '{scenario:("patch_" + $fixture),client:$client}' | tee -a "$results_file"
done

echo "results=$results_file"

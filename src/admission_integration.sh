set -eu

latifa=$1
root=$(pwd -P)
state=$(mktemp -d "${TMPDIR:-/tmp}/latifa-admission.XXXXXX")
chmod 700 "$state"
store="$state/store"
records="$state/records"
mkdir -m 700 "$records"
ready="$state/ready"
server_log="$state/server.log"
host_pid=
extra_pid=
client_pid=

cleanup() {
    if [ -n "$host_pid" ]; then
        kill -9 "$host_pid" 2>/dev/null || true
        wait "$host_pid" 2>/dev/null || true
    fi
    if [ -n "$extra_pid" ]; then
        kill -9 "$extra_pid" 2>/dev/null || true
        wait "$extra_pid" 2>/dev/null || true
    fi
    if [ -n "$client_pid" ]; then
        kill -9 "$client_pid" 2>/dev/null || true
        wait "$client_pid" 2>/dev/null || true
    fi
    rm -rf "$state"
}
trap cleanup EXIT INT TERM

start_host() {
    : >"$ready"
    : >"$server_log"
    "$latifa" serve --store "$store" "$@" >"$ready" 2>"$server_log" &
    host_pid=$!
    attempts=0
    while ! grep -q '^ready ' "$ready"; do
        if ! kill -0 "$host_pid" 2>/dev/null; then
            cat "$server_log" >&2
            return 1
        fi
        attempts=$((attempts + 1))
        if [ "$attempts" -gt 500 ]; then
            echo "Host did not become ready" >&2
            return 1
        fi
        sleep 0.01
    done
}

stop_host() {
    kill -9 "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
    host_pid=
}

contains() {
    case "$1" in
        *"$2"*) ;;
        *) echo "missing expected text: $2" >&2; echo "$1" >&2; return 1 ;;
    esac
}

start_host

# SIGKILL skips capture.abort; revisiting the same record recovers its temporary.
python3 - "$latifa" "$store" "$records" "$root" <<'PYCAPTURE'
import json, pathlib, subprocess, sys, time
binary, store, records, workspace = sys.argv[1:]
record = pathlib.Path(records) / 'capture-recovery.json'
args = [binary, 'configure', '--store', store, '--record', str(record),
        '--key', 'capture-recovery', '--session', 'direct/capture-recovery',
        '--workspace', workspace, '--model', 'model-a', '--instructions', '-']
writer = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    writer.stdin.write(b'x' * 8192)
    writer.stdin.flush()
    temporary = record.with_name('.' + record.name + '.capture.tmp')
    deadline = time.monotonic() + 5
    while not temporary.exists() or temporary.stat().st_size == 0:
        if writer.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('capture did not reach streamed temporary')
        time.sleep(.01)
    contender = subprocess.run(args, input=b'other', capture_output=True, timeout=5)
    assert contender.returncode != 0 and b'RecordCaptureBusy' in contender.stderr
    assert not record.exists()
finally:
    writer.kill()
    writer.wait(timeout=5)
    writer.stdin.close()
assert temporary.exists()
recovered = subprocess.run(args, input=b'new capture', capture_output=True, timeout=10)
assert recovered.returncode == 0, recovered.stderr
assert json.loads(record.read_text())['configuration']['instructions']['value'] == 'new capture'
assert not temporary.exists()
saved = record.read_bytes()
duplicate = subprocess.run(args, input=b'replacement', capture_output=True, timeout=5)
assert duplicate.returncode != 0 and b'RecordAlreadyExists' in duplicate.stderr
assert record.read_bytes() == saved
assert record.with_name('.' + record.name + '.capture.lock').exists()
PYCAPTURE

# The OS-held lock rejects a competing owner without relying on PID/socket state.
if "$latifa" serve --store "$store" >"$state/competing.out" 2>"$state/competing.err"; then
    echo "competing Host acquired the Store" >&2
    exit 1
fi
contains "$(cat "$state/competing.err")" "StoreAlreadyOwned"

# A listener failure stops new dispatch but keeps the Store lock and Host stack
# alive until a transferred client finishes its body read.
drain_store="$state/drain-store"
drain_ready="$state/drain-ready"
drain_error="$state/drain-error"
drain_client_ready="$state/drain-client-ready"
"$latifa" serve --store "$drain_store" --fault shutdown-after-accept >"$drain_ready" 2>"$drain_error" &
extra_pid=$!
attempts=0
while ! grep -q '^ready ' "$drain_ready"; do
    if ! kill -0 "$extra_pid" 2>/dev/null; then
        cat "$drain_error" >&2
        exit 1
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 500 ]; then
        echo "drain fixture Host did not become ready" >&2
        exit 1
    fi
    sleep 0.01
done
drain_socket=$(sed -n 's/.* socket=\([^ ]*\).*/\1/p' "$drain_ready")
python3 - "$drain_socket" "$drain_store" "$root" "$drain_client_ready" <<'PY' &
import json, os, socket, sys, time
socket_path, store, workspace, client_ready = sys.argv[1:]
body = json.dumps({
    "version": "1",
    "kind": "configure",
    "store": os.path.realpath(store),
    "key": "draining-request",
    "session": "direct/draining",
    "configuration": {
        "workspace": {"state": "value", "value": workspace},
        "model": {"state": "value", "value": "model-a"},
        "instructions": {"state": "omitted"},
        "tools": {"state": "omitted"},
        "permission_mode": {"state": "omitted"},
        "output_schema": {"state": "omitted"},
    },
}, separators=(",", ":")).encode()
client = socket.socket(socket.AF_UNIX)
client.connect(socket_path)
header = (
    "POST /v1/configure HTTP/1.1\r\n"
    "Host: local\r\n"
    "Content-Type: application/json\r\n"
    f"Content-Length: {len(body)}\r\n"
    "X-Latifa-Wire-Version: 1\r\n\r\n"
).encode()
client.sendall(header + body[:1])
with open(client_ready, "xb"):
    pass
time.sleep(0.5)
client.sendall(body[1:])
response = b""
while True:
    chunk = client.recv(4096)
    if not chunk:
        break
    response += chunk
client.close()
if not response.startswith(b"HTTP/1.1 200 "):
    raise SystemExit("transferred request did not finish during drain")
PY
client_pid=$!
attempts=0
while [ ! -e "$drain_client_ready" ]; do
    if ! kill -0 "$client_pid" 2>/dev/null; then
        wait "$client_pid"
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 500 ]; then
        echo "drain fixture client did not transfer custody" >&2
        exit 1
    fi
    sleep 0.01
done
kill -0 "$extra_pid"
python3 - "$drain_socket" <<'PY'
import socket, sys, time
deadline = time.monotonic() + 1.0
while True:
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(0.2)
    try:
        client.connect(sys.argv[1])
        data = client.recv(1)
        if not data:
            break
    except (ConnectionRefusedError, FileNotFoundError, ConnectionResetError, BrokenPipeError):
        break
    except socket.timeout:
        if time.monotonic() >= deadline:
            raise SystemExit("connection remained stranded after listener shutdown")
    finally:
        client.close()
PY
if "$latifa" serve --store "$drain_store" >"$state/drain-competing.out" 2>"$state/drain-competing.err"; then
    echo "draining Host released its Store lock early" >&2
    exit 1
fi
contains "$(cat "$state/drain-competing.err")" "StoreAlreadyOwned"
wait "$client_pid"
client_pid=
if wait "$extra_pid"; then
    echo "injected listener failure exited successfully" >&2
    exit 1
fi
extra_pid=

# Fill all ordinary places with sealed headers and incomplete bodies. A short
# control classification still receives its explicit development response; two
# additional classifiers bring the exact total to 12, and the next
# connection is rejected without displacing existing custody.
socket=$(sed -n 's/.* socket=\([^ ]*\).*/\1/p' "$ready")
python3 - "$socket" <<'PY'
import select, socket, sys, time

socket_path = sys.argv[1]
ordinary = []
for _ in range(10):
    client = socket.socket(socket.AF_UNIX)
    client.connect(socket_path)
    client.sendall(
        b"POST /v1/configure HTTP/1.1\r\n"
        b"Host: local\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: 1024\r\n"
        b"X-Latifa-Wire-Version: 1\r\n\r\n{"
    )
    ordinary.append(client)
    time.sleep(0.002)
time.sleep(0.05)
ready, _, _ = select.select(ordinary, [], [], 0)
if ready:
    raise SystemExit("ordinary capacity rejected before 10 connections")

control = socket.socket(socket.AF_UNIX)
control.connect(socket_path)
control.sendall(
    b"POST /v1/control/stop HTTP/1.1\r\n"
    b"Host: local\r\n"
    b"Content-Type: application/json\r\n"
    b"Content-Length: 0\r\n"
    b"X-Latifa-Wire-Version: 1\r\n\r\n"
)
control_response = b""
while True:
    chunk = control.recv(4096)
    if not chunk:
        break
    control_response += chunk
control.close()
if not control_response.startswith(b"HTTP/1.1 501 "):
    raise SystemExit("control headroom was not serviceable")

classification = []
for _ in range(2):
    client = socket.socket(socket.AF_UNIX)
    client.connect(socket_path)
    classification.append(client)
time.sleep(0.05)
overflow = socket.socket(socket.AF_UNIX)
overflow.connect(socket_path)
overflow_response = overflow.recv(4096)
overflow.close()
if not overflow_response.startswith(b"HTTP/1.1 503 "):
    raise SystemExit("13th connection was not rejected")

for client in classification + ordinary:
    client.close()
PY
sleep 0.1

# Partial ingress has a usable-looking key but never seals, so it mutates nothing.
socket=$(sed -n 's/.* socket=\([^ ]*\).*/\1/p' "$ready")
python3 - "$socket" "$store" <<'PY'
import json, socket, sys
sock_path, store = sys.argv[1:]
body = json.dumps({"version":"1","kind":"configure","store":store,"key":"partial-key"}, separators=(",", ":")).encode()
s = socket.socket(socket.AF_UNIX)
s.connect(sock_path)
s.sendall(("POST /v1/configure HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: %d\r\nX-Latifa-Wire-Version: 1\r\n\r\n" % (len(body) + 50)).encode())
s.sendall(body)
s.close()
PY
sleep 0.05
partial=$($latifa observe-command --store "$store" --key partial-key)
contains "$partial" '"status":"absent"'

# Messages to unknown Sessions are saved rejections and create no Session.
printf 'hello' >"$state/message.txt"
if "$latifa" message --store "$store" --record "$records/unknown-message.json" --key msg-unknown --session direct/unknown --text "$state/message.txt" --test-drop-reply after-commit >"$state/drop.out" 2>"$state/drop.err"; then
    echo "lost unknown-Session rejection unexpectedly produced a complete reply" >&2
    exit 1
fi
unknown_session=$($latifa inspect-session --store "$store" --session direct/unknown)
contains "$unknown_session" '"session":null'
unknown_created=$($latifa configure --store "$store" --record "$records/unknown-created.json" --key unknown-created --session direct/unknown --workspace "$root" --model model-a)
contains "$unknown_created" '"status":"accepted"'
stop_host
start_host
unknown=$($latifa retry --store "$store" --record "$records/unknown-message.json" --kind message)
contains "$unknown" '"status":"rejected"'
contains "$unknown" '"replayed":true'
contains "$unknown" '"code":"unknown_session"'
contains "$unknown" '"bytes":"5"'
unknown_after_creation=$($latifa inspect-session --store "$store" --session direct/unknown)
contains "$unknown_after_creation" '"pending_messages":"0"'

# A lost rejection remains the original answer even after another key creates the Session.
if "$latifa" configure --store "$store" --record "$records/incomplete.json" --key incomplete-key --session direct/rejected --test-drop-reply after-commit >"$state/drop.out" 2>"$state/drop.err"; then
    echo "lost rejection unexpectedly produced a complete reply" >&2
    exit 1
fi
created=$($latifa configure --store "$store" --record "$records/rejected-create.json" --key rejected-create --session direct/rejected --workspace "$root" --model model-a)
contains "$created" '"status":"accepted"'
defaults=$($latifa inspect-session --store "$store" --session direct/rejected)
contains "$defaults" '"tools":["bash","edit"]'
contains "$defaults" '"permission_mode":"ask"'
contains "$defaults" '"instructions":{"bytes":"0"'
contains "$defaults" '"output_schema":null'
rejected=$($latifa retry --store "$store" --record "$records/incomplete.json" --kind configure)
contains "$rejected" '"status":"rejected"'
contains "$rejected" '"replayed":true'
contains "$rejected" '"code":"incomplete_initial_configuration"'

# Lose an accepted reply, change current settings, and kill both processes.
printf 'initial instructions\n' >"$state/instructions.txt"
printf '{"type":"object"}\n' >"$state/schema.json"
if "$latifa" configure --store "$store" --record "$records/first.json" --key first-key --session direct/main --workspace "$root" --model model-a --instructions "$state/instructions.txt" --output-schema "$state/schema.json" --test-drop-reply after-commit >"$state/drop.out" 2>"$state/drop.err"; then
    echo "lost acceptance unexpectedly produced a complete reply" >&2
    exit 1
fi
updated=$($latifa configure --store "$store" --record "$records/update.json" --key update-key --session direct/main --model model-b --tools none --permission-mode bypass)
contains "$updated" '"revision":"2"'
preserved=$($latifa inspect-session --store "$store" --session direct/main)
contains "$preserved" '"bytes":"21"'
case "$preserved" in
    *'"output_schema":{"bytes":'*) ;;
    *) echo "sparse update cleared output schema" >&2; exit 1 ;;
esac
# The retry record owns its captured bytes; later source-file mutation cannot
# change the request that is replayed.
printf 'mutated after durable capture\n' >"$state/instructions.txt"
: >"$state/empty.txt"
cleared=$($latifa configure --store "$store" --record "$records/clear.json" --key clear-key --session direct/main --instructions "$state/empty.txt" --text-output)
contains "$cleared" '"revision":"3"'
stop_host
start_host

replayed=$($latifa retry --store "$store" --record "$records/first.json" --kind configure)
contains "$replayed" '"status":"accepted"'
contains "$replayed" '"replayed":true'
contains "$replayed" '"revision":"1"'
current=$($latifa inspect-session --store "$store" --session direct/main)
contains "$current" '"model":"model-b"'
contains "$current" '"revision":"3"'
contains "$current" '"tools":[]'
contains "$current" '"permission_mode":"bypass"'
contains "$current" '"instructions":{"bytes":"0"'
contains "$current" '"output_schema":null'

# The same Store-wide key conflicts across changed inputs, targets, and kinds.
changed=$($latifa configure --store "$store" --record "$records/changed.json" --key first-key --session direct/main --model model-c)
contains "$changed" '"status":"conflict"'
retargeted=$($latifa configure --store "$store" --record "$records/retargeted.json" --key first-key --session direct/other --workspace "$root" --model model-a)
contains "$retargeted" '"status":"conflict"'
changed_kind=$($latifa message --store "$store" --record "$records/changed-kind.json" --key first-key --session direct/main --text "$state/message.txt")
contains "$changed_kind" '"status":"conflict"'

# Sealed-but-unadmitted input has no saved answer; its captured record can be
# retried by a fresh client after Host restart and then admits once.
if "$latifa" configure --store "$store" --record "$records/before.json" --key before-key --session direct/before --workspace "$root" --model model-a --test-drop-reply before-admission >"$state/drop.out" 2>"$state/drop.err"; then
    echo "pre-admission disconnect unexpectedly produced a complete reply" >&2
    exit 1
fi
before_observation=$($latifa observe-command --store "$store" --key before-key)
contains "$before_observation" '"status":"absent"'
stop_host
start_host
before_retry=$($latifa retry --store "$store" --record "$records/before.json" --kind configure)
contains "$before_retry" '"status":"accepted"'
contains "$before_retry" '"replayed":false'

# An incomplete message envelope with a usable key never publishes content,
# a command answer or a queue row.
socket=$(sed -n 's/.* socket=\([^ ]*\).*/\1/p' "$ready")
python3 - "$socket" "$store" <<'PY'
import json, socket, sys
socket_path, store = sys.argv[1:]
body = json.dumps({
    "version": "1",
    "kind": "message",
    "store": store,
    "key": "partial-message-key",
    "session": "direct/main",
    "text": {"state": "value", "value": "unterminated"},
}, separators=(",", ":")).encode()
client = socket.socket(socket.AF_UNIX)
client.connect(socket_path)
client.sendall(
    ("POST /v1/message HTTP/1.1\r\n"
     "Host: local\r\n"
     "Content-Type: application/json\r\n"
     f"Content-Length: {len(body) + 20}\r\n"
     "X-Latifa-Wire-Version: 1\r\n\r\n").encode()
)
client.sendall(body)
client.close()
PY
sleep 0.05
partial_message=$($latifa observe-command --store "$store" --key partial-message-key)
contains "$partial_message" '"status":"absent"'
partial_session=$($latifa inspect-session --store "$store" --session direct/main)
contains "$partial_session" '"pending_messages":"0"'

# Invalid schemas are definite saved rejections. A known-Session message keeps
# its original captured bytes and queue admission through lost reply, source
# mutation, client exit and Host restart.
printf '{invalid' >"$state/invalid-schema.json"
invalid_schema=$($latifa configure --store "$store" --record "$records/schema.json" --key schema-key --session direct/main --output-schema "$state/invalid-schema.json")
contains "$invalid_schema" '"code":"invalid_output_schema"'
printf 'original message with "quotes", slash \\, newline\nand emoji 🙂\n' >"$state/message-source.txt"
if "$latifa" message --store "$store" --record "$records/known-message.json" --key msg-known --session direct/main --text "$state/message-source.txt" --test-drop-reply after-commit >"$state/drop.out" 2>"$state/drop.err"; then
    echo "lost message acceptance unexpectedly produced a complete reply" >&2
    exit 1
fi
printf 'mutated after caller capture' >"$state/message-source.txt"
mv "$state/message-source.txt" "$state/message-source-moved.txt"
stop_host
start_host
known_message=$($latifa retry --store "$store" --record "$records/known-message.json" --kind message)
contains "$known_message" '"status":"accepted"'
contains "$known_message" '"replayed":true'
contains "$known_message" '"admission":"1"'
contains "$known_message" '"status":"queued"'
known_observation=$($latifa observe-command --store "$store" --key msg-known)
contains "$known_observation" '"kind":"message"'
contains "$known_observation" '"status":"queued"'
contains "$known_observation" '"type":"text"'
known_session=$($latifa inspect-session --store "$store" --session direct/main)
contains "$known_session" '"pending_messages":"1"'

# Complete stdin is captured into the durable caller record before transport;
# the multi-window pipe then disappears, and a restart retry retains its exact
# independently calculated length/digest and second position.
stdin_message=$(python3 -c 'import sys; sys.stdout.write("stdin🙂line\n" * 1000)' | "$latifa" message --store "$store" --record "$records/stdin-message.json" --key msg-stdin --session direct/main --text -)
contains "$stdin_message" '"status":"accepted"'
contains "$stdin_message" '"admission":"2"'
stop_host
start_host
stdin_replay=$($latifa retry --store "$store" --record "$records/stdin-message.json" --kind message)
contains "$stdin_replay" '"replayed":true'
contains "$stdin_replay" '"admission":"2"'
python3 - "$stdin_replay" <<'PY'
import hashlib, json, sys
payload = ("stdin🙂line\n" * 1000).encode()
domain = b"latifa/content/v1"
digest = hashlib.sha256(len(domain).to_bytes(8, "big") + domain + payload).hexdigest()
answer = json.loads(sys.argv[1])
if answer["input"]["bytes"] != str(len(payload)):
    raise SystemExit("stdin capture length differs from independent oracle")
if answer["input"]["sha256"] != digest:
    raise SystemExit("stdin capture digest differs from independent oracle")
PY
ordered_session=$($latifa inspect-session --store "$store" --session direct/main)
contains "$ordered_session" '"pending_messages":"2"'

# The accepted message binding conflicts across target, canonical input and
# kind without replacing or duplicating the original admission.
retargeted_message=$($latifa message --store "$store" --record "$records/message-retargeted.json" --key msg-known --session direct/rejected --text "$state/message.txt")
contains "$retargeted_message" '"status":"conflict"'
changed_message=$($latifa message --store "$store" --record "$records/message-changed.json" --key msg-known --session direct/main --text "$state/message.txt")
contains "$changed_message" '"status":"conflict"'
message_changed_kind=$($latifa configure --store "$store" --record "$records/message-changed-kind.json" --key msg-known --session direct/main --model model-a)
contains "$message_changed_kind" '"status":"conflict"'
still_two=$($latifa inspect-session --store "$store" --session direct/main)
contains "$still_two" '"pending_messages":"2"'

# Closing the connection after complete ingress and sealing cannot revoke an
# admission already using its sealed source. The Host completes the atomic
# import even though delivery has no receiver.
python3 - "$state/during-admission-message.txt" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_bytes(b"d" * (512 * 1024))
PY
if "$latifa" message --store "$store" --record "$records/during-admission-message.json" --key msg-disconnected-during-admission --session direct/main --text "$state/during-admission-message.txt" --test-drop-reply during-admission >"$state/drop.out" 2>"$state/drop.err"; then
    echo "during-admission disconnect unexpectedly produced a complete reply" >&2
    exit 1
fi
attempts=0
while :; do
    during_observation=$($latifa observe-command --store "$store" --key msg-disconnected-during-admission)
    case "$during_observation" in
        *'"status":"accepted"'*) break ;;
    esac
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 500 ]; then
        echo "complete disconnected message did not reach admission" >&2
        exit 1
    fi
    sleep 0.01
done
contains "$during_observation" '"status":"queued"'

# Ingress scratch/file acquisition, write and seal failures happen before
# admission. Their caller captures remain retryable and acquire one admission
# only after an ordinary restart.
for fault in content-acquire content-write content-seal; do
    key="msg-$fault"
    record="$records/$key.json"
    stop_host
    start_host --fault "$fault"
    if "$latifa" message --store "$store" --record "$record" --key "$key" --session direct/main --text "$state/message.txt" >"$state/fault.out" 2>"$state/fault.err"; then
        echo "injected $fault unexpectedly admitted a message" >&2
        exit 1
    fi
    stop_host
    start_host
    absent=$($latifa observe-command --store "$store" --key "$key")
    contains "$absent" '"status":"absent"'
    recovered=$($latifa retry --store "$store" --record "$record" --kind message)
    contains "$recovered" '"status":"accepted"'
    contains "$recovered" '"replayed":false'
done

# Canonical source verification, incremental BLOB import and commit faults
# roll back content, command binding and queue admission together, then fence
# the unsafe Host until restart.
for fault in content-read content-import before-commit; do
    key="msg-$fault"
    record="$records/$key.json"
    printf '%s unique canonical import bytes\n' "$key" >"$state/$key.txt"
    stop_host
    start_host --fault "$fault"
    if "$latifa" message --store "$store" --record "$record" --key "$key" --session direct/main --text "$state/$key.txt" >"$state/fault.out" 2>"$state/fault.err"; then
        echo "injected $fault unexpectedly admitted a message" >&2
        exit 1
    fi
    contains "$(cat "$state/fault.out")" '"code":"canonical_store_failure"'
    stop_host
    start_host
    absent=$($latifa observe-command --store "$store" --key "$key")
    contains "$absent" '"status":"absent"'
    recovered=$($latifa retry --store "$store" --record "$record" --kind message)
    contains "$recovered" '"status":"accepted"'
    contains "$recovered" '"replayed":false'
done

# A failed commit is not a saved rejection or acceptance and fences the Host.
stop_host
start_host --fault before-commit
if "$latifa" configure --store "$store" --record "$records/commit-fault.json" --key commit-fault --session direct/commit-fault --workspace "$root" --model model-a >"$state/fault.out" 2>"$state/fault.err"; then
    echo "injected commit failure returned success" >&2
    exit 1
fi
contains "$(cat "$state/fault.out")" '"code":"canonical_store_failure"'
if "$latifa" observe-command --store "$store" --key commit-fault >"$state/fenced.out" 2>"$state/fenced.err"; then
    echo "fenced Host served a canonical observation" >&2
    exit 1
fi
stop_host
start_host
commit_retry=$($latifa retry --store "$store" --record "$records/commit-fault.json" --kind configure)
contains "$commit_retry" '"status":"accepted"'
contains "$commit_retry" '"replayed":false'

# Source-read failure rolls back content and command together.
stop_host
start_host --fault content-read
printf 'faulted content' >"$state/fault-content.txt"
if "$latifa" configure --store "$store" --record "$records/read-fault.json" --key read-fault --session direct/read-fault --workspace "$root" --model model-a --instructions "$state/fault-content.txt" >"$state/fault.out" 2>"$state/fault.err"; then
    echo "injected content read failure returned success" >&2
    exit 1
fi
stop_host
start_host
read_retry=$($latifa retry --store "$store" --record "$records/read-fault.json" --kind configure)
contains "$read_retry" '"status":"accepted"'
contains "$read_retry" '"replayed":false'

# Receive-side content-write failure never reaches admission.
stop_host
start_host --fault content-write
if "$latifa" configure --store "$store" --record "$records/write-fault.json" --key write-fault --session direct/write-fault --workspace "$root" --model model-a --instructions "$state/fault-content.txt" >"$state/fault.out" 2>"$state/fault.err"; then
    echo "injected ingress write failure returned success" >&2
    exit 1
fi
write_observation=$($latifa observe-command --store "$store" --key write-fault)
contains "$write_observation" '"status":"absent"'
stop_host
start_host
write_retry=$($latifa retry --store "$store" --record "$records/write-fault.json" --kind configure)
contains "$write_retry" '"status":"accepted"'

# Failed owned-leftover cleanup refuses startup and retains the accounting
# evidence; an ordinary restart then removes only that owned temporary.
stop_host
printf 'leftover' >"$store/scratch/request-999-1.tmp"
if "$latifa" serve --store "$store" --fault startup-cleanup >"$state/startup.out" 2>"$state/startup.err"; then
    echo "Host admitted after failed startup cleanup" >&2
    exit 1
fi
test -f "$store/scratch/request-999-1.tmp"
start_host
test ! -e "$store/scratch/request-999-1.tmp"

# Exact public identity bounds are independent and count decoded UTF-8 bytes.
key128=$(python3 -c 'print("k" * 128)')
session128=$(python3 -c 'print("s" * 128)')
bounded=$($latifa configure --store "$store" --record "$records/bounded.json" --key "$key128" --session "$session128" --workspace "$root" --model model-a)
contains "$bounded" '"status":"accepted"'
key129=$(python3 -c 'print("k" * 129)')
if "$latifa" configure --store "$store" --record "$records/too-long.json" --key "$key129" --session direct/too-long --workspace "$root" --model model-a >"$state/bounds.out" 2>"$state/bounds.err"; then
    echo "129-byte key was admitted" >&2
    exit 1
fi
test ! -e "$records/too-long.json"

# Message identities use the same exact decoded-byte limits while preserving
# Unicode and transport escaping without normalization.
message_key128=$(python3 -c 'print("é" * 64, end="")')
printf 'bounded message with controls\t"quote"\\slash\n' >"$state/bounded-message.txt"
bounded_message=$($latifa message --store "$store" --record "$records/bounded-message.json" --key "$message_key128" --session "$session128" --text "$state/bounded-message.txt")
contains "$bounded_message" '"status":"accepted"'
message_key129=$(python3 -c 'print("é" * 64 + "x", end="")')
if "$latifa" message --store "$store" --record "$records/message-too-long.json" --key "$message_key129" --session "$session128" --text "$state/message.txt" >"$state/bounds.out" 2>"$state/bounds.err"; then
    echo "129-byte message key was admitted" >&2
    exit 1
fi
test ! -e "$records/message-too-long.json"

escaped_key=$(python3 -c 'print("".join(map(chr, (34, 92, 10, 9))) * 32, end="")')
escaped_message=$($latifa message --store "$store" --record "$records/escaped-message.json" --key "$escaped_key" --session "$session128" --text "$state/message.txt")
contains "$escaped_message" '"status":"accepted"'
escaped_observation=$($latifa observe-command --store "$store" --key "$escaped_key")
python3 - "$escaped_key" "$escaped_observation" <<'PY'
import json, sys
expected, encoded = sys.argv[1:]
observation = json.loads(encoded)
if observation["key"] != expected:
    raise SystemExit("escaped key was normalized or truncated")
if observation["observation"]["queue"]["status"] != "queued":
    raise SystemExit("escaped key did not recover queued admission")
PY

nfc_key=$(python3 -c 'print("é", end="")')
nfd_key=$(python3 -c 'print("e\u0301", end="")')
nfc_message=$($latifa message --store "$store" --record "$records/nfc-message.json" --key "$nfc_key" --session "$session128" --text "$state/message.txt")
nfd_message=$($latifa message --store "$store" --record "$records/nfd-message.json" --key "$nfd_key" --session "$session128" --text "$state/message.txt")
contains "$nfc_message" '"status":"accepted"'
contains "$nfd_message" '"status":"accepted"'

# A detected canonical read failure fences later admission in the same Host.
# This fixture corrupts storage only while the production owner is stopped.
stop_host
python3 - "$store/latifa.sqlite3" <<'PY'
import sqlite3, sys
database = sqlite3.connect(sys.argv[1])
database.execute(
    "UPDATE session SET instructions_content_id=9223372036854775807 "
    "WHERE session_ref='direct/main'"
)
database.commit()
database.close()
PY
start_host
if "$latifa" inspect-session --store "$store" --session direct/main >"$state/corrupt-read.out" 2>"$state/corrupt-read.err"; then
    echo "canonical corruption produced a successful observation" >&2
    exit 1
fi
contains "$(cat "$state/corrupt-read.out")" '"code":"canonical_store_failure"'
if "$latifa" configure --store "$store" --record "$records/after-corruption.json" --key after-corruption --session direct/after-corruption --workspace "$root" --model model-a >"$state/corrupt-admission.out" 2>"$state/corrupt-admission.err"; then
    echo "fenced Host admitted configuration after canonical read failure" >&2
    exit 1
fi
contains "$(cat "$state/corrupt-admission.out")" '"code":"canonical_store_failure"'

stop_host

# Persisted identity/journal settings remain readable after the owner closes.
# The production client never opens this database; this is a fixture. The
# connection-local settings are asserted through the production Store tests.
python3 - "$store/latifa.sqlite3" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
expected = {
    "journal_mode": "delete",
    "mmap_size": 0,
    "application_id": 0x4C544631,
    "user_version": 2,
}
for name, value in expected.items():
    actual = db.execute("PRAGMA " + name).fetchone()[0]
    if actual != value:
        raise SystemExit(f"{name}: expected {value!r}, got {actual!r}")
db.close()
PY

# Clients do not auto-start the Host or infer absence as a saved answer.
if "$latifa" observe-command --store "$store" --key first-key >"$state/no-host.out" 2>"$state/no-host.err"; then
    echo "client auto-started an absent Host" >&2
    exit 1
fi

# Access is checked before ownership, and an incompatible Store is rejected
# before its stale socket is reclaimed.
insecure_store="$state/insecure-store"
mkdir -m 755 "$insecure_store"
if "$latifa" serve --store "$insecure_store" >"$state/insecure.out" 2>"$state/insecure.err"; then
    echo "Host accepted an insecure Store directory" >&2
    exit 1
fi
contains "$(cat "$state/insecure.err")" "InsecureDirectoryPermissions"

wire_store="$state/wire-store"
wire_ready="$state/wire-ready"
wire_error="$state/wire-error"
"$latifa" serve --store "$wire_store" >"$wire_ready" 2>"$wire_error" &
extra_pid=$!
attempts=0
while ! grep -q '^ready ' "$wire_ready"; do
    if ! kill -0 "$extra_pid" 2>/dev/null; then
        cat "$wire_error" >&2
        exit 1
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 500 ]; then
        echo "wire-version fixture Host did not become ready" >&2
        exit 1
    fi
    sleep 0.01
done
wire_socket=$(sed -n 's/.* socket=\([^ ]*\).*/\1/p' "$wire_ready")
kill -9 "$extra_pid"
wait "$extra_pid" 2>/dev/null || true
extra_pid=
test -S "$wire_socket"
python3 - "$wire_store/latifa.sqlite3" <<'PY'
import sqlite3, sys
database = sqlite3.connect(sys.argv[1])
database.execute("UPDATE store_meta SET value='future' WHERE key='wire_version'")
database.commit()
database.close()
PY
if "$latifa" serve --store "$wire_store" >"$state/wrong-wire.out" 2>"$state/wrong-wire.err"; then
    echo "Host accepted an incompatible wire version" >&2
    exit 1
fi
contains "$(cat "$state/wrong-wire.err")" "WrongStoreVersion"
test -S "$wire_socket"

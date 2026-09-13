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

cleanup() {
    if [ -n "$host_pid" ]; then
        kill -9 "$host_pid" 2>/dev/null || true
        wait "$host_pid" 2>/dev/null || true
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

# The OS-held lock rejects a competing owner without relying on PID/socket state.
if "$latifa" serve --store "$store" >"$state/competing.out" 2>"$state/competing.err"; then
    echo "competing Host acquired the Store" >&2
    exit 1
fi
contains "$(cat "$state/competing.err")" "StoreAlreadyOwned"

# Fill all ordinary places with sealed headers and incomplete bodies. A short
# control classification still receives its explicit development response;
# eight additional classifiers bring the exact total to 128, and the next
# connection is rejected without displacing existing custody.
socket=$(sed -n 's/.* socket=\([^ ]*\).*/\1/p' "$ready")
python3 - "$socket" <<'PY'
import select, socket, sys, time

socket_path = sys.argv[1]
ordinary = []
for _ in range(120):
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
    raise SystemExit("ordinary capacity rejected before 120 connections")

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
for _ in range(8):
    client = socket.socket(socket.AF_UNIX)
    client.connect(socket_path)
    classification.append(client)
time.sleep(0.05)
overflow = socket.socket(socket.AF_UNIX)
overflow.connect(socket_path)
overflow_response = overflow.recv(4096)
overflow.close()
if not overflow_response.startswith(b"HTTP/1.1 503 "):
    raise SystemExit("129th connection was not rejected")

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
unknown=$($latifa message --store "$store" --record "$records/unknown-message.json" --key msg-unknown --session direct/unknown --text "$state/message.txt")
contains "$unknown" '"code":"unknown_session"'
unknown_session=$($latifa inspect-session --store "$store" --session direct/unknown)
contains "$unknown_session" '"session":null'

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

# Invalid schemas are definite saved rejections; a known-Session message
# explicitly reports the later implementation surface as unavailable.
printf '{invalid' >"$state/invalid-schema.json"
invalid_schema=$($latifa configure --store "$store" --record "$records/schema.json" --key schema-key --session direct/main --output-schema "$state/invalid-schema.json")
contains "$invalid_schema" '"code":"invalid_output_schema"'
known_message=$($latifa message --store "$store" --record "$records/known-message.json" --key msg-known --session direct/main --text "$state/message.txt")
contains "$known_message" '"code":"model_processing_unavailable_in_issue_170"'

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
    "user_version": 1,
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

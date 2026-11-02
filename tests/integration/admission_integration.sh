set -eu
# Enter through the fixture boundary, which refuses root and builds this
# fixture's environment, then run again with the argument it adds.
if [ "${1:-}" = --entered ]; then
    shift
else
    exec python3 "$(dirname -- "$0")/host_process.py" exec sh "$0" --entered "$@"
fi

rui=$1
mode=${2:-full}
case "$mode" in
    full|artifact-smoke) ;;
    *) echo "unknown admission mode: $mode" >&2; exit 1 ;;
esac
root=$(pwd -P)
state=$(mktemp -d "${TMPDIR:-/tmp}/rui-admission.XXXXXX")
chmod 700 "$state"
state=$(PYTHONPATH="$root/tests/integration" python3 -c 'import sys; from host_process import canonical_fixture_root; print(canonical_fixture_root(sys.argv[1]))' "$state")
store="$state/store"
records="$state/records"
mkdir -m 700 "$records"
session_id() {
    python3 -c 'import json, sys; reply=json.load(sys.stdin); identity=reply["answer"]["session"]; assert reply["answer"]["status"] == "accepted", reply; assert len(identity) == 6 and all(c in "0123456789abcdefghjkmnpqrstvwxyz" for c in identity), reply; assert reply["context"]["session"] == identity, reply; print(identity)'
}
session_refs() {
    "$rui" session list --store "$store" --all | python3 -c 'import json, sys; print(json.dumps(sorted(row["reference"] for row in json.load(sys.stdin)["sessions"])))'
}

# Fresh CLI configuration fills required defaults and rejects unsupported
# providers before capture. Exercise the Host's saved rejection boundary with
# explicit wire records instead, then recover those same records through CLI.
wire_configure() {
    python3 - "$rui" "$store" "$ready" "$@" <<'PYWIRE'
import json, pathlib, socket, subprocess, sys
binary, store, ready, key, record, encoded, *drop = sys.argv[1:]
values = json.loads(encoded)
fields = ('workspace', 'provider', 'model', 'instructions', 'tools', 'permission_mode', 'output_schema')
configuration = {name: {'state': 'value', 'value': values[name]} if name in values else {'state': 'omitted'} for name in fields}
body = json.dumps({'version': '4', 'kind': 'configure', 'store': store,
                   'key': key, 'session': '', 'configuration': configuration}, separators=(',', ':')).encode()
with pathlib.Path(record).open('xb') as captured:
    captured.write(body)
pathlib.Path(record).chmod(0o600)
if not drop:
    sys.exit(subprocess.run([binary, 'request', 'recover', '--store', store,
        '--record', record, '--kind', 'configure'], timeout=15).returncode)
assert drop == ['after-commit'], drop
socket_path = dict(part.split('=', 1) for part in pathlib.Path(ready).read_text().split()[1:])['socket']
with socket.socket(socket.AF_UNIX) as client:
    client.settimeout(15)
    client.connect(socket_path)
    client.sendall(('POST /v1/configure HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\n'
        f'Content-Length: {len(body)}\r\nX-Rui-Wire-Version: 4\r\n'
        'X-Rui-Test-Drop-Reply: after-commit\r\n\r\n').encode() + body)
    assert not client.recv(16384), 'lost rejection unexpectedly delivered a reply'
PYWIRE
}
ready="$state/ready"
server_log="$state/server.log"
host_pid=
extra_pid=
client_pid=

cleanup() {
    result=$?
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
    if [ "$result" -eq 0 ]; then
        rm -rf "$state"
    else
        echo "retained admission failure state: $state" >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_host() {
    : >"$ready"
    : >"$server_log"
    "$rui" host serve --store "$store" "$@" >"$ready" 2>"$server_log" &
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

wait_host_failure() {
    attempts=0
    while kill -0 "$host_pid" 2>/dev/null; do
        case $(ps -o stat= -p "$host_pid" 2>/dev/null || true) in
            *Z*) break ;;
        esac
        attempts=$((attempts + 1))
        if [ "$attempts" -gt 500 ]; then
            echo "Host did not complete effect-aware shutdown" >&2
            return 1
        fi
        sleep 0.01
    done
    if wait "$host_pid"; then
        echo "effect-aware shutdown exited successfully" >&2
        return 1
    fi
    host_pid=
}

contains() {
    case "$1" in
        *"$2"*) ;;
        *) echo "missing expected text: $2" >&2; echo "$1" >&2; return 1 ;;
    esac
}

# A saved rejection or conflict is delivered on stdout but exits 1.
not_accepted() {
    status=0
    reply=$("$@") || status=$?
    if [ "$status" -ne 1 ]; then
        echo "expected a saved non-acceptance with exit 1, got $status: $*" >&2
        printf '%s\n' "$reply" >&2
        return 1
    fi
    printf '%s' "$reply"
}

require_test() {
    description=$1
    shift
    if test "$@"; then
        return 0
    else
        result=$?
        printf 'admission assertion failed: %s\n' "$description" >&2
        return "$result"
    fi
}

start_host

# SIGKILL skips capture.abort; revisiting the same record recovers its temporary.
capture_session=$(python3 - "$rui" "$store" "$records" "$root" <<'PYCAPTURE'
import json, pathlib, subprocess, sys, time
binary, store, records, workspace = sys.argv[1:]
record = pathlib.Path(records) / 'capture-recovery.json'
args = [binary, 'session', 'configure', '--store', store, '--record', str(record),
        '--key', 'capture-recovery',
        '--workspace', workspace, '--provider', 'codex', '--model', 'gpt-6-sol', '--instructions', '-']
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
reply = json.loads(recovered.stdout)
identity = reply['answer']['session']
assert len(identity) == 6 and all(c in '0123456789abcdefghjkmnpqrstvwxyz' for c in identity), reply
assert reply['context']['session'] == identity, reply
print(identity)
PYCAPTURE
)

# The OS-held lock rejects a competing owner without relying on PID/socket state.
if "$rui" host serve --store "$store" >"$state/competing.out" 2>"$state/competing.err"; then
    echo "competing Host acquired the Store" >&2
    exit 1
fi
contains "$(cat "$state/competing.err")" "StoreAlreadyOwned"

# The alternate build mode needs a real artifact/recovery witness, not a
# second copy of the complete ReleaseSafe fault matrix. Keep `full` opt-in.
if [ "$mode" = artifact-smoke ]; then
    printf 'original message\n' >"$state/message.txt"
    if "$rui" session send --store "$store" --to "$capture_session" --record "$records/smoke-message.json" --key smoke-message --test-drop-reply after-commit <"$state/message.txt" >"$state/drop.out" 2>"$state/drop.err"; then
        echo "lost message reply unexpectedly completed" >&2
        exit 1
    fi
    printf 'replacement input\n' >"$state/message.txt"
    stop_host
    start_host
    replayed=$($rui request recover --store "$store" --record "$records/capture-recovery.json" --kind configure)
    contains "$replayed" '"status":"accepted"'
    contains "$replayed" '"replayed":true'
    require_test 'creation replay retains allocated ID' "$(printf '%s' "$replayed" | session_id)" = "$capture_session"
    replayed=$($rui request recover --store "$store" --record "$records/smoke-message.json" --kind message)
    python3 - "$replayed" <<'PYSMOKE'
import hashlib, json, sys
reply = json.loads(sys.argv[1])
assert reply['answer']['status'] == 'accepted', reply
assert reply['answer']['replayed'] is True, reply
assert reply['queue']['status'] == 'queued', reply
assert reply['queue']['admission'] == '1', reply
payload = b'original message\n'
domain = b'rui/content/v1'
digest = hashlib.sha256(len(domain).to_bytes(8, 'big') + domain + payload).hexdigest()
assert reply['input']['bytes'] == str(len(payload)), reply
assert reply['input']['sha256'] == digest, reply
PYSMOKE
    inspected=$($rui session inspect --store "$store" --session "$capture_session")
    contains "$inspected" '"pending_messages":"1"'
    stop_host
    echo 'admission artifact smoke passed: capture errors, Store lease, lost reply and restart replay'
    exit 0
fi

# A listener failure stops new dispatch but keeps the Store lock and Host stack
# alive until a transferred client finishes its body read.
drain_store="$state/drain-store"
drain_ready="$state/drain-ready"
drain_error="$state/drain-error"
"$rui" host serve --store "$drain_store" --fault shutdown-after-accept >"$drain_ready" 2>"$drain_error" &
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
PYTHONPATH="$root/tests/integration" python3 - "$rui" "$drain_socket" "$drain_store" "$root" "$state" <<'PY'
import json, os, pathlib, socket, subprocess, sys, time
from host_process import is_peer_disconnect, preserve_failure_metadata, stop_process
rui, socket_path, store, workspace, state = sys.argv[1:]
state = pathlib.Path(state)
body = json.dumps({
    "version": "4",
    "kind": "configure",
    "store": os.path.realpath(store),
    "key": "draining-request",
    "session": "",
    "configuration": {
        "workspace": {"state": "value", "value": workspace},
        "provider": {"state": "value", "value": "codex"},
        "model": {"state": "value", "value": "gpt-6-sol"},
        "instructions": {"state": "omitted"},
        "tools": {"state": "omitted"},
        "permission_mode": {"state": "omitted"},
        "output_schema": {"state": "omitted"},
    },
}, separators=(",", ":")).encode()
client = socket.socket(socket.AF_UNIX)
client.settimeout(3)
client.connect(socket_path)
header = (
    "POST /v1/configure HTTP/1.1\r\n"
    "Host: local\r\n"
    "Content-Type: application/json\r\n"
    f"Content-Length: {len(body)}\r\n"
    "X-Rui-Wire-Version: 4\r\n\r\n"
).encode()
response = bytearray()
try:
    try:
        client.sendall(header + body)
        while chunk := client.recv(4096):
            response.extend(chunk)
            assert len(response) <= 16384, "drain response exceeded fixture bound"
    except OSError as error:
        if not is_peer_disconnect(error):
            raise
        # Intake shutdown may win before or after the first upload byte.
    (state / "drain-response.bin").write_bytes(response)
    assert b'"status":"accepted"' not in response, response
finally:
    if sys.exc_info()[0] is not None:
        preserve_failure_metadata(state / "drain-failure.json", lambda: {
            "response_bytes": len(response)})
    client.close()
PY
# Use the existing bounded failure wait for this second Host as well.
drain_pid=$extra_pid
extra_pid=$host_pid
host_pid=$drain_pid
wait_host_failure
host_pid=$extra_pid
extra_pid=
contains "$(cat "$drain_error")" "InjectedListenerFailure"
PYTHONPATH="$root/tests/integration" python3 - "$rui" "$drain_store" <<'PY'
import pathlib, sys
import model_fixture as fixture
fixture.RUI = pathlib.Path(sys.argv[1])
store = pathlib.Path(sys.argv[2])
host = fixture.start_host(store, None)
try:
    assert fixture.observe(store, "draining-request") == {"status": "absent"}
finally:
    fixture.stop_host(host)
PY

# Incomplete bodies and unclassified sockets retain their own custody without
# filling a fixed connection quota or blocking a complete control request.
stop_host
python3 - "$rui" "$store" <<'PY'
import json, pathlib, select, socket, sys, time
sys.path.insert(0, "tests/integration")
import control_integration as control
from host_process import HostDiagnostics, PeerCensus, dispose_all, stop_process

store = pathlib.Path(sys.argv[2])
host, fields = control.start_host(store, observations="control_peers")
peers = PeerCensus(HostDiagnostics(host))
socket_path = fields["socket"]
ordinary = []
classification = []
try:
    for _ in range(100):
        ordinary.append(peers.open("configure", lambda: control.open_partial(
            socket_path, "/v1/configure"), timeout=3))
    for _ in range(3):
        client = socket.socket(socket.AF_UNIX)
        client.settimeout(3)
        classification.append(client)
        client.connect(socket_path)
    head, body = peers.release_place("classification", lambda: control.raw_request(
        socket_path, "/v1/control/stop", b""), timeout=5)
    assert head.startswith(b"HTTP/1.1 501 "), (head, body)
    control.assert_intake_progress(socket_path, store, peers)
    peers.held(peers.borrowers.values())
    ready, _, _ = select.select(classification + ordinary, [], [], 0)
    assert not ready, "incomplete exchange was displaced by concurrent intake"
    for client in classification:
        peers.release_place("classification", client.close)
    classification.clear()
    peers.close(ordinary, time.monotonic() + 3)
    ordinary.clear()

    # Prove the usable-looking partial key reached ingress after retirement;
    # absence after restart alone would also pass if this request were refused.
    body = json.dumps({"version":"4","kind":"configure","store":str(store),"key":"partial-key"}, separators=(",", ":")).encode()
    # A closed object is already invalid without the required Session fields.
    # Leave the next field unfinished so the streaming parser must await input.
    body = body[:-1] + b","
    def partial():
        client = socket.socket(socket.AF_UNIX)
        try:
            client.settimeout(3)
            client.connect(socket_path)
            client.sendall(("POST /v1/configure HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: %d\r\nX-Rui-Wire-Version: 4\r\n\r\n" % (len(body) + 50)).encode() + body)
            return client
        except BaseException:
            client.close()
            raise
    ordinary.append(peers.open("configure", partial, timeout=3))
    peers.close(ordinary, time.monotonic() + 3)
    ordinary.clear()
    stop_process(host)
    peers.finish(time.monotonic())
finally:
    dispose_all(*(client.close for client in classification + ordinary), lambda: stop_process(host))
PY
start_host
partial=$($rui request inspect --store "$store" --key partial-key)
contains "$partial" '"status":"absent"'

# Messages to unknown Sessions are saved rejections and create no Session.
printf 'hello' >"$state/message.txt"
known_refs=$(session_refs)
unknown_id=$(python3 -c 'import json, sys; known=json.loads(sys.argv[1]); print(next(f"{i:06d}" for i in range(len(known)+1) if f"{i:06d}" not in known))' "$known_refs")
if "$rui" session send --store "$store" --to "$unknown_id" --record "$records/unknown-message.json" --key msg-unknown --test-drop-reply after-commit <"$state/message.txt" >"$state/drop.out" 2>"$state/drop.err"; then
    echo "lost unknown-Session rejection unexpectedly produced a complete reply" >&2
    exit 1
fi
unknown_session=$($rui session inspect --store "$store" --session "$unknown_id")
contains "$unknown_session" '"session":null'
require_test 'unknown Message creates no Session' "$(session_refs)" = "$known_refs"
# Supplying even a complete configuration cannot create a chosen canonical ID.
unknown_configure=$(not_accepted "$rui" session configure --store "$store" --record "$records/unknown-configure.json" --key unknown-configure --session "$unknown_id" --workspace "$root" --provider codex --model gpt-6-sol)
contains "$unknown_configure" '"code":"unknown_session"'
require_test 'unknown Configure creates no Session' "$(session_refs)" = "$known_refs"
unknown_created=$($rui session configure --store "$store" --record "$records/unknown-created.json" --key unknown-created --workspace "$root" --provider codex --model gpt-6-sol)
contains "$unknown_created" '"status":"accepted"'
other_session=$(printf '%s' "$unknown_created" | session_id)
stop_host
start_host
unknown=$(not_accepted "$rui" request recover --store "$store" --record "$records/unknown-message.json" --kind message)
contains "$unknown" '"status":"rejected"'
contains "$unknown" '"replayed":true'
contains "$unknown" '"code":"unknown_session"'
contains "$unknown" '"bytes":"5"'
unknown_after_creation=$($rui session inspect --store "$store" --session "$other_session")
contains "$unknown_after_creation" '"pending_messages":"0"'
unknown_configure_replay=$(not_accepted "$rui" request recover --store "$store" --record "$records/unknown-configure.json" --kind configure)
contains "$unknown_configure_replay" '"code":"unknown_session"'
contains "$unknown_configure_replay" '"replayed":true'

# A lost creation rejection remains original after another key creates a Session.
before_incomplete=$(session_refs)
wire_configure incomplete-key "$records/incomplete.json" '{}' after-commit >"$state/drop.out" 2>"$state/drop.err"
require_test 'incomplete creation creates no Session' "$(session_refs)" = "$before_incomplete"
created=$($rui session configure --store "$store" --record "$records/rejected-create.json" --key rejected-create --workspace "$root" --provider codex --model gpt-6-sol)
contains "$created" '"status":"accepted"'
rejected_session=$(printf '%s' "$created" | session_id)
defaults=$($rui session inspect --store "$store" --session "$rejected_session")
contains "$defaults" '"tools":["bash"]'
contains "$defaults" '"permission_mode":"bypass"'
contains "$defaults" '"instructions":{"bytes":"0"'
contains "$defaults" '"output_schema":null'
rejected=$(not_accepted "$rui" request recover --store "$store" --record "$records/incomplete.json" --kind configure)
contains "$rejected" '"status":"rejected"'
contains "$rejected" '"replayed":true'
contains "$rejected" '"code":"incomplete_initial_configuration"'

# Store tests own all eight initial-field combinations. Keep a partially filled
# wire request and closed-provider rejection with real request-scratch cleanup.
before_provider=$(session_refs)
missing_configuration=$(python3 -c 'import json, sys; print(json.dumps({"workspace": sys.argv[1], "model": "gpt-6-sol"}))' "$root")
missing_provider=$(not_accepted wire_configure missing-provider "$records/missing-provider.json" "$missing_configuration")
contains "$missing_provider" '"code":"incomplete_initial_configuration"'
printf 'rejected instructions' >"$state/rejected-instructions.txt"
printf '{"type":"object"}' >"$state/rejected-schema.json"
unknown_configuration=$(python3 - "$root" "$state/rejected-instructions.txt" "$state/rejected-schema.json" <<'PY'
import json, pathlib, sys
print(json.dumps({'workspace': sys.argv[1], 'provider': 'anthropic', 'model': 'gpt-6-sol',
    'instructions': pathlib.Path(sys.argv[2]).read_text(), 'output_schema': pathlib.Path(sys.argv[3]).read_text(), 'tools': []}))
PY
)
unknown_provider=$(not_accepted wire_configure unknown-provider "$records/unknown-provider.json" "$unknown_configuration")
contains "$unknown_provider" '"code":"unsupported_provider"'
require_test 'rejected providers create no Session' "$(session_refs)" = "$before_provider"
require_test 'rejected provider releases all request scratch' -z "$(find "$store/scratch" -name 'request-*.tmp' -print)"

# Equal and omitted binding fields preserve the initial binding. An unequal
# model rejects the entire mixed update before work and across Host restart.
binding=$($rui session configure --store "$store" --record "$records/binding.json" --key binding --workspace "$root" --provider codex --model gpt-6-sol)
contains "$binding" '"revision":"1"'
binding_session=$(printf '%s' "$binding" | session_id)
equal_binding=$($rui session configure --store "$store" --record "$records/equal-binding.json" --key equal-binding --session "$binding_session" --provider codex --model gpt-6-sol --tools none)
contains "$equal_binding" '"revision":"2"'
omitted_binding=$($rui session configure --store "$store" --record "$records/omitted-binding.json" --key omitted-binding --session "$binding_session" --permission-mode bypass)
contains "$omitted_binding" '"revision":"3"'
mixed_model=$(not_accepted "$rui" session configure --store "$store" --record "$records/mixed-model.json" --key mixed-model --session "$binding_session" --model gpt-6.1-sol --tools bash --permission-mode ask)
contains "$mixed_model" '"code":"model_is_immutable"'
binding_current=$($rui session inspect --store "$store" --session "$binding_session" --profile current)
contains "$binding_current" '"provider":"codex"'
contains "$binding_current" '"model":"gpt-6-sol"'
contains "$binding_current" '"revision":"3"'
contains "$binding_current" '"tools":[]'
contains "$binding_current" '"permission_mode":"bypass"'
stop_host
start_host
unknown_replay=$(not_accepted "$rui" request recover --store "$store" --record "$records/unknown-provider.json" --kind configure)
contains "$unknown_replay" '"code":"unsupported_provider"'
contains "$unknown_replay" '"replayed":true'
binding_full=$($rui session inspect --store "$store" --session "$binding_session" --profile full)
contains "$binding_full" '"provider":"codex"'
contains "$binding_full" '"model":"gpt-6-sol"'
contains "$binding_full" '"revision":"3"'
printf '%s' "$binding_full" | python3 -c 'import json,sys; rows=json.load(sys.stdin)["full"]["session_revisions"]; assert len(rows)==3; assert all(r["provider"]=="codex" and r["model"]=="gpt-6-sol" for r in rows)'
restarted_model=$(not_accepted "$rui" session configure --store "$store" --record "$records/restarted-model.json" --key restarted-model --session "$binding_session" --model gpt-6.1-sol --tools bash)
contains "$restarted_model" '"code":"model_is_immutable"'
binding_rechecked=$($rui session inspect --store "$store" --session "$binding_session" --profile current)
contains "$binding_rechecked" '"revision":"3"'
contains "$binding_rechecked" '"tools":[]'

# Lose an accepted reply, change current settings, and kill both processes.
printf 'initial instructions\n' >"$state/instructions.txt"
printf '{"type":"object"}\n' >"$state/schema.json"
if "$rui" session configure --store "$store" --record "$records/first.json" --key first-key --workspace "$root" --provider codex --model gpt-6-sol --instructions - --output-schema "$state/schema.json" --test-drop-reply after-commit <"$state/instructions.txt" >"$state/drop.out" 2>"$state/drop.err"; then
    echo "lost acceptance unexpectedly produced a complete reply" >&2
    exit 1
fi
first_recovery=$($rui request recover --store "$store" --record "$records/first.json" --kind configure)
contains "$first_recovery" '"replayed":true'
main_session=$(printf '%s' "$first_recovery" | session_id)
updated=$($rui session configure --store "$store" --record "$records/update.json" --key update-key --session "$main_session" --tools none --permission-mode bypass)
contains "$updated" '"revision":"2"'
preserved=$($rui session inspect --store "$store" --session "$main_session")
contains "$preserved" '"bytes":"21"'
case "$preserved" in
    *'"output_schema":{"bytes":'*) ;;
    *) echo "sparse update cleared output schema" >&2; exit 1 ;;
esac
# The retry record owns its captured bytes; later source-file mutation cannot
# change the request that is replayed.
printf 'mutated after durable capture\n' >"$state/instructions.txt"
: >"$state/empty.txt"
cleared=$($rui session configure --store "$store" --record "$records/clear.json" --key clear-key --session "$main_session" --instructions - --text-output <"$state/empty.txt")
contains "$cleared" '"revision":"3"'
stop_host
start_host

replayed=$($rui request recover --store "$store" --record "$records/first.json" --kind configure)
contains "$replayed" '"status":"accepted"'
contains "$replayed" '"replayed":true'
contains "$replayed" '"revision":"1"'
require_test 'lost creation replay retains allocated ID' "$(printf '%s' "$replayed" | session_id)" = "$main_session"
current=$($rui session inspect --store "$store" --session "$main_session")
contains "$current" '"provider":"codex"'
contains "$current" '"model":"gpt-6-sol"'
contains "$current" '"revision":"3"'
contains "$current" '"tools":[]'
contains "$current" '"permission_mode":"bypass"'
contains "$current" '"instructions":{"bytes":"0"'
contains "$current" '"output_schema":null'

# The same Store-wide key conflicts across changed inputs, targets, and kinds.
changed=$(not_accepted "$rui" session configure --store "$store" --record "$records/changed.json" --key first-key --workspace "$root" --provider codex --model gpt-6-astra)
contains "$changed" '"status":"conflict"'
retargeted=$(not_accepted "$rui" session configure --store "$store" --record "$records/retargeted.json" --key first-key --session "$rejected_session" --workspace "$root" --provider codex --model gpt-6-sol)
contains "$retargeted" '"status":"conflict"'
changed_kind=$(not_accepted "$rui" session send --store "$store" --to "$main_session" --record "$records/changed-kind.json" --key first-key <"$state/message.txt")
contains "$changed_kind" '"status":"conflict"'

# Sealed-but-unadmitted input has no saved answer; its captured record can be
# retried by a fresh client after Host restart and then admits once.
if "$rui" session configure --store "$store" --record "$records/before.json" --key before-key --workspace "$root" --provider codex --model gpt-6-sol --test-drop-reply before-admission >"$state/drop.out" 2>"$state/drop.err"; then
    echo "pre-admission disconnect unexpectedly produced a complete reply" >&2
    exit 1
fi
before_observation=$($rui request inspect --store "$store" --key before-key)
contains "$before_observation" '"status":"absent"'
stop_host
start_host
before_retry=$($rui request recover --store "$store" --record "$records/before.json" --kind configure)
contains "$before_retry" '"status":"accepted"'
contains "$before_retry" '"replayed":false'
before_session=$(printf '%s' "$before_retry" | session_id)

# An incomplete message envelope with a usable key never publishes content,
# a command answer or a queue row.
socket=$(sed -n 's/.* socket=\([^ ]*\).*/\1/p' "$ready")
python3 - "$socket" "$store" "$main_session" <<'PY'
import json, socket, sys
socket_path, store, session = sys.argv[1:]
body = json.dumps({
    "version": "4",
    "kind": "message",
    "store": store,
    "key": "partial-message-key",
    "session": session,
    "sender": None,
    "sender_handle": None,
    "text": {"state": "value", "value": "unterminated"},
}, separators=(",", ":")).encode()
client = socket.socket(socket.AF_UNIX)
client.connect(socket_path)
client.sendall(
    ("POST /v1/message HTTP/1.1\r\n"
     "Host: local\r\n"
     "Content-Type: application/json\r\n"
     f"Content-Length: {len(body) + 20}\r\n"
     "X-Rui-Environment-Bytes: 0\r\n"
     "X-Rui-Wire-Version: 4\r\n\r\n").encode()
)
client.sendall(body)
client.close()
PY
stop_host
start_host
partial_message=$($rui request inspect --store "$store" --key partial-message-key)
contains "$partial_message" '"status":"absent"'
partial_session=$($rui session inspect --store "$store" --session "$main_session")
contains "$partial_session" '"pending_messages":"0"'

# Invalid schemas are definite saved rejections. A known-Session message keeps
# its original captured bytes and queue admission through lost reply, source
# mutation, client exit and Host restart.
printf '{invalid' >"$state/invalid-schema.json"
invalid_schema=$(not_accepted "$rui" session configure --store "$store" --record "$records/schema.json" --key schema-key --session "$main_session" --output-schema "$state/invalid-schema.json")
contains "$invalid_schema" '"code":"invalid_output_schema"'
printf 'original message with "quotes", slash \\, newline\nand emoji 🙂\n' >"$state/message-source.txt"
if "$rui" session send --store "$store" --to "$main_session" --record "$records/known-message.json" --key msg-known --test-drop-reply after-commit <"$state/message-source.txt" >"$state/drop.out" 2>"$state/drop.err"; then
    echo "lost message acceptance unexpectedly produced a complete reply" >&2
    exit 1
fi
printf 'mutated after caller capture' >"$state/message-source.txt"
mv "$state/message-source.txt" "$state/message-source-moved.txt"
stop_host
start_host
known_message=$($rui request recover --store "$store" --record "$records/known-message.json" --kind message)
contains "$known_message" '"status":"accepted"'
contains "$known_message" '"replayed":true'
contains "$known_message" '"admission":"1"'
contains "$known_message" '"status":"queued"'
known_observation=$($rui request inspect --store "$store" --key msg-known)
contains "$known_observation" '"kind":"message"'
contains "$known_observation" '"status":"queued"'
contains "$known_observation" '"type":"text"'
known_session=$($rui session inspect --store "$store" --session "$main_session")
contains "$known_session" '"pending_messages":"1"'

# Complete stdin is captured into the durable caller record before transport;
# the multi-window pipe then disappears, and a restart retry retains its exact
# independently calculated length/digest and second position.
stdin_message=$(python3 -c 'import sys; sys.stdout.write("stdin🙂line\n" * 1000)' | "$rui" session send --store "$store" --to "$main_session" --record "$records/stdin-message.json" --key msg-stdin)
contains "$stdin_message" '"status":"accepted"'
contains "$stdin_message" '"admission":"2"'
stop_host
start_host
stdin_replay=$($rui request recover --store "$store" --record "$records/stdin-message.json" --kind message)
contains "$stdin_replay" '"replayed":true'
contains "$stdin_replay" '"admission":"2"'
python3 - "$stdin_replay" <<'PY'
import hashlib, json, sys
payload = ("stdin🙂line\n" * 1000).encode()
domain = b"rui/content/v1"
digest = hashlib.sha256(len(domain).to_bytes(8, "big") + domain + payload).hexdigest()
answer = json.loads(sys.argv[1])
if answer["input"]["bytes"] != str(len(payload)):
    raise SystemExit("stdin capture length differs from independent oracle")
if answer["input"]["sha256"] != digest:
    raise SystemExit("stdin capture digest differs from independent oracle")
PY
ordered_session=$($rui session inspect --store "$store" --session "$main_session")
contains "$ordered_session" '"pending_messages":"2"'

# The accepted message binding conflicts across target, canonical input and
# kind without replacing or duplicating the original admission.
retargeted_message=$(not_accepted "$rui" session send --store "$store" --to "$rejected_session" --record "$records/message-retargeted.json" --key msg-known <"$state/message.txt")
contains "$retargeted_message" '"status":"conflict"'
changed_message=$(not_accepted "$rui" session send --store "$store" --to "$main_session" --record "$records/message-changed.json" --key msg-known <"$state/message.txt")
contains "$changed_message" '"status":"conflict"'
message_changed_kind=$(not_accepted "$rui" session configure --store "$store" --record "$records/message-changed-kind.json" --key msg-known --session "$main_session" --model gpt-6-sol)
contains "$message_changed_kind" '"status":"conflict"'
still_two=$($rui session inspect --store "$store" --session "$main_session")
contains "$still_two" '"pending_messages":"2"'

# Closing the connection after complete ingress and sealing cannot revoke an
# admission already using its sealed source. The Host completes the atomic
# import even though delivery has no receiver.
python3 - "$state/during-admission-message.txt" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_bytes(b"d" * (512 * 1024))
PY
if "$rui" session send --store "$store" --to "$main_session" --record "$records/during-admission-message.json" --key msg-disconnected-during-admission --test-drop-reply during-admission <"$state/during-admission-message.txt" >"$state/drop.out" 2>"$state/drop.err"; then
    echo "during-admission disconnect unexpectedly produced a complete reply" >&2
    exit 1
fi
attempts=0
while :; do
    during_observation=$($rui request inspect --store "$store" --key msg-disconnected-during-admission)
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
    if "$rui" session send --store "$store" --to "$main_session" --record "$record" --key "$key" <"$state/message.txt" >"$state/fault.out" 2>"$state/fault.err"; then
        echo "injected $fault unexpectedly admitted a message" >&2
        exit 1
    fi
    stop_host
    start_host
    absent=$($rui request inspect --store "$store" --key "$key")
    contains "$absent" '"status":"absent"'
    recovered=$($rui request recover --store "$store" --record "$record" --kind message)
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
    if "$rui" session send --store "$store" --to "$main_session" --record "$record" --key "$key" <"$state/$key.txt" >"$state/fault.out" 2>"$state/fault.err"; then
        echo "injected $fault unexpectedly admitted a message" >&2
        exit 1
    fi
    contains "$(cat "$state/fault.out")" '"code":"canonical_store_failure"'
    wait_host_failure
    start_host
    absent=$($rui request inspect --store "$store" --key "$key")
    contains "$absent" '"status":"absent"'
    recovered=$($rui request recover --store "$store" --record "$record" --kind message)
    contains "$recovered" '"status":"accepted"'
    contains "$recovered" '"replayed":false'
done

# A failed commit is not a saved rejection or acceptance and fences the Host.
stop_host
start_host --fault before-commit
if "$rui" session configure --store "$store" --record "$records/commit-fault.json" --key commit-fault --workspace "$root" --provider codex --model gpt-6-sol >"$state/fault.out" 2>"$state/fault.err"; then
    echo "injected commit failure returned success" >&2
    exit 1
fi
contains "$(cat "$state/fault.out")" '"code":"canonical_store_failure"'
wait_host_failure
start_host
commit_retry=$($rui request recover --store "$store" --record "$records/commit-fault.json" --kind configure)
contains "$commit_retry" '"status":"accepted"'
contains "$commit_retry" '"replayed":false'
commit_session=$(printf '%s' "$commit_retry" | session_id)

# Source-read failure rolls back content and command together.
stop_host
start_host --fault content-read
printf 'faulted content' >"$state/fault-content.txt"
if "$rui" session configure --store "$store" --record "$records/read-fault.json" --key read-fault --workspace "$root" --provider codex --model gpt-6-sol --instructions - <"$state/fault-content.txt" >"$state/fault.out" 2>"$state/fault.err"; then
    echo "injected content read failure returned success" >&2
    exit 1
fi
wait_host_failure
start_host
read_retry=$($rui request recover --store "$store" --record "$records/read-fault.json" --kind configure)
contains "$read_retry" '"status":"accepted"'
contains "$read_retry" '"replayed":false'
read_session=$(printf '%s' "$read_retry" | session_id)

# Receive-side content-write failure never reaches admission.
stop_host
start_host --fault content-write
if "$rui" session configure --store "$store" --record "$records/write-fault.json" --key write-fault --workspace "$root" --provider codex --model gpt-6-sol --instructions - <"$state/fault-content.txt" >"$state/fault.out" 2>"$state/fault.err"; then
    echo "injected ingress write failure returned success" >&2
    exit 1
fi
write_observation=$($rui request inspect --store "$store" --key write-fault)
contains "$write_observation" '"status":"absent"'
stop_host
start_host
write_retry=$($rui request recover --store "$store" --record "$records/write-fault.json" --kind configure)
contains "$write_retry" '"status":"accepted"'
write_session=$(printf '%s' "$write_retry" | session_id)

# Crash the first request while its streamed instructions still have a name.
stop_host
start_host
python3 - "$ready" "$store" "$host_pid" <<'PYCRASH'
import json, os, signal, socket, sys, time
ready, store, pid = sys.argv[1:]
fields = dict(part.split("=", 1) for part in open(ready).read().split()[1:])
request = {"version":"4", "kind":"configure", "store":store, "key":"crashed-first", "session":"", "configuration":{"workspace":{"state":"omitted"}, "provider":{"state":"omitted"}, "model":{"state":"omitted"}}}
prefix = json.dumps(request)[:-2] + ',"instructions":{"state":"value","value":"'
with socket.socket(socket.AF_UNIX) as connection:
    connection.connect(fields["socket"])
    body = prefix.encode() + b'x' * 32768
    connection.sendall(b'POST /v1/configure HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: 1000000\r\nX-Rui-Wire-Version: 4\r\n\r\n' + body)
    path = os.path.join(store, 'scratch', 'request-0-1.tmp')
    deadline = time.monotonic() + 5
    while not os.path.exists(path):
        if time.monotonic() > deadline: raise RuntimeError('first request scratch never appeared')
        time.sleep(.01)
    os.kill(int(pid), signal.SIGKILL)
PYCRASH
wait "$host_pid" 2>/dev/null || true
host_pid=
require_test 'first streamed request scratch survives Host crash' -f "$store/scratch/request-0-1.tmp"

# Failed owned-leftover cleanup refuses startup and retains the accounting
# evidence; an ordinary restart then removes only that owned temporary.
printf unrelated >"$store/scratch/request-00-1.tmp"
printf diagnostic >"$store/scratch/diagnostic.log"
printf unrelated >"$store/scratch/unrelated.data"
if "$rui" host serve --store "$store" --fault startup-cleanup >"$state/startup.out" 2>"$state/startup.err"; then
    echo "Host admitted after failed startup cleanup" >&2
    exit 1
fi
require_test 'failed startup cleanup retains owned request scratch' -f "$store/scratch/request-0-1.tmp"
start_host
require_test 'restart removes owned request scratch' ! -e "$store/scratch/request-0-1.tmp"
require_test 'restart preserves noncanonical request lookalike' -f "$store/scratch/request-00-1.tmp"
require_test 'restart preserves diagnostic file' -f "$store/scratch/diagnostic.log"
require_test 'restart preserves unrelated file' -f "$store/scratch/unrelated.data"
require_test 'restart preserves canonical Store' -f "$store/rui.sqlite3"
recovered=$($rui session configure --store "$store" --record "$records/first-recovered.json" --key first-recovered --workspace "$root" --provider codex --model gpt-6-sol --instructions - <"$state/fault-content.txt")
contains "$recovered" '"status":"accepted"'
recovered_session=$(printf '%s' "$recovered" | session_id)

# A canonical owned name with the wrong filesystem type is neither deleted nor
# ignored. Startup refuses while holding the lease, then a later clean startup
# can acquire it after the operator-visible obstruction is removed.
stop_host
mkdir "$store/scratch/request-1-1.tmp"
if "$rui" host serve --store "$store" >"$state/startup-type.out" 2>"$state/startup-type.err"; then
    echo "Host admitted an owned temporary name with the wrong type" >&2
    exit 1
fi
contains "$(cat "$state/startup-type.err")" "UnexpectedIngressLeftover"
require_test 'wrong-type startup refusal retains owned directory' -d "$store/scratch/request-1-1.tmp"
rmdir "$store/scratch/request-1-1.tmp"
start_host
require_test 'restart after wrong-type repair preserves request lookalike' -f "$store/scratch/request-00-1.tmp"
require_test 'restart after wrong-type repair preserves diagnostic file' -f "$store/scratch/diagnostic.log"
require_test 'restart after wrong-type repair preserves unrelated file' -f "$store/scratch/unrelated.data"
require_test 'restart after wrong-type repair preserves canonical Store' -f "$store/rui.sqlite3"

# Core keys retain their decoded UTF-8 byte bound; Session IDs are allocated.
key128=$(python3 -c 'print("k" * 128)')
bounded=$($rui session configure --store "$store" --record "$records/bounded.json" --key "$key128" --workspace "$root" --provider codex --model gpt-6-sol)
contains "$bounded" '"status":"accepted"'
bounded_session=$(printf '%s' "$bounded" | session_id)
key129=$(python3 -c 'print("k" * 129)')
if "$rui" session configure --store "$store" --record "$records/too-long.json" --key "$key129" --workspace "$root" --provider codex --model gpt-6-sol >"$state/bounds.out" 2>"$state/bounds.err"; then
    echo "129-byte key was admitted" >&2
    exit 1
fi
require_test 'oversized Configure key creates no request record' ! -e "$records/too-long.json"

# Caller-named creation is rejected before publishing a capture, not aliased.
session128=$(python3 -c 'print("s" * 128)')
for invalid_session in "$session128" direct/obsolete ABCDEF abcde abcdefg abcdei; do
    if "$rui" session configure --store "$store" --record "$records/invalid-session.json" --key invalid-session --session "$invalid_session" --workspace "$root" --provider codex --model gpt-6-sol >"$state/bounds.out" 2>"$state/bounds.err"; then
        echo "noncanonical Session was admitted: $invalid_session" >&2
        exit 1
    fi
    contains "$(cat "$state/bounds.err")" 'InvalidSession'
    require_test 'invalid Session creates no request record' ! -e "$records/invalid-session.json"
done

# Message keys use the same exact decoded-byte limits while preserving
# Unicode and transport escaping without normalization.
message_key128=$(python3 -c 'print("é" * 64, end="")')
printf 'bounded message with controls\t"quote"\\slash\n' >"$state/bounded-message.txt"
bounded_message=$($rui session send --store "$store" --to "$bounded_session" --record "$records/bounded-message.json" --key "$message_key128" <"$state/bounded-message.txt")
contains "$bounded_message" '"status":"accepted"'
message_key129=$(python3 -c 'print("é" * 64 + "x", end="")')
if "$rui" session send --store "$store" --to "$bounded_session" --record "$records/message-too-long.json" --key "$message_key129" <"$state/message.txt" >"$state/bounds.out" 2>"$state/bounds.err"; then
    echo "129-byte message key was admitted" >&2
    exit 1
fi
require_test 'oversized Message key creates no request record' ! -e "$records/message-too-long.json"

escaped_key=$(python3 -c 'print("".join(map(chr, (34, 92, 10, 9))) * 32, end="")')
escaped_message=$($rui session send --store "$store" --to "$bounded_session" --record "$records/escaped-message.json" --key "$escaped_key" <"$state/message.txt")
contains "$escaped_message" '"status":"accepted"'
escaped_observation=$($rui request inspect --store "$store" --key "$escaped_key")
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
nfc_message=$($rui session send --store "$store" --to "$bounded_session" --record "$records/nfc-message.json" --key "$nfc_key" <"$state/message.txt")
nfd_message=$($rui session send --store "$store" --to "$bounded_session" --record "$records/nfd-message.json" --key "$nfd_key" <"$state/message.txt")
contains "$nfc_message" '"status":"accepted"'
contains "$nfd_message" '"status":"accepted"'

# A detected canonical read failure fences later admission in the same Host.
# This fixture corrupts storage only while the production owner is stopped.
stop_host
python3 - "$store/rui.sqlite3" "$main_session" <<'PY'
import sqlite3, sys
database = sqlite3.connect(sys.argv[1])
database.execute(
    "UPDATE session SET instructions_content_id=9223372036854775807 "
    "WHERE session_ref=?", (sys.argv[2],)
)
database.commit()
database.close()
PY
start_host
if "$rui" session inspect --store "$store" --session "$main_session" >"$state/corrupt-read.out" 2>"$state/corrupt-read.err"; then
    echo "canonical corruption produced a successful observation" >&2
    exit 1
fi
contains "$(cat "$state/corrupt-read.out")" '"code":"canonical_store_failure"'
wait_host_failure

# Persisted identity/journal settings remain readable after the owner closes.
# The production client never opens this database; this is a fixture. The
# connection-local settings are asserted through the production Store tests.
PYTHONPATH="$root/tests/integration" python3 - "$store/rui.sqlite3" <<'PY'
import sqlite3, sys
from host_process import STORE_SCHEMA as schema
db = sqlite3.connect(sys.argv[1])
expected = {
    "journal_mode": "wal",
    "mmap_size": 0,
    "application_id": 0x4C544631,
    "user_version": schema,
}
for name, value in expected.items():
    actual = db.execute("PRAGMA " + name).fetchone()[0]
    if actual != value:
        raise SystemExit(f"{name}: expected {value!r}, got {actual!r}")
db.close()
PY

# Clients do not auto-start the Host or infer absence as a saved answer.
if "$rui" request inspect --store "$store" --key first-key >"$state/no-host.out" 2>"$state/no-host.err"; then
    echo "client auto-started an absent Host" >&2
    exit 1
fi

# Access is checked before ownership, and an incompatible Store is rejected
# before its stale socket is reclaimed.
insecure_store="$state/insecure-store"
mkdir -m 755 "$insecure_store"
if "$rui" host serve --store "$insecure_store" >"$state/insecure.out" 2>"$state/insecure.err"; then
    echo "Host accepted an insecure Store directory" >&2
    exit 1
fi
contains "$(cat "$state/insecure.err")" "InsecureDirectoryPermissions"

wire_store="$state/wire-store"
wire_ready="$state/wire-ready"
wire_error="$state/wire-error"
"$rui" host serve --store "$wire_store" >"$wire_ready" 2>"$wire_error" &
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
require_test 'wire-version Host crash leaves its Unix socket' -S "$wire_socket"
python3 - "$wire_store/rui.sqlite3" <<'PY'
import sqlite3, sys
database = sqlite3.connect(sys.argv[1])
database.execute("UPDATE store_meta SET value='future' WHERE key='wire_version'")
database.commit()
database.close()
PY
if "$rui" host serve --store "$wire_store" >"$state/wrong-wire.out" 2>"$state/wrong-wire.err"; then
    echo "Host accepted an incompatible wire version" >&2
    exit 1
fi
contains "$(cat "$state/wrong-wire.err")" "WrongStoreVersion"
require_test 'wrong wire version refuses before reclaiming stale socket' -S "$wire_socket"

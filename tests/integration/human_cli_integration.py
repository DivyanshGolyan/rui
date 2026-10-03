#!/usr/bin/env python3
"""Public one-shot caller recovery and exact Bash authorization."""
import base64
import errno
import json
import fcntl
import os
import pathlib
import re
import pty
import select
import shlex
import shutil
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

import dispatch_integration as fixture
import codex_integration as codex_fixture
from conversation_page_integration import host_resources, request as public_request


def open_terminal():
    """PTYs start with unusable zero geometry unless the fixture supplies it."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    return master, slave


def run(home, *args, success=True, environment=None):
    env = {**os.environ, "HOME": str(home), **(environment or {})}
    result = subprocess.run([str(fixture.RUI), *map(str, args)], env=env, capture_output=True, text=True, timeout=20)
    if success:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    else:
        assert result.returncode != 0, (args, result.stdout, result.stderr)
    return result.stdout


def admit(home, *args):
    captured, admission = map(json.loads, run(home, *args, "--json").splitlines())
    assert captured == {"event": "captured", "request": admission["request"]}, (captured, admission)
    assert admission["event"] == "admission", admission
    return admission


def read_terminal(master, marker, timeout=15, initial=""):
    output = initial.encode()
    deadline = time.monotonic() + timeout
    markers = marker if isinstance(marker, tuple) else (marker,)
    # Typed command repaints contain '> ' too. Wait for the empty
    # composing region, not an echo of input which has not been dispatched.
    markers = tuple("\r> \r\x1b[2C" if item == "> " else item for item in markers)
    while not any(item.encode() in output for item in markers):
        remaining = deadline - time.monotonic()
        assert remaining > 0, (marker, output.decode(errors="replace"))
        assert select.select([master], [], [], remaining)[0], (marker, output.decode(errors="replace"))
        output += os.read(master, 65536)
        assert len(output) < 1024 * 1024, "unexpected unbounded terminal output"
    return (output.decode(errors="replace").replace("\r\r\n", "\n").replace("\r\n", "\n")
        .replace("\x1b[?2004h", "").replace("\x1b[?2004l", ""))


def read_terminal_end(master, child, timeout=15):
    """Drain partial output until EOF, retaining a finite failure deadline."""
    output = bytearray()
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([master], [], [], remaining)[0], output.decode(errors="replace")
        try:
            chunk = os.read(master, 65536)
        except OSError as err:
            if err.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        output.extend(chunk)
        assert len(output) < 4 * 1024 * 1024, "unbounded terminal output"
    child.wait(timeout=5)
    return output.decode(errors="replace").replace("\r\r\n", "\n").replace("\r\n", "\n")


def detach_terminal(master, child, sequence=b"/exit\n"):
    """Detach by outcome and restored input mode, not an optional notice."""
    os.write(master, sequence)
    output = read_terminal_end(master, child)
    assert child.returncode == 0, (child.returncode, output)
    restored = termios.ICANON | termios.ECHO | termios.ISIG
    assert termios.tcgetattr(master)[3] & restored == restored, "terminal mode not restored"
    return output


def terminal_step(master, command, marker="> ", before_prompt=None):
    os.write(master, (command + "\n").encode())
    if before_prompt is None and marker == "> ":
        # These commands have observable response text. An input repaint is
        # not their completion; do not synchronize the fixture on that hint.
        before_prompt = {
            '/setup': ('Defaults (read only):', 'Saved defaults for future Sessions.', 'Usage: /setup', 'rui: setup', 'rui: /setup:'),
            '/status': ('Session:', 'rui: status:'),
            '/resume': ('Session:', 'active Session unchanged'),
            '/history': ('You:', '────────', 'End of saved public history', 'No older page', 'history unavailable'),
            '/configure': ('Configured.', 'Usage: /configure', 'Use a file for', 'admitted:', 'rui: configure:'),
            '/result': ('────────', 'Rui: This', 'rui: result'),
            '/requests': ('Local recovery handles', 'rui: requests:'),
            '/help': 'Rui: /help',
            '/approve': ('Widen the terminal', 'No Action requires attention'),
        }.get(command.split(' ', 1)[0])
    if before_prompt is not None:
        # A queued command can repaint the independent next composition
        # during a read. Require its actual response before the final footer.
        response = read_terminal(master, before_prompt)
        candidates = before_prompt if isinstance(before_prompt, tuple) else (before_prompt,)
        seen = min((item for item in candidates if item in response), key=response.index)
        head, separator, tail = response.partition(seen)
        return head + separator + read_terminal(master, marker, initial=tail)
    return read_terminal(master, marker)


def reject_entry(home, workspace, args, expected):
    master, slave = open_terminal()
    child = subprocess.Popen([str(fixture.RUI), *map(str, args)], cwd=workspace,
        env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    output = b""
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not select.select([master], [], [], max(0, deadline - time.monotonic()))[0]:
                break
            try:
                chunk = os.read(master, 65536)
            except OSError as err:
                if err.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output += chunk
            assert b"Provider: [c]" not in output, "repair offered before selected resource checks"
        assert expected.encode() in output, output.decode(errors="replace")
        assert child.wait(timeout=5) != 0
        assert b"request: " not in output and b"Session: rui/" not in output
        assert not (home / ".config/rui/codex.json").exists(), "entry repaired credentials"
        assert not (home / ".config/rui/.codex.json.lock").exists(), "entry created a credential lock"
        assert not (home / ".config/rui/requests").exists(), "entry captured a Session"
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
        os.close(master)


def resume_credential_readiness(state, workspace):
    store = state / "credential-resume-store"
    host = fixture.start_host(store, None)
    try:
        session = "credential/idle"
        fixture.configure(state, store, "credential-resume", session, "model-a")
        before = fixture.command("inspect-session", "--store", store, "--session", session)
        for kind, warning in (("configured", False), ("renewal_due", False),
                ("missing", True), ("refresh_pending", True), ("malformed", True)):
            home = state / f"resume-{kind}"
            config = home / ".config/rui"
            config.mkdir(parents=True, mode=0o700)
            credential = config / "codex.json"
            if kind in ("configured", "renewal_due"):
                expiry = int(time.time()) + (3600 if kind == "configured" else -60)
                payload = base64.urlsafe_b64encode(json.dumps({"exp": expiry}).encode()).rstrip(b"=").decode()
                codex_fixture.credentials(credential, access=f"e30.{payload}.c2ln")
                credential.write_text(credential.read_text().replace("expires_at=4102444800", f"expires_at={expiry}"))
            elif kind == "refresh_pending":
                codex_fixture.credentials(credential, state=kind)
            elif kind == "malformed":
                credential.write_text("version=9\n")
                credential.chmod(0o600)
            installed = credential.read_bytes() if credential.exists() else None
            master, slave = open_terminal()
            child = subprocess.Popen([str(fixture.RUI), "--resume", session, "--store", str(store)],
                cwd=workspace, env={**os.environ, "HOME": str(home)},
                stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            try:
                output = read_terminal(master, "> ")
                assert ("credential is unavailable or needs repair" in output) == warning, (kind, output)
                assert "Provider: codex" in output and "Model: model-a" in output, output
                detach_terminal(master, child)
                assert (credential.read_bytes() if credential.exists() else None) == installed, kind
                assert not (config / "requests").exists(), "resume captured new intent"
                assert fixture.command("inspect-session", "--store", store, "--session", session) == before
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)
                os.close(master)
    finally:
        fixture.stop_host(host)


def action_ready(descriptor):
    assert select.select([descriptor], [], [], 15)[0], "Action input flush did not finish"
    assert os.read(descriptor, 1) == b"x", "Action caller exited before readiness"


def terminal_bulk(master, command, marker="> "):
    fixture.wait_for(lambda: not termios.tcgetattr(master)[3] & termios.ICANON,
        "noncanonical terminal input")
    def send():
        payload = (command + "\n").encode()
        for offset in range(0, len(payload), 1024):
            os.write(master, payload[offset:offset + 1024])

    writer = threading.Thread(target=send, daemon=True)
    writer.start()
    output = read_terminal(master, marker)
    writer.join(timeout=5)
    assert not writer.is_alive(), "bulk terminal writer stalled"
    return output


def saved_capture_cases(state, store, workspace):
    home = state / "capture-home"
    home.mkdir()
    records = home / ".config/rui/requests"
    args = ["configure", "--store", store, "--session", "capture/original",
        "--workspace", workspace, "--provider", "codex", "--model", "model-a"]
    gate = state / "capture-original-reader"
    caller = subprocess.Popen([str(fixture.RUI), *map(str, args), "--json"],
        env={**os.environ, "HOME": str(home), "RUI_TEST_CAPTURE_GATE": str(gate)},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    original = None
    record = None
    try:
        fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "capture reader publication")
        handles = json.loads(run(home, "requests", "--json"))
        assert len(handles) == 1, handles
        handle = handles[0]
        record = records / f"{handle}.json"
        original = record.read_bytes()
        assert fixture.command("observe-command", "--store", store,
            "--key", handle)["observation"]["status"] == "absent"
        # A pathname replacement after publication must not swap the bytes
        # selected by the captured owner before its announcement.
        replaced = json.loads(original)
        replaced["session"] = "capture/replacement"
        replacement = records / "replacement"
        replacement.write_text(json.dumps(replaced, separators=(",", ":")))
        replacement.replace(record)
        pathlib.Path(f"{gate}.release").touch()
        output, errors = caller.communicate(timeout=20)
        assert caller.returncode == 0, (output, errors)
        captured, admission = map(json.loads, output.splitlines())
        assert captured["request"] == handle and admission["admission"]["answer"]["status"] == "accepted"
        observed = fixture.command("observe-command", "--store", store, "--key", handle)["observation"]
        assert observed["target"] == "capture/original", ("captured owner transmitted a replaced pathname", observed)
    finally:
        if caller.poll() is None:
            caller.kill()
            caller.communicate(timeout=5)
        if original is not None:
            record.write_bytes(original)

    # Recovery must ignore a newly selected, nonexistent preference Store.
    run(home, "setup", "--store", store)
    preferences = home / ".config/rui/preferences"
    preferences.write_text(f"version=1\nstore={state / 'missing-capture-store'}\n")
    assert json.loads(run(home, "recover", handle, "--json"))["answer"]["replayed"] is True

    # Failure to announce happens after publication but before any send.
    before = set(run(home, "requests").splitlines())
    output = run(home, *args, success=False,
        environment={"RUI_TEST_CAPTURE_GATE": str(state / "missing-parent/gate")})
    assert output == "", output
    failed_notice, = set(run(home, "requests").splitlines()) - before
    assert fixture.command("observe-command", "--store", store,
        "--key", failed_notice)["observation"]["status"] == "absent"
    assert json.loads(run(home, "recover", failed_notice, "--json"))["answer"]["replayed"] is False

    # Linux libc fault injection reaches the actual post-rename directory sync,
    # not a fixture-only success path. No automatic send may follow uncertainty.
    if sys.platform == "linux":
        source, library = state / "capture-sync.c", state / "capture-sync.so"
        source.write_text(r"""
#include <dlfcn.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>
int fsync(int fd) {
    struct stat value;
    if (!fstat(fd, &value) && S_ISDIR(value.st_mode)) { errno = EIO; return -1; }
    int (*real_sync)(int) = dlsym(RTLD_NEXT, "fsync");
    return real_sync(fd);
}
""")
        subprocess.run(["cc", "-shared", "-fPIC", str(source), "-ldl", "-o", str(library)], check=True)
        before = set(run(home, "requests").splitlines())
        failed = subprocess.run([str(fixture.RUI), *map(str, args)],
            env={**os.environ, "HOME": str(home), "LD_PRELOAD": str(library)},
            capture_output=True, text=True, timeout=20)
        assert failed.returncode != 0 and "RecordDirectorySyncFailed" in failed.stderr, failed
        assert failed.stdout == "", failed.stdout
        uncertain, = set(run(home, "requests").splitlines()) - before
        assert fixture.command("observe-command", "--store", store,
            "--key", uncertain)["observation"]["status"] == "absent"
        assert json.loads(run(home, "recover", uncertain, "--json"))["answer"]["replayed"] is False
    else:
        print("capture directory-sync injection: unavailable outside Linux", flush=True)

    invalid = "01234567-89ab-4cde-8012-3456789abcde"
    unsupported = "01234567-89ab-4cde-8012-3456789abcdf"
    (records / f"{invalid}.json").write_text("not a readable record")
    stop = {"version": "1", "kind": "session_stop", "store": str(store.resolve()),
        "key": unsupported, "session": "capture/original"}
    (records / f"{unsupported}.json").write_text(json.dumps(stop, separators=(",", ":")))
    (records / "not-a-handle.json").write_text("not a record")
    listed = json.loads(run(home, "requests", "--json"))
    assert invalid in listed and unsupported in listed and "not-a-handle" not in listed, listed
    assert run(home, "recover", invalid, success=False) == ""
    assert run(home, "recover", unsupported, success=False) == ""
    master, slave = open_terminal()
    entered = subprocess.Popen([str(fixture.RUI), "--resume", "capture/original", "--store", str(store)], env={**os.environ, "HOME": str(home)},
        stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    try:
        read_terminal(master, "> ")
        listing = terminal_step(master, "/requests")
        assert handle in listing and failed_notice in listing, listing
        assert invalid not in listing and unsupported not in listing, listing
        detach_terminal(master, entered)
    finally:
        if entered.poll() is None:
            entered.kill()
            entered.wait(timeout=5)
        os.close(master)
    print("saved capture owner: pinned original bytes, preference-independent recovery, failed announcement, "
        "sync uncertainty, listing asymmetry", flush=True)


class ObservationProxy(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    """Faults real client exchanges; primary reads still reach the real Host."""
    daemon_threads = True

    def __init__(self, path):
        self.path = pathlib.Path(path)
        self.backend = self.path.with_name("call-content-backend.sock")
        self.path.rename(self.backend)
        self.fault = None
        self.hit = 0
        self.exchanges = []
        self.starts = []
        self.fault_starts = []
        self.fault_after_start = 0
        self.order = threading.Lock()
        self.before_exchange = None
        self.page_end_delta = None
        self.page_wrong_continuation = False
        self.decisions = 0
        super().__init__(str(self.path), ObservationExchange)
        os.chmod(self.path, 0o600)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=3)
        self.path.unlink()
        self.backend.rename(self.path)


class ObservationExchange(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(15)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.request.recv(4096)
            assert chunk, "client closed before request headers"
            data += chunk
            assert len(data) <= 16384, "request headers exceed fixture bound"
        head, body = data.split(b"\r\n\r\n", 1)
        length = int(next(line.split(b":", 1)[1] for line in head.split(b"\r\n") if line.lower().startswith(b"content-length:")))
        while len(body) < length:
            chunk = self.request.recv(length - len(body))
            assert chunk, "client closed before request body"
            body += chunk
        command = json.loads(body)
        proxy = self.server
        with proxy.order:
            start_index = len(proxy.starts)
            proxy.starts.append(command)
        before_exchange = proxy.before_exchange
        if before_exchange is not None and before_exchange(command, start_index) is False:
            return  # Explicitly gated transport loss, before backend delivery.
        if command["kind"] == "permission_decision":
            proxy.decisions += 1
        with proxy.order:
            fault = proxy.fault
            eligible = fault is not None and start_index >= proxy.fault_after_start
        # Predicates may independently observe the Host through this proxy.
        matched = eligible and fault(command)
        with proxy.order:
            hit = matched and proxy.fault is fault
            if hit:
                proxy.fault = None
                proxy.hit += 1
                proxy.fault_starts.append(start_index)
        with socket.socket(socket.AF_UNIX) as backend:
            backend.settimeout(15)
            backend.connect(str(proxy.backend))
            backend.sendall(head + b"\r\n\r\n" + body)
            # Headers and transfer windows have explicit bounds independent of
            # content length. Never retain a complete result in the relay.
            response_head = bytearray()
            while not response_head.endswith(b"\r\n\r\n"):
                byte = backend.recv(1)
                assert byte, "backend closed before response headers"
                response_head.extend(byte)
                assert len(response_head) <= 16384, "response headers exceed fixture bound"
            response_head = bytes(response_head[:-4])
            size = int(next(line.split(b":", 1)[1] for line in response_head.split(b"\r\n")
                if line.lower().startswith(b"content-length:")))
            altered_page = hit and (proxy.page_end_delta is not None or proxy.page_wrong_continuation)
            truncated = hit and command["kind"] in ("read_result", "conversation_content")
            if altered_page:
                # Sixteen metadata-only conversation items fit in 4 KiB;
                # content bodies never enter this exceptional JSON buffer.
                assert size <= 4096, "page exceeds bounded metadata reply"
            payload = bytearray()
            count = 0
            prefix = min(5000, max(0, size - 1)) if truncated else 0
            if not hit or truncated:
                self.request.sendall(response_head + b"\r\n\r\n")
            disconnected = False
            while chunk := backend.recv(4096):
                try:
                    if not disconnected and not hit:
                        self.request.sendall(chunk)
                    elif not disconnected and truncated and count < prefix:
                        self.request.sendall(chunk[:prefix - count])
                except (BrokenPipeError, ConnectionResetError):
                    # Physical PTY closure intentionally disconnects the CLI;
                    # drain/count the backend without retaining its suffix.
                    disconnected = True
                if altered_page:
                    assert len(payload) + len(chunk) <= 4096
                    payload.extend(chunk)
                count += len(chunk)
            assert count == size, (count, size)
        proxy.exchanges.append((command, count))
        if hit:
            if command["kind"] in ("read_result", "conversation_content"):
                pass  # The bounded partial prefix was already relayed.
            elif proxy.page_end_delta is not None or proxy.page_wrong_continuation:
                assert command["kind"] == "conversation_page" and int(command["end"]) > 0, command
                page = json.loads(payload)
                assert page["end"] == command["end"], (page, command)
                if proxy.page_wrong_continuation:
                    assert len(page["items"]) >= 2 and page["items"][0]["position"] != page["items"][-1]["position"], page
                    page["more"] = True
                    page["before_position"] = page["items"][0]["position"]
                    page["before_ordinal"] = page["items"][0]["ordinal"]
                else:
                    changed_end = int(command["end"]) + proxy.page_end_delta
                    page["end"] = str(changed_end)
                    # Keep every item valid under the altered end, so rejection
                    # proves end binding rather than incidental item validation.
                    page["items"] = [item for item in page["items"] if int(item["position"]) <= changed_end]
                payload = json.dumps(page).encode()
                self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: " + str(len(payload)).encode() + b"\r\n\r\n" + payload)
            elif getattr(proxy, "canonical", False):
                payload = b'{"version":"1","type":"invocation_error","code":"canonical_store_failure"}'
                self.request.sendall(b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: " + str(len(payload)).encode() + b"\r\n\r\n" + payload)
            else:
                # Incomplete transport is not evidence of a fenced Store.
                self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: 80\r\n\r\n{")


def observation_relay():
    """The actual proxy forwards before EOF with N-independent Python storage."""
    import tracemalloc

    for size in (64 * 1024, 8 * 1024 * 1024):
        prefix_consumed, release_eof = (threading.Event() for _ in range(2))
        failures = []
        class Backend(socketserver.BaseRequestHandler):
            def handle(self):
                try:
                    self.request.recv(4096)
                    self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(size).encode() + b"\r\n\r\n")
                    self.request.sendall(b"x" * 4096)
                    assert prefix_consumed.wait(5), "relay did not forward before backend EOF"
                    for _ in range((size - 4096) // 4096):
                        self.request.sendall(b"x" * 4096)
                    assert release_eof.wait(5), "EOF gate not released"
                except Exception as err:
                    failures.append(err)
        with tempfile.TemporaryDirectory(prefix="rui-observation-relay-") as temporary:
            path = pathlib.Path(temporary) / "relay.sock"
            backend = socketserver.UnixStreamServer(str(path), Backend)
            backend_thread = threading.Thread(target=backend.serve_forever, daemon=True)
            backend_thread.start()
            proxy = ObservationProxy(path)
            tracemalloc.start()
            try:
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(5)
                    client.connect(str(path))
                    body = b'{"kind":"read_result"}'
                    client.sendall(b"POST /v1/read-result HTTP/1.1\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
                    head = bytearray()
                    while not head.endswith(b"\r\n\r\n"):
                        head.extend(client.recv(1))
                    count = 0
                    while count < size:
                        assert select.select([client], [], [], 3)[0], "relay did not forward before backend EOF"
                        chunk = client.recv(min(4096, size - count))
                        assert chunk and chunk == b"x" * len(chunk)
                        count += len(chunk)
                        prefix_consumed.set()
                    current, peak = tracemalloc.get_traced_memory()
                    assert not proxy.exchanges, "backend EOF unexpectedly preceded the witness"
                    assert peak < 256 * 1024, ("payload retained as N grows", size, current, peak)
                    release_eof.set()
                    assert client.recv(1) == b""
                assert not failures, failures
                assert proxy.exchanges == [({"kind": "read_result"}, size)], proxy.exchanges
                print(f"Observation relay N={size}: consumed before backend EOF, traced live={current}, peak={peak}", flush=True)
            finally:
                prefix_consumed.set()
                release_eof.set()
                tracemalloc.stop()
                proxy.close()
                backend.shutdown()
                backend.server_close()
                backend_thread.join(timeout=5)


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-human-cli.")).resolve()
    home = state / "home"
    home.mkdir()
    store = state / "store"
    workspace = state / "workspace"
    workspace.mkdir()
    session = "human/bash"
    counter = workspace / "effect-count"
    arguments = json.dumps({"cmd": "printf x >> effect-count", "timeout_ms": None}, separators=(",", ":"))
    control_call = "human-call\x1b[1Ghidden\u202e"
    control_arguments = json.dumps({"cmd": "printf x >> effect-count", "timeout_ms": 10000}, separators=(",", ":")) + "\r  "
    sibling_started = state / "sibling-started"
    sibling_release = state / "sibling-release"
    sibling_effect = workspace / "sibling-effect"
    sibling_arguments = json.dumps({"cmd": f"touch {shlex.quote(str(sibling_started))}; "
        f"while [ ! -e {shlex.quote(str(sibling_release))} ]; do sleep 0.05; done; "
        "printf y >> sibling-effect", "timeout_ms": None}, separators=(",", ":"))
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("human-calls", [("bash", control_call, control_arguments)]),
        fixture.sse_answer("human-answer", "human-reason", "human-message", "first answer")[0],
        fixture.sse_answer("second-answer", "second-reason", "second-message", "second answer")[0],
        fixture.sse_tool_calls("sibling-calls", [("bash", "pending-call", arguments),
            ("bash", "running-call", sibling_arguments)]),
        fixture.sse_answer("sibling-answer", "sibling-reason", "sibling-message", "siblings done")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    host = None
    managed_host = False
    failure_release = None
    stop_release = None
    observation_release = None
    progress_release = None
    race_predecessor_release = threading.Event()
    race_message_release = threading.Event()
    resume_a_release = threading.Event()
    resume_b_release = threading.Event()
    resume_idle_release = threading.Event()
    resume_gate = state / "resume-selected-a"
    resume_idle_gate = state / "resume-selected-idle"
    race_follower = None
    race_waiter = None
    terminal_waiter = None
    race_gate = state / "follow-queued-before-current"
    wait_gate = state / "wait-active-before-current"
    completed = False
    try:
        help_result = subprocess.run([str(fixture.RUI), "--help"],
            env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=5)
        assert help_result.returncode == 0 and "rui --resume [--store PATH] [--] [REF]" in help_result.stderr, help_result
        assert "rui read-action-arguments" in help_result.stderr and "rui recover HANDLE" in help_result.stderr
        assert not store.exists(), "help started a Host"
        host = fixture.start_host(store, url)
        saved_capture_cases(state, store, workspace)
        preferences_home = state / "preferences-home"
        preferences_home.mkdir()
        fallback = preferences_home / ".local/share/rui/store"
        fresh_setup = run(preferences_home, "setup")
        assert f"Store: {fallback} (HOME fallback)" in fresh_setup
        assert "choose a supported provider" in fresh_setup and "Host: unavailable" in fresh_setup
        assert not (preferences_home / ".config").exists(), "inspection created private state"
        masked_home = state / "umask-home"
        masked_home.mkdir()
        masked_save = subprocess.run([str(fixture.RUI), "setup", "--store", str(store)],
            env={**os.environ, "HOME": str(masked_home)}, capture_output=True, text=True,
            timeout=20, umask=0o777)
        assert masked_save.returncode == 0, masked_save
        assert "(saved)" in run(masked_home, "setup"), "a second process could not reload preferences"
        for name, mode in ((".config", 0o700), (".config/rui", 0o700),
                           (".config/rui/.preferences.lock", 0o600), (".config/rui/preferences", 0o600)):
            assert (masked_home / name).stat().st_mode & 0o777 == mode, name
        existing_home = state / "existing-config-home"
        existing_home.mkdir()
        (existing_home / ".config").mkdir(mode=0o755)
        (existing_home / ".config").chmod(0o755)
        assert subprocess.run([str(fixture.RUI), "setup", "--store", str(store)],
            env={**os.environ, "HOME": str(existing_home)}, capture_output=True,
            timeout=20, umask=0o777).returncode == 0
        assert (existing_home / ".config").stat().st_mode & 0o777 == 0o755
        # Preference publication is independent of an unused HOME destination.
        max_path = os.pathconf(preferences_home, "PC_PATH_MAX")
        long_home = str(preferences_home) + "/." * ((max_path - 16 - len(str(preferences_home))) // 2)
        assert "Saved defaults" in run(long_home, "setup", "--provider", "codex")
        assert (preferences_home / ".config/rui/preferences").read_text().endswith("provider=codex\nmodel=\n")
        invalid_home = os.fsencode(state) + b"/home-\xff"
        try:
            os.mkdir(invalid_home, mode=0o700)
        except OSError as err:
            if err.errno != errno.EILSEQ:
                raise
            # macOS filesystems may reject this name before Rui sees HOME.
        invalid = subprocess.run([os.fsencode(fixture.RUI), b"setup", b"--provider", b"codex"],
            env={**os.environb, b"HOME": invalid_home}, capture_output=True, timeout=20)
        assert invalid.returncode != 0 and b"InvalidHome" in invalid.stderr, invalid
        assert not os.path.exists(invalid_home + b"/.config"), invalid
        bidi_store = state / "store-\u202ehidden"
        bidi_store.mkdir(mode=0o700)
        bidi_home = state / "bidi-home"
        bidi_home.mkdir()
        canonical_bidi_store = bidi_store.resolve()
        assert "Store: " + str(canonical_bidi_store).replace("\u202e", "\\u202e") + " (saved)" in run(
            bidi_home, "setup", "--store", bidi_store)
        assert f"store={canonical_bidi_store}\n" in (bidi_home / ".config/rui/preferences").read_text()
        assert "HomeUnavailable" in subprocess.run([str(fixture.RUI), "setup"],
            env={key: value for key, value in os.environ.items() if key != "HOME"},
            capture_output=True, text=True).stderr
        alias = state / "store-alias"
        alias.symlink_to(store, target_is_directory=True)
        assert "Saved defaults" in run(preferences_home, "setup", "--store", alias,
            "--provider", "codex", "--model", "gpt-6-luna")
        saved = preferences_home / ".config/rui/preferences"
        assert saved.read_text() == f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n"
        original_preferences = saved.read_text()
        saved.write_text(original_preferences.replace("model=gpt-6-luna", "model=family=variant"))
        assert saved.read_text().endswith("provider=codex\nmodel=family=variant\n")
        assert "Model: family=variant" in run(preferences_home, "setup")
        saved.write_text(original_preferences)
        assert saved.stat().st_mode & 0o777 == 0o600
        assert saved.parent.stat().st_mode & 0o777 == 0o700
        missing_setup = run(preferences_home, "setup")
        assert str(store.resolve()) in missing_setup
        assert "credential: missing" in missing_setup and "No fallback" in missing_setup
        assert "Host: ready without managed Codex" in missing_setup
        linked_home = state / "linked-home"
        (linked_home / ".config").mkdir(parents=True)
        (linked_home / ".config/rui").symlink_to(saved.parent, target_is_directory=True)
        assert run(linked_home, "setup", "--store", store,
            "--provider", "codex", "--model", "gpt-6-luna", success=False) == ""
        assert saved.read_text() == f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n"
        backup = saved.parent / "saved-preferences"
        saved.rename(backup)
        os.mkfifo(saved, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "setup"],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode != 0, blocked
        finally:
            saved.unlink()
            backup.rename(saved)
        retired_store = state / "retired-store"
        retired_store.mkdir(mode=0o700)
        assert "Saved defaults" in run(preferences_home, "setup", "--store", retired_store)
        retired_store.rmdir()
        assert f"Store: {retired_store} (saved)" in run(preferences_home, "setup")
        assert "Host: unavailable" in run(preferences_home, "setup")
        assert "Saved defaults" in run(preferences_home, "setup", "--model", "explicit-v2")
        assert run(preferences_home, "host", "start", success=False) == ""
        assert run(preferences_home, "serve", "--active-capacity", "1", success=False) == ""
        assert not retired_store.exists(), "selected missing saved Store was recreated"
        assert "Saved defaults" in run(preferences_home, "setup", "--store", store)
        assert f"store={store.resolve()}\n" in saved.read_text()
        credential = saved.parent / "codex.json"
        lock = saved.parent / ".codex.json.lock"
        assert not credential.exists() and not lock.exists()
        codex_fixture.credentials(credential)
        configured_setup = run(preferences_home, "setup")
        assert "credential: configured locally" in configured_setup and "remote acceptance not checked" in configured_setup
        assert not lock.exists(), "status must not create a credential lock"
        original_credential = credential.read_bytes()
        assert b"\nfedramp=0\n" in original_credential
        credential.write_bytes(original_credential.replace(b"\nfedramp=0\n", b"\nfedramp=1\n"))
        assert "credential: error" in run(preferences_home, "setup")
        assert not lock.exists(), "claim validation must remain a read-only snapshot"
        credential.write_bytes(original_credential)
        fresh_provider_home = state / "fresh-provider-home"
        (fresh_provider_home / ".config/rui").mkdir(parents=True, mode=0o700)
        codex_fixture.credentials(fresh_provider_home / ".config/rui/codex.json")
        assert "Saved defaults" in run(fresh_provider_home, "setup", "--model", "gpt-6-luna")
        assert (fresh_provider_home / ".config/rui/preferences").read_text().endswith(
            "store=\nprovider=codex\nmodel=gpt-6-luna\n")
        credential.unlink()
        os.mkfifo(credential, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "setup"],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode == 0 and "credential: error" in blocked.stdout, blocked
        finally:
            credential.unlink()
        codex_fixture.credentials(credential, state="refresh_pending")
        assert "credential: refresh required" in run(preferences_home, "setup")
        assert "state=refresh_pending" in credential.read_text(), "status must not refresh"
        credential.chmod(0o644)
        assert "credential: error" in run(preferences_home, "setup")
        credential.unlink()
        assert run(preferences_home, "setup", "--provider", "other", success=False) == ""
        assert "Saved defaults" in run(preferences_home, "setup", "--model", "other-model")
        assert saved.read_text().endswith("model=other-model\n")
        assert "Saved defaults" in run(preferences_home, "setup", "--provider", "codex")
        assert saved.read_text().endswith("model=other-model\n"), "same-provider edit erased the pin"
        assert "Saved defaults" in run(preferences_home, "setup", "--clear-model")
        assert saved.read_text().endswith("provider=codex\nmodel=\n"), "clear-model auto-pinned the recommendation"
        unchanged = saved.read_bytes()
        assert run(preferences_home, "setup", "--clear-model", "--model", "x", success=False) == ""
        assert run(preferences_home, "setup", "--model", "", success=False) == ""
        assert saved.read_bytes() == unchanged
        assert "Saved defaults" in run(preferences_home, "setup", "--model", "gpt-6-luna")
        assert run(preferences_home, "setup", "--store", state / "missing", success=False) == ""
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        # A directory in the temporary-file slot is an honest save failure;
        # no partial replacement may appear as a saved preference.
        temp = saved.parent / "preferences.tmp"
        temp.mkdir()
        blocked = subprocess.run([str(fixture.RUI), "setup", "--store", str(store)],
            env={**os.environ, "HOME": str(preferences_home)},
            capture_output=True, text=True, timeout=2)
        assert blocked.returncode != 0 and "save failed: InsecurePreferenceFile" in blocked.stderr, blocked
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        temp.rmdir()
        os.mkfifo(temp, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "setup", "--store", str(store)],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode != 0, blocked
            assert saved.read_text().endswith("model=gpt-6-luna\n")
        finally:
            temp.unlink()
        codex_fixture.credentials(credential)
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=retired\nmodel=old-model\n")
        stale = run(preferences_home, "setup")
        assert "credential: configured locally" in stale and "saved provider is unsupported; no fallback" in stale
        assert saved.read_text().endswith("provider=retired\nmodel=old-model\n")
        assert "Saved defaults" in run(preferences_home, "setup", "--store", store)
        assert saved.read_text().endswith("provider=retired\nmodel=old-model\n")
        assert "Saved defaults" in run(preferences_home, "setup", "--provider", "codex")
        assert saved.read_text().endswith("provider=codex\nmodel=\n")
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=retired\nmodel=old-model\n")
        assert "Saved defaults" in run(preferences_home, "setup", "--provider", "codex", "--model", "gpt-6-luna")
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=old-model\n")
        assert "Next Session: codex / old-model" in run(preferences_home, "setup")
        assert "Saved defaults" in run(preferences_home, "setup", "--model", "gpt-6-luna")
        saved.rename(saved.parent / "preferences.backup")
        sole = run(preferences_home, "setup")
        assert "Provider: not selected" in sole and "Next Session: codex / gpt-6-luna" in sole
        (saved.parent / "preferences.backup").rename(saved)
        credential.unlink()
        saved.write_text("version=9\n")
        assert run(preferences_home, "setup", success=False) == ""
        assert run(preferences_home, "setup", "--model", "another-model", success=False) == ""
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        saved.chmod(0o644)
        assert run(preferences_home, "setup", success=False) == ""
        saved.chmod(0o600)
        saved.rename(saved.parent / "real-preferences")
        saved.symlink_to("real-preferences")
        assert run(preferences_home, "setup", success=False) == ""
        saved.unlink()
        (saved.parent / "real-preferences").rename(saved)
        assert run(preferences_home, "setup", "--model", "bad\nmodel", success=False) == ""
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        config = admit(home, "configure", "--store", store, "--session", session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        assert config["admission"]["answer"]["status"] == "accepted", config
        # A one-shot read selects the saved Store; explicit targeting bypasses
        # even corrupt preferences, and an invalid saved destination never falls back.
        assert json.loads(run(preferences_home, "wait-session", "--session", session,
            "--json")) == {"return": "idle"}
        saved.write_text("version=9\n")
        assert run(preferences_home, "wait-session", "--session", session,
            "--json", success=False) == ""
        assert json.loads(run(preferences_home, "wait-session", "--store", store,
            "--session", session, "--json")) == {"return": "idle"}
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", session, "--store", str(store)],
            env={**os.environ, "HOME": str(preferences_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert f"Session: {session}" in read_terminal(master, "> ")
            detach_terminal(master, entered)
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        saved.unlink()
        fallback.parent.mkdir(parents=True)
        fallback.symlink_to(store, target_is_directory=True)
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", session],
            env={**os.environ, "HOME": str(preferences_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert f"Session: {session}" in read_terminal(master, "> ")
            detach_terminal(master, entered)
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        fallback.unlink()
        saved.write_text(f"version=1\nstore={state / 'missing'}\nprovider=codex\nmodel=gpt-6-luna\n")
        saved.chmod(0o600)
        assert run(preferences_home, "wait-session", "--session", session,
            "--json", success=False) == ""
        master, slave = open_terminal()
        entered = subprocess.run([str(fixture.RUI), "--resume", session],
            env={**os.environ, "HOME": str(preferences_home)}, stdin=slave,
            stdout=slave, stderr=subprocess.PIPE, timeout=5)
        os.close(slave)
        os.close(master)
        assert entered.returncode != 0 and b"FileNotFound" in entered.stderr, entered.stderr
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        assert json.loads(run(home, "wait-session", "--store", store, "--session", session,
            "--json")) == {"return": "idle"}
        before = run(preferences_home, "requests", "--json")
        invalid_store = subprocess.run([str(fixture.RUI), "message", "--store", "",
            "--session", session, "not sent"], env={**os.environ, "HOME": str(preferences_home)},
            capture_output=True, text=True, timeout=5)
        assert invalid_store.returncode != 0 and "InvalidStore" in invalid_store.stderr, invalid_store
        assert invalid_store.stdout == "" and run(preferences_home, "requests", "--json") == before
        no_tty_home = state / "no-tty-home"
        no_tty_home.mkdir()
        no_terminal = subprocess.run([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(no_tty_home)}, capture_output=True, text=True, timeout=5)
        assert no_terminal.returncode != 0 and "InteractiveTerminalRequired" in no_terminal.stderr
        assert not (no_tty_home / ".config").exists(), "non-TTY invocation created preferences or a request"
        assert not (no_tty_home / ".local/share/rui/store").exists(), "non-TTY invocation changed the Store"
        preflight_home = state / "preflight-home"
        preflight_home.mkdir()
        invalid_destination = state / "not-a-directory"
        invalid_destination.write_text("not a Store")
        reject_entry(preflight_home, workspace, ["--store", invalid_destination,
            "--provider", "codex", "--model", "explicit-pin"], "NotDir")
        assert not (preflight_home / ".config").exists(), "invalid destination changed preferences"
        overlong_component = str(state / "missing-parent") + "/" + "x" * 256
        reject_entry(preflight_home, workspace, ["--store", overlong_component,
            "--provider", "codex", "--model", "explicit-pin"], "NameTooLong")
        assert not (preflight_home / ".config").exists(), "invalid component caused repair effects"
        assert not (state / "missing-parent").exists(), "preflight created an ancestor"
        link = state / "preflight-link"
        link.symlink_to(workspace, target_is_directory=True)
        reject_entry(preflight_home, workspace, ["--store", f"{state}/missing-parent/../preflight-link/../new-store",
            "--provider", "codex", "--model", "explicit-pin"], "NotDir")
        assert not (state / "missing-parent").exists(), "rejected traversal created an ancestor"
        if sys.platform == "linux":
            escape = f"{state}/missing-parent/" + "../" * (len(state.parts)) + "sys/rui-preflight-never-created"
            reject_entry(preflight_home, workspace, ["--store", escape,
                "--provider", "codex", "--model", "explicit-pin"], "AccessDenied")
            assert not (state / "missing-parent").exists(), "read-only traversal created an ancestor"
        assert not (preflight_home / ".config").exists(), "invalid traversal caused repair effects"
        resume_credential_readiness(state, workspace)
        offline_store = state / "offline-store"
        offline_host = fixture.start_host(offline_store, None)
        try:
            reject_entry(preflight_home, workspace, ["--store", offline_store,
                "--provider", "codex", "--model", "explicit-pin"], "HostModelUnavailable")
            assert not (preflight_home / ".config").exists(), "non-model Host caused repair effects"
        finally:
            fixture.stop_host(offline_host)

        inherited_home = state / "inherited-home"
        inherited_home.mkdir()
        deleted_a = state / "deleted-a"
        deleted_a.mkdir(mode=0o700)
        run(inherited_home, "setup", "--store", deleted_a, "--provider", "codex", "--model", "deliberate-pin")
        inherited_preferences = inherited_home / ".config/rui/preferences"
        unchanged = inherited_preferences.read_bytes()
        deleted_a.rmdir()
        reject_entry(inherited_home, workspace, [], "FileNotFound")
        reject_entry(inherited_home, workspace, ["--resume", session], "FileNotFound")
        assert not deleted_a.exists(), "selected saved A was recreated"
        assert inherited_preferences.read_bytes() == unchanged
        codex_fixture.credentials(inherited_home / ".config/rui/codex.json")
        master, slave = open_terminal()
        inherited = subprocess.Popen([str(fixture.RUI), "--store", str(store)], cwd=workspace,
            env={**os.environ, "HOME": str(inherited_home)}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            welcome = read_terminal(master, "> ")
            assert "Model: deliberate-pin" in welcome, "unused missing A blocked explicit B or lost the pin"
            handle = next(line.split("request: ", 1)[1].strip() for line in welcome.splitlines()
                if line.startswith("request: "))
            current = fixture.command("inspect-session", "--store", store, "--session", f"rui/{handle}")
            assert current["session"]["model"] == "deliberate-pin", current
            assert inherited_preferences.read_bytes() == unchanged and not deleted_a.exists()
            detach_terminal(master, inherited)
        finally:
            if inherited.poll() is None:
                inherited.kill()
                inherited.wait(timeout=5)
            os.close(master)
        before_missing = set(run(preferences_home, "requests").splitlines())
        master, slave = open_terminal()
        deferred = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(preferences_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            offered = read_terminal(master, "Provider: [c]")
            assert "No locally ready provider" in offered and "Codex login" in offered, offered
            assert "No new Session created" in terminal_step(master, "d", "No new Session created")
            assert deferred.wait(timeout=5) == 0
            assert set(run(preferences_home, "requests").splitlines()) == before_missing
        finally:
            if deferred.poll() is None:
                deferred.kill()
                deferred.wait(timeout=5)
            os.close(master)
        explicit_home = state / "explicit-home"
        explicit_config = explicit_home / ".config/rui"
        explicit_config.mkdir(parents=True, mode=0o700)
        malformed = explicit_config / "preferences"
        malformed.write_text("version=9\n")
        malformed.chmod(0o600)
        reject_entry(explicit_home, workspace, ["--store", store], "UnsupportedPreferencesVersion")
        master, slave = open_terminal()
        explicit = subprocess.Popen([str(fixture.RUI), "--store", str(store),
            "--provider", "codex", "--model", "gpt-6-luna"], cwd=workspace,
            env={**os.environ, "HOME": str(explicit_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert "No locally ready provider" in read_terminal(master, "Provider: [c]")
            # Another client installs a fixture credential while this caller
            # waits for a choice. Its explicit selectors must still bypass the
            # malformed prospective defaults when it rechecks readiness.
            codex_fixture.credentials(explicit_config / "codex.json")
            os.write(master, b"d\n")
            welcome = b""
            deadline = time.monotonic() + 10
            while b"\r> \r\x1b[2C" not in welcome and time.monotonic() < deadline:
                if not select.select([master], [], [], max(0, deadline - time.monotonic()))[0]:
                    break
                try:
                    welcome += os.read(master, 65536)
                except OSError as err:
                    if err.errno != errno.EIO:
                        raise
                    break
            welcome = welcome.decode(errors="replace")
            assert "Session: rui/" in welcome and "Provider: codex" in welcome, welcome
            assert "Model: gpt-6-luna" in welcome, welcome
            assert malformed.read_text() == "version=9\n"
            detach_terminal(master, explicit)
        finally:
            if explicit.poll() is None:
                explicit.kill()
                explicit.wait(timeout=5)
            os.close(master)
        # A ready credential arriving while the prompt is open may expire
        # before choice. That is runtime renewal, not another device login.
        (explicit_config / "codex.json").unlink()
        master, slave = open_terminal()
        expiring = subprocess.Popen([str(fixture.RUI), "--store", str(store),
            "--provider", "codex", "--model", "gpt-6-luna"], cwd=workspace,
            env={**os.environ, "HOME": str(explicit_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert "No locally ready provider" in read_terminal(master, "Provider: [c]")
            expiry = int(time.time()) + 2
            credential_file = explicit_config / "codex.json"
            expiry_payload = base64.urlsafe_b64encode(json.dumps({"exp": expiry}).encode()).rstrip(b"=").decode()
            codex_fixture.credentials(credential_file, access=f"e30.{expiry_payload}.c2ln")
            credential_file.write_text(credential_file.read_text().replace("expires_at=4102444800", f"expires_at={expiry}"))
            installed = credential_file.read_bytes()
            while time.time() < expiry:
                time.sleep(0.01)
            welcome = terminal_step(master, "d")
            assert "Session: rui/" in welcome, welcome
            assert credential_file.read_bytes() == installed, "entry refreshed without dispatch"
            detach_terminal(master, expiring)
            assert malformed.read_text() == "version=9\n"
        finally:
            if expiring.poll() is None:
                expiring.kill()
                expiring.wait(timeout=5)
            os.close(master)
        longer_store = state / "another-longer-store-selector"
        other_host = fixture.start_host(longer_store, url)
        try:
            for index, (before, after) in enumerate(((store, longer_store), (longer_store, store))):
                changing_home = state / f"changing-home-{index}"
                changing_home.mkdir()
                assert "Saved defaults" in run(changing_home, "setup", "--store", before,
                    "--provider", "codex", "--model", "gpt-6-luna")
                master, slave = open_terminal()
                changing = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
                    env={**os.environ, "HOME": str(changing_home)},
                    stdin=slave, stdout=slave, stderr=slave)
                os.close(slave)
                try:
                    assert "No locally ready provider" in read_terminal(master, "Provider: [c]")
                    assert "Saved defaults" in run(changing_home, "setup", "--store", after)
                    codex_fixture.credentials(changing_home / ".config/rui/codex.json")
                    welcome = terminal_step(master, "d")
                    assert "Diagnostics:" not in welcome, welcome
                    handle = next(line.split("request: ", 1)[1].strip() for line in welcome.splitlines()
                        if line.startswith("request: "))
                    current = fixture.command("inspect-session", "--store", after,
                        "--session", f"rui/{handle}")
                    assert current["session"]["model"] == "gpt-6-luna", current
                    detach_terminal(master, changing)
                finally:
                    if changing.poll() is None:
                        changing.kill()
                        changing.wait(timeout=5)
                    os.close(master)
        finally:
            fixture.stop_host(other_host)
        changed_home = state / "post-prompt-missing-home"
        changed_home.mkdir()
        run(changed_home, "setup", "--store", store, "--provider", "codex")
        removed_after_prompt = state / "removed-after-prompt"
        removed_after_prompt.mkdir(mode=0o700)
        master, slave = open_terminal()
        changing = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(changed_home)}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            read_terminal(master, "Provider: [c]")
            run(changed_home, "setup", "--store", removed_after_prompt)
            removed_after_prompt.rmdir()
            codex_fixture.credentials(changed_home / ".config/rui/codex.json")
            rejected = terminal_step(master, "d", "FileNotFound")
            assert "request: " not in rejected and "Session: rui/" not in rejected, rejected
            assert changing.wait(timeout=5) != 0
            assert not removed_after_prompt.exists(), "post-prompt reselection recreated a saved Store"
            assert not (changed_home / ".config/rui/requests").exists()
        finally:
            if changing.poll() is None:
                changing.kill()
                changing.wait(timeout=5)
            os.close(master)
        codex_fixture.credentials(credential)
        created = []
        for _ in range(2):
            master, slave = open_terminal()
            caller = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
                env={**os.environ, "HOME": str(preferences_home)},
                stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            try:
                welcome = read_terminal(master, "> ")
                handle = next(line.split("request: ", 1)[1].strip() for line in welcome.splitlines()
                    if line.startswith("request: "))
                reference = f"rui/{handle}"
                assert f"Session: {reference}" in welcome and "Permission: bypass (Bash runs without approval)" in welcome, welcome
                assert f"Workspace (Bash cwd): {workspace.resolve()}" in welcome, welcome
                assert "Model: gpt-6-luna" in welcome and "Provider: codex" in welcome, welcome
                current = fixture.command("inspect-session", "--store", store, "--session", reference)
                assert current["session"]["permission_mode"] == "bypass", current
                assert current["session"]["workspace"] == str(workspace.resolve()), current
                assert json.loads(run(preferences_home, "recover", handle, "--json"))["answer"]["replayed"] is True
                created.append(reference)
                detach_terminal(master, caller)
            finally:
                if caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                os.close(master)
        assert created[0] != created[1], "independent new intent reused a reference"
        master, slave = open_terminal()
        lost = subprocess.Popen([str(fixture.RUI), "--test-drop-reply", "after-commit"], cwd=workspace,
            env={**os.environ, "HOME": str(preferences_home)}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            failed = read_terminal(master, "configuration not confirmed")
            assert lost.wait(timeout=5) != 0 and "\r> \r\x1b[2C" not in failed, failed
            handle = next(line.split("request: ", 1)[1].strip() for line in failed.splitlines()
                if line.startswith("request: "))
            record = preferences_home / ".config/rui/requests" / f"{handle}.json"
            original = record.read_bytes()
            run(preferences_home, "setup", "--model", "future-model")
            recovered = json.loads(run(preferences_home, "recover", handle, "--json"))
            assert recovered["answer"]["status"] == "accepted" and recovered["answer"]["replayed"], recovered
            current = fixture.command("inspect-session", "--store", store, "--session", f"rui/{handle}")
            assert current["session"]["model"] == "gpt-6-luna", "lost-reply recovery rebound the Session"
            assert record.read_bytes() == original
            assert json.loads(original)["require_model"] is True
            run(preferences_home, "setup", "--model", "gpt-6-luna")
        finally:
            if lost.poll() is None:
                lost.kill()
                lost.wait(timeout=5)
            os.close(master)
        blocked_home = state / "blocked-capture-home"
        blocked_config = blocked_home / ".config/rui"
        blocked_config.mkdir(parents=True, mode=0o700)
        (blocked_config / "preferences").write_text(
            f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        (blocked_config / "preferences").chmod(0o600)
        (blocked_config / "requests").write_text("not a directory")
        codex_fixture.credentials(blocked_config / "codex.json")
        master, slave = open_terminal()
        blocked = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(blocked_home)}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            output = read_terminal(master, "configuration not confirmed")
            assert "New Session intent" not in output and "request: " not in output, output
            assert blocked.wait(timeout=5) != 0
        finally:
            if blocked.poll() is None:
                blocked.kill()
                blocked.wait(timeout=5)
            os.close(master)
        before = set(run(preferences_home, "requests").splitlines())
        gate = state / "new-session-capture"
        master, slave = open_terminal()
        interrupted = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(preferences_home), "RUI_TEST_CAPTURE_GATE": str(gate)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "fresh configuration captured")
            early = os.read(master, 65536) if select.select([master], [], [], 0)[0] else b""
            assert b"New Session intent" not in early, "announced before the capture callback"
            after = set(run(preferences_home, "requests").splitlines())
            assert len(after - before) == 1, (before, after)
            handle = (after - before).pop()
            captured = json.loads((preferences_home / ".config/rui/requests" / f"{handle}.json").read_text())
            assert captured["require_model"] is True, captured
            interrupted.kill()
            interrupted.wait(timeout=5)
            assert "Saved defaults" in run(preferences_home, "setup", "--model", "future-model")
            recovered = json.loads(run(preferences_home, "recover", handle, "--json"))
            assert recovered["answer"]["status"] == "accepted" and not recovered["answer"]["replayed"], recovered
            recovered_again = json.loads(run(preferences_home, "recover", handle, "--json"))
            assert recovered_again["answer"]["replayed"], recovered_again
            current = fixture.command("inspect-session", "--store", store, "--session", f"rui/{handle}")
            assert current["session"]["permission_mode"] == "bypass"
            assert current["session"]["model"] == "gpt-6-luna", "recovery reselected future defaults"
            assert captured["key"] == handle and captured["session"] == f"rui/{handle}", captured
            run(preferences_home, "setup", "--model", "gpt-6-luna")
        finally:
            if interrupted.poll() is None:
                interrupted.kill()
                interrupted.wait(timeout=5)
            os.close(master)
        credential.unlink()
        initial = fixture.command("inspect-session", "--store", store, "--session", session)
        assert initial["selected_message"] is None and initial["recent_messages"] == [], initial
        master, slave = open_terminal()
        retired_entry = subprocess.run(
            [str(fixture.RUI), "session", "--store", str(store), "--session", session],
            env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave,
            stderr=subprocess.PIPE, timeout=5)
        os.close(slave)
        os.close(master)
        assert retired_entry.returncode != 0, retired_entry
        assert "InteractiveTerminalRequired" in subprocess.run(
            [str(fixture.RUI), "--resume", session, "--store", str(store)],
            env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=5).stderr
        assert config["request"] in json.loads(run(home, "requests", "--json"))
        assert json.loads(run(home, "recover", config["request"], "--json"))["answer"]["replayed"] is True
        assert run(home, "recover", config["request"]) == "admitted: accepted\nreplayed: true\n"

        text = state / "input"
        text.write_text("first input")
        dropped = run(home, "message", "--store", store, "--session", session,
            "--text", text, "--test-drop-reply", "after-commit", success=False)
        first = dropped.split("request: ", 1)[1].splitlines()[0]
        record = home / ".config/rui/requests" / f"{first}.json"
        captured = record.read_bytes()
        assert json.loads(captured)["text"]["value"] == "first input"
        text.write_text("changed after capture")
        assert first in run(home, "requests").splitlines()
        fixture.wait_for(lambda: len(endpoint.requests) == 1, "first provider request")
        recovered = json.loads(run(home, "recover", first, "--json"))
        assert recovered["answer"]["status"] == "accepted" and recovered["answer"]["replayed"] is True
        assert record.read_bytes() == captured
        assert len(endpoint.requests) == 1, endpoint.requests

        attention = run(home, "follow", first)
        assert "return: attention" in attention and "status: waiting_for_permission" in attention, attention
        action = attention.split("action: ", 1)[1].splitlines()[0]
        selected, blocked = map(json.loads, run(home, "wait-session", "--store", store,
            "--session", session, "--json").splitlines())
        assert selected == {"event": "selection", "session": session, "message": first}, selected
        assert blocked == {"return": "attention", "status": "waiting_for_permission", "action": action}, blocked
        terminal_waiter = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", session, "--terminal", "--json"],
            env={**os.environ, "HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert json.loads(terminal_waiter.stdout.readline()) == selected
        time.sleep(0.1)
        assert terminal_waiter.poll() is None, "terminal-only wait returned on permission"
        queued = admit(home, "message", "--store", store, "--session", session,
            "queued behind permission")["request"]
        assert run(home, "result", queued) == "result: queued\n"
        queued_fact = fixture.command("observe-command", "--store", store, "--key", queued)["observation"]
        assert queued_fact["queue"]["status"] == "queued" and queued_fact["progress"] == {
            "status": "waiting_for_permission", "action": action}, queued_fact
        scratch = state / "render-scratch"
        scratch.mkdir()
        render_environment = {"TMPDIR": str(scratch)}
        queued_attention = json.loads(run(home, "follow", queued, "--json", environment=render_environment))
        assert queued_attention == {"return": "attention", "status": "waiting_for_permission", "action": action}, queued_attention
        presentation = run(home, "inspect-action", "--store", store, "--session", session, "--action", action)
        assert f"Action {action}\n" in presentation, presentation
        assert 'call ID: "human-call\\x1b[1Ghidden\\u202e"' in presentation, presentation
        assert 'Bash command: "printf x >> effect-count"\nTimeout: 10000 ms' in presentation, presentation
        assert "\x1b" not in presentation and "\u202e" not in presentation and "\r" not in presentation, presentation
        fresh_home = state / "fresh-home"
        fresh_home.mkdir()
        assert not (fresh_home / ".config").exists()
        assert json.loads(run(fresh_home, "inspect-action", "--store", store, "--session", session,
            "--action", action, "--json", environment=render_environment)) == {"action": action, "call_id": control_call, "arguments": control_arguments}
        assert not (fresh_home / ".config").exists()
        assert list(scratch.iterdir()) == []
        unavailable = subprocess.run([str(fixture.RUI), "inspect-action", "--store", str(store),
            "--session", session, "--action", action, "--json"],
            env={**os.environ, "HOME": str(fresh_home), "TMPDIR": str(state / "missing-scratch")},
            capture_output=True, text=True, timeout=20)
        assert unavailable.returncode != 0 and unavailable.stdout == "", unavailable
        exact = json.loads(run(home, "inspect-action", "--store", store, "--session", session,
            "--action", action, "--json"))
        assert exact == {"action": action, "call_id": control_call, "arguments": control_arguments}, exact
        assert run(home, "result", first) == "result: processing\n"
        assert not counter.exists()

        lost_decision = run(home, "allow-action", "--store", store, "--session", session,
            "--action", action, "--test-drop-reply", "after-commit", success=False)
        decision_key = lost_decision.split("request: ", 1)[1].splitlines()[0]
        assert decision_key in run(home, "requests").splitlines()
        recovered_decision = json.loads(run(home, "recover", decision_key, "--json"))["answer"]
        assert recovered_decision["status"] == "accepted" and recovered_decision["replayed"] is True
        fixture.wait_for(lambda: fixture.completed_observation(store, first), "first saved answer")
        fixture.wait_for(lambda: fixture.completed_observation(store, queued), "queued answer after permission")
        terminal_output, terminal_error = terminal_waiter.communicate(timeout=10)
        assert terminal_waiter.returncode == 0 and json.loads(terminal_output)["observation"]["result"]["status"] == "completed", terminal_error
        terminal_waiter = None
        stale = admit(home, "deny-action", "--store", store, "--session", session,
            "--action", action)
        assert stale["admission"]["answer"]["status"] == "rejected", stale
        assert run(home, "result", queued) == "result: completed\nfirst answer\n"
        current = fixture.command("inspect-session", "--store", store, "--session", session)
        assert current["selected_message"] is None and [r["message"] for r in current["recent_messages"]] == [queued, first], current
        assert [r["outcome"] for r in current["recent_messages"]] == ["completed", "completed"], current
        assert json.loads(run(home, "wait-session", "--store", store, "--session", session,
            "--json")) == {"return": "idle"}
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", session],
            env={**os.environ, "HOME": str(preferences_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            greeting = read_terminal(master, "> ")
            assert f"Session: {session}" in greeting and f"Workspace (Bash cwd): {workspace.resolve()}" in greeting, greeting
            assert "Provider: codex" in greeting and "Model: model-a" in greeting, greeting
            assert "Permission: ask" in greeting and "Store:" not in greeting and "Work: completed" not in greeting and queued not in greeting, greeting
            help_text = terminal_step(master, "/help")
            for command in ("/help", "/status", "/wait", "/requests", "/result KEY", "/setup", "/login", "/configure", "/exit"):
                assert command in help_text, help_text
            for explanation in ("/help shows", "/status inspects", "/wait follows", "/requests lists",
                "/result KEY reads", "/configure changes", "/exit detaches"):
                assert explanation in help_text, help_text
            assert "────────\nfirst answer" in terminal_step(master, f"/result {queued}")
            assert "Local recovery handles" in terminal_step(master, "/requests")
            assert not (fresh_home / ".config/rui/requests").exists(), "re-entry should not require saved records"
            assert "No work to wait for." in terminal_step(master, "/wait", before_prompt="No work to wait for.")
            assert "gpt-6-luna" in terminal_step(master, "/setup")
            login_prompt = terminal_step(master, "/login", "Provider: [c]")
            assert "Supported integration: Codex" in login_prompt and "defer leaves this Session" in login_prompt
            assert "Login deferred" in terminal_step(master, "d")
            assert not credential.exists(), "deferred login created credentials"
            invalid_prompt = terminal_step(master, "/login", "Provider: [c]")
            assert "Codex" in invalid_prompt
            assert "No login or preference change" in terminal_step(master, "x")
            terminal_step(master, "/login", "Provider: [c]")
            assert "No login or preference change" in terminal_step(master, "12345678901234567")
            terminal_step(master, "/login", "Provider: [c]")
            os.write(master, b"\xff\n")
            assert "No login or preference change" in read_terminal(master, "> ")
            assert re.search(r"Permission: +ask(?:\n|$)", terminal_step(master, "/status"))
            assert not credential.exists()
            assert "Saved defaults for future Sessions" in terminal_step(master, "/setup --model gpt-6-luna")
            assert "Saved defaults for future Sessions" in terminal_step(master, "/setup --model other-model")
            assert saved.read_text().endswith("model=other-model\n")
            assert "provider recommendation (not pinned)" in terminal_step(master, "/setup --clear-model")
            assert saved.read_text().endswith("provider=codex\nmodel=\n")
            unchanged = saved.read_bytes()
            terminal_step(master, "/setup --clear-model --model ignored")
            assert saved.read_bytes() == unchanged, "conflicting model edits mutated preferences"
            spaced_store = state / "spaced store"
            spaced_store.mkdir(mode=0o700)
            assert "Saved defaults for future Sessions" in terminal_step(master, f'/setup --store "{spaced_store}"')
            assert str(spaced_store.resolve()) in run(preferences_home, "setup")
            quoted_store = state / 'quoted "store"'
            quoted_store.mkdir(mode=0o700)
            escaped_store = str(quoted_store).replace('"', r'\"')
            assert "Saved defaults for future Sessions" in terminal_step(
                master, f'/setup --store "{escaped_store}"')
            assert str(quoted_store.resolve()).replace('"', r'\"') in run(preferences_home, "setup")
            assert "Usage: /setup" in terminal_step(master, '/setup --store "unfinished')
            assert str(quoted_store.resolve()).replace('"', r'\"') in run(preferences_home, "setup")
            assert "Saved defaults for future Sessions" in terminal_step(master, f'/setup --store "{store}"')
            assert re.search(r"Permission: +ask(?:\n|$)", terminal_step(master, "/status"))
            assert fixture.command("inspect-session", "--store", store,
                "--session", session)["session"]["model"] == "model-a"
            assert "Usage: /configure" in terminal_step(master, "/configure --session human/other")
            assert "Use a file for" in terminal_step(master, "/configure --instructions -")
            assert "Use a file for" in terminal_step(master, "/configure --output-schema -")
            assert re.search(r"Session: +" + re.escape(session) + r"(?:\n|$)", terminal_step(master, "/status"))
            configured = terminal_step(master, '/configure --model "model-a"')
            assert "Configured." in configured and "request:" not in configured, configured
            assert re.search(r"Session: +" + re.escape(session) + r"(?:\n|$)", terminal_step(master, "/status"))
            detach_terminal(master, entered)
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        assert run(home, "follow", queued) == "return: outcome\nstatus: completed\n"
        assert run(home, "recover", stale["request"]) == "admitted: rejected\nreplayed: true\ncode: action_not_pending\n"
        stale_default = run(home, "deny-action", "--store", store, "--session", session,
            "--action", action)
        assert stale_default.splitlines()[1:] == ["admitted: rejected", "replayed: false", "code: action_not_pending"], stale_default
        assert run(home, "result", first) == "result: completed\nfirst answer\n"
        completed_result = json.loads(run(home, "result", first, "--json", environment=render_environment))
        assert completed_result["answer"] == "first answer"
        assert completed_result["observation"]["result"]["status"] == "completed"
        assert list(scratch.iterdir()) == []
        completed_follow = json.loads(run(home, "follow", first, "--json"))
        assert completed_follow["return"] == "outcome"
        assert completed_follow["observation"]["result"]["status"] == "completed"
        assert counter.read_text() == "x"

        before = set(run(home, "requests").splitlines())
        gate = state / "captured-before-handle"
        caller = subprocess.Popen(
            [str(fixture.RUI), "message", "--store", str(store), "--session", session,
             "--text", str(text), "--json"],
            env={**os.environ, "HOME": str(home), "RUI_TEST_CAPTURE_GATE": str(gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "durable capture before handle output")
        after = set(run(home, "requests").splitlines())
        assert len(after - before) == 1, (before, after)
        second = (after - before).pop()
        assert caller.poll() is None
        assert fixture.command("observe-command", "--store", store,
            "--key", second)["observation"]["status"] == "absent"
        caller.kill()
        output, _ = caller.communicate(timeout=5)
        assert caller.returncode == -signal.SIGKILL and output == b"", output
        assert second != first
        text.unlink()
        initial_recovery = json.loads(run(home, "recover", second, "--json"))["answer"]
        assert initial_recovery["status"] == "accepted" and initial_recovery["replayed"] is False
        fixture.wait_for(lambda: fixture.completed_observation(store, second), "second saved answer")
        assert run(home, "result", first) == "result: completed\nfirst answer\n"
        assert run(home, "result", second) == "result: completed\nsecond answer\n"
        assert counter.read_text() == "x" and len(endpoint.requests) == 3

        fixture.stop_host(host)
        host = fixture.start_host(store, url, active_capacity=2)
        sibling_session = "human/siblings"
        sibling_config = run(home, "configure", "--store", store, "--session", sibling_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        assert f"configuration: {sibling_session} in {store}" in sibling_config
        assert "next: rui --resume REF [--store PATH]" in sibling_config
        sibling_key = admit(home, "message", "--store", store, "--session", sibling_session,
            "two independent Actions")["request"]
        def two_actions():
            candidate = fixture.command("inspect-session", "--store", store, "--session", sibling_session)
            return candidate if len(candidate["actionable_permissions"]) == 2 else None

        report = fixture.wait_for(two_actions, "two actionable siblings")
        pending, running = [row["action"] for row in report["actionable_permissions"]]
        selection, permissions, attention = map(json.loads, run(home, "wait-session", "--store", store,
            "--session", sibling_session, "--json").splitlines())
        assert selection["message"] == sibling_key, selection
        assert permissions == {"event": "actionable_permissions", "actions": [pending, running]}, permissions
        assert attention["return"] == "attention" and attention["action"] == pending, attention
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", sibling_session, "--store", str(store)],
            env={**os.environ, "HOME": str(fresh_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            read_terminal(master, "> ")
            observation = terminal_step(master, "/wait", before_prompt="Rui: Approval is needed. Ctrl-G to inspect.")
            assert "Allow once, deny, or later?" not in observation, observation
            assert not sibling_effect.exists() and counter.read_text() == "x", observation
            terminal_step(master, "/approve", "Allow once, deny, or later? [a/d/l] ")
            terminal_step(master, "l")
            status = terminal_step(master, "/status")
            assert status.count("Action requiring attention: ") == 2, status
            assert f"Action requiring attention: {pending}" in status and f"Action requiring attention: {running}" in status, status
            detach_terminal(master, entered)
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        run(home, "allow-action", "--store", store, "--session", sibling_session,
            "--action", running)
        fixture.wait_for(lambda: sibling_started.exists(), "approved sibling in flight")
        attention = run(home, "follow", sibling_key, "--json")
        assert json.loads(attention) == {"return": "attention", "status": "in_flight", "action": pending}, attention
        assert run(home, "result", sibling_key) == "result: processing\n"
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", sibling_session, "--store", str(store)],
            env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            waiting = read_terminal(master, "> ")
            assert "Allow once, deny, or later?" not in waiting, waiting
            run(home, "deny-action", "--store", store, "--session", sibling_session,
                "--action", pending)
            sibling_release.touch()
            assert "siblings done" in read_terminal(master, "siblings done")
            detach_terminal(master, entered)
        finally:
            sibling_release.touch()
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        fixture.wait_for(lambda: fixture.completed_observation(store, sibling_key), "sibling outcome")
        assert run(home, "result", sibling_key) == "result: completed\nsiblings done\n"
        assert sibling_effect.read_text() == "y" and counter.read_text() == "x"

        failure_release = threading.Event()
        endpoint.responses.extend([
            (fixture.ResponseSpec(b"permanent failure", {}, 422), failure_release),
            fixture.sse_answer("successor-answer", "successor-reason", "successor-message", "successor done")[0],
        ])
        failure_session = "human/failure"
        run(home, "configure", "--store", store, "--session", failure_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        failed_key = admit(home, "message", "--store", store, "--session", failure_session,
            "first failing Turn")["request"]
        fixture.wait_for(lambda: len(endpoint.requests) == 6, "held first failed Turn")
        queued_key = admit(home, "message", "--store", store, "--session", failure_session,
            "queued successor")["request"]
        assert run(home, "result", queued_key) == "result: queued\n"
        follower = subprocess.Popen([str(fixture.RUI), "follow", failed_key],
            env={**os.environ, "HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.15)
        assert follower.poll() is None, follower.communicate(timeout=5)
        follower.kill()
        follower.communicate(timeout=5)
        failure_release.set()
        fixture.wait_for(lambda: fixture.command("observe-command", "--store", store,
            "--key", failed_key)["observation"].get("result"), "failed first Turn")
        assert run(home, "result", failed_key) == "result: failed\ncode: provider_http_422\n"
        fixture.wait_for(lambda: fixture.completed_observation(store, queued_key), "queued successor")
        assert run(home, "result", queued_key) == "result: completed\nsuccessor done\n"
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", failure_session, "--store", str(store)],
            env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            replay = read_terminal(master, "> ")
            assert "provider_http_422" in replay and "successor done" in replay, replay
            failed = terminal_step(master, f"/result {failed_key}")
            assert "Rui: This saved Message failed; no answer was produced." in failed, failed
            assert "Rui: Code: provider_http_422" in failed and "successor done" not in failed, failed
            assert "────────\nsuccessor done" in terminal_step(master, f"/result {queued_key}")
            detach_terminal(master, entered)
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)

        stop_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("stopped-answer", "stopped-reason",
            "stopped-message", "must not appear")[0], stop_release))
        stop_session = "human/stopped"
        run(home, "configure", "--store", store, "--session", stop_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        stopped_key = admit(home, "message", "--store", store, "--session", stop_session,
            "running when stopped")["request"]
        fixture.wait_for(lambda: len(endpoint.requests) == 8, "held stopped Turn")
        excluded_key = admit(home, "message", "--store", store, "--session", stop_session,
            "queued when stopped")["request"]
        assert run(home, "result", excluded_key) == "result: queued\n"
        stopped = fixture.command("stop-session", "--store", store, "--session", stop_session,
            "--record", state / "stop.json", "--key", "human-stop")
        assert stopped["answer"]["status"] == "accepted", stopped
        stop_release.set()
        fixture.wait_for(lambda: fixture.command("observe-command", "--store", store,
            "--key", stopped_key)["observation"].get("result"), "stopped Turn")
        assert run(home, "result", stopped_key).startswith("result: cancelled\n")
        assert run(home, "result", excluded_key) == "result: cancelled\ncode: session_stopped\n"

        rejected = admit(home, "message", "--store", store, "--session", "human/absent",
            "unknown session")
        assert rejected["admission"]["answer"]["status"] == "rejected", rejected
        assert run(home, "result", rejected["request"]) == "result: rejected\ncode: unknown_session\n"
        assert run(home, "recover", rejected["request"]) == "admitted: rejected\nreplayed: true\ncode: unknown_session\n"

        large_answer = "x" * 4095 + "🍰" + "y" * (128 * 1024)
        endpoint.responses.append(fixture.sse_answer("large-answer", "large-reason",
            "large-message", large_answer)[0])
        large_session = "human/large"
        run(home, "configure", "--store", store, "--session", large_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        large_key = admit(home, "message", "--store", store, "--session", large_session,
            "large output")["request"]
        fixture.wait_for(lambda: fixture.completed_observation(store, large_key), "large saved answer")
        reader = subprocess.Popen([str(fixture.RUI), "result", large_key, "--json"],
            env={**os.environ, "HOME": str(home), **render_environment},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            assert reader.stdout.read(256).startswith(b'{"observation":')
            assert reader.poll() is None, "large result should block on unread stdout"
            assert list(scratch.iterdir()) == [], "rendering must not leave a named payload"
        finally:
            if reader.poll() is None:
                reader.kill()
            reader.communicate(timeout=5)
        assert reader.returncode == -signal.SIGKILL and list(scratch.iterdir()) == []
        assert json.loads(run(home, "result", large_key, "--json", environment=render_environment))["answer"] == large_answer

        fixture.crash_host(host, state, "human-cli-crash")
        failed_observation = run(home, "result", first, success=False)
        assert failed_observation == "", failed_observation
        host = fixture.start_host(store, url)
        assert json.loads(run(home, "recover", first, "--json"))["answer"]["replayed"] is True
        assert run(home, "result", first) == "result: completed\nfirst answer\n"
        recovered_session = fixture.command("inspect-session", "--store", store, "--session", session)
        assert recovered_session["selected_message"] is None
        assert [row["message"] for row in recovered_session["recent_messages"]] == [second, queued, first]
        assert counter.read_text() == "x" and sibling_effect.read_text() == "y" and len(endpoint.requests) == 9

        endpoint.responses.extend([
            (fixture.sse_answer("race-prior", "race-prior-reason", "race-prior-message", "prior done")[0], race_predecessor_release),
            (fixture.sse_answer("race-a", "race-a-reason", "race-a-message", "A done")[0], race_message_release),
            fixture.sse_tool_calls("race-b", [("bash", "race-b-call", arguments)]),
            fixture.sse_answer("race-b-done", "race-b-done-reason", "race-b-done-message", "B done")[0],
        ])
        race_session = "human/follow-race"
        run(home, "configure", "--store", store, "--session", race_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        prior_receipt = run(home, "message", "--store", store, "--session", race_session, "prior")
        prior = prior_receipt.split("request: ", 1)[1].splitlines()[0]
        assert f"message: {race_session} in {store}" in prior_receipt
        assert "next: rui --resume REF [--store PATH]" in prior_receipt
        assert "next: rui follow" not in prior_receipt
        fixture.wait_for(lambda: len(endpoint.requests) == 10, "held predecessor request")
        message_a = admit(home, "message", "--store", store, "--session", race_session, "A")["request"]
        assert run(home, "result", message_a) == "result: queued\n"
        race_follower = subprocess.Popen([str(fixture.RUI), "follow", message_a, "--json"],
            env={**os.environ, "HOME": str(home), "RUI_TEST_FOLLOW_GATE": str(race_gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        fixture.wait_for(lambda: pathlib.Path(f"{race_gate}.ready").exists(), "queued A observed by follower")
        assert race_follower.poll() is None
        assert run(home, "result", message_a) == "result: queued\n"
        race_predecessor_release.set()
        fixture.wait_for(lambda: len(endpoint.requests) == 11, "A processing request")
        race_waiter = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", race_session, "--json"],
            env={**os.environ, "HOME": str(home), "RUI_TEST_FOLLOW_GATE": str(wait_gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        fixture.wait_for(lambda: pathlib.Path(f"{wait_gate}.ready").exists(), "Session wait selected A")
        race_message_release.set()
        fixture.wait_for(lambda: fixture.completed_observation(store, message_a), "A outcome before Current")
        fixture.wait_for(lambda: fixture.completed_observation(store, prior), "predecessor completion")
        message_b = admit(home, "message", "--store", store, "--session", race_session, "B")["request"]
        def b_action():
            report = fixture.command("inspect-session", "--store", store, "--session", race_session)
            return report["actionable_permissions"][0]["action"] if report["actionable_permissions"] else None

        action_b = fixture.wait_for(b_action, "B permission before Current")
        assert fixture.command("observe-command", "--store", store, "--key", message_a)["observation"]["result"]["status"] == "completed"
        pathlib.Path(f"{race_gate}.release").touch()
        pathlib.Path(f"{wait_gate}.release").touch()
        output, error = race_follower.communicate(timeout=10)
        assert race_follower.returncode == 0, (output, error)
        followed = json.loads(output)
        assert followed["return"] == "outcome" and followed["observation"]["result"]["status"] == "completed", followed
        assert followed["observation"]["target"] == race_session, followed
        race_follower = None
        wait_output, wait_error = race_waiter.communicate(timeout=10)
        assert race_waiter.returncode == 0, wait_error
        selection, observed = map(json.loads, wait_output.splitlines())
        assert selection["message"] == prior and observed["return"] == "outcome", wait_output
        assert observed["observation"]["result"]["status"] == "completed", wait_output
        race_waiter = None
        assert b_action() == action_b
        assert json.loads(run(home, "inspect-action", "--store", store, "--session", race_session,
            "--action", action_b, "--json"))["call_id"] == "race-b-call"
        denied = admit(home, "deny-action", "--store", store, "--session", race_session,
            "--action", action_b)
        assert denied["admission"]["answer"]["status"] == "accepted", denied
        fixture.wait_for(lambda: fixture.completed_observation(store, message_b), "B outcome after decision")
        control_call = "interactive-bash\x1b[1Ghidden\u202e"
        argument_prefix = '{"cmd":"printf x >> effect-count # '
        padded_arguments = json.dumps({"cmd": "printf x >> effect-count # " +
            "A" * (4095 - len(argument_prefix)) + "é", "timeout_ms": None},
            ensure_ascii=False, separators=(",", ":")) + "\r  "
        assert padded_arguments.encode()[4095:4097] == "é".encode()
        endpoint.responses.extend([
            fixture.sse_tool_calls("interactive-call", [("bash", control_call, padded_arguments)]),
            fixture.sse_answer("interactive-answer", "interactive-reason", "interactive-message",
                "interactive complete")[0],
        ])
        interactive = "human/interactive"
        run(home, "configure", "--store", store, "--session", interactive,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        master, slave = open_terminal()
        ready_read, ready_write = os.pipe()
        try:
            entered = subprocess.Popen([str(fixture.RUI), "--resume", interactive, "--store", str(store)],
                env={**os.environ, "HOME": str(home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            os.close(master)
            os.close(ready_read)
            raise
        finally:
            os.close(slave)
            os.close(ready_write)
        try:
            assert "Permission: ask" in read_terminal(master, "> ")
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 56, 0, 0))
            os.write(master, b"interactive request\n")
            # Drain resize/editor output while the request is admitted; an
            # unread PTY can backpressure the CLI before it transmits anything.
            live_call = read_terminal(master, "Proposed tool: bash")
            permissions = fixture.wait_for(lambda: fixture.command("inspect-session", "--store", store,
                "--session", interactive)["actionable_permissions"], "interactive Action attention")
            attention_marker = "Ctrl-G: inspect approval"
            attention = live_call if attention_marker in live_call else live_call + read_terminal(master, attention_marker)
            assert "Allow once, deny, or later?" not in attention, attention
            os.write(master, b"/approve\na\n")
            proposal = read_terminal(master, "Allow once, deny, or later?")
            action_ready(ready_read)
            assert counter.read_text() == "x", "pasted typeahead approved an unseen Action"
            assert "Command:" in proposal and "You: interactive request" not in proposal, proposal
            assert "Rui: Work needs your decision." not in proposal and "Rui: Work is in flight." not in proposal, proposal
            assert "────────\nPermission required · Bash\nCommand: " in proposal, proposal
            permission_view = proposal.split("Permission required · Bash", 1)[1]
            assert "Action " not in permission_view and "Assistant:" not in permission_view, proposal
            assert "call ID:" not in proposal and "request:" not in proposal and "return:" not in proposal, proposal
            assert 'Command: "printf x >> effect-count # ' in proposal, proposal
            command_view = proposal.split('Command: "', 1)[1].split('"\nTimeout:', 1)[0]
            assert "\n" not in command_view, "command should soft-wrap, not insert hard line breaks"
            assert command_view == json.loads(padded_arguments.strip())["cmd"], "displayed command changed its meaning"
            assert 'é"\nTimeout: Host default\nAllow once, deny, or later? [a/d/l] ' in proposal and "\\u00e9" not in proposal, proposal
            assert "\x1b[2J" not in proposal and "\u202e" not in proposal, proposal
            interactive_key = fixture.command("inspect-session", "--store", store, "--session", interactive)["selected_message"]
            assert interactive_key is not None, proposal
            assert interactive_key in run(home, "requests").splitlines(), "hidden receipt must remain recoverable"
            current_action = fixture.command("inspect-session", "--store", store, "--session", interactive)
            action_id = current_action["actionable_permissions"][0]["action"]
            assert [item["action"] for item in current_action["actionable_permissions"]] == [action_id], current_action
            mismatch = admit(home, "allow-action", "--store", store, "--session", session,
                "--action", action_id)
            assert mismatch["admission"]["answer"]["status"] == "rejected", mismatch
            assert mismatch["admission"]["answer"]["code"] == "target_mismatch", mismatch
            assert "No decision sent" in terminal_step(master, "l")
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 16, 0, 0))
            narrow = terminal_step(master, "/approve")
            assert "Widen the terminal to inspect this permission request; no decision sent" in narrow, narrow
            assert "Permission required" not in narrow and counter.read_text() == "x", narrow
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 56, 0, 0))
            assert "Command:" in terminal_step(master, "/approve", "Allow once, deny, or later?")
            action_ready(ready_read)
            os.write(master, b" a \n")
            assert "No decision sent" in read_terminal(master, "> ")
            assert counter.read_text() == "x", "padded choice approved an Action"
            assert "Command:" in terminal_step(master, "/approve", "Allow once, deny, or later?")
            action_ready(ready_read)
            rejected_choice = terminal_step(master, "\x1b[200~a\x1b[201~")
            assert "No decision sent" in rejected_choice, rejected_choice
            assert counter.read_text() == "x", "marked paste approved an Action"
            assert "Command:" in terminal_step(master, "/approve", "Allow once, deny, or later?")
            action_ready(ready_read)
            decisions_before = set(run(home, "requests").splitlines())
            completed_turn = terminal_step(master, "a", "interactive complete")
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            assert "interactive complete" in completed_turn and "Assistant:" not in completed_turn and not any(line.startswith("result:") for line in completed_turn.splitlines()), completed_turn
            assert "────────\ninteractive complete" in completed_turn, completed_turn
            assert not any(label in completed_turn for label in ("[user · ", "[assistant · ", "[outcome · ", "[call · ", "[status]")), completed_turn
            decision_handle, = set(run(home, "requests").splitlines()) - decisions_before
            assert "request: " not in completed_turn, "successful approval leaked a protocol receipt"
            assert json.loads((home / ".config/rui/requests" / (decision_handle + ".json")).read_text())["kind"] == "permission_decision", "approval capture must remain recoverable"
            assert "Allow once, deny, or later?" not in completed_turn, "attention must not reopen approval automatically"
            saved_result = terminal_step(master, "/result " + interactive_key, "interactive complete")
            assert "────────\ninteractive complete" in saved_result, saved_result
            markdown = "# Title\n- *item* and `code`\n- **`README.md`** — start here\n# **before `a**b` after** tail\n   ```zig\n  value = `literal`\n   ```\n" \
                "``value`` then `ok`\n**value*** then **ok**\n*value** then *ok*\n" \
                "unclosed *mark and \x1b]2;spoof\x07 Don’t café"
            endpoint.responses.append(fixture.sse_answer("markdown-answer", "markdown-reason",
                "markdown-message", markdown)[0])
            rendered = terminal_step(master, "render markdown", "Don’t café")
            assert "[assistant · " not in rendered and "\x1b[1mTitle\x1b[0m" in rendered and "Assistant:" not in rendered, rendered
            assert rendered.count("────────") == 1, rendered
            assert "\x1b[1m-\x1b[0m \x1b[3mitem\x1b[0m and \x1b[4mcode\x1b[0m" in rendered, rendered
            assert "\x1b[4mREADME.md\x1b[0m" in rendered and "`README.md`" not in rendered, rendered
            assert "a**b" in rendered and "`a**b`" not in rendered, rendered
            assert "  value = `literal`\n" in rendered and "   ```" not in rendered, rendered
            assert "``value`` then \x1b[4mok\x1b[0m\n" in rendered, rendered
            assert "**value*** then \x1b[1mok\x1b[0m\n" in rendered, rendered
            assert "*value** then \x1b[3mok\x1b[0m\n" in rendered, rendered
            assert "unclosed *mark and \\x1b]2;spoof\\x07 Don’t café" in rendered, rendered
            assert "\x1b[7m" not in rendered, rendered
            markdown_key = fixture.command("inspect-session", "--store", store,
                "--session", interactive)["recent_messages"][0]["message"]
            assert run(home, "result", markdown_key) == "result: completed\n" + markdown + "\n"
            assert json.loads(run(home, "result", markdown_key, "--json"))["answer"] == markdown
            long_markdown = "x" * 4095 + "é" + "y" * (64 * 1024)
            endpoint.responses.append(fixture.sse_answer("long-markdown", "long-reason",
                "long-message", long_markdown)[0])
            long_rendered = terminal_step(master, "render long answer", long_markdown)
            assert "[assistant · " not in long_rendered and long_markdown in long_rendered, len(long_rendered)
            if "\r> \r\x1b[2C" not in long_rendered.split(long_markdown, 1)[1]:
                long_rendered += read_terminal(master, "> ", initial=long_rendered.split(long_markdown, 1)[1])
            assert "\r> \r\x1b[2C" in long_rendered.split(long_markdown, 1)[1], long_rendered[-1000:]
            assert "Outcome: completed" not in long_rendered, long_rendered[-1000:]
            socket_path = host.rui_ready_fields["socket"]
            head, body = public_request(socket_path, store, "/v1/conversation-page", "conversation_page",
                interactive, end="0", before_position="0", before_ordinal="0")
            assert head.startswith(b"HTTP/1.1 200 "), head
            latest = next(item for item in json.loads(body)["items"] if item["kind"] == "assistant")
            head, body = public_request(socket_path, store, "/v1/conversation-content", "conversation_content",
                interactive, position=latest["position"], ordinal=latest["ordinal"], start="0", stream=True)
            assert head.startswith(b"HTTP/1.1 200 ") and body == long_markdown.encode(), (head, len(body))
            assert f"Content-Length: {len(body)}\r\n".encode() in head and len(body) > 4096, head
            head, _ = public_request(socket_path, store, "/v1/conversation-content", "conversation_content",
                interactive, position=latest["position"], ordinal=latest["ordinal"], start="1", stream=True)
            assert head.startswith(b"HTTP/1.1 400 "), head
            exported = state / "exported-assistant"
            run(home, "conversation-content", "--store", store, "--session", interactive,
                "--position", latest["position"], "--ordinal", latest["ordinal"], "--output", exported)
            assert exported.read_bytes() == long_markdown.encode()
            cli_before, host_before = host_resources(entered.pid), host_resources(host.pid)
            replayed = terminal_step(master, "/resume " + interactive, before_prompt="Session: " + interactive)
            assert "[assistant · " not in replayed and "\x1b[1mTitle\x1b[0m" in replayed, replayed
            assert "  value = `literal`\n" in replayed and "   ```" not in replayed, replayed
            assert "unclosed *mark and \\x1b]2;spoof\\x07 Don’t café" in replayed, replayed
            assert f"[content omitted: {len(long_markdown.encode())} bytes;" in replayed and "render long answer" in replayed, replayed
            assert "rui conversation-content" in replayed and "--position" in replayed and "--ordinal" in replayed, replayed
            cli_after, host_after = host_resources(entered.pid), host_resources(host.pid)
            if cli_before is not None and cli_after is not None:
                assert cli_after[1] == cli_before[1], (cli_before, cli_after)
                print(f"human CLI replay idle resources CLI={cli_before}->{cli_after} Host={host_before}->{host_after} (RSS bytes, FDs; Linux only)")
            for _ in range(3):
                assert "\x1b[1mTitle\x1b[0m" in terminal_step(master, "/resume " + interactive, before_prompt="Session: " + interactive)
            cli_repeated = host_resources(entered.pid)
            if cli_after is not None and cli_repeated is not None:
                assert cli_repeated[1] == cli_before[1], (cli_before, cli_after, cli_repeated)
                print(f"human CLI three more bounded replays CLI={cli_after}->{cli_repeated} (RSS bytes, FDs; Linux only)")
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            wide_status = terminal_step(master, "/status", before_prompt="Session:              " + interactive)
            assert "Session:              " + interactive in wide_status, wide_status
            assert "Provider:             codex" in wide_status and "Model:                model-a" in wide_status, wide_status
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 40, 0, 0))
            narrow_status = terminal_step(master, "/status", before_prompt="Session: " + interactive)
            assert "Recent messages" in narrow_status and "Session: " + interactive in narrow_status, narrow_status
            assert "Session:              " not in narrow_status and "Provider: codex" in narrow_status, narrow_status
            detach_terminal(master, entered)
            assert termios.tcgetattr(master)[3] & termios.ICANON, "terminal mode not restored"
            assert counter.read_text() == "xx", counter.read_text()
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(ready_read)
            os.close(master)
        # Both bypass calls may settle before a Session pull. Authoritative
        # public call items must still appear once before the final answer.
        bypass_session = "human/call-feed"
        bypass_arguments = json.dumps({"cmd": "printf z >> effect-count", "timeout_ms": None}, separators=(",", ":"))
        long_arguments = json.dumps({"cmd": "printf z >> effect-count # " + "a" * 290,
            "timeout_ms": None}, separators=(",", ":"))
        endpoint.responses.extend([
            fixture.sse_tool_calls("feed-calls", [("bash", "feed-one", bypass_arguments),
                ("bash", "feed-two", long_arguments)]),
            fixture.sse_answer("feed-answer", "feed-reason", "feed-message", "feed complete")[0],
        ])
        run(home, "configure", "--store", store, "--session", bypass_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "bypass")
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", bypass_session, "--store", str(store)],
            env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert "Permission: bypass (Bash runs without approval)" in read_terminal(master, "> ")
            output = terminal_step(master, "call feed", "feed complete")
            assert output.count("Proposed tool: bash\n") == 2 and "[call · " not in output, output
            assert "Proposed tool: bash\n" + bypass_arguments in output and "Proposed tool: bash\n" + long_arguments in output, output
            assert "You: call feed" in output and "Tool result:" in output, output
            assert output.index("Proposed tool: bash\n") < output.index("feed complete"), output
            assert "Running" not in output and "Rejected proposal" not in output, output
            detach_terminal(master, entered)
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        # Re-entry fixes the historical end, then catches up forward through
        # successors admitted while the opening page was held.
        prior_release = threading.Event()
        prior_release.set()
        endpoint.responses.extend([
            (fixture.sse_answer("resume-prior", "resume-prior-reason", "resume-prior-message", "prior answer")[0], prior_release),
            (fixture.sse_answer("resume-a", "resume-a-reason", "resume-a-message", "answer A")[0], resume_a_release),
            (fixture.sse_answer("resume-b", "resume-b-reason", "resume-b-message", "answer B")[0], resume_b_release),
        ])
        resume_ref = "human/resume-race"
        run(home, "configure", "--store", store, "--session", resume_ref,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        prior = admit(home, "message", "--store", store, "--session", resume_ref, "earlier turn")["request"]
        fixture.wait_for(lambda: fixture.completed_observation(store, prior), "earlier history committed")
        resume_a = admit(home, "message", "--store", store, "--session", resume_ref, "resume A")["request"]
        fixture.wait_for(lambda: fixture.command("inspect-session", "--store", store,
            "--session", resume_ref)["selected_message"] == resume_a, "A selected before re-entry")
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", resume_ref, "--store", str(store)],
            env={**os.environ, "HOME": str(home), "RUI_TEST_RESUME_GATE": str(resume_gate)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            fixture.wait_for(lambda: pathlib.Path(f"{resume_gate}.ready").exists(), "A selected before history replay")
            resume_a_release.set()
            fixture.wait_for(lambda: fixture.completed_observation(store, resume_a), "A finishes during re-entry")
            before_b = len(endpoint.requests)
            resume_b = admit(home, "message", "--store", store, "--session", resume_ref, "resume B")["request"]
            fixture.wait_for(lambda: fixture.command("inspect-session", "--store", store,
                "--session", resume_ref)["selected_message"] == resume_b, "B succeeds A")
            fixture.wait_for(lambda: len(endpoint.requests) > before_b, "B provider request held")
            pathlib.Path(f"{resume_gate}.release").touch()
            replay = read_terminal(master, "> ")
            assert "earlier turn" in replay and "prior answer" in replay, replay
            if "resume B" not in replay:
                replay += read_terminal(master, "resume B")
            assert replay.count("answer A") == 1 and "resume B" in replay, replay
            resume_b_release.set()
            replay += read_terminal(master, "answer B")
            assert replay.count("answer B") == 1, replay
            detach_terminal(master, entered)
        finally:
            resume_a_release.set()
            resume_b_release.set()
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        idle_ref = "human/resume-idle"
        endpoint.responses.append((fixture.sse_answer("resume-idle", "resume-idle-reason",
            "resume-idle-message", "later answer")[0], resume_idle_release))
        run(home, "configure", "--store", store, "--session", idle_ref,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", idle_ref, "--store", str(store)],
            env={**os.environ, "HOME": str(home), "RUI_TEST_RESUME_GATE": str(resume_idle_gate)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            fixture.wait_for(lambda: pathlib.Path(f"{resume_idle_gate}.ready").exists(), "idle selected before history replay")
            idle_new = admit(home, "message", "--store", store, "--session", idle_ref, "arrived later")["request"]
            fixture.wait_for(lambda: fixture.command("inspect-session", "--store", store,
                "--session", idle_ref)["selected_message"] == idle_new, "new work after idle selection")
            pathlib.Path(f"{resume_idle_gate}.release").touch()
            replay = read_terminal(master, "> ")
            if "arrived later" not in replay:
                replay += read_terminal(master, "arrived later")
            assert "arrived later" in replay and "answer B" not in replay, replay
            assert "Work: " not in replay, "opening header must describe captured idle Current"
            detach_terminal(master, entered)
        finally:
            pathlib.Path(f"{resume_idle_gate}.release").touch()
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        resume_b_release.set()
        fixture.wait_for(lambda: fixture.completed_observation(store, resume_b), "B settles after resume")
        spaced_ref = "human/space name"
        run(home, "configure", "--store", store, "--session", spaced_ref,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", resume_ref, "--store", str(store)],
            env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            read_terminal(master, "> ")
            switched = terminal_step(master, f"/resume {spaced_ref}")
            assert f"Session: {spaced_ref}" in switched, switched
            detach_terminal(master, entered)
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        option_ref = "--option-looking"
        run(home, "configure", "--store", store, "--session", option_ref,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", "--store", str(store), "--", option_ref],
            env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            replay = read_terminal(master, "> ")
            assert f"Session: {option_ref}" in replay and "[status] " not in replay and "compose" not in replay, replay
            detach_terminal(master, entered)
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        fixture.wait_for(lambda: len(endpoint.requests) > before_b + 1, "later idle work starts")
        resume_idle_release.set()
        fixture.wait_for(lambda: fixture.completed_observation(store, idle_new), "later idle work settles")
        control_session = "human/name\n\x1b[2J\u202e Don’t"
        run(home, "configure", "--store", store, "--session", control_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", control_session, "--store", str(store)],
            env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            greeting = read_terminal(master, "> ")
            assert "Session: human/name\\n\\x1b[2J\\u202e Don’t" in greeting, greeting
            assert "\x1b[2J" not in greeting and "\u202e" not in greeting, greeting
            detach_terminal(master, entered)
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        unsafe_session = "human/unsafe-key"
        unsafe_key = "message\n\x1b[2J\u202e"
        unsafe_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("unsafe-answer", "unsafe-reason",
            "unsafe-message", "safe result")[0], unsafe_release))
        run(home, "configure", "--store", store, "--session", unsafe_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        unsafe_text = state / "unsafe-input"
        unsafe_text.write_text("report status")
        run(home, "message", "--store", store, "--session", unsafe_session,
            "--record", state / "unsafe-record.json", "--key", unsafe_key, "--text", unsafe_text)
        fixture.wait_for(lambda: fixture.command("inspect-session", "--store", store,
            "--session", unsafe_session)["selected_message"] == unsafe_key, "unsafe key selected")
        waiter = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", unsafe_session], env={**os.environ, "HOME": str(home)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert waiter.stdout.readline() == "selected message: message\\n\\x1b[2J\\u202e\n"
            master, slave = open_terminal()
            entered = subprocess.Popen([str(fixture.RUI), "--resume", unsafe_session, "--store", str(store)],
                env={**os.environ, "HOME": str(home)},
                stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            try:
                # Current can select the Message before its user entry enters
                # the captured history page; selection, not replay, is required.
                opening = read_terminal(master, "Session: human/unsafe-key")
                assert "Session: human/unsafe-key" in opening, opening
                unsafe_release.set()
                read_terminal(master, "> ")
                fixture.wait_for(lambda: fixture.completed_observation(store, unsafe_key), "unsafe key terminal outcome")
                status = terminal_step(master, "/status", "message\\n\\x1b[2J\\u202e: completed")
                assert "message\\n\\x1b[2J\\u202e: completed" in status, status
                assert "\x1b[2J" not in status and "\u202e" not in status, status
                detach_terminal(master, entered)
            finally:
                if entered.poll() is None:
                    entered.kill()
                    entered.wait(timeout=5)
                os.close(master)
        finally:
            unsafe_release.set()
            waiter.communicate(timeout=10)
        fixture.wait_for(lambda: fixture.completed_observation(store, unsafe_key), "unsafe key result")
        assert fixture.command("inspect-session", "--store", store,
            "--session", unsafe_session)["recent_messages"][0]["message"] == unsafe_key
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", unsafe_session, "--store", str(store)],
            env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            greeting = read_terminal(master, "> ")
            assert "Session: human/unsafe-key" in greeting, greeting
            status = terminal_step(master, "/status")
            assert "message\\n\\x1b[2J\\u202e: completed" in status, status
            assert "\x1b[2J" not in status and "\u202e" not in status, status
            detach_terminal(master, entered)
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        empty_session = "human/empty-key"
        run(home, "configure", "--store", store, "--session", empty_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        empty_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("empty-answer", "empty-reason", "empty-message",
            "empty key answer")[0], empty_release))
        empty_input = state / "empty-input"
        empty_input.write_text("empty key input")
        admission = json.loads(run(home, "message", "--store", store, "--session", empty_session,
            "--record", state / "empty-record.json", "--key", "", "--text", empty_input))
        assert admission["answer"]["status"] == "accepted", admission
        fixture.wait_for(lambda: fixture.command("inspect-session", "--store", store,
            "--session", empty_session)["work"]["status"] == "in_flight", "empty key active")
        current = fixture.command("inspect-session", "--store", store, "--session", empty_session)
        assert current["selected_message"] == "", current
        empty_wait = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", empty_session, "--json"],
            env={**os.environ, "HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert json.loads(empty_wait.stdout.readline()) == {"event": "selection", "session": empty_session, "message": ""}
            empty_release.set()
            assert json.loads(empty_wait.stdout.readline())["observation"]["result"]["status"] == "completed"
            assert empty_wait.wait(timeout=10) == 0
        finally:
            empty_release.set()
            if empty_wait.poll() is None:
                empty_wait.kill()
                empty_wait.communicate(timeout=5)
        current = fixture.command("inspect-session", "--store", store, "--session", empty_session)
        assert current["selected_message"] is None and current["recent_messages"][0]["message"] == "", current
        endpoint.responses.append(fixture.sse_answer("long-answer", "long-reason", "long-message", "long input intact")[0])
        long_session = "human/long-input"
        run(home, "configure", "--store", store, "--session", long_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        master, slave = open_terminal()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 40, 0, 0))
        entered = subprocess.Popen([str(fixture.RUI), "--resume", long_session, "--store", str(store)],
            env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            greeting = read_terminal(master, "> ")
            assert "Permission: bypass (Bash runs without approval)" in greeting, greeting
            assert "Rui: Bash commands can run without asking you." not in greeting, greeting
            assert "Provider: codex" in greeting and "Model: model-a" in greeting, greeting
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 2048, 0, 0))
            before = len(endpoint.requests)
            long_text = "X" * 5000
            answer = terminal_bulk(master, long_text, "long input intact")
            assert "long input intact" in answer, answer
            assert len(endpoint.requests) == before + 1
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == long_text
            rejected = terminal_bulk(master, "Y" * (64 * 1024 + 1) + "\x7f", "Input rejected; nothing sent.")
            assert "Input rejected; nothing sent." in rejected, rejected[-1000:]
            assert len(endpoint.requests) == before + 1, "oversized input reached Host"
            os.write(master, b"\x15")
            # Rejection already clears the draft. Its empty footer may arrive
            # with the notice; Ctrl-U on that empty draft need not repaint.
            read_terminal(master, "> ", initial=rejected.split("Input rejected; nothing sent.", 1)[1])
            rejected = terminal_step(master, "invalid\x00x", "Input rejected; nothing sent.")
            assert "Input rejected; nothing sent." in rejected and "--text FILE" not in rejected, rejected
            assert len(endpoint.requests) == before + 1, "unsupported control reached Host"
            os.write(master, b"\x15")
            read_terminal(master, "> ", initial=rejected.split("Input rejected; nothing sent.", 1)[1])
            detach_terminal(master, entered)
            assert termios.tcgetattr(master)[3] & termios.ICANON
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        editor_session = "human/editor"
        run(home, "configure", "--store", store, "--session", editor_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        cases = [
            ("first second\x1b\x7fZ", "first Z"),
            ("A中e\u0301🧑‍🌾\x7f", "A中e\u0301"),
            ("\x1b[200~line1\nline2\x1b[201~", "line1\nline2"),
            ("\x1b[200~a\n\u0301\x1b[201~\x01\x7f\x7fZ", "Z"),
            ("ab\x01\x04\x05\x04", "b"),
            ("ask src/foo-bar\x17", "ask "),
            ("\x1b[123;4~Z", "Z"),
            ("\x1bZ", "Z"),
            ("abc\x1b[D\x1b[DZ", "aZbc"),
            ("\x1b[200~line1\nline2\x1b[201~\x1b[A\x01X", "Xline1\nline2"),
        ]
        endpoint.responses.extend(fixture.sse_answer(f"editor-answer-{i}", f"editor-reason-{i}",
            f"editor-message-{i}", f"edited {i}")[0] for i in range(len(cases)))
        master, slave = open_terminal()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 2048, 0, 0))
        entered = subprocess.Popen([str(fixture.RUI), "--resume", editor_session, "--store", str(store)],
            env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            read_terminal(master, "> ")
            for index, (typed, expected) in enumerate(cases):
                if index == 0:
                    os.write(master, b"first second\x1b\x7f")
                    repaint = read_terminal(master, "> first ")
                    assert "\x1b[2K" in repaint and "\x1b[0J" not in repaint, repaint
                    observed = terminal_step(master, "Z", f"edited {index}")
                elif index == 1:
                    os.write(master, typed.encode())
                    repaint = read_terminal(master, "> A中e\u0301")
                    assert "\x1b[2K" in repaint and "\x1b[0J" not in repaint, repaint
                    observed = terminal_step(master, "", f"edited {index}")
                elif typed == "abc\x1b[D\x1b[DZ":
                    os.write(master, b"abc\x1b[")
                    time.sleep(0.2)  # A recognized CSI must outlive the bare-ESC ambiguity timeout.
                    observed = terminal_step(master, "D\x1b[DZ", f"edited {index}")
                else:
                    observed = terminal_step(master, typed, f"edited {index}")
                assert f"edited {index}" in observed, observed
                if index == 2:
                    assert "You: line1\\nline2" not in observed, observed
                    assert "[assistant · " not in observed and "edited 2" in observed, observed
                if "\r> \r\x1b[2C" not in observed.split(f"edited {index}", 1)[1]:
                    read_terminal(master, "> ", initial=observed.split(f"edited {index}", 1)[1])
                body = json.loads(endpoint.requests[-1])
                actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                    if item.get("role") == "user")
                assert actual == expected, (typed, expected, actual)
            for index, (cluster, count) in enumerate((("a", 1000), ("e\u0301", 500))):
                marker = f"burst edited {index}"
                endpoint.responses.append(fixture.sse_answer(f"burst-answer-{index}",
                    f"burst-reason-{index}", f"burst-message-{index}", marker)[0])
                observed = terminal_bulk(master, cluster * count + "\x7f" * count + "Z", marker)
                assert len(observed.encode()) < 100_000, "tail deletion repainted the whole draft per key"
                body = json.loads(endpoint.requests[-1])
                actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                    if item.get("role") == "user")
                assert actual == "Z", actual
                if "\r> \r\x1b[2C" not in observed.split(marker, 1)[1]:
                    read_terminal(master, "> ", initial=observed.split(marker, 1)[1])
            endpoint.responses.append(fixture.sse_answer("paced-answer", "paced-reason",
                "paced-message", "paced edited")[0])
            os.write(master, b"a" * 100)
            read_terminal(master, "a" * 100)
            for _ in range(100):
                os.write(master, b"\x7f")
                time.sleep(0.025)  # Longer than the editor's repaint window.
            observed = terminal_step(master, "Z", "paced edited")
            assert len(observed.encode()) < 3000, ("paced ASCII deletion repainted the whole draft", len(observed.encode()))
            body = json.loads(endpoint.requests[-1])
            actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user")
            assert actual == "Z", actual
            if "\r> \r\x1b[2C" not in observed.split("paced edited", 1)[1]:
                read_terminal(master, "> ", initial=observed.split("paced edited", 1)[1])
            before = len(endpoint.requests)
            endpoint.responses.append(fixture.sse_answer("wrapped-edit", "wrapped-reason",
                "wrapped-message", "wrapped edit accepted")[0])
            accepted = terminal_bulk(master, "a" * 2050 + "\x7f" * 2048, "wrapped edit accepted")
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == "aa", body
            if "\r> \r\x1b[2C" not in accepted.split("wrapped edit accepted", 1)[1]:
                read_terminal(master, "> ", initial=accepted.split("wrapped edit accepted", 1)[1])
            before = len(endpoint.requests)
            for invalid in (b"\xc3(\n", b"\xc3\n"):
                os.write(master, invalid)
                rejected = read_terminal(master, "Input rejected; nothing sent.")
                assert "Input rejected; nothing sent." in rejected, rejected
                os.write(master, b"\x15")
                read_terminal(master, "> ", initial=rejected.split("Input rejected; nothing sent.", 1)[1])
            assert len(endpoint.requests) == before, "malformed UTF-8 reached Host"
            endpoint.responses.append(fixture.sse_answer("editor-limit-answer", "editor-limit-reason",
                "editor-limit-message", "limit accepted")[0])
            at_limit = "a" * (64 * 1024 - 2) + "é"
            accepted = terminal_bulk(master, at_limit, "limit accepted")
            assert "limit accepted" in accepted, accepted[-1000:]
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == at_limit
            if "\r> \r\x1b[2C" not in accepted.split("limit accepted", 1)[1]:
                read_terminal(master, "> ", initial=accepted.split("limit accepted", 1)[1])
            before = len(endpoint.requests)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 12, 0, 0))
            endpoint.responses.append(fixture.sse_answer("narrow-edit", "narrow-reason",
                "narrow-message", "narrow edit accepted")[0])
            accepted = terminal_step(master, "A中e\u0301\x1b[D", "narrow edit accepted")
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == "A中e\u0301", body
            if "\r> \r\x1b[2C" not in accepted.split("narrow edit accepted", 1)[1]:
                read_terminal(master, "> ", initial=accepted.split("narrow edit accepted", 1)[1])
            detach_terminal(master, entered, b"\x04")
            assert termios.tcgetattr(master)[3] & termios.ICANON
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", empty_session, "--store", str(store)],
            env={**os.environ, "HOME": str(fresh_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert "Recent messages" not in read_terminal(master, "> ")
            fixture.wait_for(lambda: not termios.tcgetattr(master)[3] & termios.ICANON,
                "terminal ready for Ctrl+C")
            detach_terminal(master, entered, b"\x03")
            assert termios.tcgetattr(master)[3] & termios.ICANON
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        # Independent read-only callers can wait for the same production
        # deadline together; keep every input class and restoration assertion.
        incomplete_callers = []
        before = len(endpoint.requests)
        try:
            for incomplete in (b"\xc3", b"\x1b[200~unfinished", b"\x1b[", b"\x1bO"):
                master, slave = open_terminal()
                try:
                    entered = subprocess.Popen([str(fixture.RUI), "--resume", empty_session, "--store", str(store)],
                        env={**os.environ, "HOME": str(fresh_home)},
                        stdin=slave, stdout=slave, stderr=slave)
                except BaseException:
                    os.close(master)
                    raise
                finally:
                    os.close(slave)
                incomplete_callers.append((master, entered))
                read_terminal(master, "> ")
                os.write(master, incomplete)
            for master, entered in incomplete_callers:
                assert "IncompleteTerminalInput" in read_terminal(master, "IncompleteTerminalInput", timeout=7)
                assert entered.wait(timeout=5) != 0
                assert termios.tcgetattr(master)[3] & termios.ICANON
            assert len(endpoint.requests) == before, "incomplete terminal input reached Host"
        finally:
            for master, entered in incomplete_callers:
                if entered.poll() is None:
                    entered.kill()
                    entered.wait(timeout=5)
                os.close(master)
        assert not endpoint.responses, f"prior fixture responses remain: {len(endpoint.responses)}"
        progress_release = threading.Event()
        endpoint.responses.extend([
            (fixture.ResponseSpec(fixture.sse_answer("held-progress", "held-progress-reason",
                "held-progress-message", "first completed")[0],
                {"Content-Type": "text/event-stream"}, gate_timeout=45), progress_release),
            fixture.sse_answer("queued-progress", "queued-progress-reason",
                "queued-progress-message", "second completed")[0],
        ])
        progress_session = "human/progress"
        run(home, "configure", "--store", store, "--session", progress_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        first_master, first_slave = open_terminal()
        first_caller = subprocess.Popen([str(fixture.RUI), "--resume", progress_session, "--store", str(store)],
            env={**os.environ, "HOME": str(home)},
            stdin=first_slave, stdout=first_slave, stderr=first_slave)
        os.close(first_slave)
        try:
            read_terminal(first_master, "> ")
            second_master, second_slave = open_terminal()
            second_caller = subprocess.Popen([str(fixture.RUI), "--resume", progress_session, "--store", str(store)],
                env={**os.environ, "HOME": str(home)},
                stdin=second_slave, stdout=second_slave, stderr=second_slave)
            os.close(second_slave)
            try:
                read_terminal(second_master, "> ")
                before = len(endpoint.requests)
                os.write(first_master, b"wait for response\n")
                fixture.wait_for(lambda: len(endpoint.requests) > before, "held processing Message")
                assert len(endpoint.requests) == before + 1 and len(endpoint.responses) == 1
                first_progress = read_terminal(first_master, "> ")
                assert "Allow once, deny, or later?" not in first_progress, first_progress
                os.write(second_master, b"queued behind slow work\n")
                waiting = read_terminal(second_master, ("1 message queued", "Ctrl-R: submission unconfirmed"))
                # A pre-existing pending-view reply can precede the second
                # capture. Saved exact intent, not a count notice, is authority.
                queued_record, = fixture.wait_for(lambda: [path
                    for path in (home / ".config/rui/requests").glob("*.json")
                    if (record := json.loads(path.read_text())).get("session") == progress_session
                    and record.get("kind") == "message"
                    and record["text"]["value"] == "queued behind slow work"], "second frontend durable capture")
                handle = queued_record.stem
                # Classification/transport failure is not admission. Exercise
                # explicit recovery of the sole capture, never a second Enter.
                recovery_end = time.monotonic() + 15
                while "1 message queued" not in waiting:
                    assert "Submission unconfirmed" in waiting, waiting
                    os.write(second_master, b"\x12")
                    recovered = read_terminal(second_master,
                        ("1 message queued", "Ctrl-R: submission unconfirmed"), timeout=recovery_end - time.monotonic())
                    assert "request: " not in recovered, "recovery created new intent"
                    waiting += recovered
                assert len([path for path in (home / ".config/rui/requests").glob("*.json")
                    if json.loads(path.read_text()).get("session") == progress_session
                    and json.loads(path.read_text()).get("kind") == "message"]) == 2
                assert json.loads((home / ".config/rui/requests" / (handle + ".json")).read_text())["text"]["value"] == "queued behind slow work"
                def queued_admission():
                    report = fixture.command("inspect-session", "--store", store, "--session", progress_session)
                    return report if report["pending_messages"] == "1" else None
                queued = fixture.wait_for(queued_admission, "queued admission behind active Message")
                assert queued["selected_message"] is not None and queued["work"]["status"] == "in_flight", queued
                assert "1 message queued" in waiting and len(endpoint.responses) == 1, waiting
                progress_release.set()
                first_answer = read_terminal(first_master, "second completed")
                second_answer = read_terminal(second_master, "second completed")
                for answer in (first_answer, second_answer):
                    assert answer.count("first completed") == 1 and answer.count("second completed") == 1, answer
                assert "[admission · " not in first_progress + waiting + first_answer + second_answer, "pending admission became permanent transcript text"
                detach_terminal(second_master, second_caller)
            finally:
                progress_release.set()
                if second_caller.poll() is None:
                    second_caller.kill()
                    second_caller.wait(timeout=5)
                os.close(second_master)
            detach_terminal(first_master, first_caller)
        finally:
            progress_release.set()
            if first_caller.poll() is None:
                first_caller.kill()
                first_caller.wait(timeout=5)
            os.close(first_master)
        observation_release = threading.Event()
        observation_started = threading.Event()
        observation_continue = threading.Event()
        observation_proxy = ObservationProxy(host.rui_ready_fields["socket"])
        endpoint.responses.append((fixture.sse_answer("observed-later", "observed-later-reason",
            "observed-later-message", "observed later")[0], observation_release))
        master, slave = open_terminal()
        entered = subprocess.Popen([str(fixture.RUI), "--resume", empty_session, "--store", str(store)],
            env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            read_terminal(master, "> ")
            before = set(run(home, "requests").splitlines())
            os.write(master, b"observe after Host loss\n")
            fixture.wait_for(lambda: len(set(run(home, "requests").splitlines()) - before) == 1,
                "captured Message before Host crash")
            after = set(run(home, "requests").splitlines())
            assert len(after - before) == 1, (before, after)
            saved_key = (after - before).pop()
            # This footer is emitted only after the terminal has consumed the
            # accepted reply and released the admission owner. An independent
            # observe-command would establish only the Host's committed fact.
            confirmed = read_terminal(master, "Working...")
            assert "Submission unconfirmed" not in confirmed, confirmed
            accepted_before_read = len(observation_proxy.starts)
            def hold_confirmed_view(command, start_index):
                if start_index >= accepted_before_read and command["kind"] == "session_view" and command["session"] == empty_session:
                    observation_started.set()
                    assert observation_continue.wait(15), "confirmed observation gate not released"
                    return False
            observation_proxy.before_exchange = hold_confirmed_view
            assert observation_started.wait(15), "no observation after terminal accepted admission"
            assert any(c["kind"] == "session_view" for c in observation_proxy.starts[accepted_before_read:])
            fixture.crash_host(host, state, "accepted-before-observation-loss")
            observation_continue.set()
            lost = read_terminal_end(master, entered)
            assert entered.returncode != 0, lost
            assert "unconfirmed" not in lost.lower() and "resubmit" not in lost.lower(), lost
            assert saved_key in lost, ("observation loss must preserve original-key guidance", lost)
            assert set(run(home, "requests").splitlines()) == after, "accepted capture was lost"
            observation_proxy.close()
            observation_proxy = None
            endpoint.responses.append(fixture.sse_answer("observed-recovery", "observed-recovery-reason",
                "observed-recovery-message", "observed after recovery")[0])
            host = fixture.start_host(store, url)
            assert fixture.command("observe-command", "--store", store,
                "--key", saved_key)["observation"]["status"] == "accepted"
        finally:
            observation_continue.set()
            observation_release.set()
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
            if observation_proxy is not None:
                observation_proxy.close()
        fixture.wait_for(lambda: fixture.completed_observation(store, saved_key), "accepted work recovered")
        fixture.stop_host(host)
        host = None
        fixture.wait_for(lambda: "Host: unavailable" in run(home, "host", "status", "--store", store),
            "Host stopped before resume")
        master, slave = open_terminal()
        managed_host = True
        entered = subprocess.Popen([str(fixture.RUI), "--resume", unsafe_session, "--store", str(store)],
            env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            replay = read_terminal(master, "> ")
            assert "Host ready" not in replay and f"Session: {unsafe_session}" in replay, replay
            assert "report status" in replay and "safe result" in replay, replay
            detach_terminal(master, entered)
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        completed = True
        print("human CLI: saved recovery, Session wait/re-entry, exact PTY approval, bounded input and Host restart passed")
    finally:
        sibling_release.touch()
        if failure_release is not None:
            failure_release.set()
        if stop_release is not None:
            stop_release.set()
        if observation_release is not None:
            observation_release.set()
        if progress_release is not None:
            progress_release.set()
        race_predecessor_release.set()
        race_message_release.set()
        resume_a_release.set()
        resume_b_release.set()
        resume_idle_release.set()
        if terminal_waiter is not None and terminal_waiter.poll() is None:
            terminal_waiter.kill()
            terminal_waiter.communicate(timeout=5)
        if race_follower is not None and race_follower.poll() is None:
            race_follower.kill()
            race_follower.communicate(timeout=5)
        if race_waiter is not None and race_waiter.poll() is None:
            race_waiter.kill()
            race_waiter.communicate(timeout=5)
        if host is not None:
            fixture.stop_host(host)
        if managed_host and "Host: ready" in run(home, "host", "status", "--store", store):
            run(home, "host", "stop", "--store", store)
            fixture.wait_for(lambda: "Host: unavailable" in run(home, "host", "status", "--store", store),
                "managed Host cleanup")
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained human CLI failure state: {state}", file=sys.stderr)


if __name__ == "__main__":
    main()

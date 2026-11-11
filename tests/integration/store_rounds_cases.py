#!/usr/bin/env python3
"""MySQL round trips a Host spends on one model operation, and while idle.

A relay between the Host and CI's live MySQL counts every COM_QUERY the Host
sends; each is one round trip, since the Store's connection waits for each
query's results before it sends the next. The Host runs from its launch
frame against a local h2 model endpoint. Each operation is one Message to a
Session whose model answers with text and no tool, so one operation is one
Turn.

BUDGET is the ratchet: a count above its bound fails, and so does an exact
count that moved down, so every round-trip cut lowers the table in the same
change. Commits and write round trips are exact, for a Session's first operation
and for each later one, and so are idle round trips. Total round trips per
operation are an upper bound while the Host still rescans after each
commit and the observe loop below polls, which makes them vary by a few
from run to run.

launch_frame_mysql_integration.py runs `run` after its own cases, with
the same arguments, so launch-frame-integration holds the budget wherever
CI starts MySQL. Like the other live MySQL integrations, it skips when RUI_TEST_MYSQL_* is
absent and fails when CI requires MySQL but omitted it.
"""
import asyncio
import json
import os
import secrets
import ssl
import subprocess
import tempfile
import threading
import time
from urllib.parse import quote

import h2_fixture
import host_process
import live_engines
import launch_frame_fixture as frame_host

WIRE = frame_host.WIRE
OPERATIONS = 4
IDLE_AFTER = 2
IDLE_SECONDS = 5

BUDGET = {
    # A Session's first operation, exact.
    "first_commits": 4,
    "first_write_round_trips": 10,
    # Each later operation, exact.
    "commits": 3,
    "write_round_trips": 7,
    # Any operation, upper bound: rescans and the observe loop below make
    # the total vary (29 for a first operation and 23 for a later one
    # over four runs once a lone write's COMMIT rode its last writes;
    # earlier work varied by up to 6).
    "round_trips": 35,
    # Over IDLE_SECONDS with no Session, exact: the Host asks again only
    # after a commit, a slot change or a scheduled retry falling due.
    "idle_round_trips": 0,
}
EXACT = ("first_commits", "first_write_round_trips", "commits", "write_round_trips", "idle_round_trips")


class Relay:
    """Forwards one Unix socket to mysqld byte for byte and records the
    text of each COM_QUERY the client sends."""

    def __init__(self, listen, upstream):
        self.listen, self.upstream = listen, upstream
        self.queries = []
        self.lock = threading.Lock()
        self.ready = threading.Event()
        self.failure = None
        threading.Thread(target=self._run, daemon=True).start()
        assert self.ready.wait(10), "the MySQL relay did not start within 10 s"
        if self.failure is not None:
            raise RuntimeError(f"the MySQL relay could not listen on {listen}") from self.failure

    def _run(self):
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            loop.run_until_complete(asyncio.start_unix_server(self._serve, path=self.listen))
        except BaseException as error:
            self.failure = error
            self.ready.set()
            return
        self.ready.set()
        loop.run_forever()

    def count(self):
        with self.lock:
            return len(self.queries)

    def since(self, start):
        with self.lock:
            return list(self.queries[start:])

    async def _serve(self, client_reader, client_writer):
        server_reader, server_writer = await asyncio.open_unix_connection(self.upstream)

        async def upstream():
            buffer = b""
            while data := await client_reader.read(65536):
                buffer += data
                while len(buffer) >= 4:
                    length = int.from_bytes(buffer[:3], "little")
                    if len(buffer) < 4 + length:
                        break
                    sequence, payload = buffer[3], buffer[4:4 + length]
                    buffer = buffer[4 + length:]
                    if sequence == 0 and payload[:1] == b"\x03":
                        with self.lock:
                            self.queries.append(payload[1:].decode("utf-8", "replace"))
                server_writer.write(data)
                await server_writer.drain()
            server_writer.close()

        async def downstream():
            while data := await server_reader.read(65536):
                client_writer.write(data)
                await client_writer.drain()
            client_writer.close()

        await asyncio.gather(upstream(), downstream(), return_exceptions=True)


def shape(queries):
    """Commits and the round trips of write transactions, START TRANSACTION
    through COMMIT or ROLLBACK."""
    commits = write_round_trips = 0
    open_transaction = 0
    for text in queries:
        # Every message starts with the session settings, none holding ';'.
        while text.lstrip().upper().startswith("SET "):
            text = text.split(";", 1)[1] if ";" in text else ""
        if open_transaction == 0 and not text.lstrip().startswith("START TRANSACTION"):
            continue
        open_transaction += 1
        tail = text.rstrip().rstrip(";").upper()
        if tail.endswith("COMMIT") or tail.endswith("ROLLBACK"):
            commits += tail.endswith("COMMIT")
            write_round_trips += open_transaction
            open_transaction = 0
    return commits, write_round_trips


def run(rui, admin):
    socket = os.environ.get(live_engines.MYSQL_SOCKET)
    password = os.environ.get(live_engines.MYSQL_ROOT_PASSWORD)
    if not socket or not password:
        assert "mysql" not in os.environ.get(live_engines.REQUIRE, "").split(","), "CI required MySQL but did not supply it"
        print("Store round trips: skipped (no RUI_TEST_MYSQL_* server)")
        return
    root = host_process.canonical_fixture_root(tempfile.mkdtemp(prefix="rui-store-rounds-"))

    def sql(text):
        return subprocess.run([admin], input=text, text=True, capture_output=True, check=True).stdout.strip()

    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", root / "key.pem", "-out", root / "cert.pem",
                    "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"], check=True, capture_output=True)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(root / "cert.pem", root / "key.pem")
    tls.set_alpn_protocols(["h2"])
    endpoint = h2_fixture.Endpoint(tls, 1, sse=True)
    threading.Thread(target=endpoint.serve_forever, daemon=True).start()
    relay = Relay(str(root / "relay.sock"), socket)

    database = "rui_rounds_" + secrets.token_hex(6)
    ddl = subprocess.run([rui, "store", "schema", "--engine", "mysql"], check=True, capture_output=True, text=True).stdout
    sql(f"CREATE DATABASE {database} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_bin;USE {database};" + ddl)
    runtime = root / "run"
    runtime.mkdir(mode=0o700)
    sock = runtime / "rui.sock"
    preset = {"model": "gpt-6.1-sol", "effort": "low", "compactAt": 100000, "tools": [], "permissionMode": "ask", "label": "Rounds"}
    value = {"v": 1, "store": f"mysql://root:{quote(password, safe='')}@{quote(str(root / 'relay.sock'), safe='')}/{database}",
             "runtimeDir": str(runtime), "activeCapacity": 1, "presets": {"rounds": preset},
             "provider": {"kind": "openai_key", "baseUrl": f"https://localhost:{endpoint.server_address[1]}/v1", "key": "sk-rounds",
                          "caFile": str(root / "cert.pem")}}
    env = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ}
    host = subprocess.Popen([rui, "host", "serve", "--launch-frame"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=open(root / "host.err", "wb"), env=env)
    host.stdin.write(frame_host.frame(value))
    host.stdin.flush()
    measured = {}
    try:
        frame_host.wait_for_host(sock, "", host)
        store = frame_host.host_info(sock, "")["store"]

        def post(route, **fields):
            return frame_host.post(sock, route, {"version": WIRE, "kind": route.replace("-", "_"), "store": store, **fields})

        # A measurement window, not an ordering wait: count what the Host
        # sends from IDLE_AFTER to IDLE_AFTER + IDLE_SECONDS after it is
        # ready, past the queries of its startup.
        ready = time.monotonic()
        counts = {}

        def window_closed():
            elapsed = time.monotonic() - ready
            if elapsed >= IDLE_AFTER:
                counts.setdefault("start", relay.count())
            if elapsed >= IDLE_AFTER + IDLE_SECONDS:
                counts["end"] = relay.count()
            return "end" in counts

        host_process.wait_for(window_closed, "the idle window", timeout=IDLE_AFTER + IDLE_SECONDS + 5)
        measured["idle_round_trips"] = counts["end"] - counts["start"]

        configured = post("configure", key="config", session="", preset="rounds", configuration={"label": {"state": "null"}})
        assert configured["answer"]["status"] == "accepted", configured
        session = configured["answer"]["session"]

        per_operation = []
        for index in range(OPERATIONS):
            start = relay.count()
            key = f"message-{index}"
            sent = frame_host.post(sock, "message", {"version": WIRE, "kind": "message", "store": store, "key": key, "session": session,
                                                     "sender": None, "sender_handle": None,
                                                     "text": {"state": "value", "value": f"rounds-{index}"}},
                                   extra=b"X-Rui-Environment-Bytes: 0\r\n")
            assert sent["answer"]["status"] == "accepted", sent
            since = None

            def completed():
                nonlocal since
                assert host.poll() is None, "the Host exited"
                reply = post("observe-command", key=key, since=since)
                since = reply.get("since")
                observed = reply.get("observation")
                result = observed.get("result") if observed is not None else None
                assert result is None or result["status"] == "completed", observed
                return result is not None

            host_process.wait_for(completed, f"operation {index} to finish", timeout=60, interval=0.05)
            queries = relay.since(start)
            commits, write_round_trips = shape(queries)
            per_operation.append({"round_trips": len(queries), "commits": commits, "write_round_trips": write_round_trips})
        for name in ("round_trips", "commits", "write_round_trips"):
            print(f"Store round trips: {name} per operation {[operation[name] for operation in per_operation]}")
        first, later = per_operation[0], per_operation[1:]
        measured["first_commits"] = first["commits"]
        measured["first_write_round_trips"] = first["write_round_trips"]
        for name in ("commits", "write_round_trips"):
            values = {operation[name] for operation in later}
            assert len(values) == 1, f"later operations differ in {name}: {sorted(values)}"
            measured[name] = values.pop()
        measured["round_trips"] = max(operation["round_trips"] for operation in per_operation)
    finally:
        host_process.close_stdin(host)
        try:
            host.wait(timeout=30)
        except subprocess.TimeoutExpired:
            host.kill()
        try:
            sql(f"DROP DATABASE IF EXISTS {database}")
        except subprocess.CalledProcessError:
            pass
    print("Store round trips: " + json.dumps(measured))
    failures = []
    for name, bound in BUDGET.items():
        if measured[name] > bound:
            failures.append(f"{name} is {measured[name]}, above its budget {bound}")
        elif name in EXACT and measured[name] < bound:
            failures.append(f"{name} fell to {measured[name]}: lower its budget from {bound}")
    assert not failures, "; ".join(failures)

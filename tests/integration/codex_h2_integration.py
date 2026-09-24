#!/usr/bin/env python3
"""Synthetic managed transfer through native TLS/HTTP2 with observed reuse."""

import os
import pathlib
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading

import codex_integration as codex
import dispatch_integration as fixture
import transport_h2_integration as h2_fixture
from host_process import HostDiagnostics, start_ready_process


def run():
    root = pathlib.Path(tempfile.mkdtemp(prefix="rui-codex-h2.")).resolve()
    private = root / "private"
    private.mkdir(mode=0o700)
    path = private / "codex.json"
    codex.credentials(path)
    os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(path)
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"),
        "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(root / "cert.pem", root / "key.pem")
    tls.set_alpn_protocols(["h2"])
    endpoint = h2_fixture.Endpoint(tls, 1, sse=True, eager_sse=True)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    host = None
    diagnostics = None
    complete = False
    store = root / "store"
    try:
        # Inherited stdio (3), fixed Host (9/11), clients (42), one execution
        # place (10), auth worker (8/10), and self-wake (1). Keep the fixture's
        # descriptor limit on the Host child, not its TLS peer or callers.
        required = {"linux": 73, "darwin": 77}[sys.platform]
        serve = [fixture.RUI, "serve", "--store", store, "--active-capacity", "1",
                 "--test-codex-fixture-endpoint", f"https://localhost:{endpoint.server_address[1]}/responses",
                 "--provider-ca-file", root / "cert.pem", "--test-phase-trace"]
        def limited(limit):
            return ["sh", "-c", 'ulimit -n "$1"; shift; exec "$@"',
                    "rui-managed-descriptors", str(limit), *serve]

        rejected = subprocess.run(limited(required - 1), capture_output=True, text=True, timeout=15)
        assert rejected.returncode != 0 and "descriptor capacity insufficient" in rejected.stderr, rejected.stderr
        assert f"required={required}" in rejected.stderr and "authentication=" in rejected.stderr
        assert not store.exists(), "managed capacity rejection created Store files"
        host, _ = start_ready_process(
            limited(required),
            required_fields={"execution": "enabled", "curl": "8.22.0",
                             "descriptor_requirement": str(required), "descriptor_limit": str(required)},
        )
        diagnostics = HostDiagnostics(host)
        configuration = fixture.command(
            "configure", "--store", store, "--record", root / "config.json", "--key", "config",
            "--session", "managed/h2", "--workspace", fixture.ROOT, "--provider", "codex",
            "--model", "model-a", "--tools", "none",
        )
        assert configuration["answer"]["status"] == "accepted"
        for index in range(2):
            key = f"message-{index}"
            text = f"managed-{index}"
            fixture.message(root, store, key, "managed/h2", text)
            fixture.wait_for(lambda key=key: fixture.completed_observation(store, key),
                             f"managed H2 answer {index}", timeout=20)
            expected = f"answer-{text}" if index == 0 else "L" * 8192 + text
            assert fixture.read_result(store, key) == expected.encode()
            fixture.wait_for(
                lambda: fixture.command("inspect-session", "--store", store, "--session", "managed/h2")["execution"]["custody_occupied"] == "0",
                "managed transfer teardown", timeout=20,
            )
        # Fixture-only replacement after all leases retire proves the next
        # launch derives the conditional header from the selected generation.
        codex.credentials(path, fedramp=True)
        fixture.message(root, store, "federal", "managed/h2", "managed-federal")
        fixture.wait_for(lambda: fixture.completed_observation(store, "federal"),
                         "FedRAMP fixture answer", timeout=20)
        assert fixture.read_result(store, "federal") == b"answer-managed-federal"
        assert len(endpoint.streams) == 3 and len(endpoint.connections) == 1
        assert len({stream for _, stream, _, _ in endpoint.streams}) == 3
        session_ids = {headers[b"session-id"] for headers in endpoint.request_headers}
        assert len(session_ids) == 1 and re.fullmatch(rb"[0-9a-f]{32}", next(iter(session_ids)))
        for headers in endpoint.request_headers[:2]:
            assert headers[b":path"] == b"/responses"
            assert headers[b"authorization"] == ("Bearer " + codex.ACCESS).encode()
            assert headers[b"chatgpt-account-id"] == codex.ACCOUNT.encode()
            assert headers[b"originator"] == b"rui"
            assert b"x-openai-fedramp" not in headers
        assert endpoint.request_headers[2][b"x-openai-fedramp"] == b"true"
        assert endpoint.request_headers[2][b"authorization"] == ("Bearer " + codex.ACCESS).encode()
        assert endpoint.request_headers[2][b"originator"] == b"rui"
        observations = diagnostics.matching("codex_transfer")
        assert len(observations) == 3, observations
        assert [row["http_version"] for row in observations] == [3, 3, 3], observations
        assert observations[0]["connection_id"] >= 0 and len({row["connection_id"] for row in observations}) == 1, observations
        assert [row["new_connections"] for row in observations] == [1, 0, 0], observations
        print("codex synthetic TLS/H2 production transfers passed: ALPN h2, one connection, three streams, curl version 3, reuse 1/0/0, conditional FedRAMP header")
        complete = True
    finally:
        if host is not None:
            fixture.stop_host(host)
        if diagnostics is not None:
            diagnostics.close()
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if complete:
            shutil.rmtree(root)
        else:
            print(f"retained Codex H2 fixture failure state: {root}", file=sys.stderr)


if __name__ == "__main__":
    run()

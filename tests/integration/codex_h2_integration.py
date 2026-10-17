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
import time

import codex_integration as codex
import model_fixture as fixture
import transport_h2_integration as h2_fixture
from host_process import HostDiagnostics, start_ready_process


def assert_managed_descriptor_rejection(rejected, limit):
    assert rejected.returncode != 0 and "descriptor capacity insufficient" in rejected.stderr, rejected.stderr
    assert not rejected.stdout.startswith("ready "), rejected.stdout
    fields = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", rejected.stderr)}
    # As in descriptor_capacity_integration, macOS libmalloc can open one
    # inherited socket. Validate every Host-owned population independently.
    inherited = fields["inherited"]
    assert inherited in ({3, 4} if sys.platform == "darwin" else {3}), fields
    fixed_host = 11 if sys.platform == "darwin" else 9
    authentication = 10 if sys.platform == "darwin" else 8
    # 100 ordinary exchanges at four descriptors, two controls and discovery.
    required = inherited + fixed_host + 403 + 10 + authentication + 2
    expected = dict(active_capacity=1, required=required, soft_limit=limit,
                    inherited=inherited, fixed_host=fixed_host, clients=403,
                    execution=10, authentication=authentication, self_wake=2)
    assert fields == expected, (fields, expected)
    print(f"managed descriptor rejection passed: {expected}", flush=True)
    return required


def run(*, observed=False):
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
        # Probe below the minimum inherited population, then test the exact
        # adjacent boundary observed before any Host-owned descriptors open.
        minimum_required = {"linux": 435, "darwin": 439}[sys.platform]
        serve = [fixture.RUI, "serve", "--store", store, "--active-capacity", "1",
                 "--test-codex-fixture-endpoint", f"https://localhost:{endpoint.server_address[1]}/responses",
                 "--provider-ca-file", root / "cert.pem", "--test-phase-trace"]
        def limited(limit):
            return ["sh", "-c", 'ulimit -n "$1"; shift; exec "$@"',
                    "rui-managed-descriptors", str(limit), *serve]

        rejected = subprocess.run(limited(minimum_required - 1), capture_output=True, text=True, timeout=15)
        required = assert_managed_descriptor_rejection(rejected, minimum_required - 1)
        assert not store.exists(), "managed capacity rejection created Store files"
        if required != minimum_required:
            rejected = subprocess.run(limited(required - 1), capture_output=True, text=True, timeout=15)
            assert assert_managed_descriptor_rejection(rejected, required - 1) == required, rejected.stderr
            assert not store.exists(), "managed capacity rejection created Store files"
        # Execute the same complete workload at the exact production limit
        # and separately with the native channel's two inherited descriptors.
        limit = required + (2 if observed else 0)
        host, _ = start_ready_process(
            limited(limit), observations="managed" if observed else None,
            required_fields={"execution": "enabled", "curl": "8.22.0",
                             "descriptor_requirement": str(limit), "descriptor_limit": str(limit)},
        )
        diagnostics = HostDiagnostics(host)
        configuration = fixture.command(
            "configure", "--store", store, "--record", root / "config.json", "--key", "config",
            "--session", "managed/h2", "--workspace", fixture.ROOT, "--provider", "codex",
            "--model", "model-a", "--tools", "none",
        )
        assert configuration["answer"]["status"] == "accepted"
        observations = []
        for index in range(3):
            if index == 2:
                # Replace only after the previous lease/custody retired.
                codex.credentials(path, fedramp=True)
            key = "federal" if index == 2 else f"message-{index}"
            text = "managed-federal" if index == 2 else f"managed-{index}"
            fixture.message(root, store, key, "managed/h2", text)
            deadline = time.monotonic() + 20
            observation, answer, _ = fixture.wait_for_result_release(
                store, key, "managed/h2", deadline,
            )
            if observed:
                processing = observation["processing"]
                preparations = fixture.wait_for(
                    lambda: diagnostics.matching("preparation_completed", **processing),
                    "preparation_completed", deadline=deadline,
                )
                assert len(preparations) == 1, preparations
                transfers = fixture.wait_for(
                    lambda: diagnostics.matching("codex_transfer", operation=processing["operation"]),
                    "codex_transfer", deadline=deadline,
                )
                assert len(transfers) == 1, transfers
                observations.append(transfers[0])
            assert observation["result"]["status"] == "completed", observation
            expected = "L" * 8192 + text if index == 1 else f"answer-{text}"
            assert answer == expected.encode(), answer
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
        if observed:
            assert len(observations) == 3, observations
            assert [row["http_version"] for row in observations] == ["3", "3", "3"], observations
            assert int(observations[0]["connection_id"]) >= 0 and len({row["connection_id"] for row in observations}) == 1, observations
            assert [row["new_connections"] for row in observations] == ["1", "0", "0"], observations
        print(f"codex synthetic TLS/H2 production transfers passed: descriptor_limit={limit}, native_receipts={observed}, ALPN h2, one connection, three streams, conditional FedRAMP header")
        complete = True
    finally:
        incoming_error = sys.exc_info()[1]
        errors = []
        for dispose in (lambda: fixture.stop_host(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5)):
            try:
                dispose()
            except BaseException as error:
                errors.append(error)
        try:
            if complete and observed and diagnostics is not None:
                assert len(diagnostics.matching("codex_transfer")) == 3, diagnostics.records
                assert len(diagnostics.matching("preparation_completed")) == 3, diagnostics.records
                # This Host has no injected before-launch delay, so it emits
                # no delayed-handoff receipts. Both endpoints are mandatory.
                assert len(diagnostics.records) == 6, diagnostics.records
        except BaseException as error:
            diagnostics.snapshot_failure(lambda: {"case": "codex_h2_final_population"})
            diagnostics.observations.preserve_failure(getattr(host, "rui_failure_snapshot", None))
            errors.append(error)
        if thread.is_alive():
            errors.append(AssertionError("Codex H2 endpoint thread did not retire"))
        if complete and incoming_error is None and not errors:
            shutil.rmtree(root)
        else:
            print(f"retained Codex H2 fixture failure state: {root}", file=sys.stderr)
        if errors:
            if incoming_error is None:
                raise errors[0]
            incoming_error.add_note("Codex H2 cleanup failed: " + ", ".join(type(error).__name__ for error in errors))


if __name__ == "__main__":
    run()
    run(observed=True)

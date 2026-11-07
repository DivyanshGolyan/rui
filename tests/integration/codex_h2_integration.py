#!/usr/bin/env python3
"""Synthetic managed transfer through native TLS/HTTP2 with observed reuse."""

import json
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
import host_process
from host_process import HostDiagnostics, dispose_all, retain_failure_state, start_ready_process
import os_semantics


def assert_managed_descriptor_rejection(rejected, limit):
    assert rejected.returncode != 0 and "descriptor capacity insufficient" in rejected.stderr, rejected.stderr
    assert not rejected.stdout.startswith("ready "), rejected.stdout
    fields = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", rejected.stderr)}
    # As in descriptor_capacity_integration, macOS libmalloc can open one
    # inherited socket. Validate every Host-owned population independently.
    inherited = fields["inherited"]
    assert inherited in os_semantics.INHERITED_DESCRIPTORS, fields
    fixed_host = os_semantics.HOST_FIXED_DESCRIPTORS
    authentication = os_semantics.AUTHENTICATION_DESCRIPTORS
    # 100 ordinary exchanges at four descriptors, two controls and discovery.
    required = inherited + fixed_host + 403 + 10 + authentication + 2
    expected = dict(active_capacity=1, required=required, soft_limit=limit,
                    inherited=inherited, fixed_host=fixed_host, clients=403,
                    execution=10, authentication=authentication, self_wake=2)
    assert fields == expected, (fields, expected)
    assert limit < required - 4 * (100 - 10), "only below-minimum intake may be refused"
    print(f"managed descriptor rejection passed: {expected}", flush=True)
    return required


def run(*, observed=False, intake=100):
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
        # These totals describe default intake100, not the refusal boundary.
        # Ten ordinary clients remain viable after dropping 90 * 4 descriptors.
        # Three inherited, fixed Host, 100 ordinary exchanges at four, two
        # controls and discovery, authentication, and the intake wake pair.
        default_required = 3 + os_semantics.HOST_FIXED_DESCRIPTORS + 403 + 10 + os_semantics.AUTHENTICATION_DESCRIPTORS + 2
        minimum_required = default_required - 4 * (100 - 10)
        serve = [fixture.RUI, "host", "serve", "--store", store, "--active-capacity", "1",
                 "--test-codex-fixture-endpoint", f"https://localhost:{endpoint.server_address[1]}/responses",
                 "--provider-ca-file", root / "cert.pem", "--test-phase-trace"]
        def limited(limit):
            return ["sh", "-c", 'set -e; ulimit -Sn "$1"; ulimit -Hn "$1"; shift; exec "$@"',
                    "rui-managed-descriptors", str(limit), *serve]

        rejected = subprocess.run(limited(minimum_required - 1), capture_output=True, text=True, timeout=15)
        required = assert_managed_descriptor_rejection(rejected, minimum_required - 1)
        assert not store.exists(), "managed capacity rejection created Store files"
        actual_minimum = required - 4 * (100 - 10)
        if actual_minimum != minimum_required:
            rejected = subprocess.run(limited(actual_minimum - 1), capture_output=True, text=True, timeout=15)
            assert assert_managed_descriptor_rejection(rejected, actual_minimum - 1) == required, rejected.stderr
            assert not store.exists(), "managed capacity rejection created Store files"
        # Execute the same complete workload at the exact production limit
        # at default and minimum intake; retain the separate default-intake
        # native channel run accounting for its two inherited descriptors.
        limit = required - 4 * (100 - intake) + (2 if observed else 0)
        host, _ = start_ready_process(
            limited(limit), observations="managed" if observed else None,
            required_fields={"execution": "enabled", "nghttp2": "1.70.0", "intake_capacity": str(intake),
                             "descriptor_requirement": str(limit), "descriptor_limit": str(limit)},
        )
        diagnostics = HostDiagnostics(host)
        configuration = fixture.command(
            "session", "configure", "--store", store, "--record", root / "config.json", "--key", "config",
            "--workspace", fixture.ROOT, "--provider", "codex",
            "--model", "gpt-6-sol", "--tools", "none",
        )
        assert configuration["answer"]["status"] == "accepted"
        session = configuration["answer"]["session"]
        observations = []
        for index in range(3):
            if index == 2:
                # Replace only after the previous lease/custody retired.
                codex.credentials(path, fedramp=True)
            key = "federal" if index == 2 else f"message-{index}"
            text = "managed-federal" if index == 2 else f"managed-{index}"
            fixture.message(root, store, key, session, text)
            deadline = time.monotonic() + 20
            observation, answer, _ = fixture.wait_for_result_release(
                store, key, session, deadline,
            )
            if observed:
                processing = observation["binding"]
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
        expected_agent = codex.expected_user_agent().encode()
        for headers, (_, _, _, body) in zip(endpoint.request_headers, endpoint.streams, strict=True):
            assert headers[b"user-agent"] == expected_agent, headers
            request = json.loads(body)
            assert request["text"] == {"verbosity": "low"}, request
            assert request["parallel_tool_calls"] is True, request
        # The codec's headers follow h2's and content-type, ahead of the
        # credential path's fields.
        for index, headers in enumerate(endpoint.request_headers):
            regular = [name for name in headers if not name.startswith(b":")]
            assert regular == [b"content-length", b"accept-encoding", b"content-type",
                               b"accept", b"session-id", b"originator",
                               b"authorization", b"chatgpt-account-id", b"user-agent",
                               *([b"x-openai-fedramp"] if index == 2 else [])], regular
            assert headers[b"accept"] == b"text/event-stream", headers
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
            # One connection opened by the first transfer, reused by the next two.
            assert [row["new_connections"] for row in observations] == ["1", "0", "0"], observations
            assert [row["replays"] for row in observations] == ["0", "0", "0"], observations
        print(f"codex synthetic TLS/H2 production transfers passed: intake_capacity={intake}, descriptor_limit={limit}, native_receipts={observed}, ALPN h2, one connection, three streams, conditional FedRAMP header")
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
            retain_failure_state("Codex H2 fixture failure state", root)
        if errors:
            if incoming_error is None:
                raise errors[0]
            incoming_error.add_note("Codex H2 cleanup failed: " + ", ".join(type(error).__name__ for error in errors))


def openai_base_url_run(*, catalog_available=False):
    """RUI_OPENAI_BASE_URL sends the OpenAI key to the Responses endpoint
    under that base, over TLS, and nowhere else. The model list holds a
    stream of its own: with one execution place and a peer allowing one
    stream per connection, a message completes while the list is held."""
    root = pathlib.Path(tempfile.mkdtemp(prefix="rui-openai-base.")).resolve()
    private = root / "private"
    private.mkdir(mode=0o700)
    key_file = private / "openai.key"
    key_file.write_text(codex.OPENAI_KEY + "\n")
    key_file.chmod(0o600)
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"),
        "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(root / "cert.pem", root / "key.pem")
    tls.set_alpn_protocols(["h2"])
    endpoint = h2_fixture.Endpoint(tls, 1, sse=True, eager_sse=True)
    endpoint.models_release = threading.Event()
    endpoint.max_streams = 1
    if catalog_available:
        endpoint.catalog = b'{"openai":{"models":{"catalog-only":{"limit":{"context":123}}}}}'
    endpoint.models = json.dumps({"object": "list", "data": [
        {"id": "gpt-6-sol", "object": "model", "created": 1, "owned_by": "openai"},
        {"id": "custom-model", "object": "model", "created": 2, "owned_by": "you"},
    ]}).encode()
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    store = root / "store"
    host = None
    complete = False
    try:
        catalog_url = f"https://localhost:{endpoint.server_address[1]}/api.json" if catalog_available else "https://127.0.0.1:1/api.json"
        # A served provider uses system trust, which this certificate joins.
        host, ready = start_ready_process([fixture.RUI, "host", "serve", "--store", store, "--provider", "openai", "--active-capacity", "1",
            "--test-models-dev-url", catalog_url], env={
            **os.environ, "RUI_OPENAI_KEY_FILE": str(key_file), "SSL_CERT_FILE": str(root / "cert.pem"),
            "RUI_OPENAI_BASE_URL": f"https://localhost:{endpoint.server_address[1]}/custom/v1/",
        })
        def model_list():
            return h2_fixture.closed_host_request(ready["socket"], store, "model_list")["providers"]
        assert model_list()[0]["source"] == "pending", model_list()
        configuration = fixture.command(
            "session", "configure", "--store", store, "--record", root / "config.json", "--key", "config",
            "--workspace", fixture.ROOT, "--provider", "openai", "--model", "gpt-6-sol", "--tools", "none",
        )
        assert configuration["answer"]["status"] == "accepted", configuration
        session = configuration["answer"]["session"]
        fixture.message(root, store, "custom-base", session, "custom-base")
        observation, answer, _ = fixture.wait_for_result_release(store, "custom-base", session, time.monotonic() + 20)
        assert observation["result"]["status"] == "completed", observation
        assert answer == b"answer-custom-base", answer
        # Listing requests while the initial GET is held do not start another.
        assert model_list()[0]["source"] == "pending", model_list()
        # Record the simultaneous held population before releasing either
        # discovery response. Later refreshes may retire/reopen connections.
        assert len(endpoint.connections) == (3 if catalog_available else 2), endpoint.connections
        endpoint.models_release.set()
        listed = fixture.wait_for(
            lambda: (value if (value := model_list())[0]["source"] != "pending" else None),
            "the OpenAI model list", timeout=20)
        assert listed == [{"provider": "openai", "source": "live", "models": [
            {"id": "gpt-6-sol", "known": True}, {"id": "custom-model", "known": False}]}], listed
        def provider_headers():
            return [headers for headers in endpoint.request_headers if headers[b":path"] != b"/api.json"]
        fixture.wait_for(
            lambda: len(provider_headers()) >= 3,
            "a model-list request refreshes the provider list again", timeout=20)
        # The key goes only to the list and Responses endpoint beside it.
        paths = [(headers[b":method"], headers[b":path"]) for headers in provider_headers()]
        assert paths[:2] == [(b"GET", b"/custom/v1/models"), (b"POST", b"/custom/v1/responses")], paths
        assert all(path == (b"GET", b"/custom/v1/models") for path in paths[2:]), paths
        for headers in provider_headers():
            assert headers[b":authority"].startswith(b"localhost:"), headers
            assert headers[b"authorization"] == ("Bearer " + codex.OPENAI_KEY).encode(), headers
            assert b"chatgpt-account-id" not in headers, headers
        assert b"content-length" not in provider_headers()[0], provider_headers()[0]
        if catalog_available:
            # The raw catalog is saved, then used conditionally by the next
            # refresh. The test only observes the network owner boundary.
            def revalidated():
                model_list()
                return next((headers for headers in endpoint.request_headers
                             if headers[b":path"] == b"/api.json" and b"if-none-match" in headers), None)
            conditional = fixture.wait_for(revalidated, "the saved catalog ETag on the next GET", timeout=20)
            assert conditional[b"if-none-match"] == b'"catalog-v1"', conditional
            for headers in endpoint.request_headers:
                if headers[b":path"] == b"/api.json":
                    assert b"authorization" not in headers and b"chatgpt-account-id" not in headers, headers
                    assert headers[b"accept-encoding"] == b"identity", headers
        print("openai base URL passed: a message completes beside held discovery GETs; repeated model-list requests refresh again; "
              + ("models.dev saves its ETag and revalidates without credentials" if catalog_available else "unreachable models.dev does not block Host readiness or the model list"))
        # A new Host whose list response is invalid publishes the catalog fallback.
        fixture.stop_host(host)
        host = None
        endpoint.models = b'{"error":"model list unavailable"}'
        host, ready = start_ready_process([fixture.RUI, "host", "serve", "--store", store, "--provider", "openai", "--active-capacity", "1"], env={
            **os.environ, "RUI_OPENAI_KEY_FILE": str(key_file), "SSL_CERT_FILE": str(root / "cert.pem"),
            "RUI_OPENAI_BASE_URL": f"https://localhost:{endpoint.server_address[1]}/custom/v1/",
        })
        fallback = fixture.wait_for(
            lambda: (value if (value := model_list())[0]["source"] != "pending" else None),
            "the OpenAI catalog fallback", timeout=20)
        assert fallback[0]["source"] == "catalog_fallback", fallback
        assert fallback[0]["models"] and all(model["known"] for model in fallback[0]["models"]), fallback
        print("openai catalog fallback passed: failed live list exposes catalog_fallback with known catalog models")
        complete = True
    finally:
        def retire():
            thread.join(timeout=5)
            assert not thread.is_alive(), "OpenAI base URL endpoint thread did not retire"
        cleaned = False
        try:
            # Every disposal runs; a body failure stays primary.
            dispose_all(lambda: fixture.stop_host(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, retire)
            cleaned = True
        finally:
            if complete and cleaned:
                shutil.rmtree(root)
            else:
                retain_failure_state("OpenAI base URL failure state", root)


def catalog_unusable_proxy_run():
    """Catalog-only Client initialization is optional; provider setup is not."""
    root = pathlib.Path(tempfile.mkdtemp(prefix="rui-catalog-proxy.")).resolve()
    home = root / "home"
    home.mkdir()
    env = {**os.environ, "HOME": str(home), "HTTPS_PROXY": "socks5://127.0.0.1:1080"}
    complete = False
    try:
        for capacity in (0, 1):
            store = root / f"store-{capacity}"
            log = root / f"host-{capacity}.stderr"
            host = None
            try:
                host, ready = start_ready_process([
                    "sh", "-c", 'log=$1; shift; exec "$@" 2>"$log"', "rui-catalog-proxy", log,
                    *fixture.host_arguments(store, None, active_capacity=capacity),
                    "--test-models-dev-url", "https://127.0.0.1:1/api.json",
                ], env=env, required_fields={"execution": "unavailable", "active_capacity": str(capacity)})
                diagnostic = b"rui: models.dev catalog unavailable (HttpsProxySchemeUnsupported); the saved catalog stands\n"
                for _ in range(3):
                    listed = h2_fixture.closed_host_request(ready["socket"], store, "model_list")
                    assert listed["providers"] == [], listed
                    info = h2_fixture.closed_host_request(ready["socket"], store, "host_info")
                    assert info["active_capacity"] == str(capacity), info
                assert host.poll() is None, host.returncode
            finally:
                if host is not None:
                    fixture.stop_host(host)
            # Optional output can be absent; validate all bytes after writer retirement.
            stderr = log.read_bytes()
            assert stderr in (b"", diagnostic), stderr
        # Even an HTTP provider shares Engine.init's proxy validation. Do not
        # swallow its failure or retry without the inherited network policy.
        required = subprocess.run([
            *fixture.host_arguments(root / "required-provider", "http://127.0.0.1:1/responses"),
            "--test-models-dev-url", "https://127.0.0.1:1/api.json",
        ], env=env, capture_output=True, text=True, timeout=10)
        assert required.returncode != 0, required
        assert "transport reactor initialization failure: HttpsProxySchemeUnsupported" in required.stderr, required
        assert "models.dev catalog unavailable" not in required.stderr, required
        print("catalog proxy failure passed: provider-free Hosts stay responsive at capacity 0 and 1; provider setup still fences")
        complete = True
    finally:
        if complete:
            shutil.rmtree(root)
        else:
            retain_failure_state("catalog proxy failure state", root)


def catalog_unusable_trust_run():
    """Optional HTTPS discovery cannot fence a cleartext provider's Reactor."""
    root = pathlib.Path(tempfile.mkdtemp(prefix="rui-catalog-trust.")).resolve()
    payload, _, _ = fixture.sse_answer("http-response", "reasoning", "message", "HTTP still works")
    endpoint = fixture.SuccessEndpoint([payload])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    store = root / "store"
    log = root / "host.stderr"
    host = None
    complete = False
    try:
        # The shared boundary disables discovery for every descendant, not
        # just start_ready_process callers. Bad HTTPS trust must be irrelevant
        # to an ordinary HTTP fixture unless the catalog case opts in below.
        host, ready = start_ready_process([
            "sh", "-c", 'log=$1; shift; exec "$@" 2>"$log"', "rui-catalog-offline", log,
            *fixture.host_arguments(store, f"http://127.0.0.1:{endpoint.server_port}/responses"),
        ], env={**os.environ, "SSL_CERT_FILE": str(root / "missing-ca.pem")})
        for _ in range(3):
            listed = h2_fixture.closed_host_request(ready["socket"], store, "model_list")["providers"]
            assert listed and listed[0]["provider"] == "codex", listed
        fixture.stop_host(host)
        host = None
        assert log.read_bytes() == b"", log.read_bytes()
        # Retain all stderr, including a diagnostic emitted before readiness.
        host, ready = start_ready_process([
            "sh", "-c", 'log=$1; shift; exec "$@" 2>"$log"', "rui-catalog-trust", log,
            *fixture.host_arguments(store, f"http://127.0.0.1:{endpoint.server_port}/responses"),
            "--test-models-dev-url", "https://127.0.0.1:1/api.json",
        ], env={**os.environ, "SSL_CERT_FILE": str(root / "missing-ca.pem")},
            required_fields={"execution": "enabled", "nghttp2": "1.70.0"})
        diagnostic = b"rui: models.dev catalog unavailable (InvalidSslCertFile); the saved catalog stands\n"
        for _ in range(3):
            listed = h2_fixture.closed_host_request(ready["socket"], store, "model_list")["providers"]
            assert listed and listed[0]["provider"] == "codex", listed
        configured = fixture.command(
            "session", "configure", "--store", store, "--record", root / "config.json", "--key", "config",
            "--workspace", fixture.ROOT, "--provider", "codex", "--model", "gpt-6-sol", "--tools", "none",
        )
        assert configured["answer"]["status"] == "accepted", configured
        session = configured["answer"]["session"]
        fixture.message(root, store, "http", session, "HTTP still works")
        observation, answer, _ = fixture.wait_for_result_release(store, "http", session, time.monotonic() + 20)
        assert observation["result"]["status"] == "completed", observation
        assert answer == b"HTTP still works", answer
        assert len(endpoint.requests) == 1, endpoint.requests
        assert host.poll() is None, host.returncode
        fixture.stop_host(host)
        host = None
        # Retirement closes the writer before checking optional asynchronous output.
        stderr = log.read_bytes()
        assert stderr in (b"", diagnostic), stderr
        print("catalog trust failure passed: Host serves model lists and an HTTP model request; no fence")
        complete = True
    finally:
        def retire():
            thread.join(timeout=5)
            assert not thread.is_alive(), "HTTP provider thread did not retire"
        cleaned = False
        try:
            dispose_all(lambda: fixture.stop_host(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, retire)
            cleaned = True
        finally:
            if complete and cleaned:
                shutil.rmtree(root)
            else:
                retain_failure_state("catalog trust failure state", root)


if __name__ == "__main__":
    host_process.enter()
    catalog_unusable_proxy_run()
    if os_semantics.SSL_CERT_FILE_TRUST:
        catalog_unusable_trust_run()
        openai_base_url_run()
        openai_base_url_run(catalog_available=True)
    else:
        print("openai base URL TLS case not run: Darwin system trust ignores SSL_CERT_FILE; unit tests cover the URL rules")
    run()
    run(observed=True)
    run(intake=10)

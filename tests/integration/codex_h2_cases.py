"""Codex managed-H2 cases that codex_h2_integration.py runs and
transport_h2_integration_test.py checks: the Codex run, the OpenAI base URL run
and the managed descriptor refusal."""
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

import codex_fixture as codex
import h2_fixture
from host_process import dispose_all, HostDiagnostics, retain_failure_state, start_ready_process
import model_fixture as fixture
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
        endpoint.catalog = b'{"openai":{"models":{"catalog-only":{"limit":{"context":123}},"gpt-6-sol":{}}}}'
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
            **os.environ, "RUI_OPENAI_KEY_FILE": str(key_file), **os_semantics.system_trust(root / "cert.pem"),
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
            **os.environ, "RUI_OPENAI_KEY_FILE": str(key_file), **os_semantics.system_trust(root / "cert.pem"),
            "RUI_OPENAI_BASE_URL": f"https://localhost:{endpoint.server_address[1]}/custom/v1/",
        })
        fallback = fixture.wait_for(
            lambda: (value if (value := model_list())[0]["source"] != "pending" else None),
            "the OpenAI catalog fallback", timeout=20)
        assert fallback[0]["source"] == "catalog_fallback", fallback
        assert fallback[0]["models"] and all(model["known"] for model in fallback[0]["models"]), fallback
        if catalog_available:
            assert fallback == [{"provider": "openai", "source": "catalog_fallback", "models": [
                {"id": "catalog-only", "known": True}, {"id": "gpt-6-sol", "known": True}]}], fallback
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


def saved_catalog_run():
    """Production Host reads one saved generation, not a shipped/Host copy."""
    from product_defaults import CATALOG, DEFAULTS, EFFORTS

    root = pathlib.Path(tempfile.mkdtemp(prefix="rui-saved-catalog.")).resolve()
    key_file = root / "openai.key"
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
    endpoint.catalog_release = threading.Event()
    endpoint.models = b'{"error":"unavailable"}'
    shipped = DEFAULTS.recommended_model
    changed_effort = next(effort for effort in EFFORTS if effort not in CATALOG[shipped].efforts)
    refused_effort = CATALOG[shipped].efforts[0]
    saved = "saved-only-d237"
    other = "non-openai-d237"
    window = 77777

    def body(models, extra=None):
        value = {"openai": {"models": models}}
        if extra is not None:
            value["another-provider"] = {"models": extra}
        return json.dumps(value, separators=(",", ":")).encode()

    endpoint.catalog = body({
        saved: {"limit": {"context": 12345}},
        shipped: {"limit": {"context": window},
                  "reasoning_options": [{"type": "effort", "values": [changed_effort]}]},
    }, {other: {}})
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    store = root / "store"
    host = None
    complete = False
    env = {**os.environ, "RUI_OPENAI_KEY_FILE": str(key_file),
           **os_semantics.system_trust(root / "cert.pem"),
           "RUI_OPENAI_BASE_URL": f"https://localhost:{endpoint.server_address[1]}/v1/"}
    arguments = [fixture.RUI, "host", "serve", "--store", store, "--provider", "openai",
                 "--active-capacity", "1", "--test-models-dev-url",
                 f"https://localhost:{endpoint.server_address[1]}/api.json"]

    def listed():
        return h2_fixture.closed_host_request(ready["socket"], store, "model_list")["providers"]

    def expected(source, ids, known=None):
        return [{"provider": "openai", "source": source,
                 "models": [{"id": model, "known": True if known is None else model in known} for model in ids]}]

    def await_list(wanted, description):
        value = fixture.wait_for(lambda: (value if (value := listed()) == wanted else None), description, timeout=30)
        assert value == wanted, (description, value, wanted)
        return value

    def catalog_requests():
        with endpoint.lock:
            return [headers for headers in endpoint.request_headers if headers[b":path"] == b"/api.json"]

    def await_response(status, etag):
        def observed():
            listed()  # The public operation requests refresh; no test scheduler authority.
            with endpoint.lock:
                return next((reply for reply in endpoint.catalog_responses
                             if reply["status"] == status and reply["etag"] == etag), None)
        return fixture.wait_for(observed, f"catalog {status} {etag}", timeout=30)

    def change_catalog(payload, etag):
        # Gate the next refresh before changing its inputs. An existing held
        # request reads these values only when explicitly released below.
        with endpoint.lock:
            endpoint.catalog_release.clear()
            endpoint.catalog = payload
            endpoint.catalog_etag = etag
        before = len(catalog_requests())
        with endpoint.lock:
            already_held = before > len(endpoint.catalog_responses)
        listed()
        if not already_held:
            fixture.wait_for(lambda: len(catalog_requests()) > before, "held catalog refresh", timeout=20)

    try:
        host, ready = start_ready_process(arguments, env=env)
        shipped_ids = [model for model, facts in CATALOG.items() if facts.openai_listed]
        await_list(expected("catalog_fallback", shipped_ids), "shipped fallback before any saved source")
        endpoint.catalog_release.set()
        first = expected("catalog_fallback", sorted([saved, shipped]))
        await_list(first, "saved-only ID replaces shipped fallback and removed IDs")
        # A source-only read must retain a successfully published generation
        # on conditional refresh, including its changed capability facts.
        conditional = await_response("304", '"catalog-v1"')
        assert conditional["headers"][b"if-none-match"] == b'"catalog-v1"', conditional
        assert listed() == first

        configured = fixture.command(
            "session", "configure", "--store", store, "--record", root / "changed.json", "--key", "changed",
            "--workspace", fixture.ROOT, "--provider", "openai", "--model", shipped, "--tools", "none",
            "--reasoning-effort", changed_effort, "--compaction-trigger", str(window),
        )
        assert configured["answer"]["status"] == "accepted", configured
        session = configured["answer"]["session"]
        for key, options, code in (
            ("effort", ["--reasoning-effort", refused_effort], "unsupported_reasoning_effort"),
            ("window", ["--compaction-trigger", str(window + 1)], "compact_at_too_large"),
        ):
            refused = fixture.command(
                "session", "configure", "--store", store, "--session", session,
                "--record", root / f"{key}.json", "--key", key, *options, expect=3,
            )
            assert refused["answer"]["code"] == code, refused

        # A live provider's IDs and order are independent of catalog membership;
        # non-OpenAI facts still mark a live ID known.
        live_ids = [other, saved, shipped, "provider-only-d237"]
        with endpoint.lock:
            endpoint.models = json.dumps({"data": [{"id": model} for model in live_ids]}).encode()
        live_first = expected("live", live_ids, {other, saved, shipped})
        await_list(live_first, "live provider order and selected known facts")

        change_catalog(body({"provider-only-d237": {}}), '"catalog-v2"')
        for _ in range(8):
            assert listed() == live_first, "an in-flight refresh changed selected facts"
        endpoint.catalog_release.set()
        live_second = expected("live", live_ids, {"provider-only-d237"})
        # Every read across publication must be a whole old or new generation.
        def coherent_publication():
            value = listed()
            assert value in (live_first, live_second), value
            return value if value == live_second else None
        fixture.wait_for(coherent_publication, "one-generation live known flags", timeout=30)

        # Malformed refreshes leave the published source authoritative.
        change_catalog(b'{"openai":{"models":', '"catalog-invalid"')
        endpoint.catalog_release.set()
        await_response("200", '"catalog-invalid"')
        def retried_invalid():
            listed()
            with endpoint.lock:
                return sum(reply["etag"] == '"catalog-invalid"' for reply in endpoint.catalog_responses) >= 2
        fixture.wait_for(retried_invalid, "failed refresh retires and retries without replacing the saved source", timeout=30)
        with endpoint.lock:
            invalid_replies = [reply for reply in endpoint.catalog_responses if reply["etag"] == '"catalog-invalid"']
        assert all(reply["headers"][b"if-none-match"] == b'"catalog-v2"' for reply in invalid_replies), invalid_replies
        assert listed() == live_second
        fixture.stop_host(host)
        host = None
        # Hold discovery on restart: saved facts are visible before any fetch
        # can complete; the live provider starts its own pending/fetch lifecycle.
        endpoint.catalog_release.clear()
        with endpoint.lock:
            endpoint.models = b'{"error":"unavailable"}'
        host, ready = start_ready_process(arguments, env=env)
        await_list(expected("catalog_fallback", ["provider-only-d237"]), "saved facts survive restart and malformed refresh")

        # A valid empty source is authoritative, not absence of a source.
        change_catalog(body({}), '"catalog-empty"')
        endpoint.catalog_release.set()
        await_list(expected("catalog_fallback", []), "empty saved generation suppresses shipped IDs")
        await_response("304", '"catalog-empty"')
        fixture.stop_host(host)
        host = None
        endpoint.catalog_release.clear()
        host, ready = start_ready_process(arguments, env=env)
        await_list(expected("catalog_fallback", []), "empty saved generation survives restart")
        # An absent ID in a saved source is genuinely unlisted for admission:
        # neither its old saved window nor its shipped window may reappear.
        absent = fixture.command(
            "session", "configure", "--store", store, "--session", session,
            "--record", root / "absent.json", "--key", "absent",
            "--reasoning-effort", changed_effort,
            "--compaction-trigger", str(max(window, CATALOG[shipped].context_window or 0) + 1),
        )
        assert absent["answer"]["status"] == "accepted", absent

        # This complete semantic reply exceeds the former shipped-derived
        # static bound, not just the small resident JSON buffer.
        large_ids = [f"saved-{index:04d}-" + "x" * 160 for index in range(4096)]
        change_catalog(body({model: {} for model in reversed(large_ids)}), '"catalog-large"')
        endpoint.catalog_release.set()
        large = await_list(expected("catalog_fallback", large_ids), "untruncated large saved catalog in sorted order")
        assert len(json.dumps(large).encode()) > 512 * 1024
        fixture.stop_host(host)
        host = None
        endpoint.catalog_release.clear()
        credential = root / "codex.json"
        codex.credentials(credential)
        codex_arguments = arguments.copy()
        codex_arguments[codex_arguments.index("--provider") + 1] = "codex"
        host, ready = start_ready_process(codex_arguments, env={**env, "RUI_CODEX_CREDENTIAL_FILE": str(credential)})
        codex_list = h2_fixture.closed_host_request(ready["socket"], store, "model_list")["providers"]
        assert codex_list == [{"provider": "codex", "source": "catalog",
                               "models": [{"id": model, "known": True} for model in large_ids]}], codex_list
        for headers in catalog_requests():
            assert b"authorization" not in headers and b"chatgpt-account-id" not in headers, headers
            assert headers[b"accept-encoding"] == b"identity", headers
        print("saved catalog passed: source authority, changed effort/window admission, live order/known, coherent refresh, 304/failure, empty/restart and >512-KiB reply")
        complete = True
    finally:
        endpoint.catalog_release.set()
        def retire():
            thread.join(timeout=5)
            assert not thread.is_alive(), "saved catalog endpoint thread did not retire"
        cleaned = False
        try:
            dispose_all(lambda: fixture.stop_host(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, retire)
            cleaned = True
        finally:
            if complete and cleaned:
                shutil.rmtree(root)
            else:
                retain_failure_state("saved catalog failure state", root)

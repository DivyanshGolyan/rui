#!/usr/bin/env python3
"""Synthetic managed transfer through native TLS/HTTP2 with observed reuse."""

import os
import pathlib
import shutil
import subprocess
import tempfile
import threading
import time

import model_fixture as fixture
import h2_fixture
import host_process
from host_process import dispose_all, retain_failure_state, start_ready_process
import os_semantics
from codex_h2_cases import openai_base_url_run, saved_catalog_run, run


REQUIRED_PROXY_FAILURE = "rui: https_proxy/HTTPS_PROXY names a scheme other than http://; Rui tunnels only through an http:// proxy. The Host did not start.\n"


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
        # Even an HTTP provider shares Engine.init's proxy validation. Startup
        # refuses it before readiness: no swallowing, no retry without the
        # inherited network policy, and no cause raced against stderr custody.
        required = subprocess.run([
            *fixture.host_arguments(root / "required-provider", "http://127.0.0.1:1/responses"),
            "--test-models-dev-url", "https://127.0.0.1:1/api.json",
        ], env=env, capture_output=True, text=True, timeout=10)
        assert required.returncode != 0, required
        assert required.stdout == "", required
        assert REQUIRED_PROXY_FAILURE in required.stderr, required
        assert "models.dev catalog unavailable" not in required.stderr, required
        print("catalog proxy failure passed: provider-free Hosts stay responsive at capacity 0 and 1; a provider Host refuses the proxy before readiness")
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
        ], env={**os.environ, **os_semantics.system_trust(root / "missing-ca.pem")})
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
        ], env={**os.environ, **os_semantics.system_trust(root / "missing-ca.pem")},
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
        saved_catalog_run()
    else:
        print("openai base URL TLS case not run: Darwin system trust takes no fixture CA; unit tests cover the URL rules")
    run()
    run(observed=True)
    run(intake=10)

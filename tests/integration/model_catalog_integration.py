#!/usr/bin/env python3
"""Host-owned Codex model catalog: admission, fail-open, refresh and secrecy."""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time

import codex_integration as codex
import model_fixture as fixture
from host_process import TestHTTPServer

CLIENT_VERSION = "0.163.0"
ROTATED = "synthetic-rotated-not-real"
SECRETS = (codex.ACCESS, ROTATED, codex.ACCOUNT, "synthetic-not-real")


def catalog_body(*rows):
    # Real catalogs carry large unrelated fields; Rui must skip them.
    return json.dumps({"models": [
        {"slug": slug, "display_name": slug, "visibility": visibility, "supported_in_api": False,
         "base_instructions": "x" * 2048, "supported_reasoning_levels": [{"effort": "low"}]}
        for slug, visibility in rows
    ]}).encode()


GOOD = catalog_body(("gpt-6-luna", "list"), ("gpt-6-sol", "list"), ("codex-auto-review", "hide"))


class CatalogEndpoint(fixture.SuccessEndpoint):
    def __init__(self):
        super().__init__([fixture.sse_answer("catalog-answer", "reasoning", "answer", "catalog answer")[0]] * 8)
        self.RequestHandlerClass = CatalogHandler
        self.catalog = (200, GOOD, 0)
        self.catalog_requests = []


class CatalogHandler(fixture.SuccessHandler):
    def do_GET(self):
        with self.server.lock:
            status, body, delay = self.server.catalog
            self.server.catalog_requests.append(
                (self.path, self.headers.get("Authorization"), self.headers.get("ChatGPT-Account-ID"),
                 self.headers.get("originator"), self.headers.get("session-id"), self.headers.get("Accept"),
                 time.monotonic()))
        try:
            time.sleep(delay)
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(body)
            except OSError:
                pass
        finally:
            self.close_connection = True


def rui(*args, expect=0, timeout=20):
    completed = subprocess.run([str(fixture.RUI), *map(str, args)], text=True, capture_output=True, timeout=timeout)
    for secret in SECRETS:
        assert secret not in completed.stdout and secret not in completed.stderr, (args, secret)
    if completed.returncode != expect:
        raise AssertionError(f"{args} returned {completed.returncode}, wanted {expect}\n{completed.stdout}\n{completed.stderr}")
    return json.loads(completed.stdout), completed.stderr


def configure(store, state, key, session, model, *, expect=0, extra=()):
    return rui("session", "configure", "--store", store, "--record", state / f"{key}.json", "--key", key,
               "--session", session, "--workspace", fixture.ROOT, "--provider", "codex", "--model", model,
               *extra, expect=expect)


def model_list(store, *, refresh=False):
    return rui("model", "list", "--store", store, *(["--refresh"] if refresh else []))[0]


def refresh_to(store, endpoint, catalog):
    with endpoint.lock:
        endpoint.catalog = catalog
    listing = model_list(store, refresh=True)
    assert listing["refresh"] == "completed", listing
    return listing


def run():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-catalog.")).resolve()
    credential_dir = state / "private"
    credential_dir.mkdir(mode=0o700)
    credential_file = credential_dir / "codex.json"
    os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(credential_file)
    codex.credentials(credential_file)
    endpoint = CatalogEndpoint()
    threading.Thread(target=endpoint.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    store = state / "store"
    host = None
    complete = False
    try:
        # A Host whose catalog fetch fails accepts any model with a reason.
        endpoint.catalog = (503, b"{}", 0)
        host = codex.start(store, url)
        fixture.wait_for(lambda: model_list(store)["last_failure"] == "http_status", "failed startup fetch")
        early, _ = configure(store, state, "early", "catalog/early", "gpt-5-codex")
        assert early["answer"]["status"] == "accepted", early
        assert early["model_catalog"] == {"verdict": "unchecked", "reason": "http_status", "age_seconds": None}, early

        # Headers match the responses route without Session affinity.
        path, authorization, account, originator, session_id, accept, _ = endpoint.catalog_requests[0]
        assert path == f"/models?client_version={CLIENT_VERSION}", path
        assert authorization == f"Bearer {codex.ACCESS}" and account == codex.ACCOUNT, (authorization, account)
        assert originator == "rui" and session_id is None and accept == "application/json"

        listing = refresh_to(store, endpoint, (200, GOOD, 0))
        assert listing["available"] and listing["last_failure"] is None, listing
        assert listing["models"] == [
            {"slug": "gpt-6-luna", "visibility": "list"}, {"slug": "gpt-6-sol", "visibility": "list"},
            {"slug": "codex-auto-review", "visibility": "hidden"}], listing

        # Absent from a fresh catalog: an unsaved rejection naming the
        # available models. The key has no saved answer.
        rejected, stderr = configure(store, state, "absent", "catalog/absent", "gpt-5-codex", expect=1)
        error = rejected["error"]
        assert error["status"] == "422" and error["certainty"] == "not_saved", error
        assert error["type"] == "model_catalog_rejection" and error["code"] == "model_unavailable", error
        assert error["model"] == "gpt-5-codex" and error["available_models"] == ["gpt-6-luna", "gpt-6-sol"], error
        assert error["available_count"] == "2", error
        assert "Model gpt-5-codex is not available for this Codex account" in stderr, stderr
        assert "gpt-6-luna, gpt-6-sol" in stderr, stderr
        assert fixture.observe(store, "absent")["status"] == "absent", "catalog rejection was saved"
        inspected, _ = rui("session", "inspect", "--store", store, "--session", "catalog/absent")
        assert inspected["session"] is None, inspected

        # Hidden and listed models are accepted; hidden warns.
        hidden, _ = configure(store, state, "hidden", "catalog/hidden", "codex-auto-review")
        assert hidden["answer"]["status"] == "accepted" and hidden["model_catalog"]["verdict"] == "hidden", hidden
        listed, _ = configure(store, state, "listed", "catalog/listed", "gpt-6-luna")
        assert listed["model_catalog"]["verdict"] == "listed" and listed["model_catalog"]["reason"] is None, listed
        current, _ = rui("session", "inspect", "--store", store, "--session", "catalog/listed")
        assert current["session"]["model_catalog"]["verdict"] == "listed", current

        # Existing Sessions never reject: equal explicit model, sparse update,
        # and inspect all report the absent verdict instead.
        equal, _ = configure(store, state, "early-equal", "catalog/early", "gpt-5-codex")
        assert equal["answer"]["status"] == "accepted" and equal["model_catalog"]["verdict"] == "absent", equal
        sparse, _ = rui("session", "configure", "--store", store, "--record", state / "sparse.json", "--key", "sparse",
                        "--session", "catalog/early", "--permission-mode", "ask")
        assert sparse["answer"]["status"] == "accepted" and "model_catalog" not in sparse, sparse
        early_current, _ = rui("session", "inspect", "--store", store, "--session", "catalog/early")
        assert early_current["session"]["model_catalog"]["verdict"] == "absent", early_current

        # Replay runs before the verdict.
        replay, _ = rui("request", "recover", "--store", store, "--record", state / "early.json", "--kind", "configure")
        assert replay["answer"]["status"] == "accepted" and replay["answer"]["replayed"], replay

        # Recovery of the unsaved rejection re-judges the original intent.
        refresh_to(store, endpoint, (200, catalog_body(("gpt-6-luna", "list"), ("gpt-5-codex", "list")), 0))
        recovered, _ = rui("request", "recover", "--store", store, "--record", state / "absent.json", "--kind", "configure")
        assert recovered["answer"]["status"] == "accepted" and recovered["answer"]["created"], recovered
        assert not recovered["answer"]["replayed"], recovered

        # Every unusable response fails open, keeps the reason, and never
        # rejects, even after a fresh catalog existed.
        for name, catalog, reason in (
            ("malformed", (200, b'{"models":[{"slug":"a"}]}', 0), "unparseable"),
            ("non200", (500, GOOD, 0), "http_status"),
            ("oversized", (200, b'{"models":[],"pad":"' + b"x" * (4 * 1024 * 1024) + b'"}', 0), "too_large"),
        ):
            # A failed refresh keeps the previous fresh catalog: reset to an
            # empty catalog source first by restarting the Host.
            fixture.stop_host(host)
            host = None
            with endpoint.lock:
                endpoint.catalog = catalog
            host = codex.start(store, url)
            fixture.wait_for(lambda: model_list(store)["last_failure"] == reason, f"{name} fetch")
            accepted, stderr = configure(store, state, f"open-{name}", f"catalog/open-{name}", "not-in-any-catalog")
            assert accepted["model_catalog"] == {"verdict": "unchecked", "reason": reason, "age_seconds": None}, accepted

        # A slow fetch never delays configuration; refresh joins one fetch.
        fixture.stop_host(host)
        host = None
        with endpoint.lock:
            endpoint.catalog = (200, GOOD, 0)
            endpoint.catalog_requests.clear()
        host = codex.start(store, url)
        fixture.wait_for(lambda: model_list(store)["available"], "fresh catalog")
        with endpoint.lock:
            endpoint.catalog = (200, GOOD, 7)
            endpoint.catalog_requests.clear()
        refreshes = [fixture.start_command("model", "list", "--store", store, "--refresh") for _ in range(3)]
        started = time.monotonic()
        quick, _ = configure(store, state, "during-fetch", "catalog/during-fetch", "gpt-6-sol")
        assert time.monotonic() - started < 2, "configuration waited for a catalog fetch"
        assert quick["model_catalog"]["verdict"] == "listed", quick
        outcomes = [fixture.finish_command(process) for process in refreshes]
        # The five-second deadline ends the seven-second response.
        fixture.wait_for(lambda: model_list(store)["last_failure"] == "timeout", "timed-out fetch", timeout=20)
        # One fetch at a time: the fixture keeps sleeping after Rui's
        # deadline, so compare Rui's request starts, not fixture overlap.
        starts = [request[-1] for request in endpoint.catalog_requests]
        assert 1 <= len(starts) <= 2, endpoint.catalog_requests
        assert all(later - earlier >= 4.5 for earlier, later in zip(starts, starts[1:])), starts
        assert all(outcome["refresh"] in ("completed", "pending") for outcome in outcomes), outcomes
        # A timed-out refresh keeps the previous fresh catalog authoritative.
        still, _ = configure(store, state, "after-timeout", "catalog/after-timeout", "gpt-5-codex", expect=1)
        assert still["error"]["code"] == "model_unavailable", still

        # A rotated credential for the same account (new generation and
        # refresh token) keeps the catalog authoritative. Fixture Hosts accept
        # only the canary access token, so the bearer itself cannot change here.
        with endpoint.lock:
            endpoint.catalog = (200, GOOD, 0)
        credential_file.write_text(credential_file.read_text()
                                   .replace("generation=1", "generation=2")
                                   .replace("refresh_token=synthetic-not-real", f"refresh_token={ROTATED}"))
        rotated, _ = configure(store, state, "rotated", "catalog/rotated", "gpt-5-codex", expect=1)
        assert rotated["error"]["code"] == "model_unavailable", rotated
        rotated_listing = refresh_to(store, endpoint, (200, GOOD, 0))
        assert rotated_listing["last_failure"] is None and rotated_listing["available"], rotated_listing

        # FedRAMP state is part of the account identity.
        codex.credentials(credential_file, fedramp=True)
        fedramp, _ = configure(store, state, "fedramp", "catalog/fedramp", "gpt-5-codex")
        assert fedramp["model_catalog"]["reason"] == "other_account", fedramp
        codex.credentials(credential_file)

        # Another account in the credential snapshot makes the catalog
        # unusable for rejection.
        record = credential_file.read_text().replace("account_id=" + codex.ACCOUNT, "account_id=other-account")
        credential_file.write_text(record)
        other, _ = configure(store, state, "other-account", "catalog/other-account", "gpt-5-codex")
        assert other["model_catalog"]["verdict"] == "unchecked" and other["model_catalog"]["reason"] == "other_account", other
        codex.credentials(credential_file)
        complete = True
    finally:
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        if complete:
            shutil.rmtree(state)
        else:
            print(f"preserved model catalog state: {state}", file=sys.stderr)


if __name__ == "__main__":
    run()
    print("model catalog integration passed")

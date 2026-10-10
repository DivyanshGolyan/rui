#!/usr/bin/env python3
"""Real producer replies through the existing Current CLI consumer boundary."""
import json
import re
import tempfile

import canonical_failure_integration as canonical
import dispatch_integration as fixture
from host_process import canonical_fixture_root


with tempfile.TemporaryDirectory(prefix="rui-current-facts-") as temporary:
    state = canonical_fixture_root(temporary)
    store = state / "store"
    host = fixture.start_host(store, None)
    try:
        fixture.configure(state, store, "configuration", "s", "model-a")
        original = fixture.command("inspect-session", "--store", store, "--session", "s")
        missing = fixture.command("inspect-session", "--store", store, "--session", "missing")
        assert missing["session"] is None and missing["execution"]["reason"] == "session_not_found", missing
        for change in ("extension", "binding", "profile", "missing-selection", "invalid-tail"):
            produced = []
            def rewrite(response):
                head, body = response.split(b"\r\n\r\n", 1)
                value = json.loads(body)
                produced.append(json.loads(body))
                assert value["session"] == original["session"], value
                if change == "extension":
                    value["extension"] = {"large": "x" * 20000}
                elif change == "binding":
                    value["session"]["reference"] = "another-session"
                elif change == "profile":
                    value["profile"] = "full"
                elif change == "missing-selection":
                    del value["selected_message"]
                body = json.dumps(value, separators=(",", ":")).encode()
                if change == "invalid-tail":
                    body += b"false"
                head = re.sub(rb"Content-Length: [0-9]+", b"Content-Length: " + str(len(body)).encode(), head)
                return head + b"\r\n\r\n" + body
            proxy = canonical.ReplyProxy(host, "/v1/inspect-session", rewrite)
            try:
                result = canonical.invoke(state, "inspect-session", "--store", store, "--session", "s")
                assert len(proxy.exchanges) == 1, proxy.exchanges
                if change == "extension":
                    assert result.returncode == 0 and json.loads(result.stdout) == produced[0], result
                else:
                    assert result.returncode != 0 and "InvalidObservation" in result.stderr and not result.stdout, (change, result)
            finally:
                proxy.close()
        full = fixture.command("inspect-session", "--store", store, "--session", "s", "--profile", "full")
        assert full["profile"] == "full" and full["full"]["session_revisions"], full
    finally:
        fixture.stop_host(host)
print("Current producer/consumer: exact metadata, explicit unconfigured, discarded extension, four pre-output refusals; Full unchanged")

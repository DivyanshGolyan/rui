#!/usr/bin/env python3
"""Real list producer: semantic output and exact scope/cursor validation."""
import json
import os
import pathlib
import subprocess
import tempfile

from canonical_failure_integration import ERROR_BYTES, ReplyProxy
import model_fixture as fixture


def main():
    with tempfile.TemporaryDirectory(prefix="rui-list-facts-") as temporary:
        root = pathlib.Path(temporary)
        home = root / "home"
        home.mkdir()
        store = root / "store"
        host = fixture.start_host(store, None)
        def invoke(*args):
            return subprocess.run([fixture.RUI, *map(str, args)], cwd=root,
                env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=10)
        try:
            allocated = []
            for index in range(9):
                configured = invoke("session", "configure", "--store", store,
                    "--workspace", root, "--provider", "codex", "--model", "gpt-6-sol")
                assert configured.returncode == 0, configured
                allocated.append(json.loads(configured.stdout)["answer"]["session"])
            def rewrite(response):
                head, body = response.split(b"\r\n\r\n", 1)
                page = json.loads(body)
                if mode == "unknown":
                    page["wire_only"] = {"nested": ["discard-me", None]}
                    page["sessions"][0]["wire_only"] = "discard-me"
                elif mode == "scope":
                    page["sessions"][0]["workspace"] = str(root) + "-other"
                elif mode == "version":
                    page["version"] = "2"
                elif mode == "cursor":
                    page["next"]["after"] = "0" + page["next"]["after"]
                elif mode == "delta":
                    # Changed rows answer a token; this listing sent none.
                    assert page["delta"] == "full", page
                    page["delta"] = "changed"
                elif mode == "exhausted" and page["next"] is not None:
                    assert len(page["sessions"]) == 8 and int(page["next"]["after"]) < int(page["next"]["ceiling"]), page
                    page["next"]["after"] = page["next"]["ceiling"]
                elif mode == "failure":
                    page = {"version": "1", "type": "busy", "code": "ordinary_capacity_exhausted",
                        "wire_only": "discard-me"}
                    head = b"HTTP/1.1 503 Unavailable"
                encoded = json.dumps(page, indent=2).encode()
                if mode == "duplicate":
                    encoded = encoded.replace(b'"type": "session_list",',
                        b'"type": "session_list", "type": "session_list",', 1)
                return (head.split(b"\r\n", 1)[0] + b"\r\nContent-Type: application/json\r\n"
                    b"X-Rui-Wire-Version: 1\r\nConnection: close\r\nContent-Length: "
                    + str(len(encoded)).encode() + b"\r\n\r\n" + encoded)
            for mode in ("exhausted", "unknown", "scope", "version", "cursor", "delta", "duplicate", "failure"):
                proxy = ReplyProxy(host, "/v1/list-sessions", rewrite)
                try:
                    result = invoke("session", "list", "--store", store)
                finally:
                    proxy.close()
                assert proxy.exchanges, "proof never reached the real list producer"
                if mode == "unknown":
                    assert result.returncode == 0, result
                    assert "discard-me" not in result.stdout, ("unknown list metadata leaked", result)
                    listed = json.loads(result.stdout)
                    assert listed["type"] == "session_list" and listed["next"] is None, result
                    references = [row["reference"] for row in listed["sessions"]]
                    assert references == allocated, result
                elif mode == "failure":
                    assert result.returncode != 0 and "HostInvocationFailed" in result.stderr and result.stdout == "", result
                    assert json.loads(result.stderr.splitlines()[0]) == {"status": 503, "type": "busy", "code": "ordinary_capacity_exhausted"}, result
                    assert "discard-me" not in result.stderr, result
                else:
                    assert result.returncode != 0 and "InvalidSessionPage" in result.stderr, (mode, result)
                    assert result.stdout == "", ("invalid first page reached output", mode, result)
            failure = (b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n"
                b"X-Rui-Wire-Version: 1\r\nConnection: close\r\nContent-Length: "
                + str(len(ERROR_BYTES)).encode() + b"\r\n\r\n" + ERROR_BYTES)
            def paged(*args, replies=()):
                """Lists through the real producer, answering page N with replies[N] when given."""
                def replace(response):
                    index = len(proxy.exchanges) - 1
                    return replies[index] if index < len(replies) and replies[index] is not None else response
                proxy = ReplyProxy(host, "/v1/list-sessions", replace)
                try:
                    result = invoke("session", "list", "--store", store, *args)
                finally:
                    proxy.close()
                return result, [json.loads(response.split(b"\r\n\r\n", 1)[1]) for _, response in proxy.exchanges], \
                    [response for _, response in proxy.exchanges]
            # Rows print only once the last page is read: a later page that
            # fails prints nothing.
            result, pages, _ = paged(replies=(None, failure))
            assert len(pages) == 2 and pages[0]["next"] is not None, pages
            assert result.returncode != 0 and "CanonicalStoreFailure" in result.stderr and result.stdout == "", result
            token = json.loads(paged()[0].stdout)["since"]
            for index, reference in enumerate(allocated):
                relabelled = invoke("session", "configure", "--store", store, "--session", reference, "--label", f"Watched {index}")
                assert relabelled.returncode == 0, relabelled
            _, full_pages, full_replies = paged()
            full_first = full_pages[0]
            # A changed listing whose continuation restarts as full prints
            # the full listing alone, so each Session appears once.
            for replies in ((None, full_replies[0]), (None, full_replies[0], failure), (None, failure)):
                result, pages, _ = paged("--since", token, replies=replies)
                assert len(pages) == len(replies) + (replies[-1] is not failure), (replies, pages)
                assert pages[0]["delta"] == "changed" and len(pages[0]["sessions"]) == 8 and "through" in pages[0]["next"], pages
                if replies[-1] is failure:
                    assert result.returncode != 0 and "CanonicalStoreFailure" in result.stderr and result.stdout == "", result
                    continue
                assert result.returncode == 0, result
                listed = json.loads(result.stdout)
                assert listed["delta"] == "full" and listed["since"] == full_first["since"], listed
                assert [row["reference"] for row in listed["sessions"]] == allocated, listed
                assert [row["label"] for row in listed["sessions"]] == [f"Watched {index}" for index in range(len(allocated))], listed
            print("Session-list facts: actual producer, all pages, one JSON value, discarded extensions, exact scope/version/canonical cursor/duplicate rejection; synthetic busy diagnostics; "
                "a failed later page prints nothing; a changed listing restarted as full prints each Session once")
        finally:
            fixture.stop_host(host)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Real list producer: semantic output and exact scope/cursor validation."""
import json
import os
import pathlib
import subprocess
import tempfile
import threading

from canonical_failure_integration import ERROR_BYTES, ReplyProxy
from control_integration import StreamingEndpoint
import model_fixture as fixture
import host_process



def prove_archive(root, home):
    store = root / "archive-store"
    host = fixture.start_host(store, None)

    def invoke(*args, input=None, expect=0):
        result = subprocess.run([fixture.RUI, *map(str, args)], cwd=root,
            env={**os.environ, "HOME": str(home)}, input=input,
            capture_output=True, text=True, timeout=15)
        assert result.returncode == expect, result
        return json.loads(result.stdout)

    def mutate(reference, archived, key):
        return invoke("session", "archive" if archived else "unarchive",
            "--store", store, "--session", reference,
            "--record", root / f"{key}.json", "--key", key)

    def listed(*flags):
        return invoke("session", "list", "--store", store, *flags)

    try:
        references = []
        for index in range(18):
            reply = invoke("session", "configure", "--store", store,
                "--workspace", root, "--provider", "codex", "--model", "gpt-6-sol",
                "--label", f"Archive proof {index}")
            references.append(reply["answer"]["session"])
        before = listed()["since"]
        for index, reference in enumerate(references[:9]):
            reply = mutate(reference, True, f"archive-{index}")
            assert reply["answer"]["status"] == "accepted", reply
            assert reply["completion"]["status"] == "completed", reply
        active = listed()
        assert [row["reference"] for row in active["sessions"]] == references[9:], active
        assert all(row["archive_state"] == "active" for row in active["sessions"]), active
        archived = listed("--archived")
        assert [row["reference"] for row in archived["sessions"]] == references[:9], archived
        assert all(row["archive_state"] == "archived" for row in archived["sessions"]), archived
        combined = listed("--include-archived")
        assert [row["reference"] for row in combined["sessions"]] == references, combined
        changed = listed("--since", before)
        if changed["delta"] == "changed":
            assert {row["reference"] for row in changed["sessions"]} == set(references[:9]), changed
            assert all(row["archive_state"] == "archived" for row in changed["sessions"]), changed
        else:
            assert changed["delta"] == "full", changed
            assert [row["reference"] for row in changed["sessions"]] == references[9:], changed
        proxy = ReplyProxy(host, "/v1/list-sessions", lambda response: response)
        try:
            archived = listed("--archived")
        finally:
            proxy.close()
        pages = [json.loads(response.split(b"\r\n\r\n", 1)[1]) for _, response in proxy.exchanges]
        assert [len(page["sessions"]) for page in pages] == [8, 1], pages
        assert all(row["archive_state"] == "archived" for page in pages for row in page["sessions"]), pages
        reference = references[0]
        exact = invoke("session", "inspect", "--store", store, "--session", reference)
        assert exact["archive_state"] == "archived", exact
        reply = mutate(reference, False, "restore")
        assert reply["answer"]["status"] == "accepted", reply
        exact = invoke("session", "inspect", "--store", store, "--session", reference)
        assert exact["archive_state"] == "active", exact
        assert exact["pending_messages"] == "0", exact
        assert exact["work"]["state"]["kind"] in ("idle", "stopped"), exact
        replay = invoke("request", "recover", "--store", store,
            "--record", root / "archive-0.json", "--kind", "session-archive")
        assert replay["answer"]["replayed"] is True, replay
        exact = invoke("session", "inspect", "--store", store, "--session", reference)
        assert exact["archive_state"] == "active", exact
        mutate(reference, True, "archive-again")
        sent = invoke("session", "send", "--store", store, "--to", reference,
            "--record", root / "restore-by-message.json", "--key", "restore-by-message",
            input="Restore by new work")
        assert sent["answer"]["status"] == "accepted", sent
        exact = invoke("session", "inspect", "--store", store, "--session", reference)
        assert exact["archive_state"] == "active", exact
        reply = mutate(reference, True, "archive-queued")
        assert reply["answer"]["status"] == "accepted", reply
        assert reply["completion"]["status"] == "completed", reply
        exact = invoke("session", "inspect", "--store", store, "--session", reference)
        assert exact["archive_state"] == "archived", exact
        assert exact["pending_messages"] == "0", exact
        assert exact["work"]["state"]["kind"] == "stopped", exact
        fixture.stop_host(host)
        host = None
        host = fixture.start_host(store, None)
        exact = invoke("session", "inspect", "--store", store, "--session", reference)
        assert exact["archive_state"] == "archived", exact
        assert exact["pending_messages"] == "0", exact
        assert [row["reference"] for row in listed("--archived")["sessions"]] == references[:9]
        replay = invoke("request", "recover", "--store", store,
            "--record", root / "archive-queued.json", "--kind", "session-archive")
        assert replay["answer"]["replayed"] is True, replay
        assert replay["completion"]["status"] == "completed", replay
        print("Session archive: native filtered pages, visibility deltas, exact reads, restore without work, "
            "archive replay after restore, new-message restore, queued-work stop and Host restart")
    finally:
        if host is not None:
            fixture.stop_host(host)



def prove_running_archive(root):
    store = root / "running-archive-store"
    endpoint = StreamingEndpoint()
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    host = None
    thread.start()
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        reference = fixture.configure(root, store, "running-archive-config", None, "gpt-6-sol")
        fixture.message(root, store, "running-archive-message", reference, "Wait for stop and archive")
        host_process.wait_for(lambda: endpoint.counts()[0] == 1, "archive provider request is in flight")
        current = fixture.command("session", "inspect", "--store", store, "--session", reference)
        assert current["work"]["state"]["kind"] == "working", current
        archived = fixture.command("session", "archive", "--store", store, "--session", reference,
            "--record", root / "running-archive.json", "--key", "running-archive")
        assert archived["answer"]["status"] == "accepted", archived
        assert archived["completion"]["status"] == "completed", archived
        current = fixture.command("session", "inspect", "--store", store, "--session", reference)
        assert current["archive_state"] == "archived", current
        assert current["work"]["state"]["kind"] == "stopped", current
        assert current["pending_messages"] == "0", current
        host_process.wait_for(lambda: endpoint.counts()[1] == 1, "archived model request disconnects")
        print("Session archive: one command stops and archives a real in-flight model request")
    finally:
        try:
            if host is not None:
                fixture.stop_host(host)
        finally:
            endpoint.release.set()
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)


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
                    page["version"] = str(int(host_process.WIRE_VERSION) + 1)
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
                    page = {"version": host_process.WIRE_VERSION, "type": "busy", "code": "ordinary_capacity_exhausted",
                        "wire_only": "discard-me"}
                    head = b"HTTP/1.1 503 Unavailable"
                encoded = json.dumps(page, indent=2).encode()
                if mode == "duplicate":
                    encoded = encoded.replace(b'"type": "session_list",',
                        b'"type": "session_list", "type": "session_list",', 1)
                return (head.split(b"\r\n", 1)[0] + b"\r\nContent-Type: application/json\r\n"
                    b"X-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\nConnection: close\r\nContent-Length: "
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
                    assert result.returncode == 5 and result.stdout == "", result
                    assert json.loads(result.stderr.splitlines()[0]) == {"status": 503, "type": "busy", "code": "ordinary_capacity_exhausted"}, result
                    assert "discard-me" not in result.stderr, result
                else:
                    assert result.returncode == 1 and "[internal_unexpected]" in result.stderr, (mode, result)
                    assert result.stdout == "", ("invalid first page reached output", mode, result)
            failure = (b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n"
                b"X-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\nConnection: close\r\nContent-Length: "
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
            assert result.returncode == 1 and "[internal_unexpected]" in result.stderr and result.stdout == "", result
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
                    assert result.returncode == 1 and "[internal_unexpected]" in result.stderr and result.stdout == "", result
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
        prove_archive(root, home)
        prove_running_archive(root)


if __name__ == "__main__":
    host_process.enter()
    main()

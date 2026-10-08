#!/usr/bin/env python3
"""Real list producer: semantic output and exact scope/cursor validation."""
import json
import os
import pathlib
import subprocess
import tempfile

from canonical_failure_integration import ReplyProxy
import dispatch_integration as fixture


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
            for index in range(9):
                configured = invoke("configure", "--store", store, "--session", f"selected/{index}",
                    "--workspace", root, "--provider", "codex", "--model", "model-a")
                assert configured.returncode == 0, configured
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
            for mode in ("exhausted", "unknown", "scope", "version", "cursor", "duplicate", "failure"):
                for presentation in (("--json",), ()):
                    proxy = ReplyProxy(host, "/v1/list-sessions", rewrite)
                    try:
                        result = invoke("sessions", "--store", store, *presentation)
                    finally:
                        proxy.close()
                    assert proxy.exchanges, "proof never reached the real list producer"
                    if mode == "unknown":
                        assert result.returncode == 0, result
                        assert "discard-me" not in result.stdout, ("unknown list metadata leaked", result)
                        if presentation:
                            pages = [json.loads(line) for line in result.stdout.splitlines()]
                            references = [row["reference"] for page in pages for row in page["sessions"]]
                        else:
                            references = [line.removeprefix("Session: ") for line in result.stdout.splitlines() if line.startswith("Session: ")]
                        assert references == [f"selected/{i}" for i in range(9)], result
                    elif mode == "failure":
                        assert result.returncode != 0 and "HostInvocationFailed" in result.stderr and result.stdout == "", result
                        assert json.loads(result.stderr.splitlines()[0]) == {"status": 503, "type": "busy", "code": "ordinary_capacity_exhausted"}, result
                        assert "discard-me" not in result.stderr, result
                    else:
                        assert result.returncode != 0 and "InvalidSessionPage" in result.stderr, (mode, result)
                        assert result.stdout == "", ("invalid first page reached output", mode, result)
            print("Session-list facts: actual producer, all pages, human/JSON facts, discarded extensions, exact scope/version/canonical cursor/duplicate rejection; synthetic busy diagnostics")
        finally:
            fixture.stop_host(host)


if __name__ == "__main__":
    main()

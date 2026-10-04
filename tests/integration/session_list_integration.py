#!/usr/bin/env python3
"""Native Host wire proof for configured-only Session discovery (no local records)."""

import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile

from host_process import start_ready_process, stop_process


RUI = pathlib.Path(sys.argv[1]).resolve()
CLIENT = pathlib.Path(sys.argv[2]).resolve()


def exchange(socket_path, route, request):
    body = json.dumps(request, ensure_ascii=True, separators=(",", ":")).encode()
    with socket.socket(socket.AF_UNIX) as client:
        client.connect(socket_path)
        client.sendall(
            f"POST /v1/{route} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n".encode()
            + body
        )
        chunks = []
        while chunk := client.recv(65536):
            chunks.append(chunk)
    head, payload = b"".join(chunks).split(b"\r\n\r\n", 1)
    assert int(next(line.split(b": ", 1)[1] for line in head.split(b"\r\n") if line.startswith(b"Content-Length: "))) == len(payload)
    return int(head.split(b" ", 2)[1]), json.loads(payload)


def linux_resources(pid):
    status = pathlib.Path(f"/proc/{pid}/status")
    if not status.exists():
        return None
    rss = next(int(line.split()[1]) for line in status.read_text().splitlines() if line.startswith("VmRSS:"))
    return {"rss_kib": rss, "fds": len(list(pathlib.Path(f"/proc/{pid}/fd").iterdir()))}


def main():
    with tempfile.TemporaryDirectory(prefix="rui-session-list-") as temporary:
        root = pathlib.Path(temporary)
        store = root / "store"
        store.mkdir(mode=0o700)
        other = root / "other"
        other.mkdir()
        home = root / "fresh-home"
        home.mkdir()
        original_home = os.environ.get("HOME")
        os.environ["HOME"] = str(home)
        process, fields = start_ready_process([RUI, "serve", "--store", store, "--active-capacity", "1"], required_fields={"execution": "unavailable"})
        try:
            address = fields["socket"]
            def base(kind):
                return {"version": "1", "kind": kind, "store": str(store)}

            def listing(workspace=None, cursor=None):
                cursor = cursor or {"after": "0", "ceiling": "0"}
                result = subprocess.run(
                    [CLIENT, store, workspace if workspace is not None else "-", cursor["after"], cursor["ceiling"]],
                    capture_output=True, timeout=10,
                )
                assert result.returncode == 0, (result.returncode, result.stderr[-2000:])
                return 200, json.loads(result.stdout)

            initial = listing()
            assert initial == (200, {"version": "1", "type": "session_list", "sessions": [], "next": None}), initial
            baseline = linux_resources(process.pid)
            # A rejected configuration creates a request fact but no Session.
            def configure(key, reference, workspace, complete=True):
                config = {
                    "workspace": {"state": "value", "value": workspace} if complete else {"state": "omitted"},
                    "provider": {"state": "value", "value": "codex"},
                    "model": {"state": "value", "value": "model-a"},
                    "instructions": {"state": "omitted"},
                    "tools": {"state": "omitted"},
                    "permission_mode": {"state": "omitted"},
                    "output_schema": {"state": "omitted"},
                }
                return exchange(address, "configure", {**base("configure"), "key": key, "session": reference, "configuration": config})

            assert configure("rejected", "not-created", str(root), False)[1]["answer"]["status"] == "rejected"
            names = [f"reverse/{10 - i:02}" for i in range(10)]
            for i, reference in enumerate(names):
                assert configure(f"created-{i}", reference, str(other) if i == 3 else str(root))[1]["answer"]["status"] == "accepted"
            first_status, first = listing(str(root))
            assert first_status == 200 and [item["reference"] for item in first["sessions"]] == [names[i] for i in (0, 1, 2, 4, 5, 6, 7, 8)], first
            assert all(item["workspace"] == str(root) for item in first["sessions"])
            assert first["next"] and int(first["next"]["ceiling"]) == 10
            assert configure("created-later", "later", str(root))[1]["answer"]["status"] == "accepted"
            assert listing(str(root), first["next"]) == (200, {"version": "1", "type": "session_list", "sessions": [
                {"reference": names[9], "workspace": str(root), "provider": "codex", "model": "model-a", "tools": ["bash"], "permission_mode": "bypass"}
            ], "next": None})
            assert [item["reference"] for item in listing(str(other))[1]["sessions"]] == [names[3]]
            assert listing(str(root) + "-alias")[1]["sessions"] == []
            assert [item["reference"] for item in listing()[1]["sessions"]] == names[:8]
            current = subprocess.run([RUI, "sessions", "--store", store, "--json"],
                cwd=root, capture_output=True, text=True, timeout=10)
            assert current.returncode == 0, current.stderr
            current_pages = [json.loads(line) for line in current.stdout.splitlines()]
            assert [row["reference"] for page in current_pages for row in page["sessions"]] == [
                names[i] for i in (0, 1, 2, 4, 5, 6, 7, 8, 9)] + ["later"]
            all_workspaces = subprocess.run([RUI, "sessions", "--store", store, "--all"],
                cwd=root, capture_output=True, text=True, timeout=10)
            assert all_workspaces.returncode == 0, all_workspaces.stderr
            assert all_workspaces.stdout.count("Session: ") == 11
            assert "Bash runs without approval" in all_workspaces.stdout
            assert exchange(address, "list-sessions", {**base("list_sessions"), "workspace": None, "after": "12", "ceiling": "11"})[0] == 400
            long_reference = "x" * 126 + "\x01\x00"
            assert configure("long-reference", long_reference, str(root))[1]["answer"]["status"] == "accepted"
            for index in range(88):
                assert configure(f"dormant-{index}", f"dormant/{index:03}", str(root))[1]["answer"]["status"] == "accepted"
            after_growth = listing(str(root))
            assert after_growth[0] == 200 and len(after_growth[1]["sessions"]) == 8
            assert len(json.dumps(after_growth[1]).encode()) < 4096
            safe = subprocess.run([RUI, "sessions", "--store", store, "--all"],
                cwd=root, capture_output=True, text=True, timeout=10)
            assert safe.returncode == 0 and "\\x00" in safe.stdout and "\x00" not in safe.stdout, safe
            cursor = after_growth[1]["next"]
            seen = [item["reference"] for item in after_growth[1]["sessions"]]
            while cursor:
                status, page = listing(str(root), cursor)
                assert status == 200 and len(page["sessions"]) <= 8
                seen.extend(item["reference"] for item in page["sessions"])
                cursor = page["next"]
            assert seen == [names[i] for i in (0, 1, 2, 4, 5, 6, 7, 8, 9)] + ["later", long_reference] + [f"dormant/{i:03}" for i in range(88)]
            grown = linux_resources(process.pid)
            if baseline and grown:
                assert grown["fds"] == baseline["fds"], (baseline, grown)
            assert list(home.iterdir()) == [], "Host discovery unexpectedly wrote a local request registry"
            assert list((store / "scratch").iterdir()) == [], "named list capture leaked scratch"
            print(f"Session list native Host: fresh HOME, exact keyset, 100 dormant, long reference, idle resources 0→100: {baseline}→{grown}")
        finally:
            stop_process(process)
            if original_home is None:
                del os.environ["HOME"]
            else:
                os.environ["HOME"] = original_home


if __name__ == "__main__":
    main()

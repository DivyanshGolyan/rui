#!/usr/bin/env python3
"""Native Host wire proof for configured-only Session discovery (no local records)."""

import fcntl
import json
import os
import pathlib
import pty
import select
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time

from host_process import start_ready_process, stop_process


RUI = pathlib.Path(sys.argv[1]).resolve()
CLIENT = pathlib.Path(sys.argv[2]).resolve()


def exchange(socket_path, route, request):
    body = json.dumps(request, ensure_ascii=True, separators=(",", ":")).encode()
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(10)
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


def configuration(store, key, reference, workspace, complete=True):
    return {
        "version": "1", "kind": "configure", "store": str(store),
        "key": key, "session": reference,
        "configuration": {
            "workspace": {"state": "value", "value": workspace} if complete else {"state": "omitted"},
            "provider": {"state": "value", "value": "codex"},
            "model": {"state": "value", "value": "model-a"},
            "instructions": {"state": "omitted"},
            "tools": {"state": "omitted"},
            "permission_mode": {"state": "omitted"},
            "output_schema": {"state": "omitted"},
        },
    }


def linux_resources(pid):
    status = pathlib.Path(f"/proc/{pid}/status")
    if not status.exists():
        return None
    rss = next(int(line.split()[1]) for line in status.read_text().splitlines() if line.startswith("VmRSS:"))
    return {"rss_kib": rss, "fds": len(list(pathlib.Path(f"/proc/{pid}/fd").iterdir()))}


def dormant_resources():
    if sys.platform != "linux":
        print("Session list FD population check unavailable: requires Linux /proc")
        return
    with tempfile.TemporaryDirectory(prefix="rui-session-list-resources-") as temporary:
        root = pathlib.Path(temporary).resolve()
        store = root / "store"
        store.mkdir(mode=0o700)
        process, fields = start_ready_process(
            [RUI, "serve", "--store", store, "--active-capacity", "1"],
            required_fields={"execution": "unavailable"},
        )
        try:
            def listing(cursor=None):
                return exchange(fields["socket"], "list-sessions", {
                    "version": "1", "kind": "list_sessions", "store": str(store),
                    "workspace": None, **(cursor or {"after": "0", "ceiling": "0"}),
                })

            # Only raw exchanges run on this Host. EOF follows report/socket
            # release; readiness and public-client body completion do not.
            status, reply = exchange(fields["socket"], "inspect-session", {
                "version": "1", "kind": "inspect_session", "store": str(store),
                "session": "not-configured",
            })
            assert status == 200, reply
            baseline = linux_resources(process.pid)
            assert baseline is not None
            assert listing() == (200, {
                "version": "1", "type": "session_list", "sessions": [], "next": None,
            })
            first = linux_resources(process.pid)
            assert first["fds"] == baseline["fds"], ("first empty list retained capture", baseline, first)
            names = [f"dormant/{99 - index:03}" for index in range(100)]
            for index, reference in enumerate(names):
                status, reply = exchange(fields["socket"], "configure",
                    configuration(store, f"created-{index}", reference, str(root)))
                assert status == 200 and reply["answer"]["status"] == "accepted", reply
            seen = []
            cursor = None
            for offset in range(0, 100, 8):
                status, page = listing(cursor)
                assert status == 200 and page["version"] == "1" and page["type"] == "session_list", page
                expected = [{
                    "reference": name, "workspace": str(root), "provider": "codex",
                    "model": "model-a", "tools": ["bash"], "permission_mode": "bypass",
                } for name in names[offset:offset + 8]]
                assert page["sessions"] == expected, page
                assert len(json.dumps(page).encode()) < 4096
                seen.extend(row["reference"] for row in page["sessions"])
                cursor = page["next"]
                if offset + 8 < 100:
                    assert cursor == {"after": str(offset + 8), "ceiling": "100"}, cursor
                else:
                    assert cursor is None, cursor
            assert seen == names
            grown = linux_resources(process.pid)
            # One exact sample, not a retry-to-equality. EOF establishes FD
            # release, not subsequent thread/admission teardown or idle RSS.
            assert grown["fds"] == baseline["fds"], (baseline, grown)
            assert list((store / "scratch").iterdir()) == [], "named list capture leaked scratch"
            print(f"Session list raw EOF resources 0→100: {baseline}→{grown}")
        finally:
            stop_process(process)


def read_terminal(master, marker, initial=""):
    output = initial.encode()
    deadline = time.monotonic() + 15
    if marker == "> ":
        marker = "\r> \r\x1b[2C"
    while marker.encode() not in output:
        assert time.monotonic() < deadline, (marker, output[-2000:])
        assert select.select([master], [], [], deadline - time.monotonic())[0], (marker, output[-2000:])
        output += os.read(master, 65536)
        assert len(output) < 100_000, "unbounded terminal output"
    return output.decode(errors="replace").replace("\r\n", "\n")


def main():
    with tempfile.TemporaryDirectory(prefix="rui-session-list-") as temporary:
        root = pathlib.Path(temporary).resolve()
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
            # A rejected configuration creates a request fact but no Session.
            def configure(key, reference, workspace, complete=True):
                return exchange(address, "configure", configuration(store, key, reference, workspace, complete))

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
            # Resume from Host facts, without a request-file index or local
            # credentials. Direct and picked entry preserve the bound settings.
            def pty_session(args, steps):
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
                child = subprocess.Popen([RUI, *args], cwd=root, env={**os.environ, "HOME": str(home)},
                    stdin=slave, stdout=slave, stderr=slave)
                os.close(slave)
                try:
                    output = read_terminal(master, steps[0][1])
                    for command, marker in steps[1:]:
                        os.write(master, (command + "\n").encode())
                        if marker is not None:
                            # The independent next draft can repaint while a
                            # command reads. Its prompt is not a response.
                            response_marker = ("No older page" if command == "/history" else
                                "Session: " if command.startswith("/resume ") else None)
                            if response_marker is not None and marker == "> ":
                                response = read_terminal(master, response_marker)
                                head, separator, tail = response.partition(response_marker)
                                output += head + separator + read_terminal(master, marker, initial=tail)
                            else:
                                output += read_terminal(master, marker)
                    assert child.wait(timeout=5) == 0, output
                    return output
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait(timeout=5)
                    os.close(master)

            direct = pty_session(["--resume", names[0], "--store", str(store)],
                [(None, "> "), ("/history", "> "), ("/exit", "Detached.")])
            assert f"Session: {names[0]}" in direct and "Permission: bypass" in direct
            assert "No older page" in direct
            picked = pty_session(["--resume", "--store", str(store)],
                [(None, "\x1b[?2004h> "), ("1", "> "), ("/resume " + names[2], "> "),
                    ("/exit", "Detached.")])
            assert f"1. {names[0]}" in picked and f"Session: {names[2]}" in picked
            all_scope = pty_session(["--resume", "--store", str(store)],
                [(None, "\x1b[?2004h> "), ("a", "\x1b[?2004h> "), ("4", "> "), ("/exit", "Detached.")])
            assert f"Session: {names[3]}" in all_scope and f"Workspace (Bash cwd): {other}" in all_scope
            next_page = pty_session(["--resume", "--store", str(store)],
                [(None, "\x1b[?2004h> "), ("n", "\x1b[?2004h> "), ("1", "> "), ("/exit", "Detached.")])
            assert f"Session: {names[9]}" in next_page, next_page
            cancelled = pty_session(["--resume", "--store", str(store)],
                [(None, "\x1b[?2004h> "), ("invalid", "\x1b[?2004h> "), ("l", None)])
            assert "No Session selected" in cancelled and "Session: " not in cancelled
            non_tty = subprocess.run([RUI, "--resume", names[0], "--store", store],
                cwd=root, capture_output=True, text=True, timeout=10)
            assert non_tty.returncode != 0 and "needs a terminal" in non_tty.stderr
            assert not list(home.iterdir()), "resume created private Session/recovery files"
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
            assert safe.returncode == 0 and "\\x01\\x00" in safe.stdout and "\x01" not in safe.stdout and "\x00" not in safe.stdout, safe
            cursor = after_growth[1]["next"]
            seen = [item["reference"] for item in after_growth[1]["sessions"]]
            while cursor:
                status, page = listing(str(root), cursor)
                assert status == 200 and len(page["sessions"]) <= 8
                seen.extend(item["reference"] for item in page["sessions"])
                cursor = page["next"]
            assert seen == [names[i] for i in (0, 1, 2, 4, 5, 6, 7, 8, 9)] + ["later", long_reference] + [f"dormant/{i:03}" for i in range(88)]
            assert list(home.iterdir()) == [], "Host discovery unexpectedly wrote a local request registry"
            assert list((store / "scratch").iterdir()) == [], "named list capture leaked scratch"
            print("Session list native Host: fresh HOME, exact keyset, 100 dormant, long reference, public client/CLI/PTy")
        finally:
            stop_process(process)
            if original_home is None:
                del os.environ["HOME"]
            else:
                os.environ["HOME"] = original_home
    dormant_resources()


if __name__ == "__main__":
    main()

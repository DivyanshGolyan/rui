#!/usr/bin/env python3
"""Native Host wire proof for configured-only Session discovery (no local records)."""

import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

from host_process import HostDiagnostics, canonical_fixture_root, start_ready_process, stop_process


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
    identities = {}
    for entry in pathlib.Path(f"/proc/{pid}/fd").iterdir():
        metadata = entry.stat()
        identities[int(entry.name)] = (metadata.st_dev, metadata.st_ino,
                                      metadata.st_mode, os.readlink(entry))
    return {"rss_kib": rss, "fds": len(identities), "identities": identities}


def trace_u64(record, field):
    value = record.get(field, "")
    assert isinstance(value, str) and 0 < len(value) <= 20 and value.isascii() and value.isdecimal(), (f"invalid trace {field}", record)
    assert str(int(value)) == value and int(value) < 2**64, (f"invalid trace {field}", record)
    return int(value)


def released_resources(pid, diagnostics, invocation):
    if sys.platform != "linux":
        return None  # Native descriptor evidence remains Linux-only.
    began_ns, ended_ns, deadline = invocation
    with diagnostics.condition:
        while True:
            assert diagnostics.read_error is None, diagnostics.read_error
            starts, releases, runs, sequences = {}, {}, set(), []
            for record in diagnostics.records:
                phase = record["rui_test_phase"]
                assert isinstance(phase, str), record
                if phase in ("release_probe_held", "release_probe_leaked"):
                    continue  # Opt-in native proof records, not Host authority.
                assert record.get("process") == str(pid) and record.get("clock") == "awake_ns", record
                assert record.get("trace_lost") is False, record
                for field in ("run", "sequence", "at_ns"):
                    trace_u64(record, field)
                sequences.append(int(record["sequence"]))
                runs.add(record["run"])
                assert len(runs) == 1, runs
                if not (phase.startswith("connection_request_") or phase == "connection_resources_released"):
                    continue
                assert record.get("subject_kind") == "request_number", record
                trace_u64(record, "subject")
                subject = record["subject"]
                if phase == "connection_resources_released":
                    trace_u64(record, "scratch_used_bytes")  # Every release, not just the selected one.
                namespace = (record["process"], record["run"], record["subject_kind"], subject)
                target = releases if phase == "connection_resources_released" else starts
                assert namespace not in target, ("duplicate exchange milestone", record)
                target[namespace] = record
            assert sequences == sorted(set(sequences)), sequences
            if sequences:
                assert sequences[0] > 0, sequences
                assert sequences == list(range(sequences[0], sequences[0] + len(sequences))), ("trace sequence gap", sequences)
            assert releases.keys() <= starts.keys(), ("orphan release", releases)
            current = [(key, record) for key, record in starts.items()
                       if record["rui_test_phase"] == "connection_request_list_sessions"
                       and began_ns <= int(record["at_ns"]) <= ended_ns]
            assert len(current) <= 1, ("ambiguous native exchange", current)
            if current:
                current_identity, start = current[0]
                prefix = {key: record for key, record in starts.items()
                          if int(record["sequence"]) <= int(start["sequence"])}
                # The controlled fresh Host has no unobserved callers. Missing
                # starts must not conceal an earlier pending cleanup owner.
                assert len(prefix) == int(current_identity[3]) + 1, prefix
                assert {int(key[3]) for key in prefix} == set(range(len(prefix))), prefix
                if prefix.keys() <= releases.keys():
                    for identity, record in prefix.items():
                        assert int(releases[identity]["sequence"]) > int(record["sequence"]), identity
                        assert int(releases[identity]["at_ns"]) >= int(record["at_ns"]), identity
                    last_release = max((releases[key] for key in prefix), key=lambda record: int(record["sequence"]))
                    assert last_release["scratch_used_bytes"] == "0", ("retained scratch charge", last_release)
                    assert time.monotonic() <= deadline, "release exceeded original command budget"
                    census = linux_resources(pid)
                    assert census is not None, "Host vanished before resource census"
                    return census
            remaining = deadline - time.monotonic()
            assert remaining > 0, ("missing exchange release within original command budget", diagnostics.records[-8:])
            diagnostics.condition.wait(remaining)


def assert_resources(baseline, current):
    assert current["fds"] == baseline["fds"], (baseline, current)
    assert current["identities"] == baseline["identities"], (baseline, current)


def main():
    with tempfile.TemporaryDirectory(prefix="rui-session-list-") as temporary:
        root = canonical_fixture_root(temporary)
        store = root / "store"
        store.mkdir(mode=0o700)
        other = root / "other"
        other.mkdir()
        home = root / "fresh-home"
        home.mkdir()
        original_home = os.environ.get("HOME")
        os.environ["HOME"] = str(home)
        process, fields = start_ready_process([RUI, "serve", "--store", store, "--active-capacity", "1", "--test-phase-trace"], required_fields={"execution": "unavailable"})
        diagnostics = HostDiagnostics(process)
        try:
            address = fields["socket"]
            latest_invocation = None
            def base(kind):
                return {"version": "1", "kind": kind, "store": str(store)}

            def listing(workspace=None, cursor=None):
                nonlocal latest_invocation
                cursor = cursor or {"after": "0", "ceiling": "0"}
                began_ns = time.monotonic_ns()
                deadline = time.monotonic() + 10
                result = subprocess.run(
                    [CLIENT, store, workspace if workspace is not None else "-", cursor["after"], cursor["ceiling"]],
                    capture_output=True, timeout=10,
                )
                latest_invocation = (began_ns, time.monotonic_ns(), deadline)
                assert result.returncode == 0, (result.returncode, result.stderr[-2000:])
                return 200, json.loads(result.stdout)

            initial = listing()
            assert initial == (200, {"version": "1", "type": "session_list", "sessions": [], "next": None}), initial
            baseline = released_resources(process.pid, diagnostics, latest_invocation)
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
            grown = released_resources(process.pid, diagnostics, latest_invocation)
            if baseline and grown:
                assert_resources(baseline, grown)
            assert list(home.iterdir()) == [], "Host discovery unexpectedly wrote a local request registry"
            assert list((store / "scratch").iterdir()) == [], "named list capture leaked scratch"
            print(f"Session list native Host: fresh HOME, exact keyset, 100 dormant, long reference, idle resources 0→100: {baseline}→{grown}")
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)
            diagnostics.close()  # Drain stderr before stop_process closes it.
            stop_process(process)
            if original_home is None:
                del os.environ["HOME"]
            else:
                os.environ["HOME"] = original_home


if __name__ == "__main__":
    main()
    from session_list_facts_integration import main as facts_main
    facts_main()

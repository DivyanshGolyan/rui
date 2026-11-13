"""Session-list value and resource assertions shared by native caller fixtures."""
import os
import pathlib
import re
import time

import host_process
import os_semantics


def assert_empty_full(page):
    """A first listing of a Store with no Sessions: everything, which is nothing."""
    assert {key: value for key, value in page.items() if key != "since"} == {
        "version": host_process.WIRE_VERSION, "type": "session_list", "sessions": [], "delta": "full", "next": None,
        "archived": False}, page
    assert re.fullmatch(r"[0-9a-f]{32}\.(0|[1-9][0-9]*)", page["since"]), page


def session_values(page):
    """All per-Session facts, without the Store-wide read freshness stamp.

    A rejected command commits a record without changing any Session. The
    next read_version can therefore change on every row; it is not a Session
    mutation. Require its canonical wire form rather than ignoring omissions.
    """
    result = []
    for incoming in page["sessions"]:
        row = incoming.copy()
        version = row.pop("read_version")
        assert re.fullmatch(r"[0-9a-f]{32}\.(0|[1-9][0-9]*)", version), version
        assert int(version.split(".")[1]) < 2**64, version
        result.append(row)
    return result


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
    began_ns, ended_ns, deadline = invocation
    with diagnostics.condition:
        while True:
            assert diagnostics.read_error is None, diagnostics.read_error
            starts, releases, runs, sequences = {}, {}, set(), []
            loss_seen = False
            for record in diagnostics.records:
                phase = record["rui_test_phase"]
                assert isinstance(phase, str), record
                if phase in ("release_probe_held", "release_probe_leaked"):
                    continue  # Opt-in native proof records, not Host authority.
                assert record.get("process") == str(pid) and record.get("clock") == "awake_ns", record
                assert isinstance(record.get("trace_lost"), bool), record
                assert not loss_seen or record["trace_lost"], ("trace loss is not sticky", record)
                loss_seen = record["trace_lost"]
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
                    if not os_semantics.PROC_FS:
                        return None  # Only the /proc resource census is Linux-specific.
                    census = linux_resources(pid)
                    assert census is not None, "Host vanished before resource census"
                    return census
            remaining = deadline - time.monotonic()
            assert remaining > 0, ("missing exchange release within original command budget", diagnostics.records[-8:])
            diagnostics.condition.wait(remaining)


def assert_resources(baseline, current):
    assert current["fds"] == baseline["fds"], (baseline, current)
    assert current["identities"] == baseline["identities"], (baseline, current)

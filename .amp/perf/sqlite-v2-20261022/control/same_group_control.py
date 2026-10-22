#!/usr/bin/env python3
"""Matched causal control for the bash-integration same-group timeout failure.

Usage: same_group_control.py RUI_BINARY OUTPUT_JSON TRIALS

Runs the exact failing fixture command (100 ms Bash timeout) TRIALS times on
one Host built from RUI_BINARY. Two `$EPOCHREALTIME` markers are added: one
before the command and one after its PID publication. The Host's phase trace
supplies the deadline (spawn + 100 ms, CLOCK_MONOTONIC) and the time it
serviced the deadline. Per trial it records:
  spawn->script start, spawn->PID published, spawn->deadline serviced,
whether the PID was published before the kill, and the resolution.
Diagnostic only; nothing here is a product or qualification check.
"""
import json
import pathlib
import sys
import tempfile
import threading
import time

binary, output, trials = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3])
sys.argv = [sys.argv[0], binary]  # model_fixture reads RUI from argv[1]
import model_fixture as fixture  # noqa: E402
import bash_integration as bash  # noqa: E402
from host_process import HostDiagnostics  # noqa: E402

TIMEOUT_MS = 100
state = pathlib.Path(tempfile.mkdtemp(prefix="rui-same-group-control."))
store = state / "store"
markers = state / "markers"
markers.mkdir()
responses = []
for i in range(trials):
    start, published, pid = (markers / f"{i}-start", markers / f"{i}-published", markers / f"{i}-pid")
    command = (
        f"printf %s \"$EPOCHREALTIME\" > {start}; "
        f"(trap '' TERM; exec >/dev/null 2>&1; sleep 30) & child=$!; "
        f"{bash.publish_pid(pid, '$child')}; printf %s \"$EPOCHREALTIME\" > {published}; wait \"$child\""
    )
    bash.add_exchange(responses, f"control-{i}", command, timeout_ms=TIMEOUT_MS)
endpoint = fixture.SuccessEndpoint(responses)
threading.Thread(target=endpoint.serve_forever, daemon=True).start()
host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses", "--test-phase-trace")
diagnostics = HostDiagnostics(host)
rows = []
try:
    for i in range(trials):
        session = f"direct/control-{i}"
        bash.configure(state, store, f"c{i}", session)
        fixture.message(state, store, f"m{i}", session, "execute")
        action = fixture.wait_for(lambda: bash.action_for(store, session), "control Action")
        bash.allow(state, store, f"a{i}", session, action["action"])
        fixture.wait_for(lambda: bash.resolution(store, session) is not None, "control resolution", timeout=20)
        fixture.wait_for(lambda: fixture.completed_observation(store, f"m{i}"), "control continuation")
        rows.append({"trial": i, "action": action["action"], "resolution": bash.resolution(store, session)})
    time.sleep(0.5)
    # Map CLOCK_MONOTONIC (Zig .awake) to realtime once, bracketing the read.
    a, m, b = time.time(), time.monotonic(), time.time()
    offset = (a + b) / 2 - m
    deadlines = {r["action"]: r for r in diagnostics.records if r.get("rui_test_phase") == "bash_deadline_established"}
    serviced = {r["action"]: r for r in diagnostics.records if r.get("rui_test_phase") == "bash_deadline_serviced"}
    for row in rows:
        i, action = row["trial"], row["action"]
        # The phase trace is lossy under load; either deadline record carries deadline_ns.
        source = deadlines.get(action) or serviced.get(action)
        deadline_ns = int(source["deadline_ns"]) if source else None
        spawn = deadline_ns / 1e9 - TIMEOUT_MS / 1000 + offset if source else None
        def ms(path):
            return round((float(path.read_text()) - spawn) * 1000, 3) if path.exists() and path.read_text() and spawn is not None else None
        row.update({
            "spawn_to_script_start_ms": ms(markers / f"{i}-start"),
            "spawn_to_pid_published_ms": ms(markers / f"{i}-published"),
            "pid_published": (markers / f"{i}-pid").exists(),
            "spawn_to_deadline_serviced_ms": (round((int(serviced[action]["at_ns"]) - deadline_ns) / 1e6 + TIMEOUT_MS, 3)
                                              if action in serviced and deadline_ns is not None else None),
            "trace_missing": [name for name, table in (("established", deadlines), ("serviced", serviced)) if action not in table],
        })
finally:
    fixture.stop_host(host)
    endpoint.shutdown()
output.write_text(json.dumps({"binary": binary, "timeout_ms": TIMEOUT_MS, "state": str(state), "rows": rows}, indent=1) + "\n")
print(json.dumps({"binary": binary, "trials": len(rows),
                  "published": sum(r["pid_published"] for r in rows),
                  "resolutions": sorted({r["resolution"] for r in rows})}))

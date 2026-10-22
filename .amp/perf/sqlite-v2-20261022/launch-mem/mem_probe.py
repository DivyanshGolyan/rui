#!/usr/bin/env python3
"""Pre-spawn Host memory probe. Usage: mem_probe.py RUI_BINARY OUTPUT_JSON

Runs the exact same-group fixture command (timeout_ms=100) once, with the Host's existing
--test-before-launch-delay-ms hold at prepared_before_handoff. While the Host sleeps there (after
Attempt admission and Bash preparation, before the dispatch handoff and spawn) it reads
/proc/<host>/status, /proc/<host>/maps and /proc/<host>/smaps_rollup. After the trial it runs
`session inspect` through the Host, which emits the Host's own in-connection PRAGMA diagnostic
(--test-sqlite-diagnostics); no outside Store reader is opened. Diagnostic only.
"""
import json, os, pathlib, sys, tempfile, threading
binary, output = sys.argv[1], pathlib.Path(sys.argv[2])
sys.argv = [sys.argv[0], binary]
import model_fixture as fixture  # noqa: E402
import bash_integration as bash  # noqa: E402
from host_process import HostDiagnostics  # noqa: E402
state = pathlib.Path(tempfile.mkdtemp(prefix="rui-launch-mem."))
store, pidfile = state / "store", state / "pid"
command = (f"(trap '' TERM; exec >/dev/null 2>&1; sleep 30) & child=$!; "
           f"{bash.publish_pid(pidfile, '$child')}; wait \"$child\"")
responses = []
bash.add_exchange(responses, "mem", command, timeout_ms=100)
endpoint = fixture.SuccessEndpoint(responses)
threading.Thread(target=endpoint.serve_forever, daemon=True).start()
host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses", "--test-phase-trace",
                          "--test-sqlite-diagnostics", "--test-before-launch-delay-ms", "400")
diagnostics = HostDiagnostics(host)
def phase(name):
    return [r for r in diagnostics.records if r.get("rui_test_phase") == name]
sample = {}
try:
    session = "direct/mem"
    bash.configure(state, store, "c", session)
    fixture.message(state, store, "m", session, "execute")
    action = fixture.wait_for(lambda: bash.action_for(store, session), "Action")
    bash.allow(state, store, "a", session, action["action"])
    fixture.wait_for(lambda: phase("prepared_before_handoff"), "prepared_before_handoff", timeout=20)
    proc = pathlib.Path(f"/proc/{host.pid}")
    status = {k: v.strip() for k, v in (l.split(":", 1) for l in (proc / "status").read_text().splitlines())}
    maps = (proc / "maps").read_text().splitlines()
    sample = {
        "status": {k: status.get(k) for k in ("VmPTE", "VmRSS", "RssAnon", "RssFile", "RssShmem", "VmSize", "VmData", "Threads")},
        "vma_count": len(maps),
        "maps": maps,
        "smaps_rollup": (proc / "smaps_rollup").read_text(),
        "children_before": (proc / "task" / str(host.pid) / "children").read_text(),
    }
    fixture.wait_for(lambda: bash.resolution(store, session) is not None, "resolution", timeout=20)
    fixture.wait_for(lambda: fixture.completed_observation(store, "m"), "continuation")
    fixture.command("session", "inspect", "--store", store, "--session", session)
    fixture.wait_for(lambda: phase("sqlite_diagnostic"), "sqlite_diagnostic")
    sample["resolution"] = bash.resolution(store, session)
    sample["sqlite_diagnostic"] = phase("sqlite_diagnostic")[-1]
    sample["host_pid"] = host.pid
finally:
    if pidfile.exists():
        try: os.kill(int(pidfile.read_text()), 9)
        except (ProcessLookupError, ValueError): pass
    fixture.stop_host(host)
    endpoint.shutdown()
output.write_text(json.dumps({"binary": binary, **sample}, indent=1) + "\n")
print(json.dumps({"binary": binary, "vma_count": sample.get("vma_count"), **sample.get("status", {})}))

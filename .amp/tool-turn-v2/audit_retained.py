#!/usr/bin/env python3
"""Read-only retrospective audit of retained tool-turn runs under the
corrected acceptance rules (Sol R1-R3).

Inputs: campaign directories of final JSONs; each JSON names its artifact
directory, whose Store, provider tool-facts.json and TUI transcript were kept.
Stores are opened with SQLite immutable read-only URIs; nothing is written.
Every check reports pass, fail or unavailable; nothing is assumed.
"""
import json, pathlib, sqlite3, sys


def session(n, i):
    return f"measure/tool-{n}/coordinator" if i == 0 else f"measure/tool-{n}/worker-{i:03d}"


RUI = "/home/user/workspace/.perf-tool/build-d4f87000/bin/rui"


def store_checks(store, n):
    """Serve the retained Store in place (its identity is its path) and read
    every original request through the product's own readers. The SQLite
    bytes and diagnostics are backed up first and restored after; their
    SHA-256 must match afterwards."""
    import hashlib, shutil, subprocess, tempfile, time
    digest = lambda path: hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    before = digest(store / "rui.sqlite3")
    backup = pathlib.Path(tempfile.mkdtemp())
    shutil.copy2(store / "rui.sqlite3", backup / "rui.sqlite3")
    shutil.copytree(store / "diagnostics", backup / "diagnostics")
    db = sqlite3.connect(f"file:{store}/rui.sqlite3?mode=ro&immutable=1", uri=True)
    rows = db.execute("SELECT session_ref, command_key, sender_session_ref FROM message_admission ORDER BY admission_id").fetchall()
    db.close()
    env = {"HOME": str(backup / "home"), "PATH": "/usr/bin:/bin"}
    (backup / "home").mkdir()
    host = subprocess.Popen([RUI, "host", "serve", "--store", str(store), "--active-capacity", "100", "--provider-endpoint", "https://127.0.0.1:9/responses"],
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    problems = []
    try:
        if not host.stdout.readline().startswith(b"ready"):
            raise RuntimeError("audit Host not ready: " + host.stderr.read().decode())
        by_session = {}
        for ref, key, sender in rows:
            by_session.setdefault(ref, []).append((key, sender))
        def result(key):
            observed = json.loads(subprocess.run([RUI, "request", "inspect", "--store", str(store), "--key", key], env=env, capture_output=True, check=True).stdout)
            text = subprocess.run([RUI, "request", "read-result", "--store", str(store), "--key", key], env=env, capture_output=True).stdout
            return observed["observation"].get("result", {}).get("status"), text
        for i in range(n):
            name = session(n, i)
            items = by_session.pop(name, [])
            seeds = [x for x in items if x[0] == f"seed-{i:03d}"]
            work = [x for x in items if x[0] != f"seed-{i:03d}"]
            if len(seeds) != 1 or result(seeds[0][0]) != ("completed", f"seeded {name}".encode()):
                problems.append(f"{name}: seed")
            if len(work) != 1:
                problems.append(f"{name}: {len(work)} non-seed admissions")
                continue
            key, sender = work[0]
            status, text = result(key)
            if status != "completed" or text != f"tool turn complete {name}".encode():
                problems.append(f"{name}: original request {key} {status} {text!r}")
            if i > 0 and (key != f"dispatch-{i:03d}" or sender != session(n, 0)):
                problems.append(f"{name}: dispatch key {key} sender {sender}")
            if i == 0 and sender is not None:
                problems.append(f"{name}: coordinator request has sender {sender}")
        if by_session:
            problems.append(f"unexpected sessions {sorted(by_session)}")
    finally:
        subprocess.run([RUI, "host", "stop", "--store", str(store)], env=env, capture_output=True)
        try:
            host.wait(timeout=20)
        except subprocess.TimeoutExpired:
            host.kill()
            host.wait()
            problems.append("audit Host needed SIGKILL")
        shutil.copy2(backup / "rui.sqlite3", store / "rui.sqlite3")
        shutil.rmtree(store / "diagnostics")
        shutil.copytree(backup / "diagnostics", store / "diagnostics")
        for extra in ("rui.sqlite3-wal", "rui.sqlite3-shm"):
            (store / extra).unlink(missing_ok=True)
        if digest(store / "rui.sqlite3") != before:
            problems.append("Store bytes not restored")
        shutil.rmtree(backup)
    return problems


def call_checks(facts, n, barrier):
    problems, unavailable = [], ["duplicate outputs for one call ID: provider stored outputs in a map, so duplicates were collapsed and cannot be detected retrospectively"]
    rows = facts["session_facts"]
    if len(rows) != n:
        return [f"{len(rows)} session facts"], unavailable
    for fact in rows:
        i = fact["index"]
        expected = {f"tool-{i:03d}-workload": "workload"}
        if i == 0:
            expected.update({f"tool-000-dispatch-{w:03d}": "dispatch" for w in range(1, n)})
        got = {o["call_id"]: o for o in fact["outputs"]}
        if set(got) != set(expected) or len(fact["outputs"]) != len(expected):
            problems.append(f"{fact['session']}: ids {sorted(set(got) ^ set(expected))[:4]}")
            continue
        for call_id, kind in expected.items():
            o = got[call_id]
            if o["kind"] != kind or not o["succeeded"]:
                problems.append(f"{call_id}: kind {o['kind']} succeeded {o['succeeded']}")
            start, end = o.get("shell_start_unix_ns", 0), o.get("shell_end_unix_ns", 0)
            if not start or not end or end < start:
                problems.append(f"{call_id}: markers {start} {end}")
            if barrier and kind == "workload":
                park = o.get("shell_park_unix_ns", 0)
                # A shell read timeout needs 120 s parked; anything shorter was released.
                if not park or park > start or start - park >= 120e9:
                    problems.append(f"{call_id}: park {park} start {start}")
    return problems, unavailable


def main():
    results = []
    for campaign in sys.argv[1:]:
        for path in sorted(pathlib.Path(campaign).glob("*.json")):
            run = json.loads(path.read_text())
            n, art = run["sessions"], pathlib.Path(run["artifacts"])
            barrier = run.get("barrier", False)
            row = {"campaign": campaign, "label": path.stem, "sessions": n, "barrier": barrier, "recorded_status": run["status"]}
            try:
                row["r1_store_problems"] = store_checks(art / "store", n)
            except Exception as error:  # Missing or unreadable Store is unavailable, not a pass.
                row["r1_store_problems"] = None
                row["r1_unavailable"] = repr(error)
            row["tui_transcript"] = "not used: cursor-addressed frames split the answer text; the Store reader is authoritative"
            facts = json.loads((art / "provider" / "tool-facts.json").read_text())
            row["r2_problems"], row["r2_unavailable"] = call_checks(facts, n, barrier)
            if barrier:
                release = run.get("barrier_release") or {}
                overlap = run["concurrency"]["workload"]["max_overlapping"]
                row["r3_problems"] = [] if release.get("parked_at_release") == n and not release.get("timed_out") and (overlap == n or run["instrumented"]) else [f"release {release} overlap {overlap}"]
                if run["instrumented"]:
                    row["r3_note"] = f"strace run: overlap {overlap} of {n}, not used for concurrency"
            row["passes_corrected_rules"] = row["r1_store_problems"] == [] and row["r2_problems"] == [] and row.get("r3_problems", []) == []
            results.append(row)
    summary = {"runs": len(results), "pass": sum(r["passes_corrected_rules"] for r in results),
               "fail_or_unavailable": [r["label"] for r in results if not r["passes_corrected_rules"]]}
    print(json.dumps({"summary": summary, "runs": results}, indent=1))


main()

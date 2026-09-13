#!/usr/bin/env python3
"""Measure issue-174 retry discovery, launch separation, churn, and custody."""

import argparse
import http.server
import json
import os
import pathlib
import re
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "src"))
from host_process import start_ready_process, stop_process


CAPACITY = 16
OPERATIONS_PER_ROUND = 32
ROUNDS = 5
HISTORY_STAGES = (32, 128)


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def footprint_bytes(report, name):
    match = re.search(rf"{name}:\s+([0-9.]+) (B|KB|MB|GB)", report)
    if match is None:
        raise RuntimeError(f"could not parse macOS {name} counter")
    scale = {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3}[match.group(2)]
    return round(float(match.group(1)) * scale)


def cpu_seconds(pid):
    fields = command("ps", "-o", "time=", "-p", str(pid)).split(":")
    seconds = float(fields[-1])
    if len(fields) >= 2:
        seconds += int(fields[-2]) * 60
    if len(fields) == 3:
        seconds += int(fields[0]) * 3600
    return seconds


def sample(pid):
    rss_kib, virtual_kib = map(
        int, command("ps", "-o", "rss=,vsz=", "-p", str(pid)).split()
    )
    report = command("/usr/bin/footprint", "-p", str(pid))
    descriptors = command("/usr/sbin/lsof", "-n", "-P", "-p", str(pid)).splitlines()
    return {
        "rss_bytes": rss_kib * 1024,
        "virtual_bytes": virtual_kib * 1024,
        "physical_footprint_bytes": footprint_bytes(report, "phys_footprint"),
        "lifetime_peak_physical_footprint_bytes": footprint_bytes(
            report, "phys_footprint_peak"
        ),
        "open_descriptor_rows": max(0, len(descriptors) - 1),
        "open_retry_scratch_descriptors": sum(
            "request-" in row or "response-" in row for row in descriptors
        ),
    }


class Endpoint(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.lock = threading.Lock()
        self.counts = {}
        self.launches = {}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(body)
        marker = next(
            content["text"]
            for item in request["input"]
            if item.get("role") == "user"
            for content in item["content"]
            if content.get("type") == "input_text"
        )
        with self.server.lock:
            ordinal = self.server.counts.get(marker, 0) + 1
            self.server.counts[marker] = ordinal
            self.server.launches.setdefault(marker, []).append(time.time_ns() // 1_000_000)
        status = 503 if ordinal == 1 else 422
        payload = f"fixture-{status}".encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


def run(binary, *args):
    return subprocess.check_output([str(binary), *map(str, args)], text=True)


def start_host(binary, store, endpoint, capacity, *extra):
    return start_ready_process(
        [
            str(binary),
            "serve",
            "--store",
            str(store),
            "--active-capacity",
            str(capacity),
            "--provider-endpoint",
            endpoint,
            "--test-retry-waits-ms",
            "50,100,150",
            *extra,
        ],
        required_fields={
            "custody_record_bytes": None,
            "execution_slot_bytes": None,
        },
    )


def stop_host(host):
    stop_process(host)


def configure(binary, root, store, key, session):
    result = json.loads(
        run(
            binary,
            "configure",
            "--store",
            store,
            "--record",
            root / f"{key}.json",
            "--key",
            key,
            "--session",
            session,
            "--workspace",
            pathlib.Path.cwd(),
            "--model",
            "model-a",
        )
    )
    if result["answer"]["status"] != "accepted":
        raise RuntimeError(result)


def message(binary, root, store, key, session, text):
    source = root / f"{key}.txt"
    source.write_text(text)
    result = json.loads(
        run(
            binary,
            "message",
            "--store",
            store,
            "--record",
            root / f"{key}.json",
            "--key",
            key,
            "--session",
            session,
            "--text",
            source,
        )
    )
    if result["answer"]["status"] != "accepted":
        raise RuntimeError(result)


def wait_for(predicate, description, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise RuntimeError(f"timed out waiting for {description}")


def inspect_execution(binary, store, session):
    return json.loads(
        run(binary, "inspect-session", "--store", store, "--session", session)
    )["execution"]


def timing_measurement(binary, root, endpoint_server, endpoint):
    store = root / "timing-store"
    marker = "timing-operation"
    host, _ = start_host(
        binary,
        store,
        endpoint,
        1,
        "--test-retry-waits-ms",
        "600000,600000,600000",
    )
    try:
        configure(binary, root, store, "timing-config", "measure/timing")
        message(binary, root, store, "timing-message", "measure/timing", marker)
        wait_for(
            lambda: endpoint_server.counts.get(marker) == 1,
            "initial temporary response",
        )
        wait_for(
            lambda: inspect_execution(binary, store, "measure/timing")[
                "custody_occupied"
            ]
            == "0",
            "initial Attempt cleanup",
        )
    finally:
        stop_host(host)

    due_at_ms = time.time_ns() // 1_000_000 + 250
    database = sqlite3.connect(store / "latifa.sqlite3")
    try:
        row = database.execute(
            "SELECT operation_id,attempt_ordinal,allowance_used,uncertain,resolution_code "
            "FROM model_operation"
        ).fetchone()
        if row is None or row[1:] != (1, 1, 0, None):
            raise RuntimeError(f"unexpected initial retry facts: {row}")
        database.execute(
            "UPDATE model_operation SET retry_due_at_ms=? WHERE operation_id=?",
            (due_at_ms, row[0]),
        )
        database.commit()
    finally:
        database.close()

    started_ms = time.time_ns() // 1_000_000
    host, _ = start_host(
        binary,
        store,
        endpoint,
        1,
        "--test-before-launch-delay-ms",
        "250",
        "--test-retry-waits-ms",
        "600000,600000,600000",
    )
    try:
        def replacement_admitted():
            execution = inspect_execution(binary, store, "measure/timing")
            return (
                time.time_ns() // 1_000_000
                if execution["custody_occupied"] == "1"
                else None
            )

        discovered_at_ms = wait_for(replacement_admitted, "replacement admission")
        wait_for(
            lambda: len(endpoint_server.launches.get(marker, [])) == 2,
            "replacement launch",
        )
        launched_at_ms = endpoint_server.launches[marker][1]
        wait_for(
            lambda: inspect_execution(binary, store, "measure/timing")[
                "custody_occupied"
            ]
            == "0",
            "permanent replacement settlement",
        )
    finally:
        stop_host(host)

    database = sqlite3.connect(store / "latifa.sqlite3")
    try:
        facts = database.execute(
            "SELECT attempt_ordinal,allowance_used,resolution_code FROM model_operation"
        ).fetchone()
    finally:
        database.close()
    if facts != (2, 2, "provider_http_422"):
        raise RuntimeError(f"unexpected timing retry facts: {facts}")
    return {
        "retry_due_at_unix_ms": due_at_ms,
        "host_started_at_unix_ms": started_ms,
        "replacement_admitted_at_unix_ms": discovered_at_ms,
        "replacement_launched_at_unix_ms": launched_at_ms,
        "discovery_after_due_ms": discovered_at_ms - due_at_ms,
        "launch_after_discovery_ms": launched_at_ms - discovered_at_ms,
        "configured_prelaunch_delay_ms": 250,
        "endpoint_attempts": endpoint_server.counts[marker],
    }


def measure_due_history_replacement(
    binary,
    store,
    endpoint_server,
    endpoint,
    session,
    target_operation,
    target_marker,
    model_operations,
    unresolved_future,
):
    started_ms = time.time_ns() // 1_000_000
    host, _ = start_host(
        binary,
        store,
        endpoint,
        CAPACITY,
        "--test-before-launch-delay-ms",
        "250",
        "--test-retry-waits-ms",
        "600000,600000,600000",
    )
    try:
        def replacement_admitted():
            execution = inspect_execution(binary, store, session)
            return (
                time.time_ns() // 1_000_000
                if execution["custody_occupied"] == "1"
                else None
            )

        admitted_ms = wait_for(
            replacement_admitted,
            f"replacement behind {unresolved_future} future retries",
        )
        wait_for(
            lambda: endpoint_server.counts.get(target_marker) == 2,
            f"history target {model_operations} launch",
        )
        launched_ms = endpoint_server.launches[target_marker][1]
        wait_for(
            lambda: inspect_execution(binary, store, session)["custody_occupied"]
            == "0",
            f"history target {model_operations} settlement",
        )
    finally:
        stop_host(host)
    database = sqlite3.connect(store / "latifa.sqlite3")
    try:
        facts = database.execute(
            "SELECT attempt_ordinal,allowance_used,resolution_code "
            "FROM model_operation WHERE operation_id=?",
            (target_operation,),
        ).fetchone()
    finally:
        database.close()
    if facts != (2, 2, "provider_http_422"):
        raise RuntimeError(f"unexpected history target facts: {facts}")
    return {
        "model_operations": model_operations,
        "older_unresolved_future_retries": unresolved_future,
        "replacement_admitted_after_start_ms": admitted_ms - started_ms,
        "replacement_launched_after_start_ms": launched_ms - started_ms,
        "database_bytes": os.path.getsize(store / "latifa.sqlite3"),
    }


def unresolved_history_measurement(binary, root, endpoint_server, endpoint):
    store = root / "history-store"
    created = 0
    rows = []
    for target_history in HISTORY_STAGES:
        host, _ = start_host(
            binary,
            store,
            endpoint,
            CAPACITY,
            "--test-retry-waits-ms",
            "600000,600000,600000",
        )
        try:
            for ordinal in range(created, target_history):
                session = f"measure/history-{ordinal}"
                configure(binary, root, store, f"history-config-{ordinal}", session)
                message(
                    binary,
                    root,
                    store,
                    f"history-message-{ordinal}",
                    session,
                    f"history-operation-{ordinal}",
                )
            wait_for(
                lambda: sum(
                    count
                    for marker, count in endpoint_server.counts.items()
                    if marker.startswith("history-operation-")
                )
                == target_history + len(rows),
                f"{target_history} initial history Attempts",
                timeout=45,
            )
            wait_for(
                lambda: inspect_execution(
                    binary, store, f"measure/history-{target_history - 1}"
                )["custody_occupied"]
                == "0",
                f"{target_history} history cleanup",
            )
        finally:
            stop_host(host)

        target_marker = f"history-operation-{target_history - 1}"
        database = sqlite3.connect(store / "latifa.sqlite3")
        try:
            target_operation = database.execute(
                "SELECT operation_id FROM model_operation WHERE session_ref=?",
                (f"measure/history-{target_history - 1}",),
            ).fetchone()[0]
            database.execute(
                "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id=?",
                (target_operation,),
            )
            database.commit()
            unresolved_future = database.execute(
                "SELECT count(*) FROM model_operation WHERE resolution_code IS NULL "
                "AND retry_due_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER)"
            ).fetchone()[0]
        finally:
            database.close()

        rows.append(
            measure_due_history_replacement(
                binary,
                store,
                endpoint_server,
                endpoint,
                f"measure/history-{target_history - 1}",
                target_operation,
                target_marker,
                target_history,
                unresolved_future,
            )
        )
        created = target_history

    database = sqlite3.connect(store / "latifa.sqlite3")
    try:
        database.execute("PRAGMA foreign_keys=OFF")
        database.execute(
            "WITH RECURSIVE sequence(value) AS (VALUES(129) UNION ALL "
            "SELECT value+1 FROM sequence WHERE value<10128) "
            "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,"
            "admission_position,attempt_ordinal,allowance_used,uncertain,retry_due_at_ms) "
            "SELECT value,value,printf('synthetic-future-%d',value),1,1,1,1,1,0,9223372036854775807 "
            "FROM sequence"
        )
        database.commit()
    finally:
        database.close()

    host, _ = start_host(
        binary,
        store,
        endpoint,
        CAPACITY,
        "--test-retry-waits-ms",
        "600000,600000,600000",
    )
    try:
        cpu_before = cpu_seconds(host.pid)
        idle_started = time.monotonic()
        time.sleep(5)
        idle_elapsed = time.monotonic() - idle_started
        future_idle_cpu = 100 * (cpu_seconds(host.pid) - cpu_before) / idle_elapsed
        configure(
            binary,
            root,
            store,
            "history-config-10128",
            "measure/history-10128",
        )
        message(
            binary,
            root,
            store,
            "history-message-10128",
            "measure/history-10128",
            "history-operation-10128",
        )
        wait_for(
            lambda: endpoint_server.counts.get("history-operation-10128") == 1,
            "10,000-row history initial Attempt",
        )
        wait_for(
            lambda: inspect_execution(binary, store, "measure/history-10128")[
                "custody_occupied"
            ]
            == "0",
            "10,000-row history cleanup",
        )
    finally:
        stop_host(host)

    database = sqlite3.connect(store / "latifa.sqlite3")
    try:
        target_operation = database.execute(
            "SELECT operation_id FROM model_operation WHERE session_ref=?",
            ("measure/history-10128",),
        ).fetchone()[0]
        database.execute(
            "UPDATE model_operation SET retry_due_at_ms=1 WHERE operation_id=?",
            (target_operation,),
        )
        database.commit()
        unresolved_future = database.execute(
            "SELECT count(*) FROM model_operation WHERE resolution_code IS NULL "
            "AND retry_due_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER)"
        ).fetchone()[0]
        model_operations = database.execute(
            "SELECT count(*) FROM model_operation"
        ).fetchone()[0]
    finally:
        database.close()
    rows.append(
        measure_due_history_replacement(
            binary,
            store,
            endpoint_server,
            endpoint,
            "measure/history-10128",
            target_operation,
            "history-operation-10128",
            model_operations,
            unresolved_future,
        )
    )
    return {
        "stages": rows,
        "future_only_idle_cpu_percent_one_core": round(future_idle_cpu, 3),
        "future_only_idle_cpu_sample_seconds": round(idle_elapsed, 3),
        "qualification_limit_ms": 2000,
    }


def churn_measurement(binary, root, endpoint_server, endpoint):
    store = root / "churn-store"
    host, ready = start_host(
        binary,
        store,
        endpoint,
        CAPACITY,
        "--test-cleanup-delay-ms",
        "250",
    )
    rows = []
    try:
        baseline = sample(host.pid)
        for round_index in range(ROUNDS):
            for index in range(OPERATIONS_PER_ROUND):
                ordinal = round_index * OPERATIONS_PER_ROUND + index
                session = f"measure/churn-{ordinal}"
                configure(binary, root, store, f"churn-config-{ordinal}", session)
                message(
                    binary,
                    root,
                    store,
                    f"churn-message-{ordinal}",
                    session,
                    f"churn-operation-{ordinal}",
                )
            expected = (round_index + 1) * OPERATIONS_PER_ROUND
            wait_for(
                lambda: sum(
                    count
                    for marker, count in endpoint_server.counts.items()
                    if marker.startswith("churn-operation-")
                )
                == expected * 2,
                f"churn round {round_index + 1} endpoint Attempts",
                timeout=45,
            )
            execution = wait_for(
                lambda: (
                    value
                    if (value := inspect_execution(
                        binary, store, f"measure/churn-{expected - 1}"
                    ))["custody_occupied"]
                    == "0"
                    else None
                ),
                f"churn cleanup {round_index + 1}",
            )
            rows.append(
                {
                    "round": round_index + 1,
                    "terminal_operations": expected,
                    "database_bytes": os.path.getsize(store / "latifa.sqlite3"),
                    "execution": execution,
                    **sample(host.pid),
                }
            )

        if any(count != 2 for marker, count in endpoint_server.counts.items() if marker.startswith("churn-operation-")):
            raise RuntimeError("a churn Operation did not launch exactly twice")

        cpu_before = cpu_seconds(host.pid)
        idle_started = time.monotonic()
        time.sleep(2)
        idle_elapsed = time.monotonic() - idle_started
        idle_cpu = 100 * (cpu_seconds(host.pid) - cpu_before) / idle_elapsed
        retained_idle = sample(host.pid)
    finally:
        stop_host(host)

    database = sqlite3.connect(store / "latifa.sqlite3")
    try:
        attempt_rows = database.execute(
            "SELECT attempt_ordinal,allowance_used,resolution_code,count(*) "
            "FROM model_operation GROUP BY attempt_ordinal,allowance_used,resolution_code"
        ).fetchall()
    finally:
        database.close()
    if attempt_rows != [(2, 2, "provider_http_422", ROUNDS * OPERATIONS_PER_ROUND)]:
        raise RuntimeError(f"unexpected churn retry facts: {attempt_rows}")
    return {
        "active_capacity": CAPACITY,
        "operations_per_round": OPERATIONS_PER_ROUND,
        "rounds": rows,
        "baseline": baseline,
        "custody_record_bytes": int(ready["custody_record_bytes"]),
        "execution_slot_bytes": int(ready["execution_slot_bytes"]),
        "idle_cpu_percent_one_core": round(idle_cpu, 3),
        "idle_cpu_sample_seconds": round(idle_elapsed, 3),
        "retained_idle": retained_idle,
        "attempt_fact_groups": attempt_rows,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("measure-model-retry currently requires macOS footprint counters")
    binary = args.binary.resolve()
    endpoint_server = Endpoint()
    endpoint_thread = threading.Thread(target=endpoint_server.serve_forever, daemon=True)
    endpoint_thread.start()
    endpoint = f"http://127.0.0.1:{endpoint_server.server_port}/responses"
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix="latifa-retry-measure-") as temporary:
            root = pathlib.Path(temporary)
            result = {
                "scope": "issue-174 production retry discovery and custody churn",
                "status": "passed",
                "tested_revision": command("git", "rev-parse", "HEAD"),
                "working_tree_dirty": bool(command("git", "status", "--porcelain")),
                "binary_sha256": command("shasum", "-a", "256", str(binary)).split()[0],
                "zig": command("zig", "version"),
                "platform": command("uname", "-a"),
                "timing": timing_measurement(binary, root, endpoint_server, endpoint),
                "unresolved_history": unresolved_history_measurement(
                    binary, root, endpoint_server, endpoint
                ),
                "churn_and_delayed_cleanup": churn_measurement(
                    binary, root, endpoint_server, endpoint
                ),
                "elapsed_seconds": round(time.monotonic() - started, 3),
                "limits": [
                    "macOS Apple Silicon runtime evidence only; supported Linux and x86 targets are compile-only",
                    "deterministic loopback HTTP classifies no TLS trust store or live-provider behavior",
                    "a 250 ms fixture delay separates committed retry discovery from provider launch",
                    "10 ms inspect-session observation adds sampling delay and is not a Runtime clock",
                    "three production-store stages put 31, 126, then 10,126 older future retries before one due replacement",
                    "the 10,126-row future-only stage measures the simple age-index baseline without a deadline probe",
                    "five 32-Operation rounds exercise 0-to-capacity-to-0 custody churn with 250 ms delayed cleanup",
                    "process termination evidence is not power-loss qualification",
                ],
            }
            encoded = json.dumps(result, indent=2) + "\n"
            if args.output:
                args.output.write_text(encoded)
            else:
                print(encoded, end="")
    finally:
        endpoint_server.shutdown()
        endpoint_server.server_close()
        endpoint_thread.join(timeout=5)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Measure issue-175 control latency, connection headroom, and resource deltas."""

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time


ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))
import control_integration as controls
from host_process import start_ready_process, stop_process


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def footprint_bytes(report, name):
    match = re.search(rf"{name}:\s+([0-9.]+) (B|KB|MB|GB)", report)
    if match is None:
        raise RuntimeError(f"could not parse macOS {name} counter")
    scale = {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3}[match.group(2)]
    return round(float(match.group(1)) * scale)


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
        "open_unix_client_sockets": sum(" unix " in row.lower() for row in descriptors),
    }


def resource_delta(before, after):
    return {
        name: after[name] - before[name]
        for name in (
            "rss_bytes",
            "virtual_bytes",
            "physical_footprint_bytes",
            "open_descriptor_rows",
            "open_unix_client_sockets",
        )
    }


def start_host(binary, store, endpoint, capacity):
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
        ],
        required_fields={"execution": "enabled", "curl": "8.22.0"},
    )


def inspect_execution(binary, store, session):
    return json.loads(
        command(
            str(binary),
            "inspect-session",
            "--store",
            str(store),
            "--session",
            session,
        )
    )["execution"]


def percentile_95(values):
    return statistics.quantiles(values, n=20)[18]


def source_worktree_dirty(output):
    ignored = None
    try:
        ignored = str(output.resolve().relative_to(ROOT))
    except ValueError:
        pass
    lines = subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=all"], text=True
    ).splitlines()
    return any(line[3:] != ignored for line in lines)


def run_measurement(binary):
    controls.LATIFA = binary
    controls.ROOT = ROOT
    state = pathlib.Path(tempfile.mkdtemp(prefix="latifa-model-control-measure-"))
    endpoint = controls.StreamingEndpoint()
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
    host = None
    held = []
    try:
        headroom_store = state / "headroom-store"
        headroom_store.mkdir(mode=0o700)
        host, fields = start_host(binary, headroom_store, url, 8)
        controls.configure(
            state, headroom_store, "measure-headroom-config", "measure/headroom"
        )
        idle = sample(host.pid)
        held = controls.fill_ordinary_capacity(fields["socket"])
        controls.assert_ordinary_capacity_busy(fields["socket"])
        saturated_before_controls = sample(host.pid)
        latencies = []
        for index in range(50):
            started = time.monotonic_ns()
            reply = controls.stop_session(
                state,
                headroom_store,
                f"measure-headroom-stop-{index}",
                "measure/headroom",
            )
            latencies.append((time.monotonic_ns() - started) / 1_000_000)
            if reply["answer"]["status"] != "accepted":
                raise RuntimeError(reply)
        saturated_after_controls = sample(host.pid)
        for connection in held:
            connection.close()
        held.clear()
        time.sleep(1)
        drained_after_first_round = sample(host.pid)

        held = controls.fill_ordinary_capacity(fields["socket"])
        controls.assert_ordinary_capacity_busy(fields["socket"])
        saturated_second_round = sample(host.pid)
        for connection in held:
            connection.close()
        held.clear()
        time.sleep(1)
        drained_after_second_round = sample(host.pid)
        stop_process(host)
        host = None

        active_store = state / "active-store"
        active_store.mkdir(mode=0o700)
        host, _ = start_host(binary, active_store, url, 8)
        sessions = [f"measure/active/{index}" for index in range(8)]
        for index, session in enumerate(sessions):
            controls.configure(
                state, active_store, f"measure-active-config-{index}", session
            )
            controls.message(
                state,
                active_store,
                f"measure-active-message-{index}",
                session,
                f"active-{index}",
            )
        controls.wait_for(lambda: endpoint.counts()[0] >= 8, "eight live model streams")
        processings = [
            controls.wait_for(
                lambda index=index: controls.observe(
                    active_store, f"measure-active-message-{index}"
                ).get("processing"),
                f"processing identity {index}",
            )
            for index in range(8)
        ]
        active = sample(host.pid)

        started = time.monotonic_ns()
        interruption = controls.interrupt_model(
            state,
            active_store,
            "measure-active-interruption",
            sessions[0],
            processings[0],
        )
        interruption_ms = (time.monotonic_ns() - started) / 1_000_000
        if interruption["answer"]["status"] != "accepted":
            raise RuntimeError(interruption)

        stop_latencies = []
        for index, session in enumerate(sessions[1:], 1):
            started = time.monotonic_ns()
            reply = controls.stop_session(
                state,
                active_store,
                f"measure-active-stop-{index}",
                session,
            )
            stop_latencies.append((time.monotonic_ns() - started) / 1_000_000)
            if reply["answer"]["status"] != "accepted":
                raise RuntimeError(reply)
        controls.wait_for(
            lambda: endpoint.counts()[1] >= 8, "eight cancelled model streams"
        )
        controls.wait_for(
            lambda: inspect_execution(binary, active_store, sessions[0])[
                "custody_occupied"
            ]
            == "0",
            "control cleanup",
        )
        cancelled_and_drained = sample(host.pid)
        stop_process(host)
        host = None

        return {
            "configurations": {
                "idle_host": {
                    "active_capacity": 8,
                    "sample": idle,
                },
                "ordinary_capacity_and_control_acknowledgment": {
                    "ordinary_connections": controls.ORDINARY_CLIENTS,
                    "control_commands": len(latencies),
                    "p95_acknowledgment_ms": round(percentile_95(latencies), 3),
                    "maximum_acknowledgment_ms": round(max(latencies), 3),
                    "qualification_limit_ms": 1000,
                    "before_controls": saturated_before_controls,
                    "after_controls": saturated_after_controls,
                    "resource_delta_from_idle": resource_delta(
                        idle, saturated_before_controls
                    ),
                    "second_saturation_round": saturated_second_round,
                    "retained_after_first_drain": drained_after_first_round,
                    "retained_after_second_drain": drained_after_second_round,
                    "retained_delta_from_idle": resource_delta(
                        idle, drained_after_second_round
                    ),
                    "second_drain_delta_from_first": resource_delta(
                        drained_after_first_round, drained_after_second_round
                    ),
                },
                "live_model_cancellation": {
                    "active_capacity": 8,
                    "active_model_streams": 8,
                    "exact_interruption_acknowledgment_ms": round(
                        interruption_ms, 3
                    ),
                    "session_stop_p95_acknowledgment_ms": round(
                        percentile_95(stop_latencies), 3
                    ),
                    "qualification_limit_ms": 1000,
                    "before_controls": active,
                    "after_cleanup": cancelled_and_drained,
                    "resource_delta_after_cleanup": resource_delta(
                        active, cancelled_and_drained
                    ),
                    "provider_disconnects": endpoint.counts()[1],
                },
            }
        }
    finally:
        for connection in held:
            connection.close()
        if host is not None:
            stop_process(host)
        endpoint.release.set()
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        shutil.rmtree(state)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=ROOT / "research/model-control/results.json",
    )
    args = parser.parse_args()
    binary = args.binary.resolve()
    results = {
        "scope": "issue-175 production Session stop and exact model interruption",
        "status": "passed",
        "tested_revision": command("git", "rev-parse", "HEAD"),
        "working_tree_dirty": source_worktree_dirty(args.output),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "zig": command("zig", "version"),
        "platform": command("uname", "-a"),
        **run_measurement(binary),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()

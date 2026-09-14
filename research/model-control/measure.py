#!/usr/bin/env python3
"""Measure issue-175 control latency, connection headroom, and resource deltas."""

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
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
    ordered = sorted(values)
    return ordered[max(0, (95 * len(ordered) + 99) // 100 - 1)]


def timing_summary(values, definition):
    return {
        "definition": definition,
        "p95_ms": round(percentile_95(values), 3),
        "maximum_ms": round(max(values), 3),
    }


def source_provenance(root, output):
    root = root.resolve()
    try:
        top_level = pathlib.Path(
            subprocess.check_output(
                ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        ).resolve()
    except subprocess.CalledProcessError:
        return None, None
    if top_level != root:
        return None, None
    revision = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()
    ignored = None
    try:
        ignored = str(output.resolve().relative_to(root))
    except ValueError:
        pass
    lines = subprocess.check_output(
        [
            "git",
            "-C",
            str(root),
            "status",
            "--porcelain",
            "--untracked-files=all",
        ],
        text=True,
        stderr=subprocess.DEVNULL,
    ).splitlines()
    return revision, any(line[3:] != ignored for line in lines)


def check_source_provenance_boundaries():
    state = pathlib.Path(tempfile.mkdtemp(prefix="latifa-provenance-check-"))
    try:
        outside = state / "outside-package"
        outside.mkdir()
        assert source_provenance(outside, outside / "results.json") == (None, None)

        unrelated = state / "unrelated"
        nested = unrelated / "nested-package"
        nested.mkdir(parents=True)
        subprocess.run(
            ["git", "init", "--quiet", str(unrelated)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        assert source_provenance(nested, nested / "results.json") == (None, None)
        return {
            "outside_git": "null_revision_and_dirty_state",
            "nested_in_unrelated_repository": "null_revision_and_dirty_state",
        }
    finally:
        shutil.rmtree(state)


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

        control_first = controls.prove_delivery_and_settlement_contention(state)
        qualified = controls.prove_real_settlement_contention(
            state,
            sample_host=sample,
            cleanup_delay_ms=1500,
        )
        timing_records = qualified["control_timings"]

        def milliseconds(field):
            return [int(record[field]) / 1_000_000 for record in timing_records]

        queue_wait = milliseconds("queue_wait_ns")
        store_lock_wait = milliseconds("store_lock_wait_ns")
        store_service = milliseconds("store_service_ns")
        post_commit_reply = milliseconds("post_commit_reply_ns")
        semantic_completion = [
            queue + lock + service
            for queue, lock, service in zip(
                queue_wait, store_lock_wait, store_service, strict=True
            )
        ]
        qualified_samples = qualified["resource_samples"]

        return {
            "configurations": {
                "idle_host": {
                    "active_capacity": 8,
                    "sample": idle,
                },
                "stalled_incomplete_ingress_diagnostic": {
                    "scope": "120 ordinary clients stopped after partial request bodies; this is retained diagnostic evidence, not the issue-175 saturated-load qualification",
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
                "control_first_settlement_race": {
                    "scope": "120 fully captured reports held during delivery while eight controls commit before sealed settlement; canonical settlement loses without fencing",
                    "status": "passed",
                    "ordinary_connections": controls.ORDINARY_CLIENTS,
                    "concurrent_control_commands": 8,
                    "model_settlement_superseded": True,
                    "total_durable_acknowledgment": timing_summary(
                        control_first["acknowledgment_ms"],
                        "caller start through receipt of the complete durable Session-stop reply",
                    ),
                },
                "real_settlement_import_contention_qualification": {
                    "scope": "120 fully captured reports held during delivery, one 32 MiB answer streamed with bounded fixture memory into real Store import, and eight later concurrent controls",
                    "ordinary_connections": controls.ORDINARY_CLIENTS,
                    "active_model_responses": 1,
                    "concurrent_control_commands": 8,
                    "large_answer_bytes": qualified["large_answer_bytes"],
                    "large_answer_sha256": qualified["large_answer_sha256"],
                    "settlement_service_ms": round(
                        qualified["settlement_service_ms"], 3
                    ),
                    "overlapping_control_keys": qualified[
                        "overlapping_control_keys"
                    ],
                    "resolved_interruption_key": qualified[
                        "resolved_interruption_key"
                    ],
                    "idle_stop_keys": qualified["idle_stop_keys"],
                    "cleanup_delay_ms": 1500,
                    "qualification_limit_ms": 1000,
                    "total_durable_acknowledgment": timing_summary(
                        qualified["acknowledgment_ms"],
                        "caller start through receipt of the complete durable control reply",
                    ),
                    "control_queue_wait": timing_summary(
                        queue_wait,
                        "Host accept through parsed control queued at the Store owner",
                    ),
                    "store_lock_wait": timing_summary(
                        store_lock_wait,
                        "Store call entry through acquisition of its single-writer mutex",
                    ),
                    "store_service": timing_summary(
                        store_service,
                        "Store mutex acquisition through committed canonical answer",
                    ),
                    "post_commit_reply": timing_summary(
                        post_commit_reply,
                        "canonical commit through completion of the Host reply write attempt",
                    ),
                    "semantic_completion": timing_summary(
                        semantic_completion,
                        "Host accept through the committed resolved-interruption or idle-stop answer",
                    ),
                    "physical_custody_release": timing_summary(
                        [qualified["physical_release_ms"]],
                        "successful settlement completion through cleanup completion and custody-slot release",
                    ),
                    "resources": {
                        **qualified_samples,
                        "captured_load_delta_from_idle": resource_delta(
                            qualified_samples["idle"],
                            qualified_samples[
                                "reports_captured_before_settlement"
                            ],
                        ),
                        "retained_delta_after_physical_release": resource_delta(
                            qualified_samples["idle"],
                            qualified_samples["physically_released"],
                        ),
                    },
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
    provenance_boundary_checks = check_source_provenance_boundaries()
    tested_revision, working_tree_dirty = source_provenance(ROOT, args.output)
    results = {
        "scope": "issue-175 production Session stop and exact model interruption",
        "status": "passed",
        "tested_revision": tested_revision,
        "working_tree_dirty": working_tree_dirty,
        "provenance_boundary_checks": provenance_boundary_checks,
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

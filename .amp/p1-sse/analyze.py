#!/usr/bin/env python3
"""Replay the bounded SSE CPU comparison from retained, optionally gzipped facts."""
import gzip
import json
import math
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parent
BINARIES = {
    "A": "e2835cb25a7e45851df6dac35de0977de8a88b9d2861eea8ee5b43bd993b3a50",
    "B": "c7f0beccc4bd72379a074b3aa72fa8323085bbed6c9955f5d12aa6a84927db32",
}


def read(relative):
    path = ROOT / "raw" / relative
    if path.exists():
        return path.read_text()
    return gzip.decompress(Path(str(path) + ".gz").read_bytes()).decode()


def facts(relative):
    return [json.loads(line) for line in read(relative).splitlines()]


def event(records, name, round_number=None):
    rows = [r["value"] for r in records if r["event"] == name
            and (round_number is None or r["value"].get("round") == round_number)]
    assert len(rows) == 1, (name, round_number, len(rows))
    return rows[0]


def close(a, b, tolerance=1e-8):
    assert math.isclose(a, b, rel_tol=1e-12, abs_tol=tolerance), (a, b)


rows = []
all_pids = []
for name in ("A1", "B1", "A2", "B2"):
    report = json.loads(read(f"run-{name}.json"))
    log = read(f"run-{name}.log")
    assert "exit=1\n" in log and "end_utc=" in log
    assert report["status"] == "incomplete" and "error" not in report
    assert report["binary_sha256"] == BINARIES[name[0]]
    assert report["tested_revision"] == "a204296c7289cf0a90f95df155c4f27832c924fe"
    group, = report["active_capacity_growth"]
    assert group["active_capacity"] == 100 and group["same_host_rounds"] == 2
    assert group["same_sessions"] is False
    identities = group["process_identity"]
    all_pids.extend(identities[k] for k in ("host_pid", "provider_pid", "controller_pid"))
    assert identities["all_distinct"]
    root_facts = facts(f"run-{name}/facts.jsonl")
    assert event(root_facts, "capacity") == group
    controller = facts(f"run-{name}/controller-facts.jsonl")
    rounds = []
    assert len(group["rounds"]) == 2
    for number, row in enumerate(group["rounds"], 1):
        assert row["round"] == number and row["status"] == "incomplete"
        assert "observation_error" not in row
        assert row["host_dimensions"] == {
            "capture": "passed", "cleanup": "passed", "durable_audit": "passed",
            "memory": "incomplete", "request_integrity": "passed", "result_delivery": "passed",
        }
        for flag in ("all_results_audited", "offline_audit_after_host_reaped",
                     "capture_observation_complete", "cleanup_observation_complete",
                     "durable_audit_prerequisite_met", "result_delivery_complete"):
            assert row[flag] is True, flag
        audits = row["audit_rows"]
        assert len(audits) == len({a["session"] for a in audits}) == 100
        for audit in audits:
            assert audit["turn_outcome"] == "completed" and audit["resolution_code"] == "answer"
            assert audit["uncertain"] == 0 and audit["last_failure_code"] is None
            assert audit["attempt_ordinal"] == audit["allowance_used"] == 1
            assert audit["output_items"] == audit["private_output_items"] == audit["assistant_projections"] == 1
        offline = event(controller, "offline_capacity_audit", number)
        assert offline["complete"] and offline["host_reaped"] and offline["rows"] == audits
        provider = facts(f"run-{name}/round-{number}/provider-facts.jsonl")
        offer = row["paced_offer"]
        final = row["fixture_completion"]
        assert event(provider, "offer_complete") == offer
        assert event(provider, "provider_complete") == final
        assert event(controller, "provider_complete", number)["summary"] == final
        for observation in (offer, final):
            assert observation["h2_connections"] == 1 and observation["h2_streams"] == 100
            assert observation["ready_streams"] == observation["offer_finished_streams"] == 100
            assert observation["completed_events"] == 600000
            assert observation["offer_bytes"] == 156000000
            assert observation["offer_failed_streams"] == observation["terminal_failed_streams"] == 0
        assert final["terminal_finished_streams"] == 100
        assert row["completion_inspection"]["execution"]["custody_occupied"] == "0"
        assert row["completion_inspection"]["execution"]["scratch_used_bytes"] == "0"
        cpu = row["cpu"]
        assert cpu["status"] == "passed" and cpu["bracket_valid"] and cpu["provider_offer_qualified"]
        assert cpu["complete_work_cpu_available"] and cpu["complete_work_at_most_120_cpu_seconds"]
        first, second = cpu["first_query"], cpu["second_query"]
        assert offer["start_unix_ns"] + 10_000_000_000 <= first["start_unix_ns"]
        assert first["start_unix_ns"] <= first["finish_unix_ns"]
        assert first["finish_unix_ns"] + 40_000_000_000 <= second["start_unix_ns"]
        assert second["start_unix_ns"] <= second["finish_unix_ns"] <= offer["earliest_final_completion_unix_ns"]
        close(cpu["cpu_seconds"], second["host_cpu_seconds"] - first["host_cpu_seconds"])
        # Go duration subtraction uses monotonic time, while serialized ns are wall time.
        close(cpu["minimum_sample_window_seconds"], (second["start_unix_ns"] - first["finish_unix_ns"]) / 1e9, 1e-6)
        window = event(controller, "cpu_window_and_offer", number)
        assert window["provider_offer"] == offer
        complete = event(controller, "host_complete", number)
        assert complete["cpu_available"] and complete["inspection"] == row["completion_inspection"]
        assert 0 < cpu["complete_work_cpu_seconds"] <= complete["host_cpu_seconds"]
        rounds.append({
            "round": number, "completed_offer_events": offer["completed_events"],
            "audited_messages": len(audits), "offer_bytes": offer["offer_bytes"],
            "terminal_bytes": final["terminal_bytes"],
            "host_complete_work_cpu_seconds": round(cpu["complete_work_cpu_seconds"], 2),
            "interior_cpu_seconds": round(cpu["cpu_seconds"], 2),
            "offer_seconds_observed": (offer["latest_final_completion_unix_ns"] - offer["start_unix_ns"]) / 1e9,
            "timing_invalid_streams": offer["timing_invalid_streams"],
            "late_completion_violations": offer["late_completion_violations"],
            "completion_gap_violations": offer["completion_gap_violations"],
        })
    total_cpu = round(sum(r["host_complete_work_cpu_seconds"] for r in rounds), 2)
    total_events = sum(r["completed_offer_events"] for r in rounds)
    rows.append({"case": name, "canonical_status": "incomplete", "exit": 1,
                 "rounds": rounds, "host_complete_work_cpu_seconds": total_cpu,
                 "completed_offer_events": total_events,
                 "audited_messages": sum(r["audited_messages"] for r in rounds),
                 "host_cpu_microseconds_per_completed_offer_event": total_cpu * 1e6 / total_events})

assert len(set(all_pids)) == len(all_pids) == 12
a = round(statistics.median(r["host_complete_work_cpu_seconds"] for r in rows if r["case"][0] == "A"), 3)
b = round(statistics.median(r["host_complete_work_cpu_seconds"] for r in rows if r["case"][0] == "B"), 3)
receipt = read("interruption-receipt.txt")
assert "--signal=SIGTERM amp-run-174400-25973.scope" in receipt
assert "20:36:53" in receipt
assert not (ROOT / "raw/run-A3.json").exists() and not (ROOT / "raw/run-B3.json").exists()
assert "exit=" not in read("run-A3.log")
summary = {
    "completed_runs": rows,
    "group_median_host_cpu_seconds": {"A": a, "B": b},
    "descriptive_median_reduction_percent": (a - b) / a * 100,
    "paired_host_cpu_reduction_seconds": [round(rows[i]["host_complete_work_cpu_seconds"] - rows[i+1]["host_complete_work_cpu_seconds"], 2) for i in (0, 2)],
    "A3": {"status": "interrupted_unknown", "host_cpu_seconds": None, "completed_events": None, "exit": None},
    "B3": {"status": "not_started", "host_cpu_seconds": None, "completed_events": None, "exit": None},
    "interior_window_completed_events": None,
    "interior_window_cpu_per_event": None,
    "limits": ["No serialized complete-work start CPU endpoint; CPU deltas come from the frozen harness and cannot be independently re-subtracted.",
               "In-window delivery progress was deferred until offer completion; no interior CPU/event or nominal denominator substitution.",
               "All completed runs retain missing-Mac-footprint incomplete status and per-stream pacing violations.",
               "Two complete pairs only; A3 interrupted by executor-scope teardown concurrent with Amp restart; no retry or B3.",
               "Host CPU excludes provider/controller/CLI and Configure, but includes admissions, result reads, terminal bytes and custody/scratch drain.",
               "Descriptive Linux fixture observation, not statistical/general speedup, live/Mac qualification or production acceptance."],
}
print(json.dumps(summary, indent=2, sort_keys=True))

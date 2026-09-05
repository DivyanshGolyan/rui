#!/usr/bin/env python3
"""Compile and run a short native custody-bookkeeping probe, with raw repetitions."""
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
MODES = ["state_scan", "dispatch_scan", "completion_lookup_burst", "completion_reuse_burst"]


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    compiler = os.environ.get("CC", "cc")
    flags = ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror"]
    results = []
    with tempfile.TemporaryDirectory(prefix="onepage-slots-") as tmp:
        binary = str(Path(tmp) / "slots")
        subprocess.run([compiler, *flags, str(ROOT / "slots.c"), "-o", binary], check=True)
        for capacity in [1, 10, 50, 100, 1000]:
            for percent in [0, 10, 50, 100]:
                for mode, name in enumerate(MODES):
                    # An untimed native warmup precedes every measurement. Increase
                    # calibration size until its measured region exceeds 0.5 ms.
                    iterations = 1
                    while True:
                        trial = json.loads(command(binary, str(capacity), str(percent), str(mode), str(iterations), "1"))
                        elapsed = trial["elapsed_ns"][0]
                        if elapsed >= 500_000 or iterations >= 1_000_000:
                            break
                        iterations *= 10
                    iterations = max(1, min(10_000_000, int(iterations * 10_000_000 / max(elapsed, 1))))
                    row = json.loads(command(binary, str(capacity), str(percent), str(mode), str(iterations), "7"))
                    samples = [value / iterations for value in row["elapsed_ns"]]
                    row.update(mode_name=name, ns_per_operation=samples,
                               median_ns=statistics.median(samples), min_ns=min(samples), max_ns=max(samples),
                               exploratory_capacity=capacity == 1000)
                    results.append(row)
            print(f"Measured capacity {capacity}", flush=True)
    cpu = command("sysctl", "-n", "machdep.cpu.brand_string") if platform.system() == "Darwin" else platform.processor()
    payload = {
        "schema_version": 1,
        "command": "python3 research/execution-control-experiments/run_slots.py",
        "compiler": command(compiler, "--version"),
        "compiler_flags": flags,
        "cpu": cpu,
        "platform": platform.platform(),
        "source_sha256": hashlib.sha256((ROOT / "slots.c").read_bytes()).hexdigest(),
        "layout_and_scan_reference": "research/host-runtime/integrated-capacity-proof/integrated_capacity.c",
        "target_repetition_ms": 10,
        "repetitions": 7,
        "results": results,
    }
    (ROOT / "slot-results.json").write_text(json.dumps(payload, indent=2) + "\n")
    lines = ["# Fixed custody table scan experiment", "",
             f"Machine: {cpu}; {payload['platform']}.", "",
             f"Compiler: {payload['compiler'].splitlines()[0]}; flags: `{' '.join(flags)}`.", "",
             "Run from the experiment worktree: `python3 research/execution-control-experiments/run_slots.py`.", "",
             "The content-free record mirrors the existing integrated prototype's 128-byte layout. "
             "Seven warmed repetitions target 10 ms each; figures below are medians, with all raw elapsed times, "
             "checksums, actual rounded occupancy, and min/max recorded in `slot-results.json`. "
             "No allocations occur inside timed loops. Acquire loads, compare-exchange operations, noinline "
             "entry points, and a compiler memory barrier prevent hoisting the work out of the loops.", "",
             "## Results", "",
             "Each figure is microseconds per full table operation or whole completion burst, not per record. "
             "Occupancy is rounded down (capacity 1 at 10% or 50% therefore has zero occupied records).", "",
             "| Capacity | Occupancy | State scan us | Dispatch scan us | Completion lookup burst us | Completion/reuse burst us |",
             "| --- | --- | ---: | ---: | ---: | ---: |"]
    for capacity in [1, 10, 50, 100, 1000]:
        for percent in [0, 10, 50, 100]:
            rows = [r for r in results if r["capacity"] == capacity and r["requested_occupancy_percent"] == percent]
            values = " | ".join(f"{r['median_ns'] / 1000:.3f}" for r in rows)
            lines.append(f"| {capacity}{' (exploratory)' if capacity == 1000 else ''} | {rows[0]['occupied']}/{capacity} | {values} |")
    lines += ["", "## Interpretation and boundaries", "",
              "The state scan reads every state word. The dispatch scan reproduces the prototype's failed "
              "DISPATCHABLE-to-ACTIVE compare-exchange plus active-state read, using model-kind records. "
              "Completion lookup searches from slot zero separately for each evenly distributed active handle. "
              "Completion/reuse seals all occupied records, sweeps sealed records, and reacquires first-free slots "
              "for each replacement; this generic allocator is an exploratory worst case, since the existing "
              "prototype admits known array positions. Reuse is packed at the start of the table.", "",
              "The lookup and first-free admission loops can do quadratic work across a full burst. "
              "A sweep's low cost must not be presented as the cost of an entire burst. Capacity 1,000 is "
              "a sensitivity experiment, not a chosen product capacity.", "",
              "Recommendation: retain the simple fixed table at the tested required capacities through 100. "
              "These isolated costs provide no current performance justification for adding an active/free index, "
              "so no indexed competitor was built. If capacity 1,000 or repeated large completion bursts become "
              "a real requirement, first try admitting a whole burst in one monotonic free-slot sweep; that removes "
              "repeated first-free scans without adding a second resident index. This is a follow-up candidate, "
              "not a measured implementation or a newly selected capacity.", "",
              "These warm-cache, single-thread timings exclude SQLite, actual cleanup, callbacks, syscall cost, "
              "thread contention/cache-line transfer, materialization, scheduling/wake cost, and model/tool execution. "
              "The process was not CPU-pinned and the laptop was not isolated; short samples have scheduler noise. "
              "They cannot establish Host responsiveness, complete allocation cost, or crash correctness.", "",
              "### Explicit scan cadence conversion", "",
              "These are arithmetic estimates for one sweep per wake; they do not select polling or measure "
              "idle wake cost. An idle implementation can sleep until signalled. Percentage means one CPU core.", "",
              "| Capacity, empty | State at 100/s CPU % | State at 1,000/s CPU % | Dispatch at 100/s CPU % | Dispatch at 1,000/s CPU % |",
              "| --- | ---: | ---: | ---: | ---: |"]
    for capacity in [1, 10, 50, 100, 1000]:
        row = next(r for r in results if r["capacity"] == capacity and r["requested_occupancy_percent"] == 0 and r["mode"] == 0)
        dispatch = next(r for r in results if r["capacity"] == capacity and r["requested_occupancy_percent"] == 0 and r["mode"] == 1)
        lines.append(f"| {capacity} | {row['median_ns'] * 100 / 1e7:.5f} | {row['median_ns'] * 1000 / 1e7:.5f} | {dispatch['median_ns'] * 100 / 1e7:.5f} | {dispatch['median_ns'] * 1000 / 1e7:.5f} |")
    lines += ["", "### Correctness assertions", "",
              "Every repetition checks the exact occupied-record checksum. The native program checks occupancy "
              "after timing, exact reuse-generation sums, successful first-free reservation, and ACTIVE state "
              "before every simulated seal. These checks validate this benchmark's work, not production safety.", ""]
    (ROOT / "SLOT_RESULTS.md").write_text("\n".join(lines))


if __name__ == "__main__":
    main()

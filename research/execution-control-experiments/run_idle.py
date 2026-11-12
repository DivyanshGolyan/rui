#!/usr/bin/env python3
"""Measure actual process CPU for empty-table condition-wait scheduling."""
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    flags = ["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-pthread"]
    rows = []
    with tempfile.TemporaryDirectory(prefix="rui-idle-") as tmp:
        binary = str(Path(tmp) / "idle")
        subprocess.run(["cc", *flags, str(ROOT / "idle.c"), "-o", binary], check=True)
        for repeat in range(3):
            for capacity in [100, 1000]:
                # Alternate order to avoid always assigning one mode the first run.
                for polling in ([0, 1] if repeat % 2 == 0 else [1, 0]):
                    row = json.loads(run(binary, str(capacity), str(polling)))
                    row.update(repeat=repeat, mode="timed_wait_5ms" if polling else "external_wake_only",
                               cpu_percent_one_core=row["process_cpu_ns"] * 100 / row["wall_ns"],
                               exploratory_capacity=capacity == 1000)
                    assert row["checksum"] == 0
                    assert row["scan_count"] == row["wait_returns"]
                    rows.append(row)
            print(f"Completed repetition {repeat + 1}/3", flush=True)
    payload = {
        "schema_version": 1,
        "command": "python3 research/execution-control-experiments/run_idle.py",
        "cpu": run("sysctl", "-n", "machdep.cpu.brand_string"),
        "platform": platform.platform(),
        "compiler": run("cc", "--version"),
        "compiler_flags": flags,
        "source_sha256": hashlib.sha256((ROOT / "idle.c").read_bytes()).hexdigest(),
        "rows": rows,
    }
    (ROOT / "idle-results.json").write_text(json.dumps(payload, indent=2) + "\n")
    lines = ["# Measured empty-table idle CPU", "",
             f"Machine: {payload['cpu']}; {payload['platform']}. "
             f"Compiler: {payload['compiler'].splitlines()[0]}, `{' '.join(flags)}`.", "",
             "Command: `python3 research/execution-control-experiments/run_idle.py` from the experiment worktree.", "",
             "A reactor thread waits on a condition variable over a fixed empty table with 128-byte records. "
             "One helper thread signals it after a one-second sleep. The external-wake-only mode has no timeout; "
             "the comparison uses a 5 ms timeout and scans after every wait return. Both scan on the final external "
             "wake. No busy loop is used. The entire process's actual CPU time comes from "
             "`CLOCK_PROCESS_CPUTIME_ID`; wall time uses `CLOCK_MONOTONIC`.", "",
             "| Capacity | Mode | Repetition | Wall ms | Process CPU ms | CPU % of one core | Wait returns / scans | Timeouts |",
             "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in rows:
        lines.append(f"| {row['capacity']} | {row['mode']} | {row['repeat'] + 1} | "
                     f"{row['wall_ns']/1e6:.2f} | {row['process_cpu_ns']/1e6:.3f} | "
                     f"{row['cpu_percent_one_core']:.4f} | {row['scan_count']} | {row['timeout_returns']} |")
    lines += ["", "Median CPU percentages:", ""]
    for capacity in [100, 1000]:
        for mode in ["external_wake_only", "timed_wait_5ms"]:
            samples = [r["cpu_percent_one_core"] for r in rows if r["capacity"] == capacity and r["mode"] == mode]
            lines.append(f"- {capacity}, {mode}: {statistics.median(samples):.4f}% of one core "
                         f"(range {min(samples):.4f}%–{max(samples):.4f}%).")
    lines += ["", "## Interpretation and limits", "",
              "This measures synthetic idle scheduling cost, including the helper thread's creation, sleep, "
              "signal, and join; memory allocation and destruction are outside timing. It is not Rui's "
              "whole-Host idle CPU baseline and does not include SQLite polling, real I/O multiplexing, "
              "transports, or evaluator work. Short one-second samples on an unpinned laptop cannot provide "
              "fine-grained energy or cross-machine guarantees. Capacity 1,000 is exploratory only.", "",
              "The 5 ms timeout is a requested minimum wait, not an observed 200 Hz cadence: scheduler delay "
              "and timer coalescing can produce fewer returns. Use the measured wake counts, not a nominal "
              "poll frequency, when interpreting these CPU figures.", "",
              "The comparison illustrates that scan-only arithmetic omits timed-wakeup overhead. Prefer "
              "sleeping until a real event when no deadline or durable poll requires a wake; the 5 ms setting "
              "is an experimental comparison, not a production cadence recommendation. It does not establish "
              "that the whole runtime may omit retry or command polling.", "",
              "All scans assert the empty-table checksum is zero and scan count equals wait returns. "
              "The no-timeout mode asserts no timeout returns. Raw rows include the one intentional external "
              "signal; spurious successful wait returns would remain visible in the counts.", ""]
    (ROOT / "IDLE_RESULTS.md").write_text("\n".join(lines))


if __name__ == "__main__":
    main()

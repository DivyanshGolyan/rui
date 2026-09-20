#!/usr/bin/env python3
"""Run the isolated Zig suite and require each scheduling mutation to fail tests.

A compiler error is not a killed mutation. This runner never starts a Rui Host,
Bash fixture, provider server, or FIFO coordinator.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def replace_once(source: str, before: str, after: str) -> str:
    count = source.count(before)
    if count != 1:
        raise ValueError(f"mutation anchor must occur once, found {count}: {before!r}")
    return source.replace(before, after, 1)


def mutants(source: str) -> dict[str, str]:
    advance = "    made_progress = driver.advancePreparation(allowance) or made_progress;"
    after_admission = (
        "    made_progress = driver.serviceLifecycle(driver.now()) or made_progress;\n"
        "    try driver.driveTransport();"
    )
    stale = replace_once(
        source,
        "pub fn run(driver: anytype, allowance: Allowance) !Next {",
        "pub fn run(driver: anytype, allowance: Allowance) !Next {\n"
        "    const sampled_once = driver.now();",
    )
    fresh_call = "driver.serviceLifecycle(driver.now())"
    if stale.count(fresh_call) != 3:
        raise ValueError("expected the three production lifecycle opportunities")
    stale = stale.replace(fresh_call, "driver.serviceLifecycle(sampled_once)")
    return {
        "drain-completion-burst": replace_once(
            source,
            "    if (try driver.nextCompletion()) |completion| {",
            "    while (try driver.nextCompletion()) |completion| {",
        ),
        "omit-post-admission-lifecycle": replace_once(
            source, after_admission, "    try driver.driveTransport();"
        ),
        "advance-preparation-twice": replace_once(source, advance, advance + "\n" + advance),
        "wait-after-progress": replace_once(
            source,
            "    return if (made_progress) .again else .wait;",
            "    return if (made_progress) .wait else .wait;",
        ),
        "reuse-stale-service-time": stale,
        "require-control-notification": replace_once(
            source,
            "    pub fn due(self: *ControlPoll, now_ns: u64, hint: bool) bool {",
            "    pub fn due(self: *ControlPoll, now_ns: u64, hint: bool) bool {\n"
            "        if (!hint) return false;",
        ),
    }


def assertion_failed(result: subprocess.CompletedProcess[str]) -> bool:
    # Zig's assertion failures are printed as FAIL (TestExpectedEqual), etc.
    # A compile failure, missing executable, or timeout must fail this runner,
    # not be misreported as evidence that an invariant caught the mutation.
    return result.returncode != 0 and re.search(r"\bFAIL\s*\(", result.stdout + result.stderr) is not None


def run_suite(zig: str, path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [zig, "test", str(path), "-O", "ReleaseSafe"],
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig", help="Zig 0.16.0 executable")
    args = parser.parse_args()
    zig = shutil.which(args.zig)
    if zig is None:
        print(f"Zig executable not found: {args.zig}", file=sys.stderr)
        return 2
    source_path = Path(__file__).resolve().parents[1] / "src" / "execution_turn.zig"
    source = source_path.read_text(encoding="utf-8")
    try:
        candidates = mutants(source)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
    baseline = run_suite(zig, source_path)
    if baseline.returncode != 0:
        print(baseline.stdout + baseline.stderr, file=sys.stderr)
        print("Baseline failed; no mutation result is valid.", file=sys.stderr)
        return 1
    print("PASS baseline")
    failed = False
    with tempfile.TemporaryDirectory(prefix="rui-execution-turn-") as directory:
        for name, mutated in candidates.items():
            path = Path(directory) / f"{name}.zig"
            path.write_text(mutated, encoding="utf-8")
            result = run_suite(zig, path)
            if assertion_failed(result):
                print(f"KILLED {name}")
            else:
                failed = True
                print(f"INVALID {name}: survived or did not reach a test assertion", file=sys.stderr)
                print(result.stdout + result.stderr, file=sys.stderr)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())

"""Run isolated protocol scenarios and require each deliberately unsafe variant to fail."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
from datetime import datetime, timezone

from build_native import build, metadata

HERE = Path(__file__).resolve().parent
CASES = {
    "rollback": None,
    "commit-before-dispatch": "recovery must not fabricate a Dispatch Permit",
    "uncertain-external": "uncertain Bash must not get a blind replacement Attempt",
    "cancel-before-cleanup": "cannot reserve slot while old executor retains pipes/resources",
    "stale-callback": "delayed old callback must not settle newer Attempt",
}


def main():
    result = {"created_utc": datetime.now(timezone.utc).isoformat(),
              "environment": metadata(), "kind": "throwaway protocol fixture",
              "repetitions_per_variant": 10, "builds": [], "runs": []}
    with tempfile.TemporaryDirectory(prefix="rui-custody-") as temporary:
        temporary = Path(temporary)
        for sanitize in (False, True):
            binary = temporary / ("custody-sanitized" if sanitize else "custody")
            result["builds"].append(build(HERE / "custody.c", binary, sanitize=sanitize))
            for case, expected_failure in CASES.items():
                for broken in (False, True) if expected_failure else (False,):
                    for repetition in range(10):
                        database = temporary / f"{sanitize}-{case}-{broken}-{repetition}.sqlite"
                        env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0:abort_on_error=1",
                                   UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
                        completed = subprocess.run([str(binary), case, str(database), str(int(broken))],
                                                   text=True, capture_output=True, timeout=15, env=env)
                        lines = completed.stdout.strip().splitlines()
                        observed = json.loads(lines[0]) if lines else None
                        passed = (completed.returncode == 2 and expected_failure in completed.stderr) if broken else (
                            completed.returncode == 0 and lines[1:] == [f"PASS {case}"])
                        passed = passed and observed == {"journal_mode": "delete", "synchronous": 3}
                        # A sanitizer report must never count as an expected negative-control failure.
                        passed = passed and not any(x in completed.stderr for x in
                            ("AddressSanitizer", "UndefinedBehaviorSanitizer", "runtime error:"))
                        result["runs"].append({"scenario": case, "broken": broken,
                            "sanitized": sanitize, "repetition": repetition,
                            "returncode": completed.returncode, "passed": passed,
                            "observed_sqlite_pragmas": observed,
                            "stdout": completed.stdout.strip(), "stderr": completed.stderr.strip()})
                        if not passed:
                            (HERE / "custody-results.json").write_text(json.dumps(result, indent=2) + "\n")
                            raise RuntimeError(result["runs"][-1])
    result["summary"] = {"total_runs": len(result["runs"]),
        "safe_runs_passed": sum(not r["broken"] and r["passed"] for r in result["runs"]),
        "negative_controls_detected": sum(r["broken"] and r["passed"] for r in result["runs"]),
        "all_passed": all(r["passed"] for r in result["runs"])}
    (HERE / "custody-results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["summary"]))


if __name__ == "__main__":
    main()

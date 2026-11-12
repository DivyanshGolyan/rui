#!/usr/bin/env python3
"""Run the existing H2 oracle with the disposable capture-counter build."""
import json
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests/qualification/linux-memory"))
import run as workload


def main():
    out = Path(sys.argv[sys.argv.index("--output") + 1]).resolve()
    # The experiment emits one short record per 100 completions; the bounded
    # 2,000-request workload fits in stderr's pipe without an extra reader.
    assert "--rounds" in sys.argv and int(sys.argv[sys.argv.index("--rounds") + 1]) <= 20
    assert "--capacity" in sys.argv and int(sys.argv[sys.argv.index("--capacity") + 1]) == 100

    def stop(process, timeout=10):
        if process.poll() is None:
            process.kill()
        _, stderr = process.communicate(timeout=timeout)
        (out / "capture-stderr.txt").write_bytes(stderr)
        records = [json.loads(line) for line in stderr.splitlines() if b'"capture_audit":true' in line]
        (out / "capture.json").write_text(json.dumps(records, indent=2))

    passed = False
    try:
        with patch.object(workload.fixture.dispatch, "stop_process", stop):
            workload.main()
        records = json.loads((out / "capture.json").read_text())
        rounds = int(sys.argv[sys.argv.index("--rounds") + 1])
        assert [r["completed"] for r in records] == list(range(100, rounds * 100 + 1, 100))
        passed = True
    finally:
        path = out / "result.json"
        if path.exists():
            result = json.loads(path.read_text())
            result.update(instrumented=True, probe_scope="disposable capture counters, not heaptrack")
            if not passed:
                result["status"] = "failed"
            path.write_text(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

"""Temporary, synthetic-only macOS counterexample; not a production test gate."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

BASELINE = "e8c7fec006b84f29cfd6511d72c69fe5f7e61794"

if len(sys.argv) == 1:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "baseline.py").write_bytes(subprocess.check_output([
            "git", "show", BASELINE + ":tests/ci/test_selection.py"]))
        (root / "sitecustomize.py").write_text(
            "import fcntl, os, time\n"
            "root = os.environ.get('GATE_DIR')\n"
            "if root:\n"
            "    with open(root + '/startup.lock', 'w') as lock:\n"
            "        fcntl.flock(lock, fcntl.LOCK_EX)\n"
            "        time.sleep(.3)\n")
        environment = dict(os.environ, PYTHONPATH=str(root))
        for variant in ("baseline", "corrected"):
            for case in ("serial", "parallel"):
                process = subprocess.Popen(
                    [sys.executable, __file__, variant, case, str(root / "baseline.py")],
                    env=environment, start_new_session=True)
                try:
                    assert process.wait(timeout=75) == 0, (variant, case)
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
else:
    variant, case, baseline = sys.argv[1:]
    sys.path.insert(0, str(Path("tests/ci").resolve()))
    source = baseline if variant == "baseline" else "tests/ci/test_selection.py"
    spec = importlib.util.spec_from_file_location("driver_under_test", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    started = time.monotonic()
    outcome = {}
    try:
        if case == "serial":
            result, lines = module.FullCheckPartitionTest().run_part("all", "host_allocator_test.py")
            assert result.returncode == 42, result
            assert lines[-1] == "host_allocator_test.py release", lines
        else:
            result, lines = module.FullCheckPartitionTest().run_part(
                "parallel", overlap=True, hold="dispatch_integration.py")
            assert result.returncode == 0, result
        outcome = dict(status="complete", returncode=result.returncode, invocations=len(lines))
    except (subprocess.TimeoutExpired, AssertionError) as error:
        if variant != "baseline":
            raise
        outcome = dict(status=type(error).__name__, detail=str(error))
        for note in getattr(error, "__notes__", []):
            print(note, flush=True)
    print(json.dumps(dict(variant=variant, case=case,
                          elapsed=round(time.monotonic() - started, 3), **outcome)), flush=True)
    assert (outcome["status"] != "complete") == (variant == "baseline"), outcome

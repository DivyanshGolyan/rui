"""Run the throwaway experiments sequentially to avoid self-induced timing contention."""
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
for runner in ("run_slots.py", "run_idle.py", "run_custody.py", "run_inspection.py"):
    subprocess.run([sys.executable, str(HERE / runner)], check=True, cwd=HERE.parents[1])
subprocess.run([sys.executable, str(HERE / "run_inspection.py"), "--sanitize", "--smoke", "--repeats", "1",
                "--output", str(HERE / "inspection-sanitizer-results.json")],
               env=dict(os.environ, ASAN_OPTIONS="detect_leaks=0"), check=True, cwd=HERE.parents[1])

import json
from pathlib import Path
import subprocess
import sys
import unittest

HOOK = Path(__file__).resolve().parents[2] / ".claude/hooks/block_full_runs.py"


def run(command):
    return subprocess.run([sys.executable, "-B", str(HOOK)], input=json.dumps(
        {"tool_name": "Bash", "tool_input": {"command": command}}), text=True, capture_output=True)


class BlockFullRunsTest(unittest.TestCase):
    def test_full_suites_and_ci_mirrors_are_refused(self):
        for command in ("zig build test", "cd rui && zig build check --summary all",
                        "/opt/zig/zig build test test-logic -j4", "zig build check-full -Dcheck-part=callers",
                        "bash /mnt/project-files/frontend/pr-gates.sh HEAD",
                        "sh /mnt/project-files/rui-dev/nonroot-check.sh", "time zig build test 2>&1 | tail",
                        "bash -c 'zig build test'", "(zig build check)", "timeout 600 zig build -j4 check",
                        "echo RUI_CI_RED=1 zig build test", "zig build test --foo RUI_CI_RED=x",
                        "RUI_CI_RED=#1 true; zig build check"):
            with self.subTest(command=command):
                result = run(command)
                self.assertEqual(result.returncode, 2)
                self.assertIn("RUI_CI_RED=", result.stderr)

    def test_focused_runs_and_a_named_ci_red_pass(self):
        for command in ("zig build test -Dtest-filter=api_key", "zig build test-logic --summary all",
                        "zig build typecheck-macos", "zig fmt --check src", "zig build",
                        "python3 tests/ci/prepush.py", "RUI_CI_RED=#755 zig build check",
                        "cd rui && RUI_CI_RED=https://x/runs/1 timeout 900 zig build test",
                        "RUI_CI_RED=#755 bash pr-gates.sh HEAD", "zig build test --summary all -Dtest-filter=x",
                        "git log --grep 'build check'", "echo test"):
            with self.subTest(command=command):
                self.assertEqual(run(command).returncode, 0, command)


if __name__ == "__main__":
    unittest.main()

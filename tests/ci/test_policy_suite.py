import json
from pathlib import Path
import sys
import tempfile
import unittest

import build_files
import policy_suite
import prepush
from select_tests import select


class PolicySuiteTest(unittest.TestCase):
    def test_suite_filters_modules_and_classes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("test_policy_example_x", "test_policy_example_y"):
                (root / f"{name}.py").write_text(
                    "import unittest\nclass Example(unittest.TestCase):\n    def test_case(self): pass\n")
            self.addCleanup(lambda: [sys.modules.pop(name, None) for name in
                                     ("test_policy_example_x", "test_policy_example_y")])
            tests = policy_suite.suite(["test_policy_example_x"], directory)
            self.assertEqual([test.id() for test in tests], ["test_policy_example_y.Example.test_case"])
            tests = policy_suite.suite(["test_policy_example_y.Example"], directory)
            self.assertEqual([test.id() for test in tests], ["test_policy_example_x.Example.test_case"])

    def test_full_uses_ci_suite_and_all_changed_paths_for_skips(self):
        available = set(build_files.steps())
        for paths in (["src/client.zig"], ["clients/ts/src/client.ts"]):
            with self.subTest(paths=paths):
                checks = list(prepush.checks(paths, available, "HEAD", mode="full"))
                policy = [(name, command) for name, command in checks if name.startswith("tests/ci")]
                self.assertEqual(len(policy), 1)
                name, command = policy[0]
                self.assertEqual(name, "tests/ci (CI policy suite)")
                self.assertIn("tests/ci/policy_suite.py", command)
                self.assertEqual(json.loads(command[command.index("--skips") + 1]),
                                 select(paths, "development", available)["policy_skips"])
        checks = list(prepush.checks(["src/client.zig"], available, "HEAD"))
        names = [name for name, _ in checks if name.startswith("tests/ci")]
        self.assertIn("tests/ci: test_client_locality.py", names)
        self.assertNotIn("tests/ci (CI policy suite)", names)

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

    def test_parallel_results_and_fixture_lifetimes(self):
        # CI-83: each table case must have the same outcome and test IDs at every worker count.
        cases = {
            "pass": ("def test_one(self): pass\n", 0, ["test_one"]),
            "failure": ("def test_one(self): self.fail('failure marker')\n", 1, ["test_one"]),
            "error": ("def test_one(self): raise ValueError('error marker')\n", 1, ["test_one"]),
            "unexpected": ("@unittest.expectedFailure\ndef test_one(self): pass\n", 1, ["test_one"]),
            "class_setup": ("@classmethod\ndef setUpClass(cls): raise ValueError('setup marker')\ndef test_one(self): pass\n", 1, []),
            "skip_class": ("@unittest.skip('class skipped')\ndef test_one(self): pass\n", 0, ["test_one"]),
        }
        import os
        import re
        import subprocess
        import textwrap
        runner = Path(policy_suite.__file__).resolve()
        for label, (body, status, expected) in cases.items():
            for jobs in (1, 2, 4):
                with self.subTest(case=label, jobs=jobs), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    decorator = "@unittest.skip('class skipped')\n" if label == 'skip_class' else ''
                    if decorator:
                        body = "def test_one(self): pass\n"
                    (root / 'test_sample.py').write_text('import unittest\n' + decorator + 'class Sample(unittest.TestCase):\n' + textwrap.indent(body, '    '))
                    result = subprocess.run([sys.executable, '-B', '-c',
                        'import policy_suite,sys; sys.exit(not policy_suite.run_parallel(policy_suite.suite([], sys.argv[1]), int(sys.argv[2]), sys.argv[1]))',
                        str(root), str(jobs)], capture_output=True, text=True,
                        env=dict(os.environ, PYTHONPATH=str(runner.parent)))
                    self.assertEqual(result.returncode, status, result.stderr)
                    markers = {'pass': 'OK', 'failure': 'failure marker', 'error': 'error marker',
                               'unexpected': 'unexpected success', 'class_setup': 'setup marker',
                               'skip_class': 'class skipped'}
                    self.assertIn(markers[label], result.stderr)
                    self.assertEqual(sorted(re.findall(r'^(test_\w+) \(', result.stderr, re.M)), expected)

        for jobs in (1, 2, 4):
            with self.subTest(case='fixtures and skips', jobs=jobs), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'test_shared.py').write_text(textwrap.dedent('''\
                    import os, unittest
                    def record(value):
                        with open(os.environ['EVENTS'], 'a') as output: output.write(value + '\\n')
                    def setUpModule():
                        record('module setup')
                        unittest.addModuleCleanup(record, 'module cleanup')
                    def tearDownModule(): record('module teardown')
                    class Shared(unittest.TestCase):
                        @classmethod
                        def setUpClass(cls):
                            record('class setup')
                            cls.addClassCleanup(record, 'class cleanup')
                        @classmethod
                        def tearDownClass(cls): record('class teardown')
                        def test_a(self): record('a')
                        def test_b(self): record('b')
                    class Other(unittest.TestCase):
                        def test_c(self): record('c')
                '''))
                (root / 'test_class_cleanup.py').write_text(textwrap.dedent('''\
                    import os, unittest
                    def record(value):
                        with open(os.environ['EVENTS'], 'a') as output: output.write(value + '\\n')
                    class Cleanup(unittest.TestCase):
                        def test_a(self): self.addClassCleanup(record, 'cleanup a'); record('class a')
                        def test_b(self): self.addClassCleanup(record, 'cleanup b'); record('class b')
                '''))
                (root / 'test_import_cleanup.py').write_text(textwrap.dedent('''\
                    import os, unittest
                    def cleanup():
                        with open(os.environ['EVENTS'], 'a') as output: output.write('import cleanup\\n')
                    unittest.addModuleCleanup(cleanup)
                    class ImportCleanup(unittest.TestCase):
                        def test_a(self): pass
                        def test_b(self): pass
                '''))
                (root / 'test_skipped.py').write_text("raise __import__('unittest').SkipTest('module skipped')\n")
                events = root / 'events'
                result = subprocess.run([sys.executable, '-B', '-c',
                    'import policy_suite,sys; sys.exit(not policy_suite.run_parallel(policy_suite.suite([], sys.argv[1]), int(sys.argv[2]), sys.argv[1]))',
                    str(root), str(jobs)], capture_output=True, text=True,
                    env=dict(os.environ, PYTHONPATH=str(runner.parent), EVENTS=str(events)))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertCountEqual(events.read_text().splitlines(), ['module setup', 'module teardown', 'module cleanup',
                    'class setup', 'class teardown', 'class cleanup', 'a', 'b', 'c', 'class a', 'class b', 'cleanup a', 'cleanup b', 'import cleanup'])
                lines = events.read_text().splitlines()
                self.assertLess(lines.index('module setup'), lines.index('a'))
                self.assertLess(lines.index('c'), lines.index('module teardown'))
                self.assertLess(lines.index('module teardown'), lines.index('module cleanup'))
                self.assertLess(lines.index('class b'), lines.index('cleanup a'))
                self.assertIn('module skipped', result.stderr)

        for fixture in ('none', 'class', 'module'):
            for failure in ('none', 'serial', 'parallel'):
                for jobs in (1, 2, 4):
                    with self.subTest(case='serial', fixture=fixture, failure=failure, jobs=jobs), tempfile.TemporaryDirectory() as directory:
                        root = Path(directory)
                        module_fixture = """
                    unittest.addModuleCleanup(record, 'module cleanup')
                    def setUpModule(): record('module setup')
                    def tearDownModule(): record('module teardown')
                        """ if fixture == 'module' else ''
                        class_fixture = """
                        @classmethod
                        def setUpClass(cls): record('class setup')
                        @classmethod
                        def tearDownClass(cls): record('class teardown')
                        """ if fixture == 'class' else ''
                        (root / 'test_store_shards.py').write_text(
                            "import os, unittest\n"
                            "def record(value):\n"
                            "    with open(os.environ['EVENTS'], 'a') as output: output.write(value + '\\n')\n"
                            + textwrap.dedent(module_fixture)
                            + "class LauncherTest(unittest.TestCase):\n"
                            + textwrap.indent(textwrap.dedent(class_fixture), '    ')
                            + textwrap.indent(textwrap.dedent('''\
                                def test_a_sibling(self): record('sibling')
                                def test_per_test_deadline_survives_closed_output(self):
                                    record('deadline')
                                    self.assertEqual(os.getpid(), int(os.environ['RUNNER_PID']))
                                    if os.environ['FAIL_CASE'] == 'serial': self.fail('serial failure marker')
                                def test_per_test_timeout_is_independent_of_process_deadline(self):
                                    record('timeout')
                                    self.assertEqual(os.getpid(), int(os.environ['RUNNER_PID']))
                            '''), '    ')
                            + "class Extra(unittest.TestCase):\n    def test_extra(self): record('extra')\n")
                        (root / 'test_other.py').write_text(textwrap.dedent('''\
                            import os, unittest
                            class Other(unittest.TestCase):
                                def test_parallel(self):
                                    with open(os.environ['EVENTS'], 'a') as output: output.write('parallel\\n')
                                    if os.environ['FAIL_CASE'] == 'parallel': self.fail('parallel failure marker')
                        '''))
                        events = root / 'events'
                        result = subprocess.run([sys.executable, '-B', '-c',
                            'import os,policy_suite,sys; os.environ["RUNNER_PID"]=str(os.getpid()); sys.exit(not policy_suite.run_parallel(policy_suite.suite([], sys.argv[1]), int(sys.argv[2]), sys.argv[1]))',
                            str(root), str(jobs)], capture_output=True, text=True,
                            env=dict(os.environ, PYTHONPATH=str(runner.parent), EVENTS=str(events), FAIL_CASE=failure))
                        self.assertEqual(result.returncode, int(failure != 'none'), result.stderr)
                        lines = events.read_text().splitlines()
                        self.assertCountEqual(lines, ['parallel', 'extra', 'sibling', 'deadline', 'timeout']
                                              + ([fixture + ' setup', fixture + ' teardown'] if fixture != 'none' else [])
                                              + (['module cleanup'] if fixture == 'module' else []))
                        self.assertLess(lines.index('parallel'), lines.index('deadline'))
                        self.assertLess(lines.index('deadline'), lines.index('timeout'))
                        if fixture != 'none':
                            self.assertLess(lines.index(fixture + ' setup'), lines.index('sibling'))
                            self.assertLess(lines.index('timeout'), lines.index(fixture + ' teardown'))
                        if fixture == 'module':
                            self.assertLess(lines.index('module setup'), lines.index('extra'))
                            self.assertLess(lines.index('extra'), lines.index('module teardown'))
                            self.assertLess(lines.index('module teardown'), lines.index('module cleanup'))
                        self.assertIn('Ran 5 tests', result.stderr)
                        if failure != 'none':
                            self.assertIn(failure + ' failure marker', result.stderr)
                            self.assertIn('FAILED (failures=1)', result.stderr)

        for label, body, marker in [('unimportable', 'raise ImportError("missing marker")\n', 'missing marker'),
                                    ('worker death', 'import os, unittest\nclass D(unittest.TestCase):\n    def test_die(self): os._exit(7)\n', 'test_die')]:
            for jobs in (1, 2, 4):
                with self.subTest(case=label, jobs=jobs), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / 'test_bad.py').write_text(body)
                    result = subprocess.run([sys.executable, '-B', '-c',
                        'import policy_suite,sys; sys.exit(not policy_suite.run_parallel(policy_suite.suite([], sys.argv[1]), int(sys.argv[2]), sys.argv[1]))',
                        str(root), str(jobs)], capture_output=True, text=True,
                        env=dict(os.environ, PYTHONPATH=str(runner.parent)))
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertIn(marker, result.stderr)
                    if label == 'worker death':
                        self.assertIn('Worker process died', result.stderr)

# CI-66: test flake source counts and trusted allowances only shrink.
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import flake_sources as flake


class FlakeSourcesTest(unittest.TestCase):
    def assert_rule_table(self, rule, samples):
        for path, text, expected in samples:
            with self.subTest(rule=rule, path=path, text=text):
                self.assertEqual(flake.inventory(text, path).get(rule, 0), expected)

    def test_fixed_sleep(self):
        self.assert_rule_table('fixed_sleep', [
            ('tests/x.py', 'time.sleep(1)\nasyncio.sleep(1)', 2),
            ('tests/x.py', '# time.sleep(1)\nx = "asyncio.sleep(1)"', 0),
            ('src/x.zig', 'test "x" { std.Thread.sleep(1); io.sleep(1); Io.sleep(1); }', 3),
            ('src/testing/helper.zig', 'fn helper() void { io.sleep(1); }', 1),
            ('src/x.zig', 'fn f() void { io.sleep(1); }\ntest "x" { const s = "io.sleep(1)"; }', 0),
            ('clients/ts/test/x.test.ts', 'await new Promise(r => setTimeout(r, 10));', 1),
            ('clients/ts/test/x.test.ts', 'await setTimeout(10);', 1),
            ('clients/ts/test/x.test.ts', '// setTimeout(r, 1)\nconst s = "setTimeout(r, 1)";', 0),
        ])

    def test_unsignaled_poll(self):
        self.assert_rule_table('unsignaled_poll', [
            ('tests/x.py', 'while time.monotonic() < deadline:\n    state = read_state()\n    if state: break', 1),
            ('tests/x.py', 'while time.monotonic() < deadline:\n    selector.select(timeout=1)', 0),
            ('tests/x.py', '# while time.monotonic() < deadline: read_state()\nx = "read_state()"', 0),
            ('src/x.zig', 'test "x" { while (clock.now() < deadline) { const x = readState(); } }', 1),
            ('src/x.zig', 'test "x" { while (clock.now() < deadline) { socket.wait(timeout); } }', 0),
            ('clients/ts/test/x.test.ts', 'while (Date.now() < deadline) { const x = readState(); }', 1),
            ('clients/ts/test/x.test.ts', 'while (Date.now() < deadline) { await socket.wait(timeout); }', 0),
        ])

    def test_flake_masking(self):
        self.assert_rule_table('flake_masking', [
            ('tests/x.py', '@pytest.mark.flaky(reruns=2)\ndef test_x(): pass', 1),
            ('tests/x.py', '# @retry(3)\nx = "--retries"', 0),
            ('tests/x.py', 'for attempt in range(3):\n    try:\n        read_data()\n    except OSError:\n        continue', 0),
            ('tests/x.py', 'subprocess.run(["test", "--retries", "2"])', 1),
            ('tests/x.py', 'for attempt in range(3):\n    try:\n        run_test()\n        break\n    except AssertionError:\n        continue', 1),
            ('src/x.zig', 'test "x" { for (0..3) |attempt| { retryTest(); } }', 1),
            ('src/x.zig', 'test "x" { state.retry = null; state.retry(); }', 0),
            ('src/x.zig', 'test "x" { for (cases) |case| { retryMouse(); try std.testing.expect(case.ok); } }', 0),
            ('src/x.zig', 'test "x" { const s = "retryTest()"; }', 0),
            ('clients/ts/test/x.test.ts', 'test("x", { retries: 2 }, runTest);', 1),
            ('clients/ts/test/x.test.ts', '// retries: 2\nconst s = "retries: 2";', 0),
        ])

    def test_test_double(self):
        self.assert_rule_table('test_double', [
            ('tests/x.py', 'unittest.mock.patch("rui.module.value")', 1),
            ('tests/x.py', 'unittest.mock.patch("some.module.value")', 1),
            ('tests/x.py', 'monkeypatch.setattr(rui, "value", fake)', 1),
            ('tests/x.py', 'clock = InjectedClock()\nprovider = ScriptedProvider()', 0),
            ('src/x.zig', 'test "x" { rui.global = fake; }', 1),
            ('src/x.zig', 'test "x" { const clock = InjectedClock.init(); }', 0),
            ('clients/ts/test/x.test.ts', 'globalThis.rui = fake;', 1),
            ('clients/ts/test/x.test.ts', 'const provider = new ScriptedProvider();', 0),
        ])

    def test_scan_reads_only_test_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, text in {
                'tests/nested/test_x.py': 'time.sleep(1)',
                'src/testing/helper.zig': 'fn helper() void { io.sleep(1); }',
                'src/x.zig': 'fn f() void { io.sleep(1); }',
                'clients/ts/test/x.test.ts': 'await setTimeout(10);',
                'clients/ts/src/x.ts': 'await setTimeout(10);',
            }.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            self.assertEqual(flake.scan(root), {
                ('tests/nested/test_x.py', 'fixed_sleep'): 1,
                ('src/testing/helper.zig', 'fixed_sleep'): 1,
                ('clients/ts/test/x.test.ts', 'fixed_sleep'): 1,
            })

    def test_exact_counts(self):
        key = ('tests/x.py', 'fixed_sleep')
        self.assertEqual(flake.check({key: 2}, {key: 2}), [])
        self.assertTrue(flake.check({key: 3}, {key: 2}))
        self.assertTrue(flake.check({key: 1}, {}))
        self.assertIn('lower the allowance to 1', flake.check({key: 1}, {key: 2})[0])
        self.assertIn('lower the allowance to 0', flake.check({}, {key: 2})[0])

    def test_trusted_base_and_bootstrap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                subprocess.run(['git', '-C', str(root), '-c', 'user.name=Test',
                                '-c', 'user.email=test@example.invalid', *args], check=True, capture_output=True)
            git('init', '-q')
            (root / 'tests').mkdir()
            (root / 'tests/x.py').write_text('time.sleep(1)\n')
            git('add', '.')
            git('commit', '-qm', 'base')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            (root / 'tests/x.py').write_text('time.sleep(1)\ntime.sleep(1)\n')
            expected = {'tests/x.py': {'fixed_sleep': 1}}
            self.assertEqual(flake.trusted_allowance(root), expected)
            target = root / flake.ALLOWANCE
            target.parent.mkdir(parents=True)
            target.write_text(json.dumps(expected))
            git('add', '.')
            git('commit', '-qm', 'seed')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            target.write_text(json.dumps({'tests/x.py': {'fixed_sleep': 2}}))
            self.assertEqual(flake.trusted_allowance(root), expected)
            self.assertTrue(flake.compare(flake.inventory_sources(flake.read_sources(root)),
                                          {'tests/x.py': {'fixed_sleep': 2}}, expected))


if __name__ == '__main__':
    unittest.main()

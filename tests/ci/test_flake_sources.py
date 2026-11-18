# CI-66: test flake source counts and trusted allowances only shrink.
import json
import contextlib
import io
from collections import Counter
from pathlib import Path
import subprocess
import tempfile
import unittest

import flake_sources as flake
from flake_sources import (ROOT, ZIG_POLL_HELPER, PYTHON_POLL_HELPER, zig_blocks, zig_sleep_ordering,
    sleep_python_tree, python_sleep_ordering, sleep_ordering, sleep_keys, tree_sources,
    review_base_sources, review_base_ceiling, moved_ceiling, sleep_allowlist_problems, load_sleep_allowance)


class FlakeSourcesTest(unittest.TestCase):
    def assert_rule_table(self, rule, samples):
        for path, text, expected in samples:
            with self.subTest(rule=rule, path=path, text=text):
                self.assertEqual(flake.inventory(text, path).get(rule, 0), expected)

    def test_downloaded_packages_are_not_repository_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sleeping = 'test "x" { std.Thread.sleep(1); }\n'
            for path in ('zig-pkg/dep/src/a.zig', 'screen-emulator/zig-pkg/dep/src/b.zig', 'src/own.zig'):
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text(sleeping)
            self.assertEqual(set(flake.read_sources(root)), {'src/own.zig'})

    def test_every_rule_shares_the_zig_test_scope(self):
        helper = ('fn helper() void {\n'
                  '    while (std.time.milliTimestamp() < deadline) { _ = readState(); }\n'
                  '    io.sleep(1);\n'
                  '}\n')
        for path, expected in [('src/store/creator_tests.zig', True), ('src/x_test.zig', True), ('src/tests.zig', True),
                               ('src/testing/helper.zig', True), ('tests/x.zig', True), ('src/a/test/x.zig', True),
                               ('src/x_tests/y.zig', True), ('src/store/creator.zig', False)]:
            with self.subTest(path=path):
                self.assertEqual(flake.ZIG_TEST_ONLY.search(path) is not None, expected)
                counts = flake.inventory(helper, path)
                self.assertEqual(counts.get('fixed_sleep', 0) > 0, expected)
                self.assertEqual(sum(counts.values()) > 0, expected)

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

    def test_main_rejects_each_new_sleep_and_exempts_poll_helpers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {
                'src/store/creator_tests.zig': 'fn helper() void {}\ntest "one" {}\ntest "two" {}\n',
                'src/testing/poll.zig': 'fn waitUntil() void { io.sleep(1); }\n',
                'tests/integration/host_process.py': 'def wait_for():\n    time.sleep(1)\n',
                'clients/ts/test/x.test.ts': 'test("x", () => {});\n',
                'tests/ci/flake_sources.json': '{}',
            }
            for name, text in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            def git(*args):
                subprocess.run(['git', '-C', directory, '-c', 'user.name=Test',
                                '-c', 'user.email=test@example.invalid', *args], check=True, capture_output=True)
            git('init', '-q')
            git('add', '.')
            git('commit', '-qm', 'base')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            def run():
                with contextlib.redirect_stdout(io.StringIO()):
                    return flake.main([], root)
            self.assertEqual(run(), 0)
            for name, changed in (
                ('src/store/creator_tests.zig', 'fn helper() void { io.sleep(1); }\ntest "one" {}\ntest "two" {}\n'),
                ('src/store/creator_tests.zig', 'fn helper() void {}\ntest "one" {}\ntest "two" { io.sleep(1); }\n'),
                ('clients/ts/test/x.test.ts', 'await setTimeout(10);\n'),
            ):
                with self.subTest(name=name, changed=changed):
                    (root / name).write_text(changed)
                    self.assertEqual(run(), 1)
                    (root / name).write_text(files[name])
            # Keeping the file total unchanged cannot transfer one test's budget to another.
            zig = root / 'src/store/creator_tests.zig'
            zig.write_text('fn helper() void {}\ntest "one" { io.sleep(1); }\ntest "two" {}\n')
            (root / flake.ALLOWANCE).write_text(json.dumps({
                'src/store/creator_tests.zig': {'fixed_sleep': {'one': [1, 'existing sleep']}}
            }))
            git('add', '.')
            git('commit', '-qm', 'allow one')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            self.assertEqual(run(), 0)
            zig.write_text('fn helper() void {}\ntest "one" {}\ntest "two" { io.sleep(1); }\n')
            self.assertEqual(run(), 1)

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
            expected = {'tests/x.py': {'fixed_sleep': {'<module>': [1, 'Existing fixed sleep recorded at migration']}}}
            self.assertEqual(flake.trusted_allowance(root), expected)
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(flake.main(['--seed'], root), 0)
            self.assertEqual(flake.validate(json.loads(output.getvalue())), expected)
            target = root / flake.ALLOWANCE
            target.parent.mkdir(parents=True)
            target.write_text(json.dumps(expected))
            git('add', '.')
            git('commit', '-qm', 'seed')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            self.assertEqual(flake.validate(flake.trusted_allowance(root)), expected)
            target.write_text(json.dumps({'tests/x.py': {'fixed_sleep': 2}}))
            with self.assertRaises(ValueError):
                flake.validate(json.loads(target.read_text()))
            self.assertEqual(flake.trusted_allowance(root), expected)
            (root / 'tests/x.py').write_text('pass\n')
            target.write_text('{}')
            git('add', '.')
            git('commit', '-qm', 'empty allowance')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            self.assertEqual(flake.trusted_allowance(root), {})
            self.assertEqual(flake.review_base_ceiling(root), {})
            target.write_text(json.dumps({'tests/x.py': {'fixed_sleep': 1, 'bad_rule': 3}}))
            git('add', '.')
            git('commit', '-qm', 'invalid legacy')
            git('update-ref', 'refs/remotes/origin/main', 'HEAD')
            with self.assertRaises(ValueError):
                flake.trusted_allowance(root)


# CI-35: sleep ordering retains its reasoned trusted allowance.
class SleepOrderingTest(unittest.TestCase):

    def test_tree_matches_the_shrink_only_allowlist(self):
        tree = list(tree_sources())
        base = dict(review_base_sources())
        offenses = sleep_ordering(tree)
        ceiling = moved_ceiling(offenses, review_base_ceiling(sources=base), sleep_keys(tree), sleep_keys(base.items()))
        self.assertEqual(sleep_allowlist_problems(offenses, load_sleep_allowance(), ceiling), [])

    def test_read_only_parsers_reuse_content_and_detect_edits(self):
        zig = 'test "cached parsing" { std.time.sleep(1); }'
        self.assertIs(zig_blocks(zig), zig_blocks(zig))
        self.assertEqual(zig_sleep_ordering("src/tests.zig", zig), {("src/tests.zig", "cached parsing"): 1})
        self.assertEqual(zig_sleep_ordering("src/tests.zig", zig.replace("sleep", "wake")), {})
        python = 'def cached_parsing():\n    time.sleep(1)\n'
        self.assertIs(sleep_python_tree(python), sleep_python_tree(python))
        self.assertEqual(python_sleep_ordering("tests/integration/cases.py", python),
                         {("tests/integration/cases.py", "cached_parsing"): 1})
        self.assertEqual(python_sleep_ordering("tests/integration/cases.py", python.replace("sleep", "wake")), {})

    def test_a_moved_test_keeps_only_its_own_allowance(self):
        base = Counter({("a.zig", "t"): 2, ("a.zig", "u"): 1})
        base_keys = {("a.zig", "t"), ("a.zig", "u"), ("c.zig", "t")}
        moved = Counter({("b.zig", "t"): 2, ("a.zig", "u"): 1})
        self.assertEqual(moved_ceiling(moved, base, set(moved), base_keys)[("b.zig", "t")], 2)
        both = base + Counter({("b.zig", "t"): 1})
        self.assertEqual(moved_ceiling(both, base, set(both), base_keys)[("b.zig", "t")], 0)
        self.assertEqual(moved_ceiling(Counter({("b.zig", "v"): 1}), base, {("b.zig", "v")}, base_keys)[("b.zig", "v")], 0)
        stayed = Counter({("b.zig", "t"): 2, ("a.zig", "u"): 1})
        self.assertEqual(moved_ceiling(stayed, base, set(stayed) | {("a.zig", "t")}, base_keys)[("b.zig", "t")], 0)
        deleted = Counter({("c.zig", "t"): 2, ("a.zig", "u"): 1})
        self.assertEqual(moved_ceiling(deleted, base, set(deleted), base_keys)[("c.zig", "t")], 0)

    def test_sleep_keys_name_every_test_whether_or_not_it_sleeps(self):
        zig = 'test "quiet" {}\ntest "loud" { std.Thread.sleep(1); }\nfn helper() void {}\n'
        python = "def run():\n    pass\n\n\nclass Case:\n    def step(self):\n        pass\n"
        self.assertEqual(sleep_keys([("src/a.zig", zig), ("src/x/tests.zig", zig),
                                     ("tests/integration/a.py", python), ("docs/b.zig", zig)]), {
            ("src/a.zig", "quiet"), ("src/a.zig", "loud"),
            ("src/x/tests.zig", "quiet"), ("src/x/tests.zig", "loud"), ("src/x/tests.zig", "helper"),
            ("docs/b.zig", "quiet"), ("docs/b.zig", "loud"),
            ("tests/integration/a.py", "run"), ("tests/integration/a.py", "Case"),
            ("tests/integration/a.py", "Case.step")})

    def test_zig_sleeps_count_in_tests_and_test_only_files(self):
        source = r'''
fn production(io: std.Io) void {
    io.sleep(.fromMilliseconds(5), .awake) catch {};
}
fn peer(io: std.Io) void {
    io.sleep(.fromMilliseconds(5), .awake) catch {};
}
test "a bare sleep counts" {
    // std.testing.io.sleep(.fromMilliseconds(1), .awake) in a comment
    const text = "std.testing.io.sleep(.fromMilliseconds(1), .awake)";
    try std.testing.io.sleep(.fromMilliseconds(150), .awake);
}
test "a sleep inside a loop still counts" {
    while (!done()) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    const Peer = struct {
        fn run() void {
            _ = std.c.poll(&[_]std.c.pollfd{}, 0, 1);
        }
    };
    try test_poll.waitUntil(std.testing.io, deadline, &flag, test_poll.isSet);
}
'''
        self.assertEqual(zig_sleep_ordering("src/a.zig", source), {
            ("src/a.zig", "a bare sleep counts"): 1,
            ("src/a.zig", "a sleep inside a loop still counts"): 2,
        })
        helper = r'''
pub fn waitUntil(io: std.Io, deadline: std.Io.Clock.Timestamp, context: anytype, comptime condition: anytype) error{Timeout}!void {
    while (!condition(context)) try io.sleep(.fromMilliseconds(1), deadline.clock);
}
pub fn pump(io: std.Io) void {
    io.sleep(.fromMilliseconds(1), .awake) catch {};
}
'''
        self.assertEqual(zig_sleep_ordering(ZIG_POLL_HELPER[0], helper), {(ZIG_POLL_HELPER[0], "pump"): 1})
        self.assertEqual(zig_sleep_ordering("src/h2/tests.zig", helper), {
            ("src/h2/tests.zig", "waitUntil"): 1, ("src/h2/tests.zig", "pump"): 1})

    def test_python_sleeps_count_everywhere_but_the_poll_helper(self):
        source = '''
import time
def wait_for(predicate, description):
    while not predicate():
        time.sleep(0.01)
def scenario():
    def peer():
        time.sleep(0.5)
    while not ready():
        time.sleep(0.01)
    wait_for(ready, "ready")
    child = "import time; time.sleep(30)"
class Handler:
    def do_POST(self):
        time.sleep(2.5)
'''
        self.assertEqual(python_sleep_ordering("tests/integration/x.py", source), {
            ("tests/integration/x.py", "wait_for"): 1,
            ("tests/integration/x.py", "scenario"): 2,
            ("tests/integration/x.py", "Handler.do_POST"): 1,
        })
        self.assertEqual(python_sleep_ordering(PYTHON_POLL_HELPER[0], source), {
            (PYTHON_POLL_HELPER[0], "scenario"): 2,
            (PYTHON_POLL_HELPER[0], "Handler.do_POST"): 1,
        })

    def test_allowlist_rejects_new_offenders_and_keeps_shrinking(self):
        key = ("src/a.zig", "peer sleeps before it replies")
        one, two, allow = Counter({key: 1}), Counter({key: 2}), {key: (1, "seeded")}
        self.assertEqual(sleep_allowlist_problems(one, allow, one), [])
        self.assertIn("2 test sleep(s) outside wait_for/waitUntil, 1 allowed", sleep_allowlist_problems(two, allow, two)[0])
        self.assertIn("1 test sleep(s) outside wait_for/waitUntil, 0 allowed", sleep_allowlist_problems(one, {}, one)[0])
        self.assertIn("remove its allowlist entry", sleep_allowlist_problems(Counter(), allow, one)[0])
        self.assertIn("lower", sleep_allowlist_problems(one, {key: (2, "seeded")}, two)[0])
        self.assertEqual(sleep_allowlist_problems(two, {key: (2, "seeded")}, one),
                         [f"{key}: allowance 2 exceeds the 1 found at the review base; the allowlist only shrinks"])
        self.assertIn("exceeds the 0 found", sleep_allowlist_problems(one, allow, Counter())[0])

    def test_review_base_sources_match_the_tree_at_that_commit(self):
        base = subprocess.run(["git", "-C", str(ROOT), "merge-base", "HEAD", "origin/main"],
                              capture_output=True, text=True, check=True).stdout.strip()
        sources = dict(review_base_sources())
        self.assertIn("src/h2/tests.zig", sources)
        self.assertEqual(sources["src/h2/tests.zig"], subprocess.run(
            ["git", "-C", str(ROOT), "show", f"{base}:src/h2/tests.zig"],
            capture_output=True, text=True, check=True).stdout)

    def test_review_base_ceiling_keeps_the_allowance_of_a_sleep_a_rule_change_moved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tests/ci").mkdir(parents=True)
            (root / "src").mkdir()
            (root / "src/a.zig").write_text(
                'fn peer(io: std.Io) void {\n    io.sleep(.fromMilliseconds(5), .awake) catch {};\n}\n'
                'test "measured" {\n    try std.testing.io.sleep(.fromMilliseconds(5), .awake);\n}\n')
            (root / "tests/ci/test_harness_contracts.py").write_text(
                'SLEEP_ORDERED = {("src/a.zig", "moved"): (1, "peer"), ("src/a.zig", "measured"): (1, "settle")}\n')

            def git(*args):
                subprocess.run(["git", "-C", directory, "-c", "user.name=t", "-c", "user.email=t@example.com",
                                "-c", "commit.gpgsign=false", *args], capture_output=True, check=True)
            git("init", "-q")
            git("add", ".")
            git("commit", "-qm", "base")
            git("update-ref", "refs/remotes/origin/main", "HEAD")
            self.assertEqual(review_base_ceiling(root), {("src/a.zig", "moved"): 1, ("src/a.zig", "measured"): 1})
            (root / "tests/ci/test_harness_contracts.py").write_text("ALLOWED = {}\n")
            git("commit", "-qam", "renamed")
            git("update-ref", "refs/remotes/origin/main", "HEAD")
            with self.assertRaisesRegex(AssertionError, "no single SLEEP_ORDERED"):
                review_base_ceiling(root)

    def test_every_allowlist_entry_has_a_reason(self):
        self.assertEqual([key for key, (count, reason) in load_sleep_allowance().items()
                          if count < 1 or not reason.strip() or "\n" in reason], [])



if __name__ == '__main__':
    unittest.main()

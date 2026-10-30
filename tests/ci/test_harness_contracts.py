"""Private fixture schema checks, discovered by the existing CI policy gate."""

import ast
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import mmap
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("host_process", ROOT / "tests/integration/host_process.py")
HOST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOST)

# Independent current schema, not expectations read from either codec.
FIELDS = (
    "rui_test_phase", "at_ns", "subject_kind", "subject", "turn", "operation",
    "attempt", "action", "scratch_used_bytes", "command_key", "kind", "control_key",
    "store_queued_at_ns", "lock_acquired_at_ns", "store_complete_at_ns",
    "reply_complete_at_ns", "queue_wait_ns", "store_lock_wait_ns", "store_service_ns",
    "post_commit_reply_ns", "host_total_ns", "start_ns", "wait_ns", "custody_occupied",
    "new_connections", "replays",
    "work_bytes", "work_items", "request_bytes",
    "process_memory_current_bytes", "process_memory_highwater_bytes", "cache_used_bytes",
    "cache_spills", "hard_heap_limit_bytes", "page_size_bytes", "cache_size_setting",
    "cache_spill_threshold", "mmap_size_bytes", "synchronous", "temp_store", "busy_timeout_ms",
    "journal_mode",
)


class ObservationCodecTest(unittest.TestCase):
    def test_stable_ids_and_cross_language_coherence(self):
        source = (ROOT / "src/TestObservation.zig").read_text()
        declaration = re.search(r"const FieldId = enum\(u8\) \{([^}]+)\};", source)
        self.assertIsNotNone(declaration, "native codec must declare explicit stable IDs")
        entries = re.findall(r"(\w+)\s*=\s*(\d+),", declaration[1])
        expected = dict(enumerate(FIELDS))
        self.assertEqual(len(entries), len(expected), "missing or duplicate codec field")
        self.assertEqual({int(value): name for name, value in entries}, expected)
        self.assertEqual(HOST.OBSERVATION_FIELDS, expected)
        go = (ROOT / "tests/qualification/measurement/observation.go").read_text()
        table = re.search(r"var observationFields = \[\.\.\.\]string\{([^}]+)\}", go)
        self.assertIsNotNone(table, "Go qualification codec must list field IDs in order")
        self.assertEqual(dict(enumerate(re.findall(r'"(\w+)"', table[1]))), expected)

    def test_frame_decodes_every_id_independent_of_field_order(self):
        values = {name: f"value-{index}" for index, name in enumerate(FIELDS)}
        # The integer-valued native fields still arrive as decimal text.
        values.update(new_connections="0", replays="902")
        payload = b"".join(
            struct.pack("<BH", index, len(value)) + value
            for index, name in reversed(list(enumerate(FIELDS)))
            for value in [values[name].encode()]
        )
        frame = struct.pack("<HBBQQQ", 28 + len(payload), 1, 0, 1, 37, os.getpid()) + payload
        self.assertLessEqual(len(frame), 512)
        state = mmap.mmap(-1, 40)
        state[:] = struct.pack("<QQQQQ", 1, os.getpid(), 37, 2, 0)
        reader, writer = os.pipe()
        observations = HOST._Observations(SimpleNamespace(pid=os.getpid(), poll=lambda: 0), reader, "status", state)
        try:
            self.assertEqual(os.write(writer, frame), len(frame))
        finally:
            os.close(writer)
        observations.close()
        self.assertEqual(observations.records, [dict(values, process=str(os.getpid()), run="37",
                                                   sequence="1", clock="awake_ns", trace_lost=False)])

    def test_session_list_release_prefix_on_both_platforms(self):
        for platform in ("darwin", "linux"):
            with self.subTest(platform=platform):
                result = subprocess.run(
                    [sys.executable, "-B", "-c",
                     f"from session_list_release_proof import oracle_controls; oracle_controls({platform!r})"],
                    cwd=ROOT / "tests/integration", capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class QualificationEvidenceTest(unittest.TestCase):
    def test_qualification_never_reads_stderr_phase_traces(self):
        # Stderr traces drop records under contention; qualification reads the
        # lossless observation channel (CODING_STANDARDS.md#evidence).
        offenders = [
            str(path.relative_to(ROOT))
            for path in sorted((ROOT / "tests/qualification").rglob("*.go"))
            if re.search(r"--test-phase-trace|trace_lost", path.read_text())
        ]
        self.assertEqual(offenders, [])


# Tests wait through one poll helper per language; every other sleep in test
# code counts against SLEEP_ORDERED. The helper's own key is the one exemption.
ZIG_POLL_HELPER = ("src/testing/poll.zig", "waitUntil")
PYTHON_POLL_HELPER = ("tests/integration/host_process.py", "wait_for")
ZIG_SLEEP = re.compile(r"\b(?:sleep|nanosleep|usleep)\s*\(|\bpoll\(\s*&\[_\][\w.]*pollfd\{\}\s*,\s*0\s*,")
ZIG_SKIPPED = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'')
ZIG_TEST = re.compile(r'\s*test\s*(?:"((?:\\.|[^"\\])*)"|(\w+))?\s*')
ZIG_DECLARATION = re.compile(r"\b(?:fn|const|var)\s+(\w+)")
ZIG_EXPRESSION = re.compile(r"(?:\.|\berror)\s*$")
ZIG_TEST_ONLY = re.compile(r"(?:^|/)(?:tests|testing)/|tests?\.zig$")


def zig_sleep_ordering(path, text):
    """Sleeps in `test` blocks, by test, and elsewhere in a test-only file, by top-level declaration."""
    code = ZIG_SKIPPED.sub(lambda match: " " * len(match[0]), text)
    names = ZIG_SKIPPED.sub(lambda match: match[0] if match[0][0] == '"' else " " * len(match[0]), text)
    tests, declarations, open_blocks, head, top_head = [], [], [], 0, 0
    for index, char in enumerate(code):
        if char == "{":
            open_blocks.append((head, index))
            head = index + 1
        elif char == "}":
            block_head, start = open_blocks.pop()
            if test := ZIG_TEST.fullmatch(names, block_head, start):
                tests.append((start, index, test[1] or test[2] or "<unnamed test>"))
            # `.{` literals and `error{` sets inside a declaration's header do not end it.
            if not open_blocks and not ZIG_EXPRESSION.search(code, top_head, start):
                if declaration := ZIG_DECLARATION.search(code, top_head, start):
                    declarations.append((start, index, declaration[1]))
                top_head = index + 1
            head = index + 1
        elif char == ";":
            head = index + 1
            if not open_blocks:
                top_head = index + 1
    test_only = ZIG_TEST_ONLY.search(path) is not None
    offenses = Counter()
    for match in ZIG_SLEEP.finditer(code):
        if code[:match.start()].rstrip().endswith("fn"):
            continue
        within = [name for start, end, name in tests if start < match.start() < end]
        if within:
            offenses[(path, within[-1])] += 1
        elif test_only:
            offenses[(path, next((name for start, end, name in declarations if start < match.start() < end),
                                 "<top level>"))] += 1
    offenses.pop(ZIG_POLL_HELPER, None)
    return offenses


def python_sleep_ordering(path, text):
    """`time.sleep`/`asyncio.sleep` calls, by top-level function or method.

    Nested functions charge the function that holds them. Sleeps in
    child-program source strings are not calls.
    """
    offenses = Counter()

    def visit(node, name):
        for child in ast.iter_child_nodes(node):
            child_name = name
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                if name is None:
                    child_name = child.name
                elif isinstance(node, ast.ClassDef) and "." not in name:
                    child_name = f"{name}.{child.name}"
            elif (isinstance(child, ast.Call) and isinstance(child.func, ast.Attribute) and child.func.attr == "sleep"
                  and getattr(child.func.value, "id", None) in ("time", "asyncio")):
                offenses[(path, name or "<module>")] += 1
            visit(child, child_name)

    visit(ast.parse(text), None)
    offenses.pop(PYTHON_POLL_HELPER, None)
    return offenses


def sleep_ordering(sources):
    """Offenses across (path, text) sources: Zig under src/ and tests/, Python fixtures and CI tests."""
    offenses = Counter()
    for path, text in sources:
        if path.endswith(".zig") and path.startswith(("src/", "tests/")):
            offenses += zig_sleep_ordering(path, text)
        elif re.fullmatch(r"tests/integration/[^/]+\.py|tests/ci/(?:test_[^/]*|[^/]*_test)\.py", path):
            offenses += python_sleep_ordering(path, text)
    return offenses


def tree_sources(root=ROOT):
    for path in sorted([*(root / "src").rglob("*"), *(root / "tests").rglob("*")]):
        if path.suffix in (".zig", ".py") and path.is_file():
            yield str(path.relative_to(root)), path.read_text()


def review_base_sources(root=ROOT):
    """Sources at the merge base with origin/main, the trusted ceiling for the allowlist."""
    def git(*args, **options):
        return subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=True, **options).stdout

    base = git("merge-base", "HEAD", "origin/main", text=True).strip()
    paths = [path for path in git("ls-tree", "-r", "--name-only", base, "--", "src", "tests", text=True).splitlines()
             if path.endswith((".zig", ".py"))]
    contents = git("cat-file", "--batch", input="".join(f"{base}:{path}\n" for path in paths).encode())
    for path in paths:
        header, contents = contents.split(b"\n", 1)
        size = int(header.split()[2])
        yield path, contents[:size].decode()
        contents = contents[size + 1:]


def review_base_ceiling(root=ROOT):
    """Per key, the larger of the rule's count at the review base and that base's own allowance."""
    # Lets an honest rule change move a sleep between keys without granting new allowance.
    sources = dict(review_base_sources(root))
    ceiling = sleep_ordering(sources.items())
    allowlists = [node.value for node in ast.parse(sources["tests/ci/test_harness_contracts.py"]).body
                  if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", None) == "SLEEP_ORDERED"]
    if len(allowlists) != 1:
        raise AssertionError("review base has no single SLEEP_ORDERED allowlist")
    for key, (count, _) in ast.literal_eval(allowlists[0]).items():
        ceiling[key] = max(ceiling[key], count)
    return ceiling


def sleep_allowlist_problems(offenses, allowed, trusted):
    problems = []
    for key in sorted(set(offenses) | set(allowed)):
        found, listed = offenses.get(key, 0), allowed.get(key, (0, ""))[0]
        if found > listed:
            problems.append(f"{key}: {found} test sleep(s) outside wait_for/waitUntil, {listed} allowed; "
                            "poll through the helper, gate on an event, or list it with a reason")
        elif found < listed:
            problems.append(f"{key}: {listed} allowed but {found} found; lower or remove its allowlist entry")
        if listed > trusted.get(key, 0):
            problems.append(f"{key}: allowance {listed} exceeds the {trusted.get(key, 0)} found at the "
                            "review base; the allowlist only shrinks")
    return problems


# Shrink-only: (count, reason) per test. A fix must lower or remove its entry,
# and no count may exceed what the review base measures.
SLEEP_ORDERED = {
    ("src/client.zig", "Host processing wait does not consume response transfer inactivity"):
        (1, "peer sleeps before replying against the client's real inactivity deadline"),
    ("src/client.zig", "Host processing wait starts inactivity only after the first response byte"):
        (1, "peer sleeps before replying against the client's real inactivity deadline"),
    ("src/client.zig", "Host-info first byte is bounded independently of normal processing waits"):
        (1, "peer sleeps before replying against the client's real inactivity deadline"),
    ("src/client.zig", "mutation response progress renews inactivity through header and body"):
        (2, "producer sleeps 4.5 s and 1 s against a 5 s inactivity limit"),
    ("src/client.zig", "response deadlines include partial header and body"):
        (1, "peer sleeps before replying against the client's real response deadline"),
    ("src/client.zig", "response transfer inactivity begins after the first byte"):
        (1, "peer sleeps before replying against the client's real inactivity deadline"),
    ("src/client.zig", "transport cancellation quanta neither expire nor renew inactivity and observed stop wins"):
        (1, "stopper requests stop after 700 ms instead of at an observed blocked write"),
    ("src/client.zig", "transport cancellation saturated Unix backlog is not a connected writable socket"):
        (1, "stopper requests stop after 150 ms instead of at an observed blocked connect"),
    ("src/h2/tests.zig", "PeerThread"):
        (1, "pump: the peer thread services its sockets every 1 ms until the test stops it"),
    ("src/server.zig", "reply delivery interrupted poll consumes the existing inactivity budget"):
        (1, "pump: the interrupter signals the blocked writer every 5 ms until the test stops it"),
    ("src/store.zig", "temporary model failures conserve allowance and exhaust after four Attempts"):
        (2, "sleeps out a 5 ms retry wait on the real clock"),
    ("tests/ci/test_selection.py", "FullCheckPartitionTest.run_part"):
        (1, "samples for 0.1 s that held authority starts no isolated work"),
    ("tests/integration/codex_integration.py", "forced_refresh_journey"):
        (3, "sleeps 0.4 s to show no refresh or resend follows a settled failure"),
    ("tests/integration/codex_integration.py", "run"):
        (1, "sleeps 0.4 s to show no resend follows a settled rejection"),
    ("tests/integration/control_integration.py", "prove_retry_wait_control"):
        (1, "sleeps past the retry wait to show no Attempt follows cancellation"),
    ("tests/integration/descriptor_capacity_integration.py", "prove_accept_pressure"):
        (1, "pauses 10 ms after releasing a held accept before the next connect"),
    ("tests/integration/dispatch_integration.py", "main"):
        (9, "settle sleeps before asserting no further provider request or result"),
    ("tests/integration/host_status_integration.py", "discovery_body_deadline"):
        (1, "client sleeps 2 s mid-header against the Host's acceptance budget"),
    ("tests/integration/human_cli_integration.py", "main"):
        (2, "input paced past the bare-ESC ambiguity timeout and the repaint window"),
    ("tests/integration/human_cli_integration.py", "persistent_opening_case"):
        (1, "sleeps 0.5 s before asserting history stopped at its start"),
    ("tests/integration/human_cli_integration.py", "renderer_cases"):
        (14, "settle sleeps before screen and request assertions"),
    ("tests/integration/model_fixture.py", "FailureHandler.do_POST"):
        (2, "slow-body and stall peers pace bytes against the client's real deadlines"),
    ("tests/integration/model_fixture.py", "SuccessHandler.do_POST"):
        (1, "paces SSE chunks by the scenario's chunk_delay"),
    ("tests/integration/terminal_restoration_integration.py", "persistent_cases"):
        (1, "sleeps 0.5 s after a command so it can reach blocked output before Ctrl-C"),
    ("tests/integration/terminal_restoration_integration.py", "renderer_backpressure_case"):
        (1, "sleeps 0.5 s to show a command stays pending behind blocked output"),
    ("tests/integration/terminal_restoration_integration.py", "visible_stream_handoff_cases"):
        (2, "sleeps 0.5 s to show a command stays pending behind held output"),
    ("tests/integration/transport_h2_integration.py", "held_population"):
        (2, "0.2 s settle, then a 3 s idle-CPU measurement window"),
}


class SleepOrderingTest(unittest.TestCase):
    """CODING_STANDARDS.md#evidence: tests order actors with gates, not sleeps."""

    def test_tree_matches_the_shrink_only_allowlist(self):
        self.assertEqual(sleep_allowlist_problems(sleep_ordering(tree_sources()), SLEEP_ORDERED,
                                                  review_base_ceiling()), [])

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

    def test_python_poll_helper_refuses_a_late_observation_and_reports_the_last_one(self):
        now = [0.0]
        clock = SimpleNamespace(monotonic=lambda: now[0], sleep=lambda delay: now.__setitem__(0, now[0] + delay))
        with patch.object(HOST, "time", clock):
            observations = iter([{"n": 1}, {}])
            self.assertEqual(HOST.wait_for(lambda: next(observations), "empty", timeout=1, interval=0.025,
                                           ready=lambda observed: observed == {}), {})

            def late():
                now[0] += 1
                return [1, 2]
            with self.assertRaisesRegex(HOST.WaitTimeout, r"timed out waiting for two; last observed \[1, 2\]"):
                HOST.wait_for(late, "two", timeout=0.5, ready=lambda found: len(found) == 2)

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
        self.assertEqual([key for key, (count, reason) in SLEEP_ORDERED.items()
                          if count < 1 or not reason.strip() or "\n" in reason], [])


FIXTURE_DIRECTORIES = ("tests/integration", "tests/qualification/direct-pty")
# Libraries and harness self-tests that launch no Rui and so need no fixture boundary.
LAUNCH_NO_RUI = {"tests/integration/os_semantics.py", "tests/integration/product_defaults.py",
                 "tests/integration/terminal_screen.py", "tests/integration/session_sequence_model_test.py"}


class FixtureEntryTest(unittest.TestCase):
    def test_every_fixture_entry_refuses_root_before_it_starts(self):
        entries = sorted({path.relative_to(ROOT).as_posix() for directory in FIXTURE_DIRECTORIES
                          for pattern in ("*.py", "*.sh") for path in (ROOT / directory).glob(pattern)} - LAUNCH_NO_RUI)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "simulated-root"
            root.mkdir()
            (root / "sitecustomize.py").write_text("import os\nos.geteuid = lambda: 0\n")
            scratch = Path(directory) / "tmp"
            scratch.mkdir()
            environment = {"PATH": os.environ["PATH"], "HOME": directory, "TMPDIR": str(scratch),
                           "PYTHONPATH": str(root)}

            def run(entry):
                command = ["sh", entry] if entry.endswith(".sh") else [sys.executable, "-B", entry]
                return entry, subprocess.run(command, cwd=ROOT, env=environment, capture_output=True,
                                             text=True, timeout=30)

            with ThreadPoolExecutor(max_workers=4) as pool:
                results = list(pool.map(run, entries))
            started = [(entry, result.returncode, result.stdout[-300:] + result.stderr[-300:])
                       for entry, result in results
                       if result.returncode == 0 or "must run as a non-root user" not in result.stderr]
            self.assertEqual(started, [], "fixture entries ran past the shared root refusal")
            self.assertEqual(list(scratch.iterdir()), [], "a refused fixture created state")

    def test_fixture_children_receive_only_the_fixture_environment(self):
        source = ("import json, subprocess, sys\n"
                  "sys.path.insert(0, sys.argv[1])\n"
                  "import host_process\n"
                  "print(subprocess.run([sys.executable, '-c', 'import json, os; print(json.dumps(dict(os.environ)))'],"
                  " capture_output=True, text=True, check=True).stdout)\n")
        with tempfile.TemporaryDirectory() as directory:
            planted = {"RUI_CODEX_CREDENTIAL_FILE": str(Path(directory) / "absent.json"),
                       "RUI_STORE": str(Path(directory) / "foreign-store"), "RUI_ADDRESS": "zzzzzz",
                       "RUI_SENDER_HANDLE": "inherited", "SSL_CERT_FILE": str(Path(directory) / "absent.pem"),
                       "HTTPS_PROXY": "http://127.0.0.1:9", "TERM": "dumb"}
            named = {"PATH": os.environ["PATH"], "HOME": directory, "TMPDIR": directory,
                     "RUI_FAILURE_ARTIFACTS": str(Path(directory) / "retained")}
            result = subprocess.run([sys.executable, "-B", "-c", source, str(ROOT / "tests/integration")],
                                    env={**planted, **named}, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            child = json.loads(result.stdout)
            self.assertEqual({name: child.get(name) for name in planted}, dict.fromkeys(planted))
            self.assertEqual({name: child.get(name) for name in named}, named)


class ImportSafetyTest(unittest.TestCase):
    def test_session_list_support_imports_ignore_process_arguments_and_workspace(self):
        source = """
import importlib, pathlib, subprocess, sys
from unittest.mock import patch
sys.path.insert(0, sys.argv[1])
sys.argv = sys.argv[2:]
original = list(sys.argv)
with patch.object(pathlib.Path, 'resolve', side_effect=AssertionError('import resolved caller configuration')), \
     patch.object(pathlib.Path, 'cwd', side_effect=AssertionError('import captured caller workspace')), \
     patch.object(subprocess, 'Popen', side_effect=AssertionError('import launched a process')):
    for name in ('session_list_integration', 'session_list_release_proof'):
        module = importlib.import_module(name)
        assert not hasattr(module, 'RUI') and not hasattr(module, 'CLIENT')
        assert callable(module.main)
assert sys.argv == original
print('import-safe')
"""
        for arguments in ([], ["foreign-runner", "-k", "--unrelated-option"]):
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run([sys.executable, "-B", "-c", source,
                                         str(ROOT / "tests/integration"), *arguments],
                                        cwd=directory, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "import-safe\n")
                self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main()

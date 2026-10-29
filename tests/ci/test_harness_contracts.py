"""Private fixture schema checks, discovered by the existing CI policy gate."""

import ast
from collections import Counter, namedtuple
import importlib.util
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
USER_SPEC = importlib.util.spec_from_file_location("fixture_user", ROOT / "tests/integration/fixture_user.py")
FIXTURE_USER = importlib.util.module_from_spec(USER_SPEC)
USER_SPEC.loader.exec_module(FIXTURE_USER)

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


ZIG_SLEEP = re.compile(r"\b(?:sleep|nanosleep|usleep)\s*\(|\bpoll\(\s*&\[_\][\w.]*pollfd\{\}\s*,\s*0\s*,")
ZIG_SKIPPED = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'')
ZIG_WHILE = re.compile(r"(?:\w+\s*:\s*)?(?:inline\s+)?while\b")
ZIG_FOR = re.compile(r"(?:\w+\s*:\s*)?(?:inline\s+)?for\b")
ZIG_LOOP = re.compile(r"(?:\w+\s*:\s*)?(?:inline\s+)?(?:while|for)\b")
ZIG_RETRY = re.compile(r"(?:\w+\s*:\s*)?(?:inline\s+)?for\s*\(\s*0\s*\.\.")
ZIG_EXIT = re.compile(r"\breturn\b|\bbreak\b(?:\s*:\s*(\w+))?")
ZIG_CONTAINER = re.compile(r"\b(\w+)\s*=\s*(?:(?:extern|packed)\s+)?(?:struct|union|enum)\b[^=]*$")
ZIG_PREFIX = re.compile(r"(?:if\s*\((?:[^()]|\([^()]*\))*\)\s*(?:\|[^|]*\|\s*)?|else\s+|return\s+"
                        r"|(?:(?:pub\s+)?(?:const|var)\s+)?[\w.\[\]]+\s*(?::[^=]*)?[-+*/|&]?=(?!=)\s*)*")
ZIG_ERROR_SET = re.compile(r"(?:^|\W)error$")
ZIG_TEST = re.compile(r'\btest\s+"((?:\\.|[^"\\])*)"')
ZIG_UNNAMED_TEST = re.compile(r"\btest\s*$")
ZIG_FN = re.compile(r"\b(pub\s+)?(?:(?:export|extern|inline)\s+)?fn\s+(\w+)\s*\(")
Scope = namedtuple("Scope", "head start end kind name public")


def zig_sleep_ordering(path, text):
    """Straight-line sleeps in Zig tests and test-only helpers, by test name.

    A sleep is a wait only when its nearest enclosing loop re-checks a
    condition: a `while` loop, or a `for (0..n) |_|` retry loop with an early
    exit. A helper that sleeps outside such a loop charges each test that uses
    it. Production code, including code a test calls, is out of scope.
    """
    code = ZIG_SKIPPED.sub(lambda match: " " * len(match[0]), text)
    declarations = ZIG_SKIPPED.sub(lambda match: match[0] if match[0][0] in "\"'" else " " * len(match[0]), text)
    # `.{` literals and `error{` sets are expressions, not bodies, so they keep
    # the enclosing statement's header.
    blocks, open_blocks, head = [], [], 0
    for index, char in enumerate(code):
        if char == "{":
            last = index - 1
            while last >= 0 and code[last].isspace():
                last -= 1
            expression = code[last] == "." or ZIG_ERROR_SET.match(code, max(0, last - 5), last + 1) is not None
            open_blocks.append((head, index, expression))
            head = index + 1
        elif char == "}":
            block_head, start, expression = open_blocks.pop()
            if expression:
                head = block_head
            else:
                blocks.append((block_head, start, index))
                head = index + 1
        elif char == ";":
            head = index + 1
    scopes, unnamed = [], 0
    for head, start, end in sorted(blocks, key=lambda block: block[1]):
        if test := ZIG_TEST.search(declarations[head:start]):
            scopes.append(Scope(head, start, end, "test", test[1], False))
        elif ZIG_UNNAMED_TEST.search(declarations[head:start]):
            unnamed += 1
            scopes.append(Scope(head, start, end, "test", f"unnamed test {unnamed}", False))
        elif fn := ZIG_FN.search(code[head:start]):
            scopes.append(Scope(head, start, end, "fn", fn[2], bool(fn[1])))
    test_only = re.search(r"(?:^|/)(?:tests|testing)/|tests?\.zig$", path) is not None

    def enclosing(position):
        return [scope for scope in scopes if scope.start < position < scope.end]

    def innermost(position):
        tests = [scope for scope in enclosing(position) if scope.kind == "test"]
        return tests[0] if tests else deepest(position)

    def deepest(position):
        return max(enclosing(position), key=lambda scope: scope.start, default=None)

    def loop_header(head, start):
        """The statement text before a body, past an unbraced `if (...)`, `else`,
        `return` or initializer that the loop sits under or produces a value for."""
        header = code[head:start].strip()
        return header[ZIG_PREFIX.match(header).end():]

    def retry(header):
        """`for (0..n) |_|`, with `n` any balanced expression."""
        if not (opened := ZIG_RETRY.match(header)):
            return False
        depth = 1
        for index in range(opened.end(), len(header)):
            depth += {"(": 1, ")": -1}.get(header[index], 0)
            if depth == 0:
                return re.match(r"\s*\|_\|", header[index + 1:]) is not None
        return False

    def in_fn(position, start):
        return any(start < scope.start < position < scope.end for scope in scopes if scope.kind == "fn")

    def in_loop(position, start):
        statement = max(code.rfind(c, start, position) for c in ";{}") + 1
        return (ZIG_LOOP.match(loop_header(statement, position)) is not None
                or any(start < inner < position < end and ZIG_LOOP.match(loop_header(head, inner))
                       for head, inner, end in blocks))

    def exits(header, start, end):
        """A `return`, or a `break` that leaves this loop rather than one inside it."""
        label = re.match(r"(\w+)\s*:", header)
        for exit in ZIG_EXIT.finditer(code, start, end):
            if in_fn(exit.start(), start):
                continue
            if exit[0] == "return" or (label and exit[1] == label[1]) or (
                    exit[1] is None and not in_loop(exit.start(), start)):
                return True
        return False

    def waits(position, scope):
        statement = max(code.rfind(c, 0, position) for c in ";{}") + 1
        header = loop_header(statement, position)
        if ZIG_WHILE.match(header):
            return True
        if ZIG_FOR.match(header):
            return retry(header) and ZIG_EXIT.search(header) is not None
        for head, start, end in sorted(blocks, key=lambda block: -block[1]):
            if (scope.start if scope else -1) < start < position < end:
                header = loop_header(head, start)
                if ZIG_WHILE.match(header):
                    return True
                if ZIG_FOR.match(header):
                    return retry(header) and exits(header, start, end)
        return False

    def container(scope):
        """The name a member helper is qualified by: its enclosing `const Name = struct`."""
        holders = [(head, start) for head, start, end in blocks if start < scope.start < end]
        if not holders:
            return None
        head, start = max(holders, key=lambda block: block[1])
        named = ZIG_CONTAINER.search(code[head:start])
        return named[1] if named else None

    def references(scope):
        """Bare calls, or calls qualified by the helper's own container; other members share only a name."""
        qualifiers = {None, container(scope)}
        return [match.start(2) for match in re.finditer(rf"(?<![\w@.])(?:(\w+)\s*\.\s*)?({scope.name})\b", code)
                if match[1] in qualifiers and not re.search(r"\bfn\s+$", code[max(0, match.start() - 16):match.start()])
                and not scope.head <= match.start() <= scope.end]

    test_code = {}

    def is_test_code(scope):
        if test_only or (scope and scope.kind == "test"):
            return True
        if scope is None or scope.public:
            return False
        if scope not in test_code:
            test_code[scope] = False
            users = [innermost(position) for position in references(scope)]
            test_code[scope] = bool(users) and all(is_test_code(user) for user in users)
        return test_code[scope]

    def charge(position, helpers, callback=False):
        # A helper passed as a callback runs on its own, so the loop that
        # registers it does not wait on its sleeps.
        scope = innermost(position)
        if (not callback and waits(position, deepest(position))) or not is_test_code(scope):
            return
        if scope and scope.kind == "fn" and scope not in helpers and (uses := references(scope)):
            for use in uses:
                charge(use, helpers | {scope}, not re.match(r"\s*\(", code[use + len(scope.name):use + len(scope.name) + 8]))
        else:
            offenses[(path, scope.name if scope else "<top level>")] += 1

    offenses = Counter()
    for match in ZIG_SLEEP.finditer(code):
        if not code[:match.start()].rstrip().endswith("fn"):
            charge(match.start(), frozenset())
    return offenses


def python_sleep_ordering(path, text):
    """Straight-line `time.sleep`/`asyncio.sleep` calls, by top-level function.

    The wait rule matches Zig's: the nearest enclosing loop in the same
    function is a `while` loop, or a `for _ in range(n)` retry loop with an
    early exit. Nested functions charge the top-level function or method that
    holds them. Sleeps in child-program source strings are not calls.
    """
    offenses = Counter()

    loops = (ast.While, ast.For, ast.AsyncFor)

    def exits(node, own):
        """A `return`, or a `break` that leaves the loop whose body holds `node` (`own`)."""
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
            return False
        if isinstance(node, ast.Return) or (own and isinstance(node, ast.Break)):
            return True
        if isinstance(node, loops):
            return any(exits(child, False) for child in node.body) or any(exits(child, own) for child in node.orelse)
        return any(exits(child, own) for child in ast.iter_child_nodes(node))

    def retry(loop):
        return (isinstance(loop.target, ast.Name) and loop.target.id == "_"
                and isinstance(loop.iter, ast.Call) and getattr(loop.iter.func, "id", None) == "range"
                and any(exits(node, True) for node in loop.body))

    def visit(children, node, name, polling):
        for child in children:
            child_name, child_polling = name, polling
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                if name is None:
                    child_name = child.name
                elif isinstance(node, ast.ClassDef) and "." not in name:
                    child_name = f"{name}.{child.name}"
                child_polling = False
            elif isinstance(child, ast.Lambda):
                child_polling = False
            elif isinstance(child, ast.While):
                child_polling = True
            elif isinstance(child, (ast.For, ast.AsyncFor)):
                child_polling = retry(child)
            elif (isinstance(child, ast.Call) and isinstance(child.func, ast.Attribute)
                  and child.func.attr == "sleep" and getattr(child.func.value, "id", None) in ("time", "asyncio")
                  and not polling):
                offenses[(path, name or "<module>")] += 1
            if isinstance(child, loops):
                # The else suite runs once after the loop, outside its polling.
                after = {id(part) for part in child.orelse}
                visit([part for part in ast.iter_child_nodes(child) if id(part) not in after], child, name, child_polling)
                visit(child.orelse, child, name, polling)
            else:
                visit(ast.iter_child_nodes(child), child, child_name, child_polling)

    tree = ast.parse(text)
    visit(ast.iter_child_nodes(tree), tree, None, False)
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


def sleep_allowlist_problems(offenses, allowed, trusted):
    problems = []
    for key in sorted(set(offenses) | set(allowed)):
        found, listed = offenses.get(key, 0), allowed.get(key, (0, ""))[0]
        if found > listed:
            problems.append(f"{key}: {found} sleep-ordered step(s), {listed} allowed; "
                            "wait on a gate or event the other actor sets")
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
        (1, "delayedResponse peer sleeps against the client's real inactivity deadline"),
    ("src/client.zig", "Host processing wait starts inactivity only after the first response byte"):
        (1, "delayedResponse peer sleeps against the client's real inactivity deadline"),
    ("src/client.zig", "Host-info first byte is bounded independently of normal processing waits"):
        (1, "delayedResponse peer sleeps against the client's real inactivity deadline"),
    ("src/client.zig", "mutation response progress renews inactivity through header and body"):
        (2, "producer sleeps 4.5 s and 1 s against a 5 s inactivity limit"),
    ("src/client.zig", "response deadlines include partial header and body"):
        (1, "delayedResponse peer sleeps against the client's real response deadline"),
    ("src/client.zig", "response transfer inactivity begins after the first byte"):
        (1, "delayedResponse peer sleeps against the client's real inactivity deadline"),
    ("src/client.zig", "transport cancellation quanta neither expire nor renew inactivity and observed stop wins"):
        (1, "stopper requests stop after 700 ms instead of at an observed blocked write"),
    ("src/client.zig", "transport cancellation saturated Unix backlog is not a connected writable socket"):
        (1, "stopper requests stop after 150 ms instead of at an observed blocked connect"),
    ("src/store.zig", "temporary model failures conserve allowance and exhaust after four Attempts"):
        (2, "sleeps out a 5 ms retry wait on the real clock"),
    ("tests/integration/codex_integration.py", "forced_refresh_journey"):
        (3, "sleeps 0.4 s to show no refresh or resend follows a settled failure"),
    ("tests/integration/codex_integration.py", "run"):
        (1, "sleeps 0.4 s to show no resend follows a settled rejection"),
    ("tests/integration/control_integration.py", "prove_retry_wait_control"):
        (1, "sleeps past the retry wait to show no Attempt follows cancellation"),
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
                                                  sleep_ordering(review_base_sources())), [])

    def test_zig_straight_line_sleeps_are_charged_to_their_test(self):
        source = '''
fn pause(ms: c_int) void {
    _ = std.c.poll(&[_]std.c.pollfd{}, 0, ms);
}
fn production(io: std.Io) void {
    io.sleep(.fromMilliseconds(5), .awake) catch {};
}
pub fn serve(io: std.Io) void {
    production(io);
}
test "peer sleeps before it replies" {
    const Peer = struct {
        fn run(io: std.Io) void {
            std.Io.sleep(io, .fromMilliseconds(150), .awake) catch {};
        }
    };
    _ = Peer;
    pause(150);
    // std.testing.io.sleep(.fromMilliseconds(1), .awake) in a comment
    const text = "std.testing.io.sleep(.fromMilliseconds(1), .awake)";
    _ = text;
}
test "polls wait on a condition" {
    while (!done()) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    while (true) {
        if (done()) break;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    for (0..1000) |_| {
        if (done()) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    for (items) |item| {
        if (item) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    while (!done()) {
        for (items) |_| try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    production(std.testing.io);
    // test "commented out" declares nothing
    while (!done()) {
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    while (!ready(.{})) {
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}
fn settle() error{Oops}!void {
    try std.testing.io.sleep(.fromMilliseconds(1), .awake);
}
test "an error-set helper still charges its test" {
    try settle();
}
test "a peer declared inside a poll still sleeps first" {
    while (!done()) {
        const Peer = struct {
            fn run(io: std.Io) void {
                std.Io.sleep(io, .fromMilliseconds(150), .awake) catch {};
            }
        };
        _ = Peer;
    }
}
test {
    try std.testing.io.sleep(.fromMilliseconds(150), .awake);
}
test "an inner loop's exit does not make its outer loop poll" {
    for (0..10) |_| {
        for (items) |item| {
            if (item) break;
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    for (0..10) |_| {
        for (items) |item| if (item) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    for (0..10) |_| {
        const Probe = struct {
            fn ready() bool {
                return true;
            }
        };
        _ = Probe;
        _ = blk: {
            break :blk 1;
        };
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    while (!done()) {} else {
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}
fn nap() void {
    std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
}
pub fn drive(thing: anytype) void {
    thing.nap();
}
test "an unrelated member call does not make a helper production code" {
    nap();
}
const Helper = struct {
    fn doze() void {
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
};
test "a container-qualified helper call charges its test" {
    Helper.doze();
}
test "a poll under an unbraced condition still waits" {
    if (enabled) while (!done()) {
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    if (enabled) while (!done()) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    if (enabled) {} else for (0..10) |_| {
        if (done()) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}
fn peer() void {
    std.testing.io.sleep(.fromMilliseconds(150), .awake) catch {};
}
test "a callback spawned inside a poll still sleeps first" {
    while (!done()) {
        const thread = try std.Thread.spawn(.{}, peer, .{});
        thread.join();
    }
}
test "a retry bound may call, and a poll may produce a value" {
    for (0..@as(usize, @min(10, limit()))) |_| {
        if (ready()) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    const result = while (true) {
        if (ready()) break true;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    };
    _ = result;
    total += for (0..10) |_| {
        if (ready()) break 1;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else 0;
}
test "a labeled break from an inner loop leaves the retry" {
    outer: for (0..10) |_| {
        for (items) |item| if (item) break :outer;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}
'''
        self.assertEqual(zig_sleep_ordering("src/a.zig", source), {
            ("src/a.zig", "peer sleeps before it replies"): 2,
            ("src/a.zig", "polls wait on a condition"): 2,
            ("src/a.zig", "an error-set helper still charges its test"): 1,
            ("src/a.zig", "a peer declared inside a poll still sleeps first"): 1,
            ("src/a.zig", "unnamed test 1"): 1,
            ("src/a.zig", "an inner loop's exit does not make its outer loop poll"): 4,
            ("src/a.zig", "an unrelated member call does not make a helper production code"): 1,
            ("src/a.zig", "a container-qualified helper call charges its test"): 1,
            ("src/a.zig", "a callback spawned inside a poll still sleeps first"): 1,
        })

    def test_python_straight_line_sleeps_are_charged_to_their_function(self):
        source = '''
import time
def scenario():
    def peer():
        time.sleep(0.5)
    while not ready():
        time.sleep(0.01)
    for _ in range(100):
        if ready():
            break
        time.sleep(0.01)
    for case in cases:
        time.sleep(0.2)
    child = "import time; time.sleep(30)"
class Handler:
    def do_POST(self):
        time.sleep(2.5)
def inner_exits():
    for _ in range(10):
        for item in items:
            if item:
                break
        time.sleep(1)
    for _ in range(10):
        def probe():
            return True
        time.sleep(1)
    for _ in range(10):
        for item in items:
            pass
        else:
            break
        time.sleep(0.01)
def lambda_peer():
    while not ready():
        threading.Thread(target=lambda: time.sleep(1)).start()
def after_the_loop():
    while not ready():
        time.sleep(0.01)
    else:
        time.sleep(1)
    for _ in range(10):
        if ready():
            break
        time.sleep(0.01)
    else:
        time.sleep(1)
'''
        self.assertEqual(python_sleep_ordering("tests/integration/x.py", source), {
            ("tests/integration/x.py", "scenario"): 2,
            ("tests/integration/x.py", "inner_exits"): 2,
            ("tests/integration/x.py", "after_the_loop"): 2,
            ("tests/integration/x.py", "lambda_peer"): 1,
            ("tests/integration/x.py", "Handler.do_POST"): 1,
        })

    def test_allowlist_rejects_new_offenders_and_keeps_shrinking(self):
        key = ("src/a.zig", "peer sleeps before it replies")
        one, two, allow = Counter({key: 1}), Counter({key: 2}), {key: (1, "seeded")}
        self.assertEqual(sleep_allowlist_problems(one, allow, one), [])
        self.assertIn("2 sleep-ordered step(s), 1 allowed", sleep_allowlist_problems(two, allow, two)[0])
        self.assertIn("1 sleep-ordered step(s), 0 allowed", sleep_allowlist_problems(one, {}, one)[0])
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

    def test_every_allowlist_entry_has_a_reason(self):
        self.assertEqual([key for key, (count, reason) in SLEEP_ORDERED.items()
                          if count < 1 or not reason.strip() or "\n" in reason], [])


class FixtureUserTest(unittest.TestCase):
    def test_root_stops_with_the_non_root_instruction(self):
        with patch.object(FIXTURE_USER.os, "geteuid", return_value=0), self.assertRaises(SystemExit) as stopped:
            FIXTURE_USER.main()
        self.assertIn("must run as a non-root user", stopped.exception.code)

    def test_ordinary_user_proceeds(self):
        with patch.object(FIXTURE_USER.os, "geteuid", return_value=30033):
            self.assertIsNone(FIXTURE_USER.main())


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

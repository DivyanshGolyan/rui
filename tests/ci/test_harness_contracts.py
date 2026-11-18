
import ast
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import mmap
import os
from pathlib import Path
import re
import site
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import build_files


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
SPEC = importlib.util.spec_from_file_location("host_process", ROOT / "tests/integration/host_process.py")
HOST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOST)

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


def flushes_closed_stdin(version):
    return version[:2] < (3, 13) or version[:2] == (3, 13) and version[2] < 10 or tuple(version[:3]) == (3, 14, 0)


class ChildInputTest(unittest.TestCase):

    def test_communicate_after_closing_stdin_by_hand_fails_where_python_flushes_it_and_close_stdin_does_not(self):
        child = subprocess.Popen(["cat"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        child.stdin.write(b"by hand")
        child.stdin.close()
        if flushes_closed_stdin(sys.version_info):
            with self.assertRaisesRegex(ValueError, "flush of closed file"):
                child.communicate(timeout=5)
            child.wait(timeout=5)
            child.stdout.close()
        else:
            self.assertEqual(child.communicate(timeout=5), (b"by hand", None))
        child = subprocess.Popen(["cat"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        child.stdin.write(b"owned")
        HOST.close_stdin(child)
        self.assertEqual(child.communicate(timeout=5), (b"owned", None))

    def test_no_fixture_closes_a_child_stdin_itself(self):
        offenders = [
            f"{path.relative_to(ROOT)}:{number}"
            for pattern in ("*.py", "*.sh")
            for path in sorted((ROOT / "tests/integration").glob(pattern))
            if path.name != "host_process.py"
            for number, line in enumerate(path.read_text().splitlines(), 1)
            if re.search(r"\.stdin\.close\(\)", line)
        ]
        self.assertEqual(offenders, [], "close a child's stdin with host_process.close_stdin(child)")


TMP_DIR = re.compile(r"\b(?:var|const)\s+(\w+)\s*=\s*std\.testing\.tmpDir\(\s*\.\{([^}]*)\}\s*\)")


def path_only_handle_uses(source):
    """Lines where a test chmods or lists a `std.testing.tmpDir` opened without `.iterate = true`.

    Without it Linux opens the directory O_PATH, and fchmod or a listing of
    that handle fails with an unexpected errno (#1040's observation fixture).
    """
    found = []
    for match in TMP_DIR.finditer(source):
        if re.search(r"\.iterate\s*=\s*true", match[2]):
            continue
        rest = source[match.end():]
        end = re.search(rf"\b(?:var|const)\s+{match[1]}\s*=", rest)
        scope = rest[:end.start()] if end else rest
        use = re.search(rf"\b{match[1]}\.dir\.(?:setPermissions|iterate|walk)\(", scope)
        if use:
            found.append(source.count("\n", 0, match.end() + use.start()) + 1)
    return found


class TemporaryDirectoryTest(unittest.TestCase):
    def test_a_path_only_tmp_dir_is_never_chmodded_or_listed(self):
        self.assertEqual(path_only_handle_uses(
            "var tmp = std.testing.tmpDir(.{});\ndefer tmp.cleanup();\ntry tmp.dir.setPermissions(io, .fromMode(0o700));\n"), [3])
        self.assertEqual(path_only_handle_uses(
            "var tmp = std.testing.tmpDir(.{ .iterate = true });\ntry tmp.dir.setPermissions(io, .fromMode(0o700));\n"), [])
        offenders = [f"{path.relative_to(ROOT)}:{line}"
                     for path in sorted((ROOT / "src").rglob("*.zig"))
                     for line in path_only_handle_uses(path.read_text())]
        self.assertEqual(offenders, [], "open the directory with std.testing.tmpDir(.{ .iterate = true })")


class QualificationEvidenceTest(unittest.TestCase):
    def test_qualification_never_reads_stderr_phase_traces(self):
        offenders = [
            str(path.relative_to(ROOT))
            for path in sorted((ROOT / "tests/qualification").rglob("*.go"))
            if re.search(r"--test-phase-trace|trace_lost", path.read_text())
        ]
        self.assertEqual(offenders, [])


class SleepHelperTest(unittest.TestCase):

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



FIXTURE_DIRECTORIES = ("tests/integration", "tests/qualification/direct-pty")
REFUSAL = "must run as a non-root user"


def fixture_entries():
    for directory in FIXTURE_DIRECTORIES:
        for path in sorted((ROOT / directory).glob("*.sh")):
            yield path.relative_to(ROOT).as_posix()
        for path in sorted((ROOT / directory).glob("*.py")):
            if any(isinstance(node, ast.If) and ast.unparse(node.test) == "__name__ == '__main__'"
                   for node in ast.parse(path.read_text()).body):
                yield path.relative_to(ROOT).as_posix()


FIXTURE_LIBRARY_ENTRIES = {
    "tests/integration/host_process.py": "The fixture boundary: every fixture imports it, and its exec entry enters before running a command",
    "tests/integration/mysql_server.py": "Holds the MySQL image pin: check.yml starts the server through its command line, mysql_wire_integration through its functions",
}


def fixture_imports(root):
    from select_tests import PYTHON_IMPORT
    directory = root / "tests/integration"
    fixtures = {path.relative_to(root).as_posix() for path in directory.glob("*.py")
                if any(isinstance(node, ast.If) and ast.unparse(node.test) == "__name__ == '__main__'"
                       for node in ast.parse(path.read_text()).body)}
    check = root / "tests/integration/check.sh"
    for source, launched in ((build_files.source(root) if (root / "build.zig").exists() else "", r'"(tests/integration/\w+\.py)"'),
                             (check.read_text() if check.exists() else "", r'\$directory/(\w+\.py)')):
        fixtures |= {name if name.startswith("tests/") else f"tests/integration/{name}"
                     for name in re.findall(launched, source)}
    fixtures -= FIXTURE_LIBRARY_ENTRIES.keys()
    found = set()
    for path in sorted([*directory.glob("*.py"), *directory.glob("*.sh"),
                        *(root / "tests/qualification").rglob("*.py"), *(root / "research").rglob("*.py")]):
        importer = path.relative_to(root).as_posix()
        for match in PYTHON_IMPORT.finditer(path.read_text()):
            for module in (match[1] and [match[1]] or re.split(r"\s*,\s*", match[2])):
                target = f"tests/integration/{module}.py"
                if target in fixtures and target != importer:
                    found.add((importer, target))
    return sorted(found)


class FixtureImportTest(unittest.TestCase):
    def test_no_fixture_module_imports_another(self):
        self.assertEqual(
            [f"{importer} imports fixture {target}: move what it uses into a library without a main block "
             f"(such as {Path(target).stem.removesuffix('_integration')}_fixture.py), or move the cases it runs "
             f"into a cases library that {Path(target).name} runs" for importer, target in fixture_imports(ROOT)], [])

    def test_fixtures_are_entries_and_launched_scripts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tests/integration").mkdir(parents=True)
            main = 'if __name__ == "__main__":\n    host_process.enter()\n'
            for name, source in {
                "host_process.py": main,
                "a_integration.py": "import host_process\n" + main,
                "b_integration.py": "import host_process, a_integration as a\n" + main,
                "launched.py": "print('runs at import')\n",
                "c_fixture.py": 'PROBE = """\nimport launched\n"""\n',
                "d_integration.sh": "python3 - <<'PY'\nimport a_integration\nPY\n",
            }.items():
                (root / "tests/integration" / name).write_text(source)
            (root / "tests/qualification/harness").mkdir(parents=True)
            (root / "tests/qualification/harness/run.py").write_text("from a_integration import ReplyProxy\n")
            (root / "build.zig").write_text('run.addFileArg(b.path("tests/integration/launched.py"));\n')
            self.assertEqual(fixture_imports(root),
                             [("tests/integration/b_integration.py", "tests/integration/a_integration.py"),
                              ("tests/integration/c_fixture.py", "tests/integration/launched.py"),
                              ("tests/integration/d_integration.sh", "tests/integration/a_integration.py"),
                              ("tests/qualification/harness/run.py", "tests/integration/a_integration.py")])


class FixtureEntryTest(unittest.TestCase):
    def simulated_user(self, directory, euid):
        simulated = Path(directory) / f"simulated-{euid}"
        simulated.mkdir()
        (simulated / "sitecustomize.py").write_text(f"import os\nos.geteuid = lambda: {euid}\n")
        return os.pathsep.join([str(simulated), site.getusersitepackages()])

    def test_every_fixture_entry_refuses_root_before_it_starts(self):
        entries = list(fixture_entries())
        self.assertIn("tests/integration/admission_integration.sh", entries)
        self.assertNotIn("tests/integration/model_fixture.py", entries)
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory) / "tmp"
            scratch.mkdir()
            environment = {"PATH": os.environ["PATH"], "HOME": directory, "TMPDIR": str(scratch),
                           "PYTHONPATH": self.simulated_user(directory, 0)}

            binaries = [str(Path(directory) / "absent-rui"), str(Path(directory) / "absent-actor")]

            def run(entry):
                command = ["sh", entry, *binaries] if entry.endswith(".sh") else [sys.executable, "-B", entry, *binaries]
                return entry, subprocess.run(command, cwd=ROOT, env=environment, capture_output=True,
                                             text=True, timeout=30)

            with ThreadPoolExecutor(max_workers=4) as pool:
                results = list(pool.map(run, entries))
            started = [(entry, result.returncode, result.stdout[-300:] + result.stderr[-300:])
                       for entry, result in results
                       if result.returncode == 0 or REFUSAL not in result.stderr]
            self.assertEqual(started, [], "fixture entries ran past the shared root refusal")
            self.assertEqual(list(scratch.iterdir()), [], "a refused fixture created state")

    def test_importing_the_boundary_leaves_the_process_alone(self):
        source = ("import json, os, sys\n"
                  "before = dict(os.environ)\n"
                  "sys.path.insert(0, sys.argv[1])\n"
                  "import host_process\n"
                  "print(json.dumps({'before': before, 'after': dict(os.environ)}))\n")
        with tempfile.TemporaryDirectory() as directory:
            environment = {"PATH": os.environ["PATH"], "HOME": directory, "LANG": "C.UTF-8", "RUI_STORE": "inherited",
                           "HTTPS_PROXY": "http://127.0.0.1:9", "PYTHONPATH": self.simulated_user(directory, 0)}
            result = subprocess.run([sys.executable, "-B", "-c", source, str(ROOT / "tests/integration")],
                                    env=environment, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            observed = json.loads(result.stdout)
            self.assertEqual(observed["before"], observed["after"])

    def test_fixture_children_receive_only_the_fixture_environment(self):
        source = ("import json, subprocess, sys\n"
                  "sys.path.insert(0, sys.argv[1])\n"
                  "import host_process\n"
                  "network = host_process.enter()\n"
                  "child = subprocess.run([sys.executable, '-c', 'import json, os; print(json.dumps(dict(os.environ)))'],"
                  " capture_output=True, text=True, check=True).stdout\n"
                  "print(json.dumps({'network': network, 'child': json.loads(child)}))\n")
        with tempfile.TemporaryDirectory() as directory:
            network = {"SSL_CERT_FILE": str(Path(directory) / "absent.pem"), "HTTPS_PROXY": "http://127.0.0.1:9"}
            planted = {"RUI_CODEX_CREDENTIAL_FILE": str(Path(directory) / "absent.json"),
                       "RUI_STORE": str(Path(directory) / "foreign-store"), "RUI_ADDRESS": "zzzzzz",
                       "RUI_SENDER_HANDLE": "inherited", "VIRTUAL_ENV": directory,
                       **network}
            named = {"PATH": os.environ["PATH"], "HOME": directory, "TMPDIR": directory,
                     "RUI_FAILURE_ARTIFACTS": str(Path(directory) / "retained")}
            result = subprocess.run([sys.executable, "-B", "-c", source, str(ROOT / "tests/integration")],
                                    env={**planted, **named, "TERM": "dumb",
                                         "PYTHONPATH": self.simulated_user(directory, 30033)},
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            observed = json.loads(result.stdout)
            self.assertEqual(observed["network"], network)
            child = observed["child"]
            self.assertEqual({name: child.get(name) for name in planted}, dict.fromkeys(planted))
            self.assertNotIn("PYTHONPATH", child)
            self.assertEqual({name: child.get(name) for name in named}, named)
            self.assertEqual(child["TERM"], "xterm-256color")
            self.assertNotIn("RUI_TEST_MODELS_DEV_URL", child)

    def test_exec_entry_runs_its_command_only_inside_the_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            ran = Path(directory) / "ran"
            command = [sys.executable, "-B", str(ROOT / "tests/integration/host_process.py"), "exec",
                       sys.executable, "-c",
                       "import json, os, sys; open(sys.argv[1], 'w').write(json.dumps(dict(os.environ)))",
                       str(ran)]
            caller = {"PATH": os.environ["PATH"], "HOME": directory, "LANG": "C.UTF-8", "RUI_STORE": "inherited",
                      "GOFLAGS": "-mod=mod", "RUI_TEST_MODELS_DEV_URL": "https://models.dev/api.json"}
            refused = subprocess.run(command, env={**caller, "PYTHONPATH": self.simulated_user(directory, 0)},
                                     capture_output=True, text=True, timeout=30)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn(REFUSAL, refused.stderr)
            self.assertFalse(ran.exists(), "a refused command ran")
            admitted = subprocess.run(command, env={**caller, "PYTHONPATH": self.simulated_user(directory, 30033)},
                                      capture_output=True, text=True, timeout=30)
            self.assertEqual(admitted.returncode, 0, admitted.stderr)
            expected = {"PATH": os.environ["PATH"], "HOME": directory, "LANG": "C.UTF-8",
                        "TERM": "xterm-256color"}
            control = subprocess.run([sys.executable, "-c",
                                      "import json, os; print(json.dumps(dict(os.environ)))"],
                                     env=expected, capture_output=True, text=True, timeout=30)
            self.assertEqual(control.returncode, 0, control.stderr)
            self.assertEqual(json.loads(ran.read_text()), json.loads(control.stdout))

    def test_go_measurements_run_through_the_exec_entry(self):
        build = build_files.source()
        steps = re.findall(r'const (\w+)_step = b\.step\(\s*"measure-', build)
        self.assertGreaterEqual(len(steps), 10)
        for name in steps:
            self.assertRegex(build, rf"const {name} = addMeasurement\(b, ", name)
        helper = re.search(r"\nfn addMeasurement\(.*?\n\}\n", build, re.S).group(0)
        self.assertIn('run.addFileArg(b.path("tests/integration/host_process.py"));\n'
                      '    run.addArgs(&.{ "exec", "env", "GOTOOLCHAIN=local", "go", "run", "-mod=readonly" });',
                      helper)
        self.assertEqual(build.count('"go", "run"'), 1, "a Go measurement launched outside the fixture boundary")


class ProcessCensusTest(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(ROOT / "tests/integration"))
        self.addCleanup(sys.path.remove, str(ROOT / "tests/integration"))
        import os_semantics
        self.semantics = os_semantics

    def test_ownership_is_the_executed_image_whatever_the_process_is_called(self):
        original = Path(sys.executable).resolve(strict=True)
        marker = b"ready\n"
        program = "import os; os.write(1, b'ready\\n'); os.read(0, 1)"
        with tempfile.TemporaryDirectory() as directory:
            copy = Path(directory) / "owned-python"
            copy.write_bytes(original.read_bytes())
            copy.chmod(0o755)
            self.assertEqual(copy.read_bytes(), original.read_bytes())
            self.assertFalse(copy.samefile(original), "the owned image must have a distinct inode")
            children = []
            try:
                for executable, name in ((copy, "renamed"), (original, str(copy))):
                    process = subprocess.Popen([name, "-S", "-B", "-c", program], executable=executable,
                                               env={"PYTHONHOME": sys.base_prefix}, stdin=subprocess.PIPE,
                                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    children.append(process)
                    self.await_marker(process, marker, f"readiness from {name}")
                owned, named = children
                for process in children:
                    self.assertIsNone(process.poll(), "actor exited before census")
                found = self.semantics.processes_executing(copy)
                for process in children:
                    self.assertIsNone(process.poll(), "actor exited during census")
                self.assertIn(owned.pid, found)
                self.assertNotIn(named.pid, found)
            finally:
                HOST.dispose_all(
                    *(lambda process=process: HOST.close_stdin(process) for process in reversed(children)),
                    *(lambda process=process: HOST.stop_process(process) for process in reversed(children)))

    def await_marker(self, process, marker, label):
        """Waits, bounded by the shared wait owner, until the child writes exactly marker to stdout."""
        os.set_blocking(process.stdout.fileno(), False)
        received = bytearray()

        def ready():
            self.assertIsNone(process.poll(), "actor exited before readiness")
            try:
                chunk = os.read(process.stdout.fileno(), len(marker) - len(received))
            except BlockingIOError:
                return False
            self.assertTrue(chunk, "actor closed stdout before readiness")
            received.extend(chunk)
            self.assertEqual(received, marker[:len(received)])
            return received == marker

        HOST.wait_for(ready, label)

    def ready_child(self, *arguments, env=None):
        """Starts a child that announces itself once initialised, then waits on stdin.

        Samples taken after the announcement see its exec'd arguments and settled descriptors.
        """
        child = subprocess.Popen([sys.executable, "-S", "-c", "import sys; print('ready', flush=True); sys.stdin.read()",
                                  *arguments], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        try:
            self.await_marker(child, b"ready\n", "the census child's readiness")
        except BaseException:
            child.kill()
            child.communicate(timeout=5)
            raise
        return child

    def test_process_state_tells_running_from_zombie_from_reaped(self):
        # CI-68
        child = self.ready_child()
        try:
            self.assertFalse(self.semantics.process_state(child.pid).startswith("Z"))
            HOST.close_stdin(child)
            HOST.wait_for(lambda: self.semantics.process_state(child.pid).startswith("Z"), "the exited child's zombie entry")
        finally:
            child.kill()
            child.wait(timeout=5)
        self.assertIsNone(self.semantics.process_state(child.pid))
        listing = self.semantics.describe_processes((os.getpid(),))
        self.assertIn(str(os.getpid()), listing)

    def test_command_census_reads_each_process_argv(self):
        # CI-69
        census = dict(self.semantics.process_commands())
        self.assertEqual(Path(census[os.getpid()][0]).name, Path(sys.orig_argv[0]).name)
        self.assertEqual(census[os.getpid()][1:], sys.orig_argv[1:])

    def test_launch_records_hold_arguments_and_environment_where_the_kernel_shows_them(self):
        # CI-70
        child = self.ready_child("argument-marker", env={"RUI_LAUNCH_MARKER": "environment-marker"})
        try:
            records = self.semantics.launch_records(child.pid)
        finally:
            child.communicate(timeout=5)
        if not self.semantics.PROC_FS:
            self.assertIsNone(records)
            return
        self.assertEqual(set(records), {"cmdline", "environ"})
        self.assertIn(b"argument-marker", records["cmdline"])
        self.assertIn(b"RUI_LAUNCH_MARKER=environment-marker", records["environ"])
        with self.semantics.simulate("darwin"):
            self.assertIsNone(self.semantics.launch_records(os.getpid()))

    def test_resource_readers_observe_a_live_process(self):
        # CI-71
        child = self.ready_child()
        try:
            names = self.semantics.open_descriptor_names(child.pid)
            self.assertGreaterEqual(len(names), 3, names)
            self.assertGreater(self.semantics.process_resident_kib(child.pid), 0)
            self.assertGreaterEqual(self.semantics.process_cpu_seconds(child.pid), 0)
            memory = self.semantics.process_memory(child.pid)
            if self.semantics.PROC_FS:
                self.assertEqual(set(memory), {"rss_kib", "peak_kib"})
                self.assertGreaterEqual(memory["peak_kib"], memory["rss_kib"])
                self.assertEqual(len(self.semantics.descriptor_links(child.pid)), len(names))
                self.assertIsNotNone(self.semantics.socket_table("unix"))
            else:
                self.assertIsNone(memory)
            self.assertEqual(self.semantics.physical_footprint_peak(child.pid) is not None, self.semantics.FOOTPRINT)
        finally:
            child.communicate(timeout=5)
        self.assertIsNone(self.semantics.process_memory(child.pid))
        self.assertIsNone(self.semantics.socket_table("rui-no-such-table"))

    def test_locks_exclude_other_open_descriptions_until_released(self):
        # CI-72
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "host.lock"
            path.touch()
            with path.open("rb") as holder, path.open("rb") as other:
                self.semantics.take_lock(holder)
                self.assertFalse(self.semantics.try_lock(other))
                self.assertFalse(self.semantics.try_lock(other, shared=True))
                self.semantics.release_lock(holder)
                self.assertTrue(self.semantics.try_lock(other, shared=True))
                self.assertTrue(self.semantics.try_lock(holder, shared=True))
                self.assertFalse(self.semantics.try_lock(holder))

    def test_darwin_census_fails_loudly_when_lsof_fails(self):
        def lsof(returncode, stdout="", stderr=""):
            return patch.object(self.semantics.subprocess, "run",
                                return_value=subprocess.CompletedProcess([], returncode, stdout, stderr))

        with self.semantics.simulate("darwin"):
            with lsof(0, "p12\np34\n"):
                self.assertEqual(self.semantics.processes_executing("/bin/sh"), {12, 34})
            with lsof(1):
                self.assertEqual(self.semantics.processes_executing("/bin/sh"), set())
            with lsof(1, stderr="lsof: status error on /bin/sh: Permission denied\n"), \
                    self.assertRaises(AssertionError):
                self.semantics.processes_executing("/bin/sh")


class SessionListValuesTest(unittest.TestCase):
    def test_only_read_freshness_is_removed_from_session_comparisons(self):
        from session_list_fixture import session_values
        row = {"read_version": "a"*32 + ".1", "reference": "aaaaaa", "revision": "1",
               "work": {"state": {"kind": "finished", "since": "1"}},
               "last_line": {"position": "2", "text": "Answer"}, "label": "Label"}
        before = {"sessions": [row]}
        later = {"sessions": [{**row, "read_version": "a"*32 + ".2"}]}
        self.assertEqual(session_values(before), session_values(later))
        for field, value in (("reference", "bbbbbb"), ("revision", "2"),
                             ("work", {"state": {"kind": "stopped", "since": "1"}}),
                             ("last_line", {"position": "3", "text": None}), ("label", "Changed")):
            with self.subTest(field=field):
                self.assertNotEqual(session_values(before), session_values({"sessions": [{**row, field: value}]}))
        self.assertIn("read_version", row, "the comparison must not mutate the reply")
        with self.assertRaises(KeyError):
            session_values({"sessions": [{"reference": "aaaaaa"}]})
        for invalid in ("nope", "a"*32 + ".01", "a"*32 + ".18446744073709551616"):
            with self.subTest(invalid=invalid), self.assertRaises(AssertionError):
                session_values({"sessions": [{**row, "read_version": invalid}]})


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


class ToolIntentDisposalTest(unittest.TestCase):
    def test_mysql_tool_store_preserves_body_failure_and_reports_drop_failure(self):
        source = """
import os, pathlib, subprocess, sys, tempfile
from unittest.mock import patch
sys.path.insert(0, sys.argv[1])
sys.argv = ['tool-intent-unit', '/never-launched-rui']
import tool_intent_cases as tools
for body_failed in (False, True):
    for cleanup_failed in (False, True):
        primary = AssertionError('tool intent body failed')
        cleanup = OSError('database drop failed')
        statements = []
        def run(command, **arguments):
            if command[0] == 'fixture-admin':
                statement = arguments['input']
                statements.append(statement)
                if statement.startswith('DROP DATABASE') and cleanup_failed:
                    raise cleanup
                return subprocess.CompletedProcess(command, 0, stdout='', stderr='')
            assert command[1:] == ['store', 'schema', '--engine', 'mysql'], command
            return subprocess.CompletedProcess(command, 0, stdout='emitted schema', stderr='')
        caught = None
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
            'RUI_TEST_MYSQL_SOCKET': '/fixture.sock', 'RUI_TEST_MYSQL_ROOT_PASSWORD': 'fixture-password',
            'RUI_TEST_MYSQL_ADMIN': 'fixture-admin',
        }), patch.object(tools.subprocess, 'run', side_effect=run):
            try:
                with tools.tool_store('mysql', temporary):
                    if body_failed:
                        raise primary
            except BaseException as error:
                caught = error
        expected = primary if body_failed else cleanup if cleanup_failed else None
        assert caught is expected, (body_failed, cleanup_failed, caught, expected)
        assert sum(statement.startswith('DROP DATABASE') for statement in statements) == 1, statements
        if body_failed and cleanup_failed:
            assert any('database drop failed' in note for note in primary.__notes__), primary.__notes__
print('body/drop failure matrix passed')
"""
        result = subprocess.run([sys.executable, "-B", "-c", source, str(ROOT / "tests/integration")],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "body/drop failure matrix passed\n")


if __name__ == "__main__":
    unittest.main()

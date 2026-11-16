import json
import os
import re
import signal
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

import store_shards as shards
import unit_test_names as inventories
import unit_test_runner

ROOT = Path(__file__).resolve().parents[2]


class TerminalTimesTest(unittest.TestCase):
    def test_split_markers_and_diagnostics(self):
        parser = shards.TerminalTimes(["store.test.first", "store.test.second"])
        parser.feed(b"1/2 store.test.first..", 1)
        parser.feed(b".warning: diagnostic\n", 2)
        parser.feed(b"OK\n2/2 store.test.second...", 5)
        parser.feed(b"OK\nAll 2 tests passed.\n", 8)
        self.assertEqual(parser.finish(), [("store.test.first", 3, "OK"), ("store.test.second", 3, "OK")])

    def test_ellipsis_in_name_is_not_the_progress_delimiter(self):
        name = "store.rsql.test.row_number() OVER (ORDER BY ...) is the one window"
        data = f"1/1 {name}...OK\n".encode()
        for split in range(len(data) + 1):
            parser = shards.TerminalTimes([name])
            parser.feed(data[:split], 1)
            parser.feed(data[split:], 2)
            self.assertEqual(parser.finish()[0][0], name)

    def test_incomplete_and_nonsequential_output_fails_closed(self):
        for data in (b"", b"1/1 t...", b"2/2 t...OK\n"):
            with self.subTest(data=data), self.assertRaises(ValueError):
                parser = shards.TerminalTimes(["t"])
                parser.feed(data, 1)
                parser.finish()


class ExclusiveOwnerTest(unittest.TestCase):
    def test_every_server_global_mutator_is_in_the_exclusive_owner(self):
        import test_harness_contracts as contracts
        source = (ROOT / "src/store/mysql_testing.zig").read_text()
        _, tests, declarations = contracts.zig_blocks(source)
        bodies = {name: source[start:end] for start, end, name in declarations}
        global_functions = {name for name, body in bodies.items() if "SET GLOBAL" in body}
        while True:
            callers = {name for name, body in bodies.items()
                       if any(re.search(r"\b" + re.escape(callee) + r"\s*\(", body) for callee in global_functions)}
            if callers <= global_functions:
                break
            global_functions |= callers
        expected = {name for start, end, name in tests if "SET GLOBAL" in source[start:end] or
                    any(re.search(r"\b" + re.escape(callee) + r"\s*\(", source[start:end]) for callee in global_functions)}
        owner = (ROOT / "src/unit_test_partition.zig").read_text().split("pub fn exclusive(", 1)[1].split("fn fixedOwner", 1)[0]
        registered = set(re.findall(r'^\s*"(store\.mysql live[^"\n]+)",', owner, re.MULTILINE))
        self.assertTrue(expected)
        self.assertEqual(registered, expected)


class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="store shard tests ")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.binary = self.directory / "fake runner"

    def script(self, text, names=None):
        if names is None:
            names = list(dict.fromkeys(re.findall(r"(?:store\.test\.|test\.)[a-z]+", text)))
        if names == "exclusive":
            inventory = "    i = int(os.environ.get('RUI_UNIT_SHARD', '0/1').split('/')[0])\n    names = (['store.test.exclusive'] if i == 0 else []) + ['store.test.normal' + str(i)]\n"
        else:
            inventory = "    names = ['store.test.' + os.environ['RUI_UNIT_SHARD'].split('/')[0]]\n" if names == "shard" else f"    names = {names!r}\n"
        preamble = (
            "import sys, os, struct\n"
            "if '--listen=-' in sys.argv:\n"
            + inventory +
            ("    if os.environ.get('RUI_UNIT_EXCLUSIVE'): names = ['store.test.exclusive']\n" if names == "exclusive" else "    if os.environ.get('RUI_UNIT_EXCLUSIVE'): names = []\n") +
            "    strings = b'\\0'; offsets = []\n"
            "    for name in names:\n"
            "        offsets.append(len(strings)); strings += name.encode() + b'\\0'\n"
            "    body = struct.pack('<II',len(strings),len(names)) + b''.join(struct.pack('<I',i) for i in offsets) + bytes(4*len(names)) + strings\n"
            "    sys.stdin.buffer.read()\n"
            "    sys.stdout.buffer.write(struct.pack('<II',3,len(body)) + body)\n"
            "    raise SystemExit(0)\n"
        )
        self.binary.write_text(f"#!{sys.executable}\n" + preamble + text)
        self.binary.chmod(0o755)
        return str(self.binary)

    def test_run_launches_every_shard_concurrently_and_merges_all_records(self):
        events = self.directory / "events"
        record = self.directory / "record"
        self.script(
            "import os\nfrom pathlib import Path\n"
            "i,k = map(int, os.environ['RUI_UNIT_SHARD'].split('/'))\n"
            f"directory = Path({str(self.directory)!r})\n"
            "(directory / ('ready-' + str(i))).touch()\n"
            # FIFO is the actual gate; every child must start before parent can
            # release them. A serialized launcher would reach its deadline.
            "with open(directory / ('gate-' + str(i))) as gate: gate.read()\n"
            f"with open({str(events)!r}, 'a') as event: event.write(str(i) + ':' + os.environ['RUI_UNIT_MYSQL_NAMESPACE'] + '\\n')\n"
            "Path(os.environ['RUI_TEST_MYSQL_RECORD']).write_text('prepares=1 migrations=' + str(int(i == 0)) + ' conformance=1\\n')\n"
            "print('1/1 store.test.' + str(i) + '...OK', flush=True)\n", names="shard")
        for index in range(shards.SHARD_COUNT):
            os.mkfifo(self.directory / f"gate-{index}")
        import threading
        from host_process import wait_for
        def release():
            wait_for(lambda: all((self.directory / f"ready-{i}").exists() for i in range(shards.SHARD_COUNT)),
                     "all shard processes started", timeout=3, interval=0.01)
            for index in range(shards.SHARD_COUNT):
                with open(self.directory / f"gate-{index}", "w") as gate:
                    gate.write("run")
        thread = threading.Thread(target=release)
        thread.start()
        with patch("builtins.print"):
            self.assertEqual(shards.run(self.binary, [], 5, "run", dict(os.environ, RUI_TEST_MYSQL_RECORD=str(record))), 0)
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())
        entries = events.read_text().splitlines()
        self.assertEqual({line.split(':')[0] for line in entries}, {str(i) for i in range(shards.SHARD_COUNT)})
        self.assertEqual(len({line.split(':')[1] for line in entries}), shards.SHARD_COUNT)
        self.assertEqual(shards.live_engines.parse_record(record.read_text()),
                         {"prepares": shards.SHARD_COUNT, "migrations": 1, "conformance": shards.SHARD_COUNT})

    def test_shard_zero_finishes_global_mutations_before_peers_start(self):
        gate = self.directory / "global gate"
        ready = self.directory / "global ready"
        done = self.directory / "global done"
        os.mkfifo(gate)
        self.script(
            "import os\nfrom pathlib import Path\n"
            "i = int(os.environ['RUI_UNIT_SHARD'].split('/')[0])\n"
            "if i == 0:\n"
            "    print('1/2 store.test.exclusive...', end='', flush=True)\n"
            f"    Path({str(ready)!r}).touch()\n"
            f"    with open({str(gate)!r}) as gate: gate.read()\n"
            f"    Path({str(done)!r}).touch()\n"
            "    print('OK\\n2/2 store.test.normal0...OK', flush=True)\n"
            "else:\n"
            f"    assert Path({str(done)!r}).exists(), 'peer overlapped SET GLOBAL'\n"
            "    print('1/1 store.test.normal' + str(i) + '...OK', flush=True)\n", names="exclusive")
        import threading
        from host_process import wait_for
        def release():
            wait_for(ready.exists, "exclusive test to enter", timeout=3, interval=.01)
            with open(gate, 'w') as pipe:
                pipe.write('restore global settings')
        thread = threading.Thread(target=release)
        thread.start()
        with patch('builtins.print'):
            self.assertEqual(shards.run(self.binary, [], 5, 'run', os.environ), 0)
        thread.join(timeout=3)
        self.assertFalse(thread.is_alive())

    def test_failure_keeps_early_diagnostic_after_long_remaining_output(self):
        self.script("print('1/1 store.test.failed...FAIL (error.Witness)')\n"
                    "print('first assertion witness')\n"
                    "print('later runner output' * 5000)\n"
                    "raise SystemExit(1)\n")
        result = shards.execute(self.binary, [], os.environ, 2, "failed")
        self.assertEqual(result.status, 1)
        self.assertGreater(len(result.diagnostic), 65536)
        self.assertIn("first assertion witness", result.diagnostic)
        self.assertIn("FAIL (error.Witness)", result.diagnostic)

    def test_timeout_kills_and_reaps_active_process(self):
        pid_file = self.directory / "pid"
        self.script(f"import os, signal\nfrom pathlib import Path\nPath({str(pid_file)!r}).write_text(str(os.getpid()))\nprint('1/1 store.test.stalled...', end='', flush=True)\nsignal.pause()\n")
        result = shards.execute(self.binary, [], os.environ, .2, "stalled")
        self.assertEqual(result.status, 124)
        self.assertIn("deadline exceeded", result.diagnostic)
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pid_file.read_text()), 0)

    def test_per_test_timeout_is_independent_of_process_deadline(self):
        self.script("import signal\nprint('1/1 store.test.stalled...', end='', flush=True)\nsignal.pause()\n")
        result = shards.execute(self.binary, [], os.environ, 5, "stalled", test_timeout=.1)
        self.assertEqual(result.status, 124)
        self.assertIn("test timeout", result.diagnostic)
        self.assertLess(result.seconds, 2)

    def test_per_test_deadline_survives_closed_output(self):
        self.script("import os, signal\nprint('1/1 store.test.closed...', end='', flush=True)\nos.close(1); os.close(2)\nsignal.pause()\n")
        result = shards.execute(self.binary, [], os.environ, 3, "closed", test_timeout=.1)
        self.assertEqual(result.status, 124)
        self.assertIn("test timeout", result.diagnostic)
        self.assertLess(result.seconds, 1)

    def test_sigterm_retires_every_detached_test_process_group(self):
        pid_file = self.directory / "active"
        self.script("import os, signal, subprocess\nfrom pathlib import Path\n"
                    "descendant = subprocess.Popen([__import__('sys').executable, '-c', 'import signal; signal.pause()'])\n"
                    f"Path({str(pid_file)!r}).write_text(str(os.getpid()) + ':' + str(descendant.pid))\n"
                    "print('1/1 store.test.active...', end='', flush=True)\nsignal.pause()\n")
        command = [sys.executable, "-c",
                   "import os, sys, store_shards as s; sys.exit(s.run(sys.argv[1], [], 10, 'aggregate', os.environ))",
                   str(self.binary)]
        process = subprocess.Popen(command, env=dict(os.environ, PYTHONPATH=str(ROOT / "tests/ci")),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        child = None
        try:
            from host_process import wait_for
            wait_for(pid_file.exists, "active test and descendant", timeout=3, interval=.01)
            child, descendant = map(int, pid_file.read_text().split(':'))
            process.terminate()
            stdout, stderr = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM, (stdout, stderr))
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
            census = subprocess.run(['ps', '-o', 'stat=', '-p', str(descendant)], capture_output=True, text=True)
            self.assertTrue(not census.stdout.strip() or census.stdout.strip().startswith('Z'), census.stdout)
        finally:
            if child is not None:
                try:
                    os.killpg(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=3)

    def test_nonzero_child_and_missing_record_cannot_publish_acceptance(self):
        record = self.directory / "record"
        record.write_text("prepares=999\n")
        self.script("raise SystemExit(7)\n")
        with patch("builtins.print"):
            self.assertEqual(shards.run(self.binary, [], 2, "run", dict(os.environ, RUI_TEST_MYSQL_RECORD=str(record))), 7)
        self.assertFalse(record.exists())
        self.script("print('1/1 store.test.ok...OK')\n")
        with patch("builtins.print"), self.assertRaises(FileNotFoundError):
            shards.run(self.binary, [], 2, "run", dict(os.environ, RUI_TEST_MYSQL_RECORD=str(record)))
        self.assertFalse(record.exists())

    def test_native_record_cannot_overwrite_store_and_aggregate_retains_original(self):
        record = self.directory / "record"
        self.script("import os\nfrom pathlib import Path\nPath(os.environ['RUI_TEST_MYSQL_RECORD']).write_text('prepares=1\\n')\nprint('1/1 test.ok...OK')\n")
        record.write_text("prepares=999\n")
        with patch("builtins.print"):
            self.assertEqual(shards.run(self.binary, [], 2, "native", dict(os.environ, RUI_TEST_MYSQL_RECORD=str(record))), 0)
        self.assertEqual(record.read_text(), "prepares=999\n")
        self.assertEqual(Path(str(record) + ".native").read_text(), "prepares=1\n")
        with patch("builtins.print"):
            self.assertEqual(shards.run(self.binary, [], 2, "aggregate", dict(os.environ, RUI_TEST_MYSQL_RECORD=str(record))), 0)
        self.assertEqual(record.read_text(), "prepares=1\n")

    def test_measurement_writes_only_complete_passing_inventory(self):
        output = self.directory / "times.json"
        self.script("print('1/2 store.test.one...OK\\n2/2 store.test.two...OK')\n")
        with patch("builtins.print"):
            self.assertEqual(shards.run(self.binary, [], 2, "measure", os.environ, output), 0)
        self.assertEqual(set(json.loads(output.read_text())), {"store.test.one", "store.test.two"})
        self.script("print('1/1 store.test.skip...SKIP')\n")
        with patch("builtins.print"):
            self.assertEqual(shards.run(self.binary, [], 2, "measure", os.environ, output), 0)
        self.assertEqual(set(json.loads(output.read_text())), {"store.test.skip"})

    def test_record_join_rejects_missing_or_negative_inputs(self):
        output = self.directory / "out"
        first = self.directory / "first"
        first.write_text("prepares=-1\n")
        with self.assertRaises(ValueError):
            shards.merge_records([first], output)
        with self.assertRaises(FileNotFoundError):
            shards.merge_records([self.directory / "missing"], output)
        self.assertFalse(output.exists())

    def test_timeout_units_match_selected_gate_budget(self):
        self.assertEqual(shards.duration("5m"), 300)
        self.assertEqual(shards.duration("1200"), 1200)
        with self.assertRaises(ValueError):
            shards.duration("forever")


@unittest.skipUnless(shutil.which("zig") and os.environ.get("RUI_TEST_ZIG_METADATA_PROBE") == "1",
                     "set RUI_TEST_ZIG_METADATA_PROBE=1 for compiled assignment domain and mutation")
class CompilerShardTest(unittest.TestCase):
    def test_complete_recorded_inventory_with_additions_removals_and_drop_mutation(self):
        # The measured names are an independent full-root inventory. Build a tiny
        # no-op root carrying every one, then change its inventory relative to the
        # committed measurements without recompiling the product's Store tests.
        measured = json.loads((ROOT / "tests/ci/store_test_times.json").read_text())
        self.assertGreater(len(measured), 100)
        old_names = sorted(measured)
        current = old_names[1:] + ["store.test.new test missing from measurements"]
        transformed = {"store.test." + name: seconds for name, seconds in measured.items()}
        zig = shutil.which("zig")
        environment = subprocess.check_output([zig, "env"], text=True)
        lib = json.loads(re.search(r'\.lib_dir = ("(?:[^"\\]|\\.)*")', environment)[1])
        stock = (Path(lib) / "compiler/test_runner.zig").read_text()
        with tempfile.TemporaryDirectory(prefix="store shard domain ") as directory:
            root = Path(directory)
            source = root / "store.zig"
            source.write_text("\n".join("test " + json.dumps(name, ensure_ascii=False) + " {}" for name in current))
            (root / "partition.zig").write_text((ROOT / "src/unit_test_partition.zig").read_text())
            (root / "options.zig").write_text("pub const root: usize = 1; pub const sharded = true;")
            generated = unit_test_runner.generate(stock, transformed)
            runner = root / "runner.zig"
            binary = root / "tests"
            command = [zig, "test", "--test-no-exec", "-fno-llvm", "--test-runner", str(runner),
                       "--dep", "unit_test_partition", "--dep", "unit_test_options",
                       f"-Mroot={source}", f"-Munit_test_partition={root / 'partition.zig'}",
                       f"-Munit_test_options={root / 'options.zig'}", f"-femit-bin={binary}"]
            runner.write_text(generated)
            subprocess.run(command, check=True, capture_output=True, timeout=60)
            with patch.dict(os.environ):
                os.environ.pop("RUI_UNIT_SHARD", None)
                complete = inventories.query(binary)
            self.assertEqual(len(complete), len(current))
            for count in range(1, 9):
                selected = []
                for index in range(count):
                    with patch.dict(os.environ, RUI_UNIT_SHARD=f"{index}/{count}"):
                        selected.extend(inventories.query(binary))
                inventories.compare(complete, selected)
            # Mutate the real generated selection seam: the chosen test is
            # omitted from every shard while the unsharded oracle is unchanged.
            target = complete[0]
            runner.write_text(generated.replace("if (owner != shard.index) continue;",
                "if (owner != shard.index or std.mem.eql(u8, test_fn.name, " + json.dumps(target) + ")) continue;"))
            subprocess.run(command, check=True, capture_output=True, timeout=60)
            selected = []
            for index in range(shards.SHARD_COUNT):
                with patch.dict(os.environ, RUI_UNIT_SHARD=f"{index}/{shards.SHARD_COUNT}"):
                    selected.extend(inventories.query(binary))
            with self.assertRaisesRegex(ValueError, "inventory mismatch.*dropped"):
                inventories.compare(complete, selected)


@unittest.skipUnless(os.environ.get("RUI_TEST_STORE_BINARY"), "set RUI_TEST_STORE_BINARY for the complete compiled Store inventory")
class StoreInventoryTest(unittest.TestCase):
    def test_global_mutators_are_first_and_only_in_shard_zero(self):
        binary = os.environ["RUI_TEST_STORE_BINARY"]
        with patch.dict(os.environ, RUI_UNIT_EXCLUSIVE="1"):
            exclusive = inventories.query(binary)
        self.assertEqual(len(exclusive), 7)
        for index in range(shards.SHARD_COUNT):
            with patch.dict(os.environ, RUI_UNIT_SHARD=f"{index}/{shards.SHARD_COUNT}"):
                selected = inventories.query(binary)
            if index == 0:
                self.assertEqual(selected[:len(exclusive)], exclusive)
            else:
                self.assertFalse(set(exclusive).intersection(selected))

    def test_runtime_invalid_selector_fails_closed(self):
        binary = os.environ["RUI_TEST_STORE_BINARY"]
        for text in ("0/0", "4/4", "wrong"):
            with patch.dict(os.environ, RUI_UNIT_SHARD=text), self.assertRaisesRegex(ValueError, "failed"):
                inventories.query(binary)

    def test_every_compiled_test_belongs_to_exactly_one_shard_for_k_1_through_8(self):
        binary = os.environ["RUI_TEST_STORE_BINARY"]
        with patch.dict(os.environ):
            os.environ.pop("RUI_UNIT_SHARD", None)
            complete = inventories.query(binary)
        self.assertGreater(len(complete), 100)
        for count in range(1, 9):
            with self.subTest(count=count):
                selected = []
                for index in range(count):
                    with patch.dict(os.environ, RUI_UNIT_SHARD=f"{index}/{count}"):
                        selected.extend(inventories.query(binary))
                inventories.compare(complete, selected)


if __name__ == "__main__":
    unittest.main()

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from stack_frames import PAGE, POLICY, ROOT, allowance_growth, check, parse


# objdump -d --no-show-raw-insn -C of a Host whose main thread spawns one worker.
DISASSEMBLY = """
Disassembly of section .text:

0000000000001000 <server.serve>:
    1000:\tpush   %rbp
    1004:\tmov    $0x3000,%eax
    1009:\tcall   2000 <__zig_probe_stack>
    100e:\tsub    %rax,%rsp
    1011:\tcall   1100 <server.Intake.run__func_12>
    1016:\tlea    0x1e4(%rip),%rdx        # 1200 <Thread.PosixThreadImpl.spawn__func_7.Instance.entryFn>
    101d:\tcall   1300 <debug.panic__func_3>

0000000000001100 <server.Intake.run__func_12>:
    1100:\tsub    $0x2800,%rsp
    1107:\tjmp    1400 <store.Store.capture>

0000000000001200 <Thread.PosixThreadImpl.spawn__func_7.Instance.entryFn>:
    1200:\tsub    $0x48,%rsp
    1204:\tcall   1500 <worker.receive>

0000000000001300 <debug.panic__func_3>:
    1300:\tsub    $0x10000,%rsp

0000000000001400 <store.Store.capture>:
    1400:\tsub    $0x100,%rsp
    1407:\tcall   1400 <store.Store.capture>

0000000000001500 <worker.receive>:
    1500:\tmov    $0x5000,%eax
    1505:\tcall   2000 <__zig_probe_stack>
    150a:\tsub    %rax,%rsp
    150d:\tcall   1100 <server.Intake.run__func_12>

0000000000001600 <client.only>:
    1600:\tsub    $0x40000,%rsp

0000000000002000 <__zig_probe_stack>:
    2000:\tsub    $0x1000,%rsp
"""

WORKER_ENTRY = "Thread.PosixThreadImpl.spawn.Instance.entryFn (worker)"


# Each over-budget frame's page ceiling; server.Intake.run measures 0x2800.
SEEDED = {"server.serve": 0x3000, "server.Intake.run": 0x3000, "worker.receive": 0x5000}
# Each thread's deepest chain, 22784 and 31048 bytes, rounded up to a page.
CEILINGS = {"main thread": 0x6000, "worker": 0x8000}


def policy(exceptions, threads=None, ceilings=None, modules=()):
    anchors = {"main thread": "server.serve", **({"worker": "worker.receive"} if threads is None else threads)}
    ceilings = {**CEILINGS, **(ceilings or {})}
    return {"budget_bytes": 8192,
            "threads": {label: {"anchor": anchor, "chain_ceiling": ceilings.get(label, 0)}
                        for label, anchor in anchors.items()},
            "host_modules": list(modules),
            "exceptions": [{"function": name, "frame_bytes": size, "cause": "fixture"}
                           for name, size in exceptions.items()]}


def gate(exceptions, disassembly=DISASSEMBLY, threads=None, ceilings=None, modules=()):
    return check(parse(disassembly), policy(exceptions, threads, ceilings, modules))


class StackFramesTest(unittest.TestCase):
    def test_every_reachable_frame_over_budget_fails_without_an_exception(self):
        report, failures = gate({})
        self.assertEqual(sorted(failure.split(":")[0] for failure in failures), sorted(SEEDED))
        self.assertIn("worker.receive: frame 20480 bytes exceeds the 8192-byte budget "
                      f"(via {WORKER_ENTRY} > worker.receive)", "\n".join(failures))
        # Panic paths, the probe helper and code no Host stack calls are not Host frames.
        self.assertNotIn("debug.panic", "\n".join(failures))
        self.assertNotIn("client.only", "\n".join(failures))

    def test_exceptions_at_the_measured_frame_pass_and_report_each_deepest_chain(self):
        report, failures = gate(SEEDED)
        self.assertEqual(failures, [])
        self.assertIn("main thread (server.serve): deepest chain 22784 bytes (22 KiB), ceiling 24576", report)
        self.assertIn("worker (Thread.PosixThreadImpl.spawn__func_7.Instance.entryFn): "
                      "deepest chain 31048 bytes (30 KiB), ceiling 32768", report)
        self.assertIn(f"        72 {WORKER_ENTRY}", report)

    def test_generated_suffixes_are_normalized(self):
        _, failures = gate(SEEDED, DISASSEMBLY.replace("__func_12", "__func_99").replace("__func_7", "__struct_8"))
        self.assertEqual(failures, [])

    def test_stale_exception_must_be_deleted(self):
        _, failures = gate({**SEEDED, "store.Store.capture": 0x2000, "gone.function": 0x4000})
        self.assertEqual(failures, [
            "store.Store.capture: now fits (256 bytes); delete this exception from stack_frames.json",
            "gone.function: is no longer reachable; delete this exception from stack_frames.json",
        ])

    def test_grown_frame_fails(self):
        _, failures = gate({**SEEDED, "worker.receive": 0x4fff})
        self.assertEqual(failures, [f"worker.receive: frame grew to 20480 bytes, past its 20479-byte exception "
                                    f"(via {WORKER_ENTRY} > worker.receive)"])

    def test_a_whole_page_of_shrinkage_must_lower_the_exception_to_its_page_ceiling(self):
        _, failures = gate({**SEEDED, "worker.receive": 0x6000, "server.Intake.run": 0x4000})
        self.assertEqual(failures, [
            "worker.receive: frame shrank to 20480 bytes; lower its frame_bytes from 24576 to 20480 in stack_frames.json",
            "server.Intake.run: frame shrank to 10240 bytes; lower its frame_bytes from 16384 to 12288 in stack_frames.json",
        ])
        # Less than a page is CPU-model noise, not a page the thread gave back.
        _, failures = gate({**SEEDED, "worker.receive": 0x5fff})
        self.assertEqual(failures, [])

    def test_the_largest_instance_of_a_generic_function_is_its_frame(self):
        larger = DISASSEMBLY.replace("150d:\tcall   1100 <server.Intake.run__func_12>",
                                     "150d:\tcall   1700 <server.Intake.run__func_13>") + """
0000000000001700 <server.Intake.run__func_13>:
    1700:\tsub    $0x3800,%rsp
"""
        _, failures = gate(SEEDED, larger, ceilings={"worker": 0x9000})
        self.assertEqual([failure.split(":")[0] for failure in failures], ["server.Intake.run"])
        self.assertIn("grew to 14336 bytes", failures[0])

    def test_thread_entries_are_told_apart_by_their_anchor(self):
        spawned = DISASSEMBLY.replace("0x48,%rsp", "0x4000,%rsp")
        _, failures = gate({**SEEDED, WORKER_ENTRY: 0x4000}, spawned, ceilings={"worker": 0xc000})
        self.assertEqual(failures, [])
        _, failures = gate(SEEDED, spawned, ceilings={"worker": 0xc000})
        self.assertEqual([failure.split(":")[0] for failure in failures], [WORKER_ENTRY])

    def test_a_deepest_chain_past_its_ceiling_fails_and_a_page_under_it_must_lower_it(self):
        _, failures = gate(SEEDED, ceilings={"main thread": 0x5000})
        self.assertEqual(failures, ["main thread: deepest chain grew to 22784 bytes, past its 20480-byte chain_ceiling"])
        _, failures = gate(SEEDED, ceilings={"worker": 0xa000})
        self.assertEqual(failures, ["worker: deepest chain shrank to 31048 bytes; lower its chain_ceiling "
                                    "from 40960 to 32768 in stack_frames.json"])
        # Less than a page under the ceiling is noise, not a page given back.
        _, failures = gate(SEEDED, ceilings={"main thread": 22784 + PAGE - 1})
        self.assertEqual(failures, [])

    def test_a_chain_through_a_recursive_cycle_counts_the_cycle_from_every_entry(self):
        functions = parse("""
0000000000001000 <server.serve>:
    1000:\tsub    $0x100,%rsp
    1007:\tcall   1100 <cycle.x>
    100c:\tcall   1300 <cycle.z>

0000000000001100 <cycle.x>:
    1100:\tsub    $0x10,%rsp
    1104:\tcall   1200 <cycle.y>
    1109:\tcall   1400 <big.leaf>

0000000000001200 <cycle.y>:
    1200:\tsub    $0x10,%rsp
    1204:\tcall   1100 <cycle.x>

0000000000001300 <cycle.z>:
    1300:\tsub    $0x1800,%rsp
    1307:\tcall   1200 <cycle.y>

0000000000001400 <big.leaf>:
    1400:\tsub    $0x1800,%rsp
""")
        # Walk x before z, so y is first reached while x is on the chain.
        functions["server.serve"]["calls"] = ["cycle.x", "cycle.z"]
        report, failures = check(functions, policy({}, threads={}, ceilings={"main thread": 0x4000}))
        self.assertEqual(failures, [])
        self.assertEqual(report, ["main thread (server.serve): deepest chain 12576 bytes (12 KiB), ceiling 16384",
                                  "       256 server.serve", "      6144 cycle.z", "        16 cycle.y",
                                  "        16 cycle.x", "      6144 big.leaf"])

    def test_host_module_functions_are_walked_without_a_direct_caller(self):
        # A callback reached only through a function pointer.
        callback = DISASSEMBLY + """
0000000000001700 <server_host.onWake__func_4>:
    1700:\tsub    $0x3000,%rsp
    1707:\tcall   1800 <posix.big>

0000000000001800 <posix.big>:
    1800:\tsub    $0x2400,%rsp
"""
        _, failures = gate(SEEDED, callback)
        self.assertEqual(failures, [])
        _, failures = gate(SEEDED, callback, modules=["server_host"])
        self.assertEqual(failures, [
            "server_host.onWake: frame 12288 bytes exceeds the 8192-byte budget (via server_host.onWake). "
            "Give big values one address their owner provides instead of a stack slot.",
            "posix.big: frame 9216 bytes exceeds the 8192-byte budget (via server_host.onWake > posix.big). "
            "Give big values one address their owner provides instead of a stack slot.",
        ])
        with self.assertRaisesRegex(ValueError, "no function of host_modules \\['renamed'\\]"):
            gate(SEEDED, callback, modules=["server_host", "renamed"])

    def test_only_the_panic_handlers_are_left_unwalked(self):
        debugging = DISASSEMBLY.replace("101d:\tcall   1300 <debug.panic__func_3>", """101d:\tcall   1300 <debug.panic__func_3>
    1022:\tcall   1900 <debug.print__func_5>
    1027:\tcall   1a00 <debug.FullPanic((function 'defaultPanic')).integerOverflow>""") + """
0000000000001900 <debug.print__func_5>:
    1900:\tsub    $0x2400,%rsp

0000000000001a00 <debug.FullPanic((function 'defaultPanic')).integerOverflow>:
    1a00:\tsub    $0x3000,%rsp
    1a07:\tcall   1b00 <debug.dumpCurrentStackTrace>

0000000000001b00 <debug.dumpCurrentStackTrace>:
    1b00:\tsub    $0x4000,%rsp
"""
        _, failures = gate(SEEDED, debugging)
        self.assertEqual([failure.split(":")[0] for failure in failures], ["debug.print"])

    def test_every_spawned_thread_is_named_by_exactly_one_anchor(self):
        with self.assertRaisesRegex(ValueError, "reaches anchors \\[\\]"):
            gate(SEEDED, threads={"worker": "client.only"})
        with self.assertRaisesRegex(ValueError, "reaches anchors \\['worker', 'other'\\]"):
            gate(SEEDED, threads={"worker": "worker.receive", "other": "store.Store.capture"})
        with self.assertRaisesRegex(ValueError, "no Host thread reaches the anchor of \\['engine'\\]"):
            gate(SEEDED, DISASSEMBLY.replace("# 1200 <", "# 1200 <spawn.removed>"),
                 threads={"engine": "worker.receive"})
        with self.assertRaisesRegex(ValueError, "server.serve is not in the binary"):
            gate(SEEDED, DISASSEMBLY.replace("<server.serve>:", "<cli.main>:"))
        unnamed = policy(SEEDED)
        del unnamed["threads"]["main thread"]
        with self.assertRaisesRegex(ValueError, "name the main thread by the anchor server.serve exactly once"):
            check(parse(DISASSEMBLY), unnamed)

    def test_repository_policy_is_a_seeded_ratchet(self):
        rules = json.loads(POLICY.read_text())
        self.assertEqual(rules["budget_bytes"], 8192)
        names = [entry["function"] for entry in rules["exceptions"]]
        self.assertEqual(len(names), len(set(names)))
        for entry in rules["exceptions"]:
            self.assertGreater(entry["frame_bytes"], rules["budget_bytes"], entry["function"])
            self.assertEqual(entry["frame_bytes"] % PAGE, 0, entry["function"])
            self.assertTrue(entry["cause"].strip(), entry["function"])
            # A cause stands on its own; no table outside the repository explains it.
            self.assertNotRegex(entry["cause"], r"\brows? \d", entry["function"])
        for label, spec in rules["threads"].items():
            self.assertGreater(spec["chain_ceiling"], 0, label)
            self.assertEqual(spec["chain_ceiling"] % PAGE, 0, label)
        modules = rules["host_modules"]
        self.assertEqual(len(modules), len(set(modules)))
        # Each names a source file by its Zig namespace; the h2 package's
        # files are named from its own root.
        for module in modules:
            path = module.replace(".", "/") + ".zig"
            self.assertTrue((ROOT / "src" / path).exists() or (ROOT / "src/h2" / path).exists(), module)

    def test_repository_allowance_does_not_grow_from_trusted_base(self):
        self.assertEqual(allowance_growth(), [])

    def test_candidate_cannot_enlarge_allowance_from_trusted_git_base(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "stack_frames.json"
            git = ["git", "-C", str(root), "-c", "user.name=Test", "-c", "user.email=test@example.invalid"]

            def commit(message):
                subprocess.run(git + ["add", "."], check=True)
                subprocess.run(git + ["commit", "-qm", message], check=True)

            subprocess.run(git + ["init", "-q"], check=True)
            (root / "README").write_text("trusted\n")
            commit("before the gate")
            subprocess.run(git + ["update-ref", "refs/remotes/origin/main", "HEAD"], check=True)
            path.write_text(json.dumps(policy({"a.big": 0x4000})))
            # First introduction: the reviewed seed is the allowance.
            self.assertEqual(allowance_growth(root, path), [])
            commit("seed")
            subprocess.run(git + ["update-ref", "refs/remotes/origin/main", "HEAD"], check=True)
            path.write_text(json.dumps(policy({"a.big": 0x3000})))
            self.assertEqual(allowance_growth(root, path), [])
            path.write_text(json.dumps(policy({"a.big": 0x5000, "b.new": 0x3000},
                                              ceilings={"main thread": 0x7000, "engine": 0x1000},
                                              threads={"worker": "worker.receive", "engine": "engine.run"})))
            commit("candidate grows allowance")
            self.assertEqual(allowance_growth(root, path), [
                "a.big: frame_bytes 20480 exceeds the trusted 16384",
                "b.new: frame_bytes 12288 exceeds the trusted absence",
                "main thread: chain_ceiling 28672 exceeds the trusted 24576",
                "engine: chain_ceiling 4096 exceeds the trusted absence",
            ])
            rules = policy({"a.big": 0x4000})
            rules["budget_bytes"] = 16384
            path.write_text(json.dumps(rules))
            self.assertEqual(allowance_growth(root, path), ["budget_bytes 16384 exceeds the trusted 8192"])


if __name__ == "__main__":
    unittest.main()

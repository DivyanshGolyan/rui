import ast
import contextlib
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import os
import re
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import build_files
import prepush
import select_tests

ROOT = prepush.ROOT

SOURCE_CHECKS = {"tests/ci: test_import_architecture.py", "tests/ci: test_provider_locality.py",
                 "tests/ci: test_wire_version.py", "tests/ci: test_harness_contracts.py",
                 "tests/ci: test_platform_boundary.py", "tests/ci: test_fixture_literals.py"}
FIXTURE_CHECKS = {"tests/ci: test_wire_version.py", "tests/ci: test_harness_contracts.py",
                  "tests/ci: test_platform_boundary.py", "tests/ci: test_store_schema_fixtures.py",
                  "tests/ci: test_fixture_literals.py"}

WHITESPACE = [sys.executable, "-B", "tests/ci/prepush.py", "--fix-whitespace", "BASE"]

AVAILABLE = set(build_files.steps())


class PrepushTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.addCleanup(patch.stopall)
        patch.object(prepush, "ROOT", self.root).start()
        patch.object(prepush, "previous_red", return_value=(None, [])).start()

    def file(self, path, text=""):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commands(self, paths, deleted=()):
        for path in paths:
            if path not in deleted:
                self.file(path)
        return dict(prepush.checks(paths, AVAILABLE, "BASE"))

    def test_generated_settings_metadata_is_checked_against_head(self):
        (self.root / "clients/ts/node_modules").mkdir(parents=True)
        artifact = "clients/ts/src/settings-kinds.ts"
        results = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0),
                   subprocess.CompletedProcess([], 0, stdout=artifact + "\n")]
        with patch.object(prepush.subprocess, "run", side_effect=results) as run, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(1, prepush.regenerate())
        self.assertEqual(["zig", "build", "-j1", "openapi", "--summary", "none"], run.call_args_list[0].args[0])
        diff = run.call_args_list[-1].args[0]
        self.assertEqual(["git", "diff", "--name-only", "HEAD", "--", *prepush.GENERATED], diff)
        self.assertIn(artifact, diff)
        self.assertIn(artifact, out.getvalue())

    def test_default_and_hook_are_feedback_only(self):
        paths = ["src/store/schema.zig", "src/cli_args.zig", "tests/integration/activity_integration.py"]
        self.commands(paths)
        for mode in ("default", "quick"):
            with self.subTest(mode=mode):
                commands = dict(prepush.checks(paths, AVAILABLE, "BASE", mode))
                self.assertFalse({"development selection", "macOS type check", "unfiltered unit compile",
                                  "stack frames", "TypeScript client", "tests/ci"} & commands.keys())
                self.assertTrue({"whitespace", "zig fmt", "schema number", "undefined Python names"} <= commands.keys())
                self.assertIsInstance(commands["hosted acceptance"], prepush.Skipped)
                self.assertIn("not evaluated", commands["hosted acceptance"].reason)

    def test_shared_inputs_keep_focused_feedback_without_a_policy_sweep(self):
        self.file("tests/ci/test_prepush.py")
        commands = self.commands(["tests/ci/prepush.py", ".github/workflows/check.yml"])
        self.assertIn("tests/ci: test_prepush.py", commands)
        self.assertNotIn("tests/ci", commands)
        self.assertNotIn("development selection", commands)

    def test_verify_rui_map_inputs_select_the_map_test(self):
        for path in (".claude/skills/verify-rui/scripts/frames.json",
                     ".claude/skills/verify-rui/features/README.md",
                     ".claude/skills/verify-rui/features/frames.md",
                     ".claude/skills/verify-rui/features/new-feature.md"):
            for deleted in ((), (path,)):
                with self.subTest(path=path, deleted=deleted):
                    commands = self.commands([path], deleted=deleted)
                    self.assertIn("tests/ci: test_verify_rui_map.py", commands)
                    self.assertIn("test_verify_rui_map.py", commands["tests/ci: test_verify_rui_map.py"])

    def test_upgrade_fixture_changes_select_their_existing_policy_consumers(self):
        for path, consumer in (
            ("tests/integration/previous_release_upgrade.py", "test_previous_release_upgrade.py"),
            ("tests/integration/host_serve_dialect.py", "test_previous_release_upgrade.py"),
            ("tests/integration/upgrade_integration.py", "test_upgrade_fixture.py"),
        ):
            for mode in ("default", "quick"):
                for deleted in ((), (path,)):
                    with self.subTest(path=path, mode=mode, deleted=deleted):
                        if deleted:
                            (self.root / path).unlink(missing_ok=True)
                        self.commands([path], deleted=deleted)
                        checks = dict(prepush.checks([path], AVAILABLE, "BASE", mode))
                        self.assertIn("tests/ci: " + consumer, checks)
                        self.assertIn(consumer, checks["tests/ci: " + consumer])

    def test_docs_only_select_whitespace(self):
        self.assertEqual(self.commands(["AGENTS.md"]), {"whitespace": WHITESPACE})

    def test_generation_uses_the_emitter_import_closure(self):
        files = {
            "src/logic_tests.zig": "const cores = .{\n};\n",
            "src/openapi_main.zig": 'const api = @import("openapi.zig");',
            "src/openapi.zig": 'const wire = @import("protocol.zig");',
            "src/protocol.zig": "", "src/Root.zig": "",
        }
        graph = select_tests.Graph(files, files.__getitem__)
        with patch.object(prepush, "tree_graph", return_value=graph):
            self.assertIn("generated files", self.commands(["src/protocol.zig"]))
            self.assertNotIn("generated files", self.commands(["src/Root.zig"]))
            self.assertIn("generated files", self.commands(["openapi.json"]))

    def test_core_boundary_uses_registered_cores_in_every_mode(self):
        graph = select_tests.tree_graph()
        self.assertTrue(graph.cores)
        expected = ["zig", "build", "-j1", "test-logic-only",
                    "-Dtest-filter=functional cores stay within the core boundary"]
        with patch.object(prepush, "tree_graph", return_value=graph):
            for mode in ("default", "quick", "full"):
                for path in sorted(graph.cores):
                    with self.subTest(mode=mode, path=path):
                        commands = dict(prepush.checks([path], AVAILABLE, "BASE", mode))
                        self.assertIn("core boundary", commands)
                        self.assertEqual(commands["core boundary"], expected)
                for path in ("src/server.zig", "docs/example.md", "tests/ci/prepush.py"):
                    with self.subTest(mode=mode, path=path):
                        self.assertNotIn("core boundary", dict(prepush.checks([path], AVAILABLE, "BASE", mode)))

    def test_client_changes_defer_broad_client_checks(self):
        commands = self.commands(["clients/ts/src/index.ts"])
        self.assertNotIn("TypeScript client", commands)
        self.assertIn("hosted acceptance", commands)

    def test_client_locality_inputs_run_the_gate_and_self_checks(self):
        for path in ("src/client.zig", "src/nested/client_rule.zig", "clients/ts/src/client.ts",
                     "clients/ts/src/nested/client.ts", "tests/ci/client_locality.py",
                     "tests/ci/test_client_locality.py", "tests/ci/caller_errors.py", "tests/ci/host_settings_locality.py",
                     "tests/ci/select_tests.py", "tests/ci/import_architecture.py", "tests/ci/stack_frames.json"):
            for mode in ("default", "quick"):
                for deleted in (False, True):
                    with self.subTest(path=path, mode=mode, deleted=deleted):
                        if deleted:
                            (self.root / path).unlink(missing_ok=True)
                        else:
                            self.file(path)
                        commands = dict(prepush.checks([path], AVAILABLE, "BASE", mode))
                        self.assertEqual(commands["client locality"],
                                         [sys.executable, "-B", "tests/ci/client_locality.py"])
                        self.assertIn("test_client_locality.py", commands["tests/ci: test_client_locality.py"])
        for path in ("docs/example.md", "clients/ts/README.md", "tests/integration/activity_integration.py"):
            with self.subTest(path=path):
                commands = dict(prepush.checks([path], AVAILABLE, "BASE"))
                self.assertNotIn("client locality", commands)
                self.assertNotIn("tests/ci: test_client_locality.py", commands)

    def test_deleted_files_select_owner_checks_not_file_tools(self):
        commands = self.commands(["src/cli_args.zig"], deleted=["src/cli_args.zig"])
        self.assertIn("caller errors", commands)
        self.assertNotIn("zig fmt", commands)

    def test_explicit_policy_routes_name_existing_test_modules_and_filters(self):
        for _, tests in prepush.SOURCE_POLICY:
            for module, pattern in tests:
                with self.subTest(module=module, pattern=pattern):
                    tree = ast.parse((ROOT / "tests/ci" / module).read_text())
                    methods = [f"{node.name}.{child.name}" for node in tree.body if isinstance(node, ast.ClassDef)
                               for child in node.body if isinstance(child, ast.FunctionDef) and child.name.startswith("test_")]
                    self.assertTrue(methods)
                    if pattern != "*":
                        self.assertTrue(any(pattern in method for method in methods))

    def test_the_unfiltered_unit_compile_is_ci_unit_producer_command(self):
        import build_artifact
        with patch.dict(os.environ, {"RUNNER_TEMP": str(self.root), "GITHUB_EVENT_NAME": "push"}), \
                patch.object(build_artifact, "compile_command", wraps=build_artifact.compile_command) as command, \
                patch.object(build_artifact.subprocess, "run") as run:
            build_artifact.build(["test"], "unit")
            command.assert_called_once_with(["test"], "unit", pr_mode=False)
            ci = run.call_args.args[0]
            command.reset_mock()
            local = prepush.unit_compile()
            command.assert_called_once_with(["test"], "unit", jobs=1)
        # The graph and backend are shared; local feedback has an explicit
        # one-job resource budget while hosted producers use their own limit.
        without_jobs = lambda args: [arg for arg in args if not arg.startswith("-j")]
        self.assertEqual(without_jobs(local[:-2]), without_jobs(ci[:ci.index("--prefix")]))
        self.assertEqual([arg for arg in local if arg.startswith("-j")], ["-j1"])
        self.assertNotIn("-Dtest-filter", " ".join(local))

    def test_local_unit_compile_keeps_llvm_even_in_a_pr_environment(self):
        with patch.dict(os.environ, GITHUB_EVENT_NAME="pull_request"):
            self.assertNotIn("-Dpr-ci=true", prepush.unit_compile())


    def test_full_adds_the_unit_compile_stack_frames_and_live_mysql_only_with_a_server(self):
        paths = ["src/store/rsql.zig"]
        default = self.commands(paths)
        without = dict(prepush.checks(paths, AVAILABLE, "BASE", "full"))
        with_server = dict(prepush.checks(paths, AVAILABLE, "BASE", "full", mysql=True))
        for full in (without, with_server):
            self.assertEqual(set(full) - set(default), {"development selection", "macOS type check", "unfiltered unit compile", "stack frames", "live MySQL"})
            self.assertEqual({name: full[name] for name in default}, default)
            self.assertEqual(full["unfiltered unit compile"], prepush.unit_compile())
            self.assertEqual(full["stack frames"], ["zig", "build", "-j1", "stack-frames", "-Dcpu=baseline", "--summary", "line"])
        self.assertEqual(with_server["live MySQL"], ["env", "RUI_TEST_REQUIRE_ENGINES=mysql", "zig", "build", "test-store", "--summary", "line"])
        self.assertIsInstance(without["live MySQL"], prepush.Skipped)
        self.assertIn("RUI_TEST_MYSQL_SOCKET", without["live MySQL"].reason)
        self.assertTrue(without["live MySQL"].reason.endswith("so CI runs test-store"))

    def test_full_runs_a_live_need_only_through_its_own_root_and_skips_every_other(self):
        no_root = "no target runs only these tests"
        cases = {
            "src/request_encoding.zig": (None, None),
            "src/store/rsql.zig": (["test-store"], None),
            "src/store/mysql.zig": (["test-store"], None),
            "src/store/Store.zig": (["test-store"], None),
            "tests/integration/settings_integration.py": (["settings-integration"], None),
            "src/host_start.zig": (["settings-integration"], None),
            "src/find_tools_tests.zig": (None, [no_root]),
            "src/read_transcript.zig": (None, [no_root]),
            "src/store/wire/pg.zig": (None, ["(test-pg)"]),
            "src/store/wire/mysql_connection.zig": (["test-store"], ["(mysql-wire-integration)"]),
        }
        for path, (live, left) in cases.items():
            with self.subTest(path=path):
                self.file(path)
                full = dict(prepush.checks([path], AVAILABLE, "BASE", "full", mysql=True))
                command = full.get("live MySQL")
                self.assertEqual(command and command[4:-2], live)
                skipped = full.get("live, CI only")
                if left is None:
                    self.assertIsNone(skipped)
                else:
                    self.assertIsInstance(skipped, prepush.Skipped, "recorded as skipped, never as passed")
                    self.assertTrue(skipped.reason.endswith("CI runs it"))
                    for text in left:
                        self.assertIn(text, skipped.reason)
                default = dict(prepush.checks([path], AVAILABLE, "BASE"))
                self.assertFalse({"live MySQL", "live, CI only"} & set(default))

    def test_the_live_mysql_step_never_runs_a_whole_suite(self):
        candidates = {path for patterns, *_ in select_tests.LIVE_RULES for path in patterns if "*" not in path and not path.startswith("!")}
        candidates |= {"src/store/rsql.zig", "src/store/Store.zig", "src/store/schema.zig", "src/store.zig"}
        candidates |= select_tests.tree_graph().live_conformance
        for path in sorted(candidates):
            with self.subTest(path=path):
                self.file(path)
                command = dict(prepush.checks([path], AVAILABLE, "BASE", "full", mysql=True)).get("live MySQL")
                if command:
                    self.assertFalse(set(command) & {"test", "test-native", "check", "check-full"}, command)
                    self.assertFalse(any(word.startswith("-Dtest-filter") for word in command))

    def test_mysql_is_reachable_only_through_a_listening_named_socket_with_a_password(self):
        path = str(self.root / "m.sock")
        environ = {"RUI_TEST_MYSQL_SOCKET": path, "RUI_TEST_MYSQL_ROOT_PASSWORD": "pw"}
        self.assertFalse(prepush.mysql_reachable(environ), "nothing listens")
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(path)
            server.listen()
            self.assertTrue(prepush.mysql_reachable(environ))
            self.assertFalse(prepush.mysql_reachable({"RUI_TEST_MYSQL_SOCKET": path}))
            self.assertFalse(prepush.mysql_reachable({}))

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, path, text, message):
        self.file(path, text)
        self.git("add", "-A")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def test_merged_base_finds_only_a_merge_of_a_commit_the_base_reaches(self):
        self.git("init", "-q", "-b", "main")
        self.commit("a", "1\n", "root")
        self.git("checkout", "-qb", "feature")
        self.commit("b", "1\n", "feature")
        self.git("checkout", "-q", "main")
        self.commit("a", "2\n", "main moves")
        self.git("checkout", "-qb", "other", "feature")
        self.commit("c", "1\n", "other")
        self.git("checkout", "-q", "feature")

        def merged():
            with contextlib.chdir(self.root):
                return select_tests.merged_base(self.git("merge-base", "HEAD", "main"), "main")

        self.assertFalse(merged(), "no merge")
        self.git("merge", "-q", "--no-ff", "-m", "merge other", "other")
        self.assertFalse(merged(), "a merge of a branch main does not reach")
        self.git("merge", "-q", "--no-ff", "-m", "merge main", "main")
        self.assertTrue(merged(), "a merge of main")
        self.commit("b", "2\n", "after the merge")
        self.assertTrue(merged(), "commits after the merge keep it in history")

    def receipt_repository(self):
        self.git("init", "-q")
        self.commit("a", "1\n", "root")
        return self.git("rev-parse", "HEAD^{tree}")

    def run_checks(self, *commands, base="BASE"):
        with redirect_stdout(io.StringIO()):
            return prepush.run([(f"check {index}", command) for index, command in enumerate(commands)], "default", base)

    def test_a_receipt_covers_only_its_clean_tree_with_every_command_passed(self):
        tree = self.receipt_repository()
        results = self.run_checks(["true"], prepush.Skipped("no server"))
        self.assertEqual(results, [{"name": "check 0", "command": ["true"], "exit": 0}, {"name": "check 1", "skipped": "no server"}])
        receipt = prepush.read_receipt()
        self.assertEqual((receipt["tree"], receipt["base"], receipt["mode"]), (tree, "BASE", "default"))
        self.assertTrue(prepush.receipt_path().is_relative_to((self.root / ".git").resolve()), "untracked, per checkout")
        self.assertTrue(prepush.receipt_covers(receipt, [(tree, "BASE"), (tree, "BASE")]), "same tree")
        self.assertFalse(prepush.receipt_covers(receipt, [(tree, "OTHER")]), "same tree checked against another merge base")
        changed = self.commit("a", "2\n", "change")
        self.assertFalse(prepush.receipt_covers(receipt, [(self.git("rev-parse", f"{changed}^{{tree}}"), "BASE")]), "changed tree")
        self.assertFalse(prepush.receipt_covers(receipt, [(tree, "BASE"), (self.git("rev-parse", "HEAD^{tree}"), "BASE")]),
                         "one of two pushed trees changed")
        head = (self.git("rev-parse", "HEAD^{tree}"), "BASE")

        self.run_checks(["true"], ["false"])
        self.assertFalse(prepush.receipt_covers(prepush.read_receipt(), [head]), "a failed command")
        for commands in ((), (prepush.Skipped("no server"),)):
            with self.subTest(commands=commands):
                self.run_checks(*commands)
                self.assertFalse(prepush.receipt_covers(prepush.read_receipt(), [head]), "a run that ran nothing passes nothing")

    def test_a_dirty_working_tree_never_yields_a_receipt_matching_head(self):
        tree = self.receipt_repository()
        for dirty in (lambda: self.file("a", "edited\n"), lambda: self.file("untracked", "new\n")):
            with self.subTest():
                dirty()
                self.run_checks(["true"])
                self.assertIsNone(prepush.read_receipt()["tree"])
                self.assertFalse(prepush.receipt_covers(prepush.read_receipt(), [(tree, "BASE")]))
                self.git("checkout", "-q", "--", ".")
                self.git("clean", "-qfd")
        self.run_checks(["sh", "-c", "echo changed > a"])
        self.assertFalse(prepush.receipt_covers(prepush.read_receipt(), [(tree, "BASE")]), "a check that dirtied the tree")
        self.git("checkout", "-q", "--", ".")
        self.run_checks(["true"])
        self.assertTrue(prepush.receipt_covers(prepush.read_receipt(), [(tree, "BASE")]))

    def test_pushing_a_tree_with_a_passing_receipt_does_not_run_the_checks_again(self):
        self.git("init", "-q", "-b", "main")
        self.commit("a", "1\n", "root")
        self.git("checkout", "-qb", "feature")
        head = self.commit("b", "1\n", "feature")
        tree = self.git("rev-parse", "HEAD^{tree}")
        planned = patch.object(prepush, "checks", side_effect=lambda paths, *_: iter([("probe", ["true"])] if paths else [])).start()

        def run(*argv, pushed=None):
            environ = {"RUI_PREPUSH_PUSHED": f" {pushed}"} if pushed else {}
            with patch("sys.argv", ["prepush.py", *argv]), patch.dict(os.environ, environ), contextlib.chdir(self.root), \
                    redirect_stdout(io.StringIO()) as output, self.assertRaises(SystemExit) as result:
                prepush.main()
            return result.exception.code, output.getvalue()

        def push(sha):
            before = planned.call_count
            code, output = run("--quick", "--base", "main", pushed=sha)
            self.assertEqual(code, 0)
            return planned.call_count > before, output

        self.assertEqual(run("--base", "HEAD")[0], 0)
        self.assertEqual(prepush.read_receipt()["results"], [], "the diff against HEAD is empty")
        self.assertTrue(push(head)[0], "a receipt against another base, which ran nothing, does not cover the push")
        ran, output = push(head)
        self.assertFalse(ran, "the same tree and base again: nothing runs")
        self.assertIn(f"run on tree {tree} against {self.git('merge-base', 'HEAD', 'main')} passed", output)
        self.commit("a", "2\n", "change")
        self.assertFalse(push(head)[0], "pushing the old commit still matches its tree and base")
        self.assertTrue(push(self.git("rev-parse", "HEAD"))[0], "a new tree runs the checks")
        self.git("checkout", "-q", "--orphan", "unrelated")
        orphan = self.commit("c", "1\n", "no history shared with main")
        self.git("checkout", "-q", "feature")
        self.assertIsNone(prepush.pushed_key(orphan, "main"))
        self.assertTrue(push(orphan)[0], "a commit with no merge base is not covered: --quick runs")

    def test_whitespace_in_committed_lines_is_fixed_in_the_working_tree_and_still_fails(self):
        self.git("init", "-q")
        self.file("clean.zig", "const a = 1;\n")
        self.file("lines.zig", "const a = 1;\n")
        self.file("probe.patch", "context\n")
        self.file("edited.md", "one\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "base")
        base = self.git("rev-parse", "HEAD")
        self.assertEqual(prepush.fix_whitespace(base), 0)
        self.file("lines.zig", "const a = 1;  \nconst b = 2;\t\nconst c = 3; // keep  inner spaces\n\n\n")
        self.file("probe.patch", "context\n+added \n")
        self.file("edited.md", "one\ntwo \n")
        self.git("add", "-A")
        self.git("commit", "-qm", "whitespace")
        self.file("edited.md", "zero\none\ntwo \n")
        with redirect_stdout(io.StringIO()) as output:
            self.assertEqual(prepush.fix_whitespace(base), 1)
        self.assertEqual((self.root / "lines.zig").read_text(),
                         "const a = 1;\nconst b = 2;\nconst c = 3; // keep  inner spaces\n")
        self.assertEqual((self.root / "probe.patch").read_text(), "context\n+added \n")
        self.assertEqual((self.root / "edited.md").read_text(), "zero\none\ntwo \n")
        self.assertIn("Fixed whitespace in the working tree of lines.zig:", output.getvalue())
        self.git("commit", "-qam", "fixed")
        self.file("probe.patch", "context\n")
        self.file("edited.md", "one\n")
        self.git("commit", "-qam", "reverted")
        self.assertEqual(prepush.fix_whitespace(base), 0)

    def test_a_hook_run_leaves_the_pushing_repository_before_its_checks_start_git(self):
        self.git("init", "-q")
        pushing = self.root / "pushing"
        subprocess.run(["git", "init", "-q", str(pushing)], check=True)
        hook = {"GIT_DIR": str(pushing / ".git"), "GIT_WORK_TREE": str(pushing), "GIT_INDEX_FILE": str(pushing / ".git/index")}
        with patch.dict(os.environ, hook):
            self.assertEqual(Path(self.git("rev-parse", "--absolute-git-dir")), (pushing / ".git").resolve(),
                             "git -C does not outrank a hook's repository")
            prepush.leave_hook_repository()
            self.assertEqual(Path(self.git("rev-parse", "--absolute-git-dir")), (self.root / ".git").resolve())

    def test_installed_hook_runs_quick_checks_for_each_push_but_not_a_deletion(self):
        self.git("init", "-q")
        self.file("tests/ci/prepush.py", "import os, pathlib, sys\n"
                  "pathlib.Path(__file__).with_name('ran').write_text(' '.join(sys.argv[1:]) + ':' + os.environ['RUI_PREPUSH_PUSHED'])\n")
        hooks = self.root / "hooks"
        self.git("config", "core.hooksPath", str(hooks))
        with redirect_stdout(io.StringIO()):
            prepush.install_hook()
        hook = hooks / "pre-push"

        def push(*local_shas):
            (self.root / "tests/ci/ran").unlink(missing_ok=True)
            subprocess.run([str(hook), "origin", "url"], cwd=self.root, check=True, text=True,
                           input="".join(f"refs/heads/x {sha} refs/heads/x {'0' * 40}\n" for sha in local_shas))
            ran = self.root / "tests/ci/ran"
            return ran.read_text() if ran.exists() else None

        self.assertEqual(push("a" * 40), f"--quick: {'a' * 40}", "an older prepush.py sees only --quick")
        self.assertEqual(push("a" * 40, "0" * 40, "b" * 40), f"--quick: {'a' * 40} {'b' * 40}")
        self.assertIsNone(push("0" * 40), "deleting a remote branch pushes nothing to check")
        hook.write_text(prepush.PREVIOUS_HOOKS[0])
        with redirect_stdout(io.StringIO()):
            prepush.install_hook()
        self.assertEqual(hook.read_text(), prepush.HOOK, "an earlier Rui hook is upgraded")
        hook.write_text("#!/bin/sh\nexit 0\n")
        with self.assertRaises(SystemExit):
            prepush.install_hook()
        self.assertEqual(hook.read_text(), "#!/bin/sh\nexit 0\n", "another hook is never replaced")

    def test_cached_feedback_retains_ci_deferrals_without_an_executed_pass(self):
        tree = self.receipt_repository()
        self.run_checks(["true"], prepush.Skipped("upgrade-integration needs an exclusive ordinary hosted runner UID"))
        receipt = prepush.read_receipt()
        self.assertEqual(receipt["scope"], "local-feedback")
        self.assertNotIn("exit", receipt["results"][1])
        head = self.git("rev-parse", "HEAD")
        with patch("sys.argv", ["prepush.py", "--quick"]), \
                patch.dict(os.environ, {prepush.PUSHED: head}), \
                patch.object(prepush, "pushed_key", return_value=(tree, "BASE")), \
                patch.object(prepush, "checks", side_effect=AssertionError("reran cached feedback")), \
                redirect_stdout(io.StringIO()) as output, self.assertRaises(SystemExit) as result:
            prepush.main()
        self.assertEqual(result.exception.code, 0)
        self.assertIn("Hosted acceptance was not evaluated", output.getvalue())
        self.assertIn("upgrade-integration needs an exclusive ordinary hosted runner UID", output.getvalue())

    def test_uid_global_upgrade_is_deferred_in_every_local_mode(self):
        self.file("src/upgrade.zig")
        for mode in ("default", "quick", "full"):
            with self.subTest(mode=mode):
                commands = dict(prepush.checks(["src/upgrade.zig"], AVAILABLE, "BASE", mode))
                for command in commands.values():
                    if not isinstance(command, prepush.Skipped):
                        self.assertNotIn("upgrade-integration", command)
                self.assertIn("upgrade-integration", commands["hosted acceptance"].reason)
                self.assertIn("exclusive ordinary hosted runner UID", commands["hosted acceptance"].reason)

    def test_empty_diff_runs_nothing(self):
        self.assertEqual(self.commands([]), {})

    def test_plan_does_not_execute_checks(self):
        self.file("build.zig")
        with patch("sys.argv", ["prepush.py", "--plan"]), patch.object(prepush, "changed_paths", return_value=(["AGENTS.md"], "BASE")), patch.object(prepush.subprocess, "check_output", return_value="BASE\n"), patch.object(prepush.subprocess, "run") as run, redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(SystemExit) as result:
                prepush.main()
        self.assertEqual(result.exception.code, 0)
        run.assert_not_called()
        plan = json.loads(output.getvalue())
        self.assertEqual(plan["base"], "BASE")
        self.assertEqual(plan["paths"], ["AGENTS.md"])
        self.assertEqual([check["name"] for check in plan["checks"]], ["whitespace"])

    def test_execution_runs_each_command_once_and_reports_failures(self):
        self.file("build.zig")
        checks = [("first", ["first"]), ("second", ["second"])]
        with patch("sys.argv", ["prepush.py"]), patch.object(prepush, "changed_paths", return_value=(["file"], "BASE")), patch.object(prepush.subprocess, "check_output", return_value="BASE\n"), patch.object(prepush, "checks", return_value=iter(checks)), patch.object(prepush.subprocess, "run", side_effect=[type("Result", (), {"returncode": 1})(), type("Result", (), {"returncode": 0})()]) as run, patch.object(prepush, "receipt_path", return_value=self.root / "receipt"), redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(SystemExit) as result:
                prepush.main()
        self.assertEqual(result.exception.code, 1)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(json.loads(output.getvalue().splitlines()[-1]), {"failed": ["first"], "skipped": []})
        self.assertEqual([result["exit"] for result in json.loads((self.root / "receipt").read_text())["results"]], [1, 0])


if __name__ == "__main__":
    unittest.main()

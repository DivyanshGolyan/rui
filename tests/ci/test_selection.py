import json
import re
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from select_tests import execution_batches, select, setup_requirements


AVAILABLE = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', Path("build.zig").read_text()))


class SelectionTest(unittest.TestCase):
    def test_development_does_not_claim_native_acceptance(self):
        result = select(["src/bash_platform.c", "src/store.zig"], "development", AVAILABLE)
        self.assertEqual(result["targets"], ["test-logic"])
        self.assertFalse(result["native_required"])
        self.assertFalse(result["acceptance_reused"])

    def test_portable_owner_does_not_require_full_suite(self):
        result = select(["src/request_encoding.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["test-logic"])
        self.assertFalse(result["native_required"])

    def test_logic_root_selects_its_executable_root(self):
        result = select(["src/logic_tests.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["test-logic"])

    def test_frontend_policy_keeps_value_and_native_handoff_checks(self):
        for path in ("src/SessionFrontend.zig", "src/SessionSubmission.zig",
                     "src/session_consent.zig", "src/session_departure.zig"):
            result = select([path], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertEqual(result[family], ["admission-debug-integration", "check", "test-logic"])

    def test_composed_gates_do_not_cover_the_separate_logic_root(self):
        for logic in ("src/logic_tests.zig", "src/AnswerRenderer.zig",
                      "src/request_encoding.zig", "src/execution_turn.zig"):
            for composed in ("src/server.zig", "src/store.zig", "build.zig"):
                with self.subTest(logic=logic, composed=composed):
                    result = select([logic, composed], "review", AVAILABLE)
                    self.assertIn("test-logic", result["targets"])
                    self.assertTrue(set(result["targets"]) & {"check", "check-full"})

    def test_docs_are_not_runtime_acceptance(self):
        self.assertEqual(select(["VERIFICATION.md"], "review", AVAILABLE)["targets"], [])

    def test_shared_state_and_unknown_code_fail_closed(self):
        for path in ("src/store.zig", "src/future_owner.zig", "tests/integration/future_case.py"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["check"])
            self.assertTrue(result["native_required"])

    def test_store_sql_keeps_native_owner_without_unrelated_mac_suite(self):
        result = select(["src/store.zig"], "review", AVAILABLE)
        self.assertEqual(result["native_targets"], ["test"])
        combined = select(["src/store.zig", "src/server.zig"], "review", AVAILABLE)
        self.assertEqual(combined["native_targets"], ["admission-debug-integration", "check"])

    def test_bash_keeps_real_custody_and_recovery_checks(self):
        result = select(["src/bash_platform.c"], "review", AVAILABLE)
        self.assertIn("bash-lifecycle-integration", result["targets"])
        self.assertIn("bash-recovery-integration", result["targets"])
        self.assertTrue(result["native_required"])

    def test_union_deduplicates_only_checks_owned_by_broad_gate(self):
        result = select(["src/store.zig", "src/codex_credentials.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["check", "codex-credential-integration", "codex-h2-integration"])
        self.assertEqual(result["native_targets"], ["codex-credential-integration", "codex-h2-integration", "codex-integration", "test"])

    def test_build_changes_keep_long_and_debug_checks(self):
        result = select(["build.zig"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertTrue({"admission-debug-integration", "check-full", "evaluator-churn",
                             "test-full", "current-facts-integration", "server-delivery-integration"}
                            <= set(result[family]))
        self.assertIn("login-signal-integration", result["targets"])
        self.assertNotIn("login-signal-integration", result["native_targets"])

    def test_transport_inputs_keep_both_native_h2_owners(self):
        for path in ("src/build_transport.sh", "src/curl-post-retry.patch", "build.zig.zon"):
            result = select([path], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertIn("transport-h2-integration", result[family])
                self.assertIn("codex-h2-integration", result[family])

    def test_bootstrap_action_is_not_cheap_ci_policy(self):
        for path in (".github/actions/setup/action.yml", "install.sh", "src/fetch_dependencies.sh"):
            result = select([path], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertTrue({"check-full", "admission-debug-integration", "test-full",
                                 "evaluator-churn", "transport-h2-integration",
                                 "codex-h2-integration"} <= set(result[family]))

    def test_shared_driver_selects_one_native_inventory(self):
        for paths in (["tests/integration/check.sh"],
                      ["tests/integration/check.sh", "build.zig"],
                      ["tests/integration/check.sh", "src/server.zig"],
                      ["tests/integration/check.sh", "tests/integration/terminal_restoration_integration.py"]):
            result = select(paths, "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertIn("check-full", result[family])
                self.assertNotIn("check", result[family])
                self.assertNotIn("terminal-restoration-integration", result[family])

    def test_standalone_oracles_have_executable_platform_routes(self):
        for owner in ("login-signal", "current-facts", "server-delivery"):
            path = f"tests/integration/{owner.replace('-', '_')}_integration.py"
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], [f"{owner}-integration"])
            self.assertEqual(result["native_targets"],
                             [] if owner == "login-signal" else [f"{owner}-integration"])
            combined = select([path, "build.zig"], "review", AVAILABLE)
            self.assertIn(f"{owner}-integration", combined["targets"])

    def test_standalone_imported_helpers_keep_their_real_oracles(self):
        result = select(["tests/integration/model_fixture.py"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertTrue({"current-facts-integration", "server-delivery-integration"}
                            <= set(result[family]))
        self.assertEqual(execution_batches(["current-facts-integration", "server-delivery-integration"]),
                         [["current-facts-integration"], ["server-delivery-integration"]])

    def test_model_scenarios_do_not_select_shared_fixture_consumers(self):
        result = select(["tests/integration/dispatch_integration.py"], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertEqual(result[family], ["dispatch-integration"])

    def test_standalone_helper_routes_add_without_losing_existing_consumers(self):
        for path, owner in (("host_process.py", "check"),
                            ("control_integration.py", "check"),
                            ("canonical_failure_integration.py", "canonical-failure-integration")):
            result = select([f"tests/integration/{path}"], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertIn(owner, result[family])

    def test_shared_fixture_helpers_keep_composed_and_separate_consumers(self):
        for name in ("control_integration.py", "model_fixture.py", "host_process.py"):
            path = f"tests/integration/{name}"
            standalone = {"codex-h2-integration", "transport-h2-integration", "server-delivery-integration"}
            if name != "control_integration.py":
                standalone.add("current-facts-integration")
            for composed, paths in (("check", [path]), ("check-full", [path, "build.zig"])):
                with self.subTest(name=name, composed=composed):
                    result = select(paths, "review", AVAILABLE)
                    for family in ("targets", "native_targets"):
                        self.assertTrue({composed, *standalone} <= set(result[family]))
                        self.assertNotIn("control-integration", result[family])

    def test_canonical_failure_is_covered_by_the_composed_human_cli_gate(self):
        path = "tests/integration/canonical_failure_integration.py"
        alone = select([path], "review", AVAILABLE)
        for family in ("targets", "native_targets"):
            self.assertIn("canonical-failure-integration", alone[family])
            self.assertNotIn("check", alone[family])
        for composed in ("src/server.zig", "build.zig"):
            combined = select([path, composed], "review", AVAILABLE)
            for family in ("targets", "native_targets"):
                self.assertNotIn("canonical-failure-integration", combined[family])
                self.assertIn("current-facts-integration", combined[family])

    def test_ci_policy_does_not_make_build_qualification_universal(self):
        for path in (".github/workflows/check.yml",
                     ".github/workflows/cache-maintenance.yml", ".github/scripts/prune-caches.cjs",
                     "tests/ci/select_tests.py", "tests/ci/run_selected.py"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["test-logic"])
            self.assertEqual(result["native_targets"], ["test-logic"])

    def test_missing_required_target_is_an_error_not_a_skip(self):
        with self.assertRaisesRegex(ValueError, "absent"):
            select(["src/bash.zig"], "review", AVAILABLE - {"bash-recovery-integration"})

    def test_new_session_policy_paths_keep_portable_and_original_native_gates(self):
        # Select each path alone: a simultaneous CLI or logic-root edit must not
        # mask missing coverage when a later change touches only the new owner.
        cases = {
            "src/new_session_selection.zig": ["admission-debug-integration", "check", "test-logic"],
            "src/preference_values.zig": ["admission-debug-integration", "check", "test-logic"],
            "src/provider_selection.zig": ["admission-debug-integration", "check", "test-logic"],
            "src/model_capability.zig": ["dispatch-integration", "test", "test-logic", "transport-h2-integration"],
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                result = select([path], "review", AVAILABLE)
                for family in ("targets", "native_targets"):
                    self.assertEqual(result[family], expected)
                combined = select([path, "src/server.zig"], "review", AVAILABLE)
                for family in ("targets", "native_targets"):
                    self.assertIn("test-logic", combined[family])
                    self.assertIn("check", combined[family])

    def test_preference_owner_and_fixture_use_canonical_membership(self):
        result = select(["src/preferences.zig"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["admission-debug-integration", "check"])
        self.assertEqual(result["native_targets"], ["admission-debug-integration", "check"])
        for path in ("tests/integration/preference_policy_integration.py",
                     "tests/integration/preference_policy.zig"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["preference-policy-integration"])
            self.assertEqual(result["native_targets"], ["preference-policy-integration"])
            combined = select([path, "src/protocol.zig"], "review", AVAILABLE)
            self.assertEqual(combined["targets"], ["check"])
            self.assertEqual(combined["native_targets"], ["check"])

    def test_existing_fixture_target_and_new_fixture_fallback(self):
        result = select(["tests/integration/host_stop_integration.py"], "review", AVAILABLE)
        self.assertEqual(result["targets"], ["host-stop-integration"])

    def test_h2_fixture_and_companion_keep_their_owning_target(self):
        for path in ("tests/integration/transport_h2_integration.py",
                     "tests/integration/transport_h2_integration_test.py"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["transport-h2-integration"])
            self.assertEqual(result["native_targets"], ["transport-h2-integration"])

    def test_public_read_fixture_and_client_select_owner_once(self):
        for owner in ("proposal", "activity"):
            for suffix in ("_integration.py", "_client.zig"):
                path = f"tests/integration/{owner}{suffix}"
                result = select([path], "review", AVAILABLE)
                self.assertEqual(result["targets"], [f"{owner}-integration"])
                self.assertEqual(result["native_targets"], [f"{owner}-integration"])
                combined = select([path, "src/protocol.zig"], "review", AVAILABLE)
                self.assertEqual(combined["targets"], ["check"])
                self.assertEqual(combined["native_targets"], ["check"])

    def test_admission_owners_keep_complete_debug_matrix(self):
        for path in ("src/server.zig", "tests/integration/admission_integration.sh"):
            result = select([path, "src/store.zig"], "review", AVAILABLE)
            self.assertIn("admission-debug-integration", result["targets"])
            self.assertIn("admission-debug-integration", result["native_targets"])

    def test_qualification_code_is_not_treated_as_stored_evidence(self):
        for path in ("tests/qualification/linux-memory/test_run.py",
                     "tests/qualification/linux-memory/malloc_probe.c"):
            result = select([path], "review", AVAILABLE)
            self.assertEqual(result["targets"], ["test-logic"])
            self.assertTrue(result["linux_memory_checks"])
            self.assertTrue(result["manual_checks"])
        result = select(["tests/qualification/transport-topology/measure.py"], "review", AVAILABLE)
        self.assertTrue(result["manual_checks"])
        self.assertFalse(result["linux_memory_checks"])
        self.assertEqual(select(["tests/qualification/linux-memory/results.json"], "review", AVAILABLE)["targets"], [])

    def test_setup_installs_only_selected_fixture_dependencies(self):
        self.assertEqual(setup_requirements(["test-logic"]), {"go": False, "h2": False})
        self.assertEqual(setup_requirements(["check-full"]), {"go": False, "h2": False})
        self.assertEqual(setup_requirements(["measurement-check"]), {"go": True, "h2": False})
        for target in ("transport-h2-integration", "codex-h2-integration"):
            self.assertEqual(setup_requirements([target, "measurement-check"]),
                             {"go": True, "h2": True})

    def test_batches_share_builds_but_isolate_timing_witnesses(self):
        targets = ["test", "dispatch-integration", "transport-h2-integration",
                   "test-full", "evaluator-churn", "admission-debug-integration",
                   "host-launch-integration", "check-full", "workflow-check",
                   "evaluator-host-integration"]
        self.assertEqual(execution_batches(targets), [
            ["workflow-check", "evaluator-host-integration"],
            ["test", "dispatch-integration"],
            ["transport-h2-integration"],
            ["test-full"], ["evaluator-churn"], ["admission-debug-integration"],
            ["host-launch-integration"], ["check-full"],
        ])
        self.assertEqual(execution_batches([]), [])

    def test_requested_ref_cannot_publish_shared_caches(self):
        workflow = Path('.github/workflows/qualify-macos.yml').read_text()
        # Dispatch may run on main while executing an unreviewed source SHA.
        # The server's scoped token, not requested-ref setup code, owns access.
        self.assertRegex(workflow, r'(?m)^cache-mode: read$')
        self.assertEqual(len(re.findall(r'(?m)^\s*cache-mode:', workflow)), 1,
                         'a job override could restore cache-write authority')

    def test_cache_proof_tracks_cache_policy_not_every_runtime_edit(self):
        for path in ("build.zig", ".github/actions/setup/action.yml", "tests/ci/cache_execution.py",
                     ".github/workflows/cache-maintenance.yml", ".github/workflows/qualify-macos.yml",
                     ".github/scripts/prune-caches.cjs"):
            self.assertTrue(select([path], "review", AVAILABLE)["cache_execution_checks"])
        self.assertFalse(select(["src/store.zig"], "review", AVAILABLE)["cache_execution_checks"])

    def test_cache_maintenance_preserves_unowned_and_current_caches(self):
        result = subprocess.run(["node", "--test", "tests/ci/cache_maintenance.test.cjs"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_isolated_full_check_parts_keep_other_selected_work_once(self):
        targets = ["admission-debug-integration", "check-full", "evaluator-churn", "test-full"]
        self.assertEqual(execution_batches(targets, "execution"),
                         [["check-full", "-Dcheck-part=execution"]])
        self.assertEqual(execution_batches(targets, "callers"), [
            ["admission-debug-integration"], ["check-full", "-Dcheck-part=callers"],
            ["evaluator-churn"], ["test-full"],
        ])
        with self.assertRaises(ValueError):
            execution_batches(["test-logic"], "execution")

    def test_unreachable_push_base_falls_back_without_hiding_review_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(
                    ["git", "-c", "user.name=Selector test", "-c", "user.email=test@example.invalid",
                     *args], cwd=directory, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-b", "main")
            root = Path(directory)
            (root / "build.zig").write_text(Path("build.zig").read_text())
            git("add", "build.zig")
            git("commit", "-m", "base")
            git("checkout", "-b", "candidate")
            (root / "src").mkdir()
            (root / "src/request_encoding.zig").write_text("// changed owner\n")
            git("add", ".")
            git("commit", "-m", "candidate")
            command = ["python3", str(Path("tests/ci/select_tests.py").resolve()),
                       "--base", "1" * 40, "--phase", "development"]
            missing = subprocess.run(command, cwd=directory, capture_output=True, text=True)
            self.assertNotEqual(missing.returncode, 0)
            for base in ("1" * 40, "0" * 40):
                command[command.index("--base") + 1] = base
                fallback = subprocess.run(command + ["--fallback-base", "main"],
                                          cwd=directory, capture_output=True, text=True)
                self.assertEqual(fallback.returncode, 0, fallback.stderr)
                selected = json.loads(fallback.stdout)
                self.assertEqual(selected["targets"], ["test-logic"])
                self.assertEqual(selected["base"], git("rev-parse", "main"))


class FullCheckPartitionTest(unittest.TestCase):
    def run_part(self, part, fail="", overlap=False, hold="", timing=False, clock_error=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Exercise the shell gate's public commands without launching product
            # fixtures. A controlled clock checks elapsed reporting, not speed.
            command = '''#!/bin/sh
if [ "$1" = - ]; then exec "$TEST_PYTHON" "$@"; fi
fixture=$(basename "${1:-$0}")
identity="$fixture.$2"
if [ "$fixture" = human_cli_integration.py ]; then
    test "$RUI_TEST_TERMINAL_NOTICE" = notice || exit 46
fi
if [ "$CHECK_TIMING" = 1 ]; then
    case "$fixture" in
        human_cli_integration.py|preference_policy_integration.py)
            touch "$GATE_DIR/$fixture.started"
            read -r release < "$GATE_DIR/$fixture.release"
            test "$release" = r || exit 45 ;;
    esac
fi
if [ "$CHECK_OVERLAP" = 1 ]; then
    touch "$GATE_DIR/$identity.started"
    if [ "$fixture" = human_cli_integration.py ]; then
        n=0
        while [ ! -e "$GATE_DIR/activity_integration.py.release.started" ]; do
            n=$((n + 1))
            if [ "$n" -ge 200 ]; then exit 43; fi
            sleep 0.01
        done
    fi
    case "$fixture:$2" in
        host_launch_integration.py:*|host_process_test.py:*|host_allocator_test.py:*|admission_integration.sh:debug)
            touch "$GATE_DIR/isolated.started"
            peers="human_cli_integration.py.release preference_policy_integration.py.preferences
                session_list_integration.py.release conversation_page_integration.py.release
                proposal_integration.py.release activity_integration.py.release
                host_status_integration.py.release host_stop_integration.py.release"
            if [ "$TEST_PART" = parallel ]; then
                peers="$peers native. admission_integration.sh.release dispatch_integration.py.release
                    bash_owner_integration.py.release bash_integration.py.release
                    bash_lifecycle_integration.py.release bash_recovery_integration.py.release
                    codex_integration.py.release control_integration.py.release
                    descriptor_capacity_integration.py.release"
            fi
            for peer in $peers; do
                if [ ! -e "$GATE_DIR/$peer.done" ]; then exit 44; fi
            done ;;
    esac
    if [ "$fixture" = "$HOLD_FIXTURE" ] && [ "$2" != debug ]; then
        read -r release < "$GATE_DIR/release"
        test "$release" = r || exit 45
    fi
    touch "$GATE_DIR/$identity.done"
fi
printf "%s %s\\n" "$fixture" "$2" >> "$GATE_DIR/invocations"
if [ "$fixture" = "$FAIL_FIXTURE" ]; then exit 42; fi
'''
            for name in ("python3", "sh", "native"):
                (root / name).write_text(command)
                (root / name).chmod(0o755)
            invocations = root / "invocations"
            invocations.touch()
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", FAIL_FIXTURE=fail,
                       CHECK_OVERLAP=str(int(overlap)), GATE_DIR=str(root), TEST_PYTHON=sys.executable,
                       HOLD_FIXTURE=hold, TEST_PART=part, CHECK_TIMING=str(int(timing)))
            if clock_error:
                (root / "sitecustomize.py").write_text(
                    "import sys, time\n"
                    "def fail_clock():\n    raise OSError('injected clock failure')\n"
                    f"if (len(sys.argv) == 1) == {clock_error == 'start'!r}:\n"
                    "    time.monotonic_ns = fail_clock\n")
                env["PYTHONPATH"] = str(root)
            arguments = (["parallel", str(root / "native"), "status", "sessions", "proposal", "activity", "preferences", "notice"]
                         if part == "parallel" else
                         ["status", "sessions", "proposal", "activity", "preferences", part, "notice"])
            command = [
                "/bin/sh", "tests/integration/check.sh", "release", "debug", *arguments,
            ]
            if timing:
                clock = root / "clock"
                clock.write_text("10000000000")
                (root / "sitecustomize.py").write_text(
                    "import os, time\nfrom pathlib import Path\n"
                    "time.monotonic_ns = lambda: int(Path(os.environ['GATE_DIR'], 'clock').read_text())\n")
                env.update(PYTHONPATH=str(root), TMPDIR=str(root))
                fixtures = ("human_cli_integration.py", "preference_policy_integration.py")
                releases = []
                process = None
                try:
                    for fixture in fixtures:
                        fifo = root / f"{fixture}.release"
                        os.mkfifo(fifo)
                        releases.append(os.open(fifo, os.O_RDWR | os.O_NONBLOCK))
                    process = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    deadline = time.monotonic() + 5
                    while not all((root / f"{fixture}.started").exists() for fixture in fixtures):
                        self.assertIsNone(process.poll())
                        self.assertLess(time.monotonic(), deadline, "both timed fixtures must start")
                        time.sleep(.005)
                    clock.with_suffix(".next").write_text("13000000000")
                    clock.with_suffix(".next").replace(clock)
                    os.write(releases[1], b"r\n")
                    # The later inventory entry must save its own elapsed time
                    # while the earlier entry still prevents batch printing.
                    deadline = time.monotonic() + 5
                    while not any(path.read_text().strip() for path in root.glob("rui-check.*/preference-policy.status")):
                        self.assertIsNone(process.poll())
                        self.assertLess(time.monotonic(), deadline, "completed peer must record timing before inventory wait")
                        time.sleep(.005)
                    clock.with_suffix(".next").write_text("30000000000")
                    clock.with_suffix(".next").replace(clock)
                finally:
                    for release in releases:
                        os.write(release, b"r\n")
                    try:
                        if process is not None:
                            stdout, stderr = process.communicate(timeout=10)
                    finally:
                        for release in releases:
                            os.close(release)
                result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
            elif hold:
                os.mkfifo(root / "release")
                # Own release before launch, including assertion-failure disposal.
                release = os.open(root / "release", os.O_RDWR | os.O_NONBLOCK)
                process = None
                try:
                    process = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    deadline = time.monotonic() + 3
                    while not list(root.glob(f"{hold}.*.started")):
                        self.assertIsNone(process.poll())
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(.005)
                    # The peer is explicitly held, not assumed slow. Give an
                    # incorrectly skipped wait a bounded chance to launch work.
                    deadline = time.monotonic() + .1
                    while time.monotonic() < deadline:
                        self.assertFalse((root / "isolated.started").exists())
                        time.sleep(.005)
                finally:
                    os.write(release, b"r\n")
                    try:
                        if process is not None:
                            stdout, stderr = process.communicate(timeout=10)
                    finally:
                        os.close(release)
                result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
            else:
                try:
                    result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
                except subprocess.TimeoutExpired as failure:
                    failure.add_note(f"part={part!r}, failing fixture={fail!r}, overlap={overlap!r}")
                    failure.add_note(f"completed invocations: {invocations.read_text()!r}")
                    failure.add_note(f"stdout: {failure.stdout!r}\nstderr: {failure.stderr!r}")
                    raise
            return result, invocations.read_text().splitlines()

    def records(self, result):
        return re.findall(r"^([a-z-]+) (?:passed|failed): exit=(\d+) elapsed=(\d+\.\d{3})s$",
                          result.stdout + result.stderr, re.MULTILINE)

    def test_elapsed_belongs_to_invocation_not_inventory_wait(self):
        for part in ("callers", "parallel"):
            for fail in ("", "preference_policy_integration.py"):
                with self.subTest(part=part, fail=fail):
                    result, _ = self.run_part(part, fail=fail, timing=True)
                    self.assertEqual(result.returncode, int(bool(fail)), result.stdout + result.stderr)
                    records = {name: (status, elapsed) for name, status, elapsed in self.records(result)}
                    self.assertEqual(records["preference-policy"], ("42" if fail else "0", "3.000"))
                    self.assertEqual(records["human-cli"], ("0", "20.000"))

    def test_parts_are_disjoint_and_cover_the_unchanged_full_gate(self):
        expected = {
            "admission_integration.sh release", "dispatch_integration.py release",
            "bash_owner_integration.py release", "bash_integration.py release",
            "human_cli_integration.py release", "preference_policy_integration.py preferences",
            "bash_lifecycle_integration.py release", "bash_recovery_integration.py release",
            "codex_integration.py release", "control_integration.py release",
            "session_list_integration.py release", "conversation_page_integration.py release",
            "proposal_integration.py release", "activity_integration.py release",
            "descriptor_capacity_integration.py release", "host_status_integration.py release",
            "host_launch_integration.py release", "host_stop_integration.py release",
            "admission_integration.sh debug", "host_process_test.py ",
            "host_allocator_test.py release",
        }
        outputs = {}
        for part in ("all", "execution", "callers", "parallel"):
            result, lines = self.run_part(part)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(lines), len(set(lines)), lines)
            records = self.records(result)
            self.assertEqual(len(records), len(lines), result.stdout + result.stderr)
            self.assertEqual(len({name for name, _, _ in records}), len(lines))
            self.assertTrue(all(status == "0" for _, status, _ in records))
            outputs[part] = set(lines)
        self.assertEqual(outputs["all"], expected)
        # The ordinary driver also owns the native binary; the full gate runs
        # that binary in the build graph instead. Every process case is shared.
        self.assertEqual(outputs["parallel"], expected | {"native "})
        self.assertEqual(outputs["execution"] & outputs["callers"], set())
        self.assertEqual(outputs["execution"] | outputs["callers"], expected)
        self.assertIn("dispatch_integration.py release", outputs["execution"])
        self.assertIn("human_cli_integration.py release", outputs["callers"])

    def test_callers_overlap_private_fixtures_then_drain_before_deadline_cases(self):
        for part in ("callers", "parallel"):
            result, _ = self.run_part(part, overlap=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_parallel_gate_drains_native_and_execution_peers(self):
        for peer in ("native", "admission_integration.sh", "dispatch_integration.py",
                     "bash_owner_integration.py", "bash_integration.py",
                     "bash_lifecycle_integration.py", "bash_recovery_integration.py",
                     "codex_integration.py", "control_integration.py", "descriptor_capacity_integration.py"):
            with self.subTest(peer=peer):
                result, _ = self.run_part("parallel", overlap=True, hold=peer)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failure_or_invalid_part_cannot_report_success(self):
        complete = {}
        for part in ("callers", "parallel"):
            result, lines = self.run_part(part)
            self.assertEqual(result.returncode, 0)
            complete[part] = set(lines)
        for fixture in ("human_cli_integration.py", "preference_policy_integration.py",
                        "session_list_integration.py", "conversation_page_integration.py",
                        "proposal_integration.py", "activity_integration.py",
                        "host_status_integration.py", "host_stop_integration.py",
                        "host_launch_integration.py", "host_process_test.py",
                        "host_allocator_test.py", "admission_integration.sh"):
            for part in ("callers", "parallel", "all"):
                result, lines = self.run_part(part, fixture)
                self.assertEqual(result.returncode, 42 if part == "all" else 1, (part, fixture))
                records = self.records(result)
                self.assertEqual(len(records), len(lines), result.stdout + result.stderr)
                self.assertIn("42", [status for _, status, _ in records])
                if part == "all":
                    self.assertEqual(lines[-1].split()[0], fixture)
                else:
                    self.assertEqual(set(lines), complete[part])
        for part in ("execution", "parallel", "all"):
            result, _ = self.run_part(part, "dispatch_integration.py")
            self.assertNotEqual(result.returncode, 0, part)
        result, _ = self.run_part("parallel", "native")
        self.assertNotEqual(result.returncode, 0)
        result, lines = self.run_part("not-a-part")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(lines, [])
        self.assertEqual(self.records(result), [])

    def test_failure_still_drains_a_held_peer_before_isolated_cases(self):
        for part in ("callers", "parallel"):
            result, _ = self.run_part(part, fail="preference_policy_integration.py",
                                      overlap=True, hold="host_stop_integration.py")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            records = {name: status for name, status, _ in self.records(result)}
            self.assertEqual(records["preference-policy"], "42")
            self.assertEqual(records["host-stop"], "0")
            self.assertEqual(records["host-launch"], "0")

    def test_clock_failure_preserves_fixture_results(self):
        for clock_error in ("start", "finish"):
            for part in ("all", "execution", "callers", "parallel"):
                fixture = "dispatch_integration.py" if part == "execution" else "preference_policy_integration.py"
                failures = ("", fixture, "host_launch_integration.py") if part in ("callers", "parallel") else ("", fixture)
                for fail in failures:
                    with self.subTest(clock_error=clock_error, part=part, fail=fail):
                        result, lines = self.run_part(part, fail=fail, clock_error=clock_error)
                        expected = (42 if part in ("all", "execution") else 1) if fail else 0
                        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                        records = re.findall(r"^([a-z-]+) (?:passed|failed): exit=(\d+) elapsed=unavailable$",
                                             result.stdout + result.stderr, re.MULTILINE)
                        self.assertEqual(len(records), len(lines), result.stdout + result.stderr)
                        self.assertEqual({status for _, status in records}, {"0", "42"} if fail else {"0"})


if __name__ == "__main__":
    unittest.main()

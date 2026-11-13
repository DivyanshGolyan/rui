"""Upgrade grammar detection must follow installed help, not checkout layout."""
from contextlib import ExitStack, redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/integration"))
# model_fixture takes the binary argument at import time.
with patch.object(sys, "argv", [__file__, "rui"]):
    import previous_release_upgrade as upgrade


class DialectTest(unittest.TestCase):
    def test_installed_grammars(self):
        # Usage spellings from the pinned 0e4b222 release and resource-first CLIs.
        legacy = "rui message --store PATH --record FILE --key KEY --session REF --text FILE|-\n"
        for name, send, start, pause, expected in (
            ("previous", None, False, False, (False, False, False, False)),
            ("address", "rui session send [--to ADDRESS] [--text FILE|-]\n",
             False, False, (True, True, False, False)),
            ("short IDs before pause", "rui session send [--to ID]\n",
             True, False, (True, False, True, True)),
            ("settings document only", "rui session send [--to ID]\n",
             True, True, (True, False, True, True)),
            ("candidate", "rui session send [--to ID]\n",
             True, True, (True, False, True, True)),
        ):
            for refused in (1, 2):
                with self.subTest(name=name, refused=refused):
                    binary = Path("/installed/without/checkout/rui")
                    replies = {(): legacy}
                    if send is not None:
                        replies.update({("request", "inspect"): "rui request inspect [HANDLE]\n",
                                        ("session", "send"): send})
                    if name == "settings document only":
                        replies[("host", "serve")] = "rui host serve [--settings FILE|-]\n"
                    if name == "candidate":
                        replies[("host", "serve")] = "rui host serve [--set PATH=VALUE]\n"
                    if start:
                        replies[("session", "start")] = "rui session start [--store PATH]\n"
                    if pause:
                        replies[("host", "pause")] = "rui host pause [--store PATH]\n"

                    def run(argv, **kwargs):
                        self.assertEqual(argv[0], binary)
                        self.assertEqual(argv[-1], "--help")
                        self.assertEqual(kwargs, dict(input="", capture_output=True, text=True, timeout=5))
                        command = tuple(argv[1:-1])
                        # Legacy usage errors may print the entire global help;
                        # only successful help identifies an installed operation.
                        return subprocess.CompletedProcess(argv, 0 if command in replies else refused,
                                                           replies.get(command, legacy), "")

                    with patch.object(upgrade.subprocess, "run", side_effect=run):
                        dialect = upgrade.Dialect(binary)
                    self.assertEqual((dialect.resource_first, dialect.address_send,
                                      dialect.short_ids, dialect.stdin_message), expected)
                    self.assertEqual(dialect.host_settings, name == "candidate")
                    self.assertEqual(dialect.pause, ("host", "pause" if pause else "stop"))
                    self.assertEqual(dialect.serve(), ("host", "serve") if send else ("serve",))
                    with patch.object(upgrade.fixture, "command", return_value={
                        "answer": {"status": "accepted", "session": "k7m2qx"},
                    }) as command:
                        session = dialect.configure(Path("/state"), Path("/store"), "key",
                                                    "upgrade/session", "model")
                    self.assertEqual(session, "k7m2qx" if dialect.short_ids else "upgrade/session")
                    self.assertEqual("--session" in command.call_args.args, not dialect.short_ids)

    def test_unexpected_probe_failure_is_not_an_old_dialect(self):
        for status in (-11, 6):
            with self.subTest(status=status), patch.object(upgrade.subprocess, "run", return_value=
                    subprocess.CompletedProcess([], status, "", "environment failure")):
                with self.assertRaises(AssertionError):
                    upgrade.Dialect(Path("/installed/rui"))

    def test_missing_help_is_not_an_old_dialect(self):
        with patch.object(upgrade.subprocess, "run", return_value=subprocess.CompletedProcess([], 2, "", "")):
            with self.assertRaisesRegex(AssertionError, "No command help"):
                upgrade.Dialect(Path("/installed/rui"))

    def test_upgrade_compares_bindings_in_each_installed_reply(self):
        identity = {"turn": "1", "operation": "2", "attempt": "1"}
        # CLI grammar is probed from installed help; observation shape comes
        # from each reply, never a checkout's protocol source.
        dialect = upgrade.Dialect.__new__(upgrade.Dialect)
        self.assertEqual(dialect.binding({"state": "processing", "binding": identity}), identity)
        self.assertEqual(dialect.binding({"state": "completed", "binding": identity}), identity)
        self.assertTrue(dialect.terminal({"state": "completed"}))
        self.assertFalse(dialect.terminal({"state": "processing", "result": {"status": "completed"}}))
        self.assertEqual(dialect.binding({"processing": identity}), identity)
        self.assertTrue(dialect.terminal({"result": {"status": "completed"}}))
        self.assertFalse(dialect.terminal({"processing": identity}))
        self.assertTrue(dialect.terminal({"state": "cancelled", "result": {"status": "cancelled"}}))


class SupportedRangeTest(unittest.TestCase):
    def test_range_comes_from_target_migrations_not_version_punctuation(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            source = checkout / "src/store/schema.zig"
            source.parent.mkdir(parents=True)
            source.write_text("pub const schema_version: u32 = 56;\n"
                              "pub const migration_baseline: u32 = 51;\n")
            self.assertEqual(upgrade.supported_range(checkout), (51, 56))
            source.write_text("pub const schema_version: u32 = 40;\n")
            self.assertEqual(upgrade.supported_range(checkout), (40, 40))
            source.unlink()
            (checkout / "src/store.zig").write_text("pub const schema_version: u32 = 37;\n")
            self.assertEqual(upgrade.supported_range(checkout), (37, 37))

    def test_historical_source_build_uses_current_native_publisher_not_old_installer(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve()
            library = home / ".local/lib/rui"
            library.mkdir(parents=True)
            command = home / ".local/bin/rui"
            command.parent.mkdir()
            command.write_bytes(b"historical fixture artifact")
            with patch.dict(upgrade.os.environ, {"HOME": str(home)}), \
                 patch.object(upgrade.subprocess, "check_output", return_value="pinned-sha\n"), \
                 patch.object(upgrade.subprocess, "run") as run:
                upgrade.install(Path("/historical-checkout"), Path("/current-native-rui"))
            calls = [call.args[0] for call in run.call_args_list]
            self.assertEqual(calls[0][:4], ["zig", "build", "-Doptimize=ReleaseSafe", "--prefix"])
            self.assertEqual(calls[1], [Path("/current-native-rui"), "--publish-install", str(home),
                                       calls[0][4], "intentional-source"])
            self.assertFalse(any("install.sh" in str(argument) for call in calls for argument in call))


class RunningUpgradeTest(unittest.TestCase):
    def check_activation(self, *, status="ready", instance="candidate-instance", store="/store",
                         pid=12, executable=Path("/candidate/bin/rui"), version="0.69.10000",
                         output="/store: restarted on 0.69.10000\n", retired=True):
        binary = Path("/candidate/bin/rui")
        previous = {"store": "/store", "instance": "previous-instance"}
        dialect = Mock()
        dialect.host_status.return_value = status, json.dumps({
            "store": store, "instance": instance,
        })
        seed = SimpleNamespace(pid=11, poll=lambda: 1 if retired else None)

        def wait(predicate, description, **kwargs):
            self.assertTrue(predicate(), description)
            self.assertEqual(kwargs, {"timeout": 10})

        with ExitStack() as stack:
            stack.enter_context(redirect_stdout(io.StringIO()))
            stack.enter_context(patch.object(upgrade.os_semantics, "unix_stream"))
            stack.enter_context(patch.object(upgrade.os_semantics, "socket_peer_pid", return_value=pid))
            stack.enter_context(patch.object(upgrade.os_semantics, "process_executable", return_value=executable))
            stack.enter_context(patch.object(upgrade, "release_version", return_value=version))
            stack.enter_context(patch.object(upgrade, "wait_for", side_effect=wait))
            # Activation evidence may never start or repair the Host itself.
            stack.enter_context(patch.object(upgrade.subprocess, "run", side_effect=AssertionError("no explicit restart")))
            upgrade.assert_running_upgrade(dialect, binary, Path("/store"), seed,
                {"socket": "/host.sock"}, previous, "0.69.10000", output)
        dialect.host_status.assert_called_once_with(binary, Path("/store"), 5)

    def test_candidate_instance_image_version_and_restart_report(self):
        self.check_activation()

    def test_rejects_installer_leaving_previous_instance_running(self):
        with self.assertRaisesRegex(AssertionError, "left the old Host running"):
            self.check_activation(instance="previous-instance")

    def test_rejects_incomplete_or_misdirected_activation(self):
        for changes in (
            {"status": "unavailable"}, {"store": "/another-store"}, {"pid": 11},
            {"executable": Path("/previous/bin/rui")}, {"version": "0.69.1"},
            {"output": "Installed Rui; no restart performed"}, {"retired": False},
        ):
            with self.subTest(changes=changes), self.assertRaises(AssertionError):
                self.check_activation(**changes)

    def test_running_host_does_not_use_unrestartable_hidden_test_flags(self):
        dialect = upgrade.Dialect.__new__(upgrade.Dialect)
        dialect.resource_first = True
        dialect.host_settings = False
        dialect.binary = Path("/previous/bin/rui")
        with patch.object(upgrade.fixture, "RUI", Path("/previous/bin/rui")):
            args = dialect.host_arguments(Path("/store"), "http://127.0.0.1/responses", retry_waits=False)
        self.assertEqual(args, ["/previous/bin/rui", "host", "serve", "--store", "/store",
                               "--active-capacity", "1", "--provider-endpoint", "http://127.0.0.1/responses"])

    def test_candidate_host_uses_generic_settings_without_hidden_restart_flags(self):
        dialect = upgrade.Dialect.__new__(upgrade.Dialect)
        dialect.resource_first = True
        dialect.host_settings = True
        dialect.binary = Path("/candidate/bin/rui")
        with patch.object(upgrade.fixture, "RUI", Path("/candidate/bin/rui")):
            args = dialect.host_arguments(Path("/store"), "http://127.0.0.1/responses", retry_waits=False)
        self.assertEqual(args, ["/candidate/bin/rui", "host", "serve", "--store", "/store",
                               "--set", "execution.activeCapacity=1", "--set", "providers={}",
                               "--set", "providers.codex.endpoint=http://127.0.0.1/responses",
                               "--set", "providers.codex.unauthenticated=true"])

    def test_resource_diagnostics_keep_the_baseline_executable_and_grammar(self):
        for modern in (False, True):
            dialect = upgrade.Dialect.__new__(upgrade.Dialect)
            dialect.binary = Path("/historical/bin/rui")
            dialect.resource_first = modern
            dialect.host_settings = modern
            with patch.object(upgrade.fixture, "RUI", Path("/candidate/bin/rui")):
                args = dialect.host_arguments(Path("/store"))
            self.assertEqual(args[:4] if not modern else args[:5],
                             ["/historical/bin/rui", "serve", "--store", "/store"] if not modern else
                             ["/historical/bin/rui", "host", "serve", "--store", "/store"])
            self.assertEqual(args[-4:] if modern else args[-2:],
                             ["--set", "execution.activeCapacity=1", "--set", "providers={}"] if modern else
                             ["--active-capacity", "1"])
            self.assertNotIn("--test-retry-waits-ms", args)

    def test_release_installer_uses_real_template_and_local_archive_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            binary = root / "native-actor"
            binary.write_bytes(b"archive construction fixture, never executed")
            with patch.object(upgrade, "release_version", return_value="0.69.10000"), \
                 patch.object(upgrade.subprocess, "run", return_value=subprocess.CompletedProcess(
                     [], 0, "installer transcript", "")) as run:
                _, output = upgrade.install_candidate_release(ROOT, binary, root)
            self.assertEqual(output, "installer transcript")
            script = (root / "install.sh").read_text()
            self.assertNotIn("@PUBLISH@", script)
            self.assertNotIn("@VERSION@", script)
            self.assertIn('"$prefix/bin/rui" host restart --all', script)
            self.assertIn("actual=$(digest", script)
            command = run.call_args
            self.assertEqual(command.args[0], ["sh", root / "install.sh"])
            self.assertEqual(command.kwargs["timeout"], 60)
            env = command.kwargs["env"]
            self.assertTrue(env["RUI_UPGRADE_LOCAL_ARCHIVE"].startswith("file://"))
            self.assertEqual(env["RUI_NO_MODIFY_PATH"], "1")

    def test_release_installer_nonzero_exit_is_not_masked_by_transcript(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            binary = root / "native-actor"
            binary.write_bytes(b"not executed")
            with patch.object(upgrade, "release_version", return_value="0.69.10000"), \
                 patch.object(upgrade.subprocess, "run", return_value=subprocess.CompletedProcess(
                     [], 1, "/store: restarted on 0.69.10000", "")), \
                 self.assertRaises(AssertionError):
                upgrade.install_candidate_release(ROOT, binary, root)


if __name__ == "__main__":
    unittest.main()

"""Upgrade grammar detection must follow installed help, not checkout layout."""
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

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


if __name__ == "__main__":
    unittest.main()

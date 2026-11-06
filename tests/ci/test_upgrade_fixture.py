"""A teardown failure cannot turn native Upgrade qualification green."""
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
import upgrade_integration as upgrade


class TmuxDisposalTest(unittest.TestCase):
    def result(self, code=0, out="", err=""):
        return subprocess.CompletedProcess([], code, out, err)

    def stop(self, replies):
        with patch.object(upgrade.subprocess, "run", side_effect=replies) as run:
            upgrade.stop_tmux(["tmux", "-S", "/fixture/owned.sock"], {"HOME": "/fixture"}, 123)
        self.assertEqual(run.call_args_list[0].args[0][-1], "kill-server")
        self.assertEqual(run.call_args_list[1].args[0], ["ps", "-p", "123", "-o", "stat="])

    def test_failed_kill_of_live_server_is_not_silently_accepted(self):
        replies = [self.result(9, err="injected teardown failure"), self.result(out="S\n")]
        with patch.object(upgrade.subprocess, "run", side_effect=replies), \
                self.assertRaisesRegex(AssertionError, "kill-server failed with a live server"):
            upgrade.stop_tmux(["tmux", "-S", "/fixture/owned.sock"], {}, 123)

    def test_failed_kill_accepts_only_independently_confirmed_absence(self):
        self.stop([self.result(1, err="no server running"), self.result(1)])
        self.stop([self.result(1, err="no server running"), self.result(out="Z\n")])
        with self.assertRaisesRegex(AssertionError, "server census failed"):
            self.stop([self.result(1, err="no server running"), self.result(2, err="inspection denied")])

    def test_successful_kill_also_confirms_server_retirement(self):
        self.stop([self.result(), self.result(1)])

    def test_cleanup_does_not_replace_body_failure(self):
        failure = RuntimeError("original fixture body failure")
        with self.assertRaises(RuntimeError) as raised:
            try:
                raise failure
            finally:
                upgrade.dispose_all(lambda: self.stop([
                    self.result(9, err="injected teardown failure"), self.result(out="S\n")]))
        self.assertIs(raised.exception, failure)
        self.assertTrue(any("kill-server failed with a live server" in note for note in failure.__notes__))

    def test_unobserved_server_identity_remains_unconfirmed(self):
        with patch.object(upgrade.subprocess, "run", return_value=self.result()), \
                self.assertRaisesRegex(AssertionError, "identity was not observed"):
            upgrade.stop_tmux(["tmux", "-S", "/fixture/owned.sock"], {}, None)


if __name__ == "__main__":
    unittest.main()

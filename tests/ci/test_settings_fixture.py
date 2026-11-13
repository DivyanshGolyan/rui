"""The settings fixture compares decoded failures without losing stderr framing."""
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
import settings_fixture  # noqa: E402


class SettingsRefusalTest(unittest.TestCase):
    @staticmethod
    def streams(message, escaped, code="settings_invalid"):
        failure = {"code": code, "message": message}
        out = json.dumps({"rui_start_error": failure}, ensure_ascii=False).encode() + b"\n"
        err = b"rui: the Host did not start: " + escaped + b" [" + code.encode() + b"]\n"
        return failure, out, err

    def check_refusal(self, message, escaped):
        failure, out, err = self.streams(message, escaped)
        with patch.object(settings_fixture, "output", return_value=(out, err)):
            self.assertEqual(failure, settings_fixture.refusal(SimpleNamespace(returncode=1)))

    def test_raw_and_literal_escape_sequences_stay_distinct(self):
        for message, escaped in (("plain message", b"plain message"),
                                 ("line\nbreak", rb"line\nbreak"),
                                 (r"line\nbreak", rb"line\\nbreak"),
                                 ("\x1b", rb"\x1b"),
                                 (r"\x1b", rb"\\x1b")):
            with self.subTest(message=message):
                self.check_refusal(message, escaped)

    def test_controls_quotes_backslash_and_unicode_round_trip_as_bytes(self):
        for message, escaped in (("\r\t\x00\x1b\x7f", rb"\r\t\x00\x1b\x7f"),
                                 ('"\\', rb'\"\\'),
                                 ("\u0085\u2028\u2029\ufeff", rb"\xc2\x85\xe2\x80\xa8\xe2\x80\xa9\xef\xbb\xbf"),
                                 ("😎\u2028", b"\xf0\x9f\x98\x8e" + rb"\xe2\x80\xa8")):
            with self.subTest(message=message):
                self.check_refusal(message, escaped)

    def test_stderr_requires_one_physical_line_its_code_and_matching_message(self):
        _, out, err = self.streams("message", b"message")
        for bad in (err.rstrip(b"\n"), err + b"\n", err.replace(b"message", b"line\nbreak"),
                    err.replace(b"settings_invalid", b"mysql_login"),
                    err.replace(b"message", b"different"), err.replace(b"rui:", b"other:")):
            with self.subTest(stderr=bad), patch.object(settings_fixture, "output", return_value=(out, bad)):
                with self.assertRaises(AssertionError):
                    settings_fixture.refusal(SimpleNamespace(returncode=1))

    def test_stdout_requires_one_terminal_line_feed(self):
        _, out, err = self.streams("message", b"message")
        for bad in (out.rstrip(b"\n"), out + b"\n"):
            with self.subTest(stdout=bad), patch.object(settings_fixture, "output", return_value=(bad, err)):
                with self.assertRaises(AssertionError):
                    settings_fixture.refusal(SimpleNamespace(returncode=1))

    def test_forbidden_values_are_rejected_in_either_stream(self):
        for message in ("never-print-this-value", "message"):
            _, out, err = self.streams(message, message.encode())
            if message == "message":
                out = out.replace(b'"code":', b'"unrelated": "never-print-this-value", "code":')
            with self.subTest(message=message), patch.object(settings_fixture, "output", return_value=(out, err)):
                with self.assertRaises(AssertionError):
                    settings_fixture.refusal(SimpleNamespace(returncode=1), forbidden=("never-print-this-value",))

    def test_failure_exit_status_is_required(self):
        _, out, err = self.streams("message", b"message")
        with patch.object(settings_fixture, "output", return_value=(out, err)):
            with self.assertRaises(AssertionError):
                settings_fixture.refusal(SimpleNamespace(returncode=0))


if __name__ == "__main__":
    unittest.main()

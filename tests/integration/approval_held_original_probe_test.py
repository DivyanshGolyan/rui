"""Python-only controls for held-original result classification; no native run."""

import pathlib
import struct
import tempfile
import unittest
from unittest import mock

import approval_held_original_probe as probe


class HeldOriginalProbeTest(unittest.TestCase):
    root = pathlib.Path("/private/tmp/owned-test-root")
    socket = pathlib.Path("/tmp/rui-502/registered-owned.sock")
    key = "12345678-1234-4234-8234-123456789abc"

    def log(self, case="accepted", approval="held", offered="false", complete=True):
        result = (f"HELD-WIRE-SETUP store={self.root} socket={self.socket}\n"
                  f"HELD-WIRE-DELIVERED session=k7m2qx action=10 key={self.key} "
                  f"task_live=true wire=exact peer=held approval={approval} offered={offered}\n")
        if complete:
            count, retry = (2, "true") if case == "retry" else (1, "false")
            result += f"HELD-ORIGINAL fixture-only Message requests={count} explicit_retry={retry} decision=10:allow_once count=1\n"
        return result

    def classify(self, text, status=0, flags=0, case="accepted"):
        return probe.classify(case, status, text, self.root, self.socket, flags)

    def test_positive_requires_full_native_result_and_matching_case(self):
        for case in probe.CASES:
            result = self.classify(self.log(case), case=case)
            self.assertTrue(result["native_test_pass"])
            self.assertFalse(result["host_accepted"])
            self.assertFalse(result["red_control_observed"])
        for flags in (None, 1, 2, 4, 8, 1 << 33):
            self.assertFalse(self.classify(self.log(), flags=flags)["native_test_pass"])
        for status in (-6, -9, 1):
            self.assertFalse(self.classify(self.log(), status=status)["native_test_pass"])
        self.assertFalse(self.classify(self.log("accepted"), case="retry")["native_test_pass"])
        self.assertFalse(self.classify(self.log().replace(str(self.root), "/tmp/other"))["native_test_pass"])
        self.assertFalse(self.classify(self.log().replace("decision=10:allow_once", "decision=11:allow_once"))["native_test_pass"])
        self.assertFalse(self.classify(self.log().replace("approval=held", "approval=choice"))["native_test_pass"])
        self.assertFalse(self.classify(self.log(complete=False))["native_test_pass"])

    def test_omission_requires_clean_behavior_failure_not_arbitrary_crash(self):
        text = self.log(approval="choice", offered="true", complete=False)
        text += "try std.testing.expect(screen.offered() == null);\n"
        result = self.classify(text, flags=1)
        self.assertTrue(result["red_control_observed"])
        self.assertFalse(result["native_test_pass"])
        for status, flags in ((-6, None), (-9, None), (0, 0), (0, 2), (0, 5), (0, 1 | (1 << 33))):
            self.assertFalse(self.classify(text, status=status, flags=flags)["red_control_observed"])
        self.assertFalse(self.classify(text.replace("screen.offered() == null", "unrelated assertion"), flags=1)["red_control_observed"])
        self.assertFalse(self.classify(text.replace("approval=choice", "approval=held"), flags=1)["red_control_observed"])
        self.assertFalse(self.classify(text.replace("peer=held", "peer=answered"), flags=1)["red_control_observed"])

    def test_results_require_exact_sequence_and_selected_index(self):
        def wire(flags, index=7):
            frames = [(0, b"0.17.0"), (3, b"metadata"), (5, b""), (4, struct.pack("<IQ", index, flags))]
            return b"".join(struct.pack("<II", tag, len(body)) + body for tag, body in frames)
        for flags in (0, 1, 2, 1 << 33):
            self.assertEqual(probe.test_result(wire(flags), {"index": 7}), flags)
        for data in (wire(0, index=8), wire(0)[:-1], wire(0) + b"x", b"", wire(0)[14:]):
            with self.assertRaises(ValueError):
                probe.test_result(data, {"index": 7})

    def test_exact_names_and_cleanup_are_not_caller_labels(self):
        expected = {
            "accepted": "SessionFrontend.test.held original wire blocks confirmation until Message joins",
            "retry": "SessionFrontend.test.held original wire retains unconfirmed Message until explicit same-key retry joins",
        }
        for case, name in expected.items():
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                evidence = pathlib.Path(directory)
                def fake_run(*args):
                    self.assertEqual(probe.owner.FULL_TEST_NAME, name)
                    return {"classification": "pass", "native_test_pass": True, "red_control_observed": False, "cleanup": "failed"}
                original_name = probe.owner.FULL_TEST_NAME
                with mock.patch.object(probe.owner, "run", side_effect=fake_run):
                    result = probe.run(pathlib.Path("unused"), evidence, 1, "0" * 64, case)
                self.assertEqual(result["classification"], "inconclusive")
                self.assertFalse(result["native_test_pass"])
                self.assertEqual(probe.owner.FULL_TEST_NAME, original_name)

    def test_changed_custody_owner_refused_before_launch(self):
        with mock.patch.object(probe, "OWNER_SHA256", "0" * 64), mock.patch.object(probe.owner, "run") as launch:
            with self.assertRaisesRegex(ValueError, "frozen source"):
                probe.run(pathlib.Path("unused"), pathlib.Path("unused"), 1, "0" * 64, "accepted")
            launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()

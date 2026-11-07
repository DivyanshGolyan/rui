"""CLI compatibility checks for the isolated native renderer helper."""

from contextlib import redirect_stderr, redirect_stdout
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
LOADER = SourceFileLoader("verify_rui", str(ROOT / ".claude/skills/verify-rui/scripts/verify-rui"))
HELPER = module_from_spec(spec_from_loader(LOADER.name, LOADER))
LOADER.exec_module(HELPER)


def receipt(session):
    return {"context": {"session": session, "key": f"key-{session}", "kind": "message"},
            "answer": {"status": "accepted", "session": session, "replayed": False}}


class SessionStartReceiptTest(unittest.TestCase):
    def test_reads_context_not_answer_or_configuration(self):
        value = receipt("k7m2qx")
        value["answer"]["session"] = "not-the-authority"
        value["configuration"] = {"model": "fixture"}
        self.assertEqual(HELPER.session_start_id(json.dumps(value) + "\n"), "k7m2qx")

    def test_rejects_bare_ids_malformed_and_unaccepted_receipts(self):
        bad = ["k7m2qx", '"k7m2qx"', "null", "[]", "{}", '{"context":null}',
               json.dumps({"session": "k7m2qx", "answer": {"status": "accepted"}})]
        for session in (None, 7, {}, [], "", " ", " k7m2qx"):
            bad.append(json.dumps(receipt(session)))
        for status in ("rejected", "conflict", None):
            value = receipt("k7m2qx")
            value["answer"]["status"] = status
            bad.append(json.dumps(value))
        value = receipt("k7m2qx")
        value["error"] = {"certainty": "unconfirmed"}
        bad.append(json.dumps(value))
        for stdout in bad:
            with self.subTest(stdout=stdout), redirect_stderr(io.StringIO()) as errors:
                with self.assertRaises(SystemExit) as raised:
                    HELPER.session_start_id(stdout)
                self.assertEqual(raised.exception.code, 2)
                self.assertIn("invalid session start receipt", errors.getvalue())

    def test_new_seed_uses_receipt_session_ids_without_metadata_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / "source"
            source.mkdir()
            calls = []

            def fixture(*args, **kwargs):
                (next((base / "scratch").glob("vr.*")) / "fixture.port").write_text("12345")
                return SimpleNamespace(pid=123, poll=lambda: None)

            def rui_cmd(run, *argv, **kwargs):
                calls.append((argv, kwargs))
                session = {"demo": "k7m2qx", "approve": "n176x8"}[argv[-1]] if argv[:2] == ("session", "start") else "k7m2qx"
                return subprocess.CompletedProcess(argv, 0, json.dumps(receipt(session)), f"request: key-{session}\n")

            build = {"tree": "tree", "binary": "/unused/rui", "files_sha256": {"rui": "hash"}, "source": str(source)}
            fake_codex = SimpleNamespace(credentials=lambda path: path.write_text("synthetic"))
            (base / "scratch").mkdir()
            args = SimpleNamespace(sha="a" * 40, label="receipt-test", seed=1, no_sessions=False,
                                   active_capacity=2, host_setenv=[])
            original_argv, original_path = sys.argv[:], sys.path[:]
            try:
                with patch.object(HELPER, "CACHE", base / "cache"), \
                     patch.object(HELPER, "SCRATCH_PARENT", base / "scratch"), \
                     patch.object(HELPER, "load_build", return_value=build), \
                     patch.dict(sys.modules, {"codex_integration": fake_codex}), \
                     patch.object(HELPER.subprocess, "Popen", side_effect=fixture), \
                     patch.object(HELPER.Run, "own"), \
                     patch.object(HELPER.Run, "rui_cmd", new=rui_cmd), \
                     patch.object(HELPER, "launch_host", return_value=SimpleNamespace(stdout='{"instance":"owned"}')), \
                     patch.object(HELPER, "wait_request") as waited, redirect_stdout(io.StringIO()) as output:
                    HELPER.cmd_new(args)
                meta = json.loads((Path(output.getvalue().strip()) / "run.json").read_text())
                self.assertEqual(meta["sessions"], {"demo": "k7m2qx", "approve": "n176x8"})
                seed = [call for call in calls if call[0][:2] == ("session", "send")]
                self.assertEqual(len(seed), 1)
                self.assertEqual(seed[0][0][-2:], ("--to", "k7m2qx"))
                self.assertEqual(seed[0][1]["input"], "Seed history message 1: " + "lorem ipsum dolor sit amet " * 12)
                self.assertEqual([call.args[1] for call in waited.call_args_list],
                                 ["key-k7m2qx", "key-n176x8", "key-k7m2qx"])
            finally:
                sys.argv[:], sys.path[:] = original_argv, original_path


class EvidenceSelectorTest(unittest.TestCase):
    def test_exports_use_explicit_session_selector_and_preserve_cli_failures(self):
        for inspect_rc in (0, 2):
            with self.subTest(inspect_rc=inspect_rc), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "evidence").mkdir()
                meta = {"sha": "a" * 40, "scratch": str(root / "scratch"), "home": str(root / "home"),
                        "store": str(root / "store"), "project": str(root / "project"), "binary": "/unused/rui",
                        "sessions": {"demo": "k7m2qx", "approve": "n176x8"}}
                (root / "run.json").write_text(json.dumps(meta))
                calls = []

                def rui_cmd(run, *argv, **kwargs):
                    calls.append(argv)
                    if argv[:2] == ("session", "inspect"):
                        return subprocess.CompletedProcess(argv, inspect_rc, '{"session":"exact-output"}\n',
                                                           "selector failed\n" if inspect_rc else "")
                    return subprocess.CompletedProcess(argv, 0, "[]", "")

                with patch.object(HELPER.Run, "rui_cmd", new=rui_cmd), redirect_stdout(io.StringIO()):
                    HELPER.cmd_evidence(SimpleNamespace(run=root))
                inspects = [call for call in calls if call[:2] == ("session", "inspect")]
                self.assertEqual(inspects, [
                    ("session", "inspect", "--store", root / "store", "--session", session, "--profile", "full")
                    for session in ("k7m2qx", "n176x8")])
                summary = json.loads((root / "evidence/summary.json").read_text())
                for name in ("demo-inspect", "approve-inspect"):
                    self.assertEqual(summary["exports_rc"][name], inspect_rc)
                    self.assertEqual((root / f"evidence/export/{name}.json").read_text(), '{"session":"exact-output"}\n')
                    if inspect_rc:
                        self.assertEqual((root / f"evidence/export/{name}.stderr").read_text(), "selector failed\n")


if __name__ == "__main__":
    unittest.main()

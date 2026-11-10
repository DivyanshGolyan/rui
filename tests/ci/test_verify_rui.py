import contextlib
import io
import json
from pathlib import Path
import runpy
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).parents[2] / ".claude/skills/verify-rui/scripts/verify-rui"


class VerifyRuiTest(unittest.TestCase):
    def test_new_sends_seed_to_session_id_from_start_response(self):
        module = runpy.run_path(str(SCRIPT))
        new = module["cmd_new"]
        run_type = module["Run"]
        sent_to = []

        def rui_cmd(_run, *args, **_kwargs):
            if args[:2] == ("session", "start"):
                return types.SimpleNamespace(returncode=0, stdout=json.dumps({
                    "context": {"store": "/tmp/store", "session": "fybw8c", "kind": "message"},
                    "configuration": {"provider": "codex", "model": "gpt-5.5"},
                    "answer": {"status": "accepted", "replayed": False, "session": "fybw8c", "admission": "1"},
                    "input": {"type": "text", "bytes": "22"}, "queue": {"status": "queued", "admission": "1"},
                }), stderr="request: fixture-request\n")
            sent_to.append(args[args.index("--to") + 1])
            return types.SimpleNamespace(returncode=0, stderr="request: fixture-request\n")

        def fixture(_args, **kwargs):
            (Path(kwargs["env"]["TMPDIR"]).parent / "fixture.port").write_text("1234")
            kwargs["stdout"].close()
            return types.SimpleNamespace(pid=123)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            build = {"tree": "tree", "binary": "/unused/rui", "files_sha256": {"rui": "hash"}, "source": temp}
            args = types.SimpleNamespace(sha="a" * 40, label="test", active_capacity=2, host_setenv=[], no_sessions=False, seed=1)
            replacements = {"CACHE": root / "cache", "SCRATCH_PARENT": root, "load_build": lambda _sha: build,
                            "launch_host": lambda _run: types.SimpleNamespace(stdout='{"instance":"host"}'),
                            "wait_request": lambda *_args: None}
            with patch.dict(new.__globals__, replacements), patch.object(run_type, "rui_cmd", rui_cmd), \
                    patch.object(run_type, "own"), patch("subprocess.Popen", fixture), \
                    patch.dict(sys.modules, {"codex_integration": types.SimpleNamespace(credentials=lambda _path: None)}), \
                    patch.object(sys, "argv", sys.argv[:]), patch.object(sys, "path", sys.path[:]), \
                    contextlib.redirect_stdout(io.StringIO()):
                new(args)
            self.assertEqual(sent_to, ["fybw8c"])

    def test_scratch_root_follows_host_platform(self):
        for platform, expected in (("darwin", "/private/tmp"), ("linux", "/tmp")):
            with self.subTest(platform=platform), patch.object(sys, "platform", platform):
                self.assertEqual(runpy.run_path(str(SCRIPT))["SCRATCH_PARENT"], Path(expected))

    def test_cleanup_removes_only_run_scratch_under_its_root(self):
        module = runpy.run_path(str(SCRIPT))
        cleanup = module["cmd_cleanup"]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scratch_parent = root / "scratch"
            scratch_parent.mkdir()
            for scratch, removed in ((scratch_parent / "vr.owned", True), (root / "vr.outside", False)):
                scratch.mkdir()
                evidence_root = root / ("run-" + scratch.name)
                (evidence_root / "evidence").mkdir(parents=True)
                (evidence_root / "run.json").write_text(json.dumps({
                    "scratch": str(scratch), "home": str(scratch / "home"),
                    "store": str(scratch / "store"), "project": str(scratch / "project"),
                    "binary": "/unused/rui",
                }))
                with patch.dict(cleanup.__globals__, {"SCRATCH_PARENT": scratch_parent}), \
                        contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as result:
                    cleanup(types.SimpleNamespace(run=evidence_root, no_export=True))
                self.assertEqual(result.exception.code, 0)
                self.assertEqual(scratch.exists(), not removed)


if __name__ == "__main__":
    unittest.main()

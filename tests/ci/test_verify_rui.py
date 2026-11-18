import contextlib
import copy
import io
import json
import os
from pathlib import Path
import runpy
import site
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import types
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).parents[2] / ".claude/skills/verify-rui/scripts/verify-rui"


sys.path.insert(0, str(SCRIPT.parents[4] / "tests/integration"))
from terminal_screen import Cell, Cursor, Frame


def committed(text, columns=100, lines=20):
    rows = tuple(tuple(Cell(char, None, False) for char in row) for row in text.rstrip("\n").split("\n"))
    return Frame(columns, lines, Cursor(2, 3), False, rows, "121933", "d4cebf", "d4cebf")


def sidebar_rows(label, layout):
    layouts = {
        "chat": ("─" * 40 + "┼" + "─" * 99, "│ gpt-6.1-sol · low"),
        "settings": ("─" * 40 + "┤" + " " * 99, "│ Notifications"),
        "ascii-chat": ("-" * 40 + "+" + "-" * 99, "| gpt-6.1-sol . low"),
        "ascii-settings": ("-" * 40 + "+" + " " * 99, "| Notifications"),
        "overview": ("─" * 46, ""),
        "wide-overview": ("─" * 140, ""),
        "ascii-overview": ("-" * 46, ""),
        "ascii-wide-overview": ("-" * 140, ""),
    }
    rule, right = layouts[layout]
    row = "     Settings  " + label
    if right:
        row = row.ljust(40) + right
    return rule + "\n" + row


class VerifyRuiTest(unittest.TestCase):
    def test_resize_ignores_inflight_spinner_until_reset_frame_commits(self):
        import io
        import threading

        terminal_type = runpy.run_path(str(SCRIPT))["FrameTerminal"]
        terminal = terminal_type.__new__(terminal_type)
        capture = types.SimpleNamespace(generation=7, reset_generation=0, frame_reset_generation=0)
        capture.resize = lambda *_: None
        terminal.capture = capture
        terminal.condition = threading.Condition()
        terminal.master = 41
        terminal.output_events = io.StringIO()
        terminal.process = types.SimpleNamespace(output=types.SimpleNamespace(complete=False))
        accepted = []

        def wait(predicate, _description, **_kwargs):
            capture.generation += 1
            accepted.append(predicate(capture))
            capture.reset_generation += 1
            accepted.append(predicate(capture))
            capture.frame_reset_generation = capture.reset_generation
            capture.generation += 1
            accepted.append(predicate(capture))

        terminal.wait = wait
        with patch("fcntl.ioctl"):
            terminal.resize((46, 30))
        self.assertEqual(accepted, [False, False, True])

    def test_host_launcher_uses_exact_credential_free_generic_settings(self):
        launch = runpy.run_path(str(SCRIPT))["launch_host"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = types.SimpleNamespace(
                rui=Path("/candidate/rui"), store=root / "store", project=root, evidence=root,
                meta={"host_options": {"active_capacity": 8, "host_setenv": ["HOST_ONLY=secret"]},
                      "fixture_url": "http://127.0.0.1:1234/responses"},
                env=lambda: {"HOME": str(root)}, own=lambda *_args, **_kwargs: None,
                rui_cmd=lambda *_args, **_kwargs: types.SimpleNamespace(returncode=0, stdout='{"status":"ready"}', stderr=""))
            captured = {}

            def start(argv, **kwargs):
                captured.update(argv=argv, env=kwargs["env"])
                kwargs["stdout"].close()
                kwargs["stderr"].close()
                return types.SimpleNamespace(pid=123)

            for restartable in (False, True):
                with self.subTest(restartable=restartable), patch("subprocess.Popen", start):
                    launch(run, restartable=restartable)
                expected = ["/candidate/rui", "host", "serve", "--store", str(run.store),
                            "--set", "execution.activeCapacity=8", "--set", "providers={}",
                            "--set", "providers.codex.endpoint=http://127.0.0.1:1234/responses",
                            "--set", "providers.codex.unauthenticated=true"]
                if not restartable:
                    expected += ["--test-retry-waits-ms", "50,100,150"]
                self.assertEqual(captured["argv"], expected)
                self.assertEqual(captured["env"]["HOST_ONLY"], "secret")

    def test_image_consent_fixture_emits_one_typed_image_call_then_summary(self):
        from host_process import wait_for

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scratch = root / "scratch"
            scratch.mkdir()
            untrusted = root / "candidate/tests/integration"
            untrusted.mkdir(parents=True)
            (untrusted / "model_fixture.py").write_text('raise RuntimeError("candidate fixture loaded")\n')
            (root / "run.json").write_text(json.dumps({
                "id": "image-consent-test", "scratch": str(scratch),
                "home": str(scratch / "home"), "store": str(scratch / "store"),
                "project": str(scratch), "binary": "/unused/rui",
                "source": str(root / "candidate"),
            }))
            with subprocess.Popen([sys.executable, str(SCRIPT), "_fixture", str(root)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) as provider:
                try:
                    port = scratch / "fixture.port"
                    wait_for(lambda: port.exists() or provider.poll() is not None,
                             "image fixture port or child exit", timeout=10)
                    self.assertTrue(port.exists(), "image fixture did not start")
                    url = "http://127.0.0.1:" + port.read_text() + "/responses"
                    user = {"role": "user", "content": "Review with an image consent check."}

                    def request(items):
                        body = json.dumps({"input": items}).encode()
                        with urllib.request.urlopen(urllib.request.Request(url, body,
                                {"Content-Type": "application/json"}), timeout=5) as reply:
                            return [json.loads(line[6:]) for line in reply.read().decode().splitlines()
                                    if line.startswith("data: {")]

                    events = request([user])
                    calls = [event["item"] for event in events
                             if event.get("type") == "response.output_item.done"
                             and event.get("item", {}).get("type") == "function_call"]
                    self.assertEqual(len(calls), 1, events)
                    self.assertEqual(calls[0]["name"], "read_image")
                    self.assertEqual(json.loads(calls[0]["arguments"]), {"path": "design/checkout.png"})
                    request([user, {"type": "function_call_output", "call_id": calls[0]["call_id"],
                                    "output": "Image read denied."}])
                    records = [json.loads(line) for line in (root / "evidence/provider.jsonl").read_text().splitlines()]
                    self.assertEqual([row["kind"] for row in records if "kind" in row],
                                     ["image-consent-call", "tool-summary"])
                finally:
                    provider.terminate()
                    provider.communicate(timeout=5)

    def test_child_imports_user_site_with_synthetic_home(self):
        run_type = runpy.run_path(str(SCRIPT))["Run"]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            base = root / "user-base"
            home = root / "synthetic-home"
            home.mkdir()
            python = sys._base_executable
            user_site = subprocess.check_output(
                [python, "-m", "site", "--user-site"], text=True,
                env={**os.environ, "PYTHONUSERBASE": str(base)},
            ).strip()
            Path(user_site).mkdir(parents=True)
            (Path(user_site) / "verify_rui_fixture_dependency.py").write_text("VALUE = 42\n")
            (root / "run.json").write_text(json.dumps({
                "scratch": str(root), "home": str(home), "store": str(root / "store"),
                "project": str(root), "binary": "/unused/rui",
            }))
            with patch.object(site, "getuserbase", return_value=str(base)):
                env = run_type(root).env()
            command = [python, "-c", "import verify_rui_fixture_dependency; print(verify_rui_fixture_dependency.VALUE)"]
            without = subprocess.run(command, env={k: v for k, v in env.items() if k != "PYTHONUSERBASE"},
                                     capture_output=True, text=True)
            self.assertNotEqual(without.returncode, 0)
            with_base = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(with_base.returncode, 0, with_base.stderr)
            self.assertEqual(with_base.stdout.strip(), "42")
            self.assertEqual(env["HOME"], str(home))

    def test_new_sends_seed_to_session_id_from_start_response(self):
        module = runpy.run_path(str(SCRIPT))
        new = module["cmd_new"]
        run_type = module["Run"]
        sent_to = []
        started = []

        def rui_cmd(_run, *args, **_kwargs):
            if args[:2] == ("session", "start"):
                started.append(args)
                return types.SimpleNamespace(returncode=0, stdout=json.dumps({
                    "context": {"store": "/tmp/store", "session": "fybw8c", "kind": "message"},
                    "configuration": {"provider": "codex", "model": "gpt-5.5"},
                    "answer": {"status": "accepted", "replayed": False, "session": "fybw8c", "admission": "1"},
                    "input": {"type": "text", "bytes": "22"}, "queue": {"status": "queued", "admission": "1"},
                }), stderr="request: fixture-request\n")
            sent_to.append(args[args.index("--to") + 1])
            return types.SimpleNamespace(returncode=0, stderr="request: fixture-request\n")

        def fixture(_args, **kwargs):
            kwargs["stdout"].close()
            saved = json.loads(Path(_args[-1], "run.json").read_text())
            self.assertIs(saved.get("no_sessions"), args.no_sessions)
            (Path(kwargs["env"]["TMPDIR"]).parent / "fixture.port").write_text("1234")
            return types.SimpleNamespace(pid=123)

        for no_sessions in (False, True):
            sent_to.clear()
            started.clear()
            with self.subTest(no_sessions=no_sessions), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                build = {"tree": "tree", "binary": "/unused/rui", "files_sha256": {"rui": "hash"}, "source": temp}
                args = types.SimpleNamespace(sha="a" * 40, label="test", active_capacity=2, host_setenv=[], no_sessions=no_sessions, seed=0 if no_sessions else 1)
                replacements = {"CACHE": root / "cache", "SCRATCH_PARENT": root, "load_build": lambda _sha: build,
                                "launch_host": lambda _run: types.SimpleNamespace(stdout='{"instance":"host"}'),
                                "wait_request": lambda *_args: None}
                with patch.dict(new.__globals__, replacements), patch.object(run_type, "rui_cmd", rui_cmd), \
                        patch.object(run_type, "own"), patch("subprocess.Popen", fixture), \
                        patch.dict(sys.modules, {"codex_integration": types.SimpleNamespace(credentials=lambda _path: None)}), \
                        patch.object(sys, "argv", sys.argv[:]), patch.object(sys, "path", sys.path[:]), \
                        contextlib.redirect_stdout(io.StringIO()):
                    new(args)
                    self.assertEqual(sys.path[0], str(SCRIPT.parents[4] / "tests/integration"))
                self.assertEqual(sent_to, [] if no_sessions else ["fybw8c"])
                self.assertEqual(len(started), 0 if no_sessions else 2)
                saved = json.loads(next((root / "cache/runs").glob("*/run.json")).read_text())
                self.assertIs(saved["no_sessions"], no_sessions)
                if no_sessions:
                    self.assertEqual(saved["sessions"], {})

    def test_doctor_validates_registered_session_references(self):
        module = runpy.run_path(str(SCRIPT))
        doctor = module["cmd_doctor"]
        normal = {"demo": "demo-id", "approve": "approve-id"}
        listed = {"sessions": [{"reference": sid} for sid in normal.values()]}
        cases = [
            ("normal", {"sessions": normal, "no_sessions": False}, listed, 0, True),
            ("tree build", {"sha": "tree-" + "a" * 64, "sessions": normal}, listed, 0, True),
            ("legacy normal", {"sessions": normal}, listed, 0, True),
            ("intentional empty", {"sessions": {}, "no_sessions": True}, {"sessions": []}, 0, True),
            ("unmarked empty", {"sessions": {}}, {"sessions": []}, 0, False),
            ("unexpected row", {"sessions": {}, "no_sessions": True}, listed, 0, False),
            ("scenario", {"sessions": {"Agent": "agent-id"}, "no_sessions": True},
             {"sessions": [{"reference": "agent-id"}]}, 0, True),
            ("extra row", {"sessions": normal},
             {"sessions": listed["sessions"] + [{"reference": "extra-id"}]}, 0, True),
            ("ID only in label", {"sessions": normal},
             {"sessions": [{"reference": "other-id", "label": "demo-id"},
                           {"reference": "approve-id"}]}, 0, False),
            ("missing scenario ID", {"sessions": {**normal, "Agent": "agent-id"}}, listed, 0, False),
        ]
        for name in normal:
            cases.append(("missing mapping " + name,
                          {"sessions": {key: sid for key, sid in normal.items() if key != name}}, listed, 0, False))
            cases.append(("missing row " + name, {"sessions": normal},
                          {"sessions": [{"reference": sid} for key, sid in normal.items() if key != name]}, 0, False))
        for registry in (None, [], "bad", {"": "id"}, {" ": "id"}, {1: "id"}, {"Agent": ""},
                         {"Agent": " "}, {"Agent": None}, {"Agent": 1}, {"Agent": []}, {"Agent": {}},
                         {"demo": "same", "approve": "same"}):
            cases.append(("invalid registry", {"sessions": registry, "no_sessions": True}, listed, 0, False))
        cases.append(("missing registry", {"no_sessions": True}, {"sessions": []}, 0, False))
        for flag in (None, 0, 1, "true", [], {}):
            cases.append(("invalid flag", {"sessions": normal, "no_sessions": flag}, listed, 0, False))
        for payload in (None, [], {}, {"sessions": None}, {"sessions": {}}, {"sessions": "bad"},
                        {"sessions": [None]}, {"sessions": [{}]}, {"sessions": [{"reference": ""}]},
                        {"sessions": [{"reference": 1}]}, {"sessions": [{"reference": None}]},
                        {"sessions": listed["sessions"] * 2}):
            cases.append(("invalid listing", {"sessions": normal}, payload, 0, False))
        for row in (None, [], {}, {"reference": ""}, {"reference": " "},
                    {"reference": 1}, {"reference": []}, {"reference": {}}):
            cases.append(("invalid extra row", {"sessions": normal},
                          {"sessions": listed["sessions"] + [row]}, 0, False))
        cases.extend([
            ("failed listing", {"sessions": normal}, listed, 1, False),
            ("failed empty listing", {"sessions": {}, "no_sessions": True}, {"sessions": []}, 1, False),
            ("malformed JSON", {"sessions": normal}, "not JSON", 0, False),
        ])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / "rui"
            binary.touch()
            for name, metadata, payload, rc, expected in cases:
                with self.subTest(name=name, metadata=metadata, payload=payload):
                    reports = []
                    run = types.SimpleNamespace(root=root, scratch=root, home=root / "home", store=root / "store",
                        evidence=root, rui=binary, sock=root / "absent-socket",
                        meta={"sha": "sha", "binary_sha256": "hash", "source": temp,
                              "fixture_url": "http://fixture/responses", "id": "run", "host_instance": "host", **metadata},
                        owned=lambda: [{"kind": "host", "pid": 123, "lstart": "start"}])
                    run.sid = types.MethodType(module["Run"].sid, run)
                    def command(*args, **kwargs):
                        if args[:2] == ("session", "list"):
                            return types.SimpleNamespace(returncode=rc, stdout=payload if isinstance(payload, str)
                                                         else json.dumps(payload), stderr="")
                        return types.SimpleNamespace(returncode=0, stdout='{"instance":"host"}', stderr="")
                    run.rui_cmd = unittest.mock.Mock(side_effect=command)
                    replacements = {"Run": lambda _path: run, "sha256": lambda _path: "hash",
                        "load_build": lambda identifier: {"sha": identifier, "head": "sha", "files_sha256": {"rui": "hash"}},
                        "process_start": lambda _pid: ("start",), "accessibility": lambda: "unused",
                        "append_jsonl": lambda _path, report: reports.append(report)}
                    with patch.dict(doctor.__globals__, replacements), \
                            patch("subprocess.run", side_effect=lambda argv, **_kwargs: types.SimpleNamespace(
                                stdout="sha" if argv[0] == "git" else "n" + str(run.store))), \
                            patch("urllib.request.urlopen", return_value=io.BytesIO(b'{"verify_rui_fixture":"run"}')), \
                            contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as result:
                        doctor(types.SimpleNamespace(run=root, expect_sha=None))
                    session_check = next(check for check in reports[0]["checks"]
                                         if check["check"] == "configured Sessions present")
                    self.assertEqual(session_check["ok"], expected)
                    self.assertEqual(result.exception.code, 0 if expected else 1)
                    self.assertEqual(reports[0]["verdict"], "PASS" if expected else "ISSUES")
                    self.assertEqual(sum(call.args[:2] == ("session", "list")
                                         for call in run.rui_cmd.call_args_list), 1)

    def test_tap_resolves_recorded_build_in_run_cache(self):
        tap = runpy.run_path(str(SCRIPT))["tap_main"]
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp) / "cache"
            for identifier in ("a" * 40, "tree-" + "b" * 64):
                with self.subTest(identifier=identifier):
                    build = cache / "builds" / identifier
                    build.mkdir(parents=True)
                    (build / "manifest.json").write_text(json.dumps({"screen_library": identifier}))
                    run = types.SimpleNamespace(root=cache / "runs" / "run",
                                                meta={"sha": identifier, "source": "/source"})
                    def require_screen(record):
                        self.assertEqual(record["screen_library"], identifier)
                        raise RuntimeError("build resolved")
                    with patch.dict(tap.__globals__, {"Run": lambda _path: run, "require_screen": require_screen}), \
                            self.assertRaisesRegex(RuntimeError, "build resolved"):
                        tap(types.SimpleNamespace(run="run"))

    def test_scratch_root_follows_host_platform(self):
        for platform, expected in (("darwin", "/private/tmp"), ("linux", "/tmp")):
            with self.subTest(platform=platform), patch.object(sys, "platform", platform):
                self.assertEqual(runpy.run_path(str(SCRIPT))["SCRATCH_PARENT"], Path(expected))

    def test_cleanup_removes_only_run_scratch_under_its_root(self):
        module = runpy.run_path(str(SCRIPT))
        cleanup = module["cmd_cleanup"]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            scratch_parent = root / "scratch"
            scratch_parent.mkdir()
            linked_parent = root / "scratch-link"
            linked_parent.symlink_to(scratch_parent, target_is_directory=True)
            for scratch, parent, removed in (
                (scratch_parent / "vr.owned", scratch_parent, True),
                (scratch_parent / "vr.linked", linked_parent, True),
                (root / "vr.outside", linked_parent, False),
            ):
                scratch.mkdir()
                evidence_root = root / ("run-" + scratch.name)
                (evidence_root / "evidence").mkdir(parents=True)
                (evidence_root / "run.json").write_text(json.dumps({
                    "scratch": str(scratch), "home": str(scratch / "home"),
                    "store": str(scratch / "store"), "project": str(scratch / "project"),
                    "binary": "/unused/rui",
                }))
                with patch.dict(cleanup.__globals__, {"SCRATCH_PARENT": parent}), \
                        contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as result:
                    cleanup(types.SimpleNamespace(run=evidence_root, no_export=True))
                self.assertEqual(result.exception.code, 0)
                self.assertEqual(scratch.exists(), not removed)


class FramesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helper = runpy.run_path(str(SCRIPT))

    def scenario(self):
        return {"sizes": ["140x40", "46x30"], "states": [
            {"name": "empty", "open": "overview", "steps": []},
            {"name": "chat", "open": "Fix it", "cast": [
                {"label": "Fix it", "workspace": "code/rui", "mode": "bypass", "messages": ["rich answer"]}
            ], "steps": [{"text": "/help"}, {"keys": ["Enter"]}, {"wait": "Keys", "timeout": 2}]},
        ]}

    def test_host_suspension_validates_actions_and_lifetime(self):
        for steps in ([{"host": "suspend"}], [{"host": "suspend"}, {"host": "resume"}],
                      [{"host": "suspend"}, {"host": "resume"}, {"host": "pause"}]):
            data = self.scenario()
            data["states"][0].update(steps=steps, expect=[])
            self.helper["validate_scenario"](data)
        for steps in ([{"host": "resume"}], [{"host": "suspend"}, {"host": "suspend"}],
                      [{"host": "suspend"}, {"host": "pause"}], [{"host": "suspend"}, {"host": "start"}]):
            data = self.scenario()
            data["states"][0].update(steps=steps, expect=[])
            with self.assertRaisesRegex(ValueError, "Host"):
                self.helper["validate_scenario"](data)

    def test_host_suspension_signals_only_the_verified_owned_process_and_logs_it(self):
        control = self.helper["frame_host_suspension"]
        host = {"kind": "host", "pid": 123, "lstart": "owned start"}
        run = types.SimpleNamespace(owned=lambda: [host], evidence=Path("/evidence"))
        with patch.dict(control.__globals__, {"process_start": lambda _pid: ("owned start", "rui host serve"),
                "append_jsonl": unittest.mock.Mock()}), patch.object(os, "kill") as kill:
            log = control.__globals__["append_jsonl"]
            control(run, True)
            with self.assertRaisesRegex(self.helper["FrameFailure"], "already suspended"):
                control(run, True)
            control(run, False)
            control(run, False)
            self.assertEqual(kill.call_args_list, [unittest.mock.call(123, self.helper["signal"].SIGSTOP),
                                                  unittest.mock.call(123, self.helper["signal"].SIGCONT)])
            self.assertEqual([call.args[1]["signal"] for call in log.call_args_list], ["STOP", "CONT"])
            self.assertIsNone(run.frame_suspended_host)
        for owned, current in (([], None), ([host], None), ([host], ("reused PID", "other")),
                               ([host, {**host, "pid": 124}], ("owned start", "rui host serve"))):
            with self.subTest(owned=owned, current=current):
                run = types.SimpleNamespace(owned=lambda: owned, evidence=Path("/evidence"))
                with patch.dict(control.__globals__, {"process_start": lambda _pid: current}), \
                        patch.object(os, "kill") as kill, self.assertRaises(self.helper["FrameFailure"]):
                    control(run, True)
                kill.assert_not_called()
        run = types.SimpleNamespace(frame_suspended_host=host, evidence=Path("/evidence"))
        with patch.dict(control.__globals__, {"process_start": lambda _pid: ("reused PID", "other")}), \
                patch.object(os, "kill") as kill, self.assertRaises(self.helper["FrameFailure"]):
            control(run, False)
        kill.assert_not_called()

    def test_host_suspension_retains_cleanup_authority_when_logging_or_resume_fails(self):
        control = self.helper["frame_host_suspension"]
        host = {"kind": "host", "pid": 123, "lstart": "owned start"}
        run = types.SimpleNamespace(owned=lambda: [host], evidence=Path("/evidence"))
        with patch.dict(control.__globals__, {"process_start": lambda _pid: ("owned start", "rui host serve"),
                "append_jsonl": unittest.mock.Mock(side_effect=OSError("log unavailable"))}), \
                patch.object(os, "kill") as kill:
            with self.assertRaisesRegex(OSError, "log unavailable"):
                control(run, True)
            self.assertEqual(run.frame_suspended_host, host)
            with self.assertRaisesRegex(OSError, "log unavailable"):
                control(run, False)
            self.assertIsNone(run.frame_suspended_host)
            self.assertEqual(kill.call_count, 2)
        run.frame_suspended_host = host
        with patch.dict(control.__globals__, {"process_start": lambda _pid: ("owned start", "rui host serve")}), \
                patch.object(os, "kill", side_effect=PermissionError("no resume")):
            with self.assertRaisesRegex(PermissionError, "no resume"):
                control(run, False)
            self.assertEqual(run.frame_suspended_host, host)

    def test_frame_state_resumes_owned_host_on_success_and_capture_or_step_failure(self):
        command = self.helper["cmd_frames"]
        scenario = {"sizes": ["140x40"], "states": [{"name": name, "open": "overview", "steps": []} for name in ("empty", "chat")]}
        for capture_ok, failing in ((True, None), (False, None), (True, "chat")):
            with self.subTest(capture_ok=capture_ok, failing=failing):
                resume = unittest.mock.Mock()
                with patch.dict(command.__globals__, {"frame_host_suspension": resume}), \
                        contextlib.redirect_stderr(io.StringIO()):
                    if capture_ok and failing is None:
                        calls, _records = self.run_frames_scenario(scenario)
                        self.assertIn(("close",), calls)
                    else:
                        with self.assertRaises(SystemExit):
                            self.run_frames_scenario(scenario, capture_ok=capture_ok, failing_state=failing)
                self.assertEqual(resume.call_count, 2)
                self.assertTrue(all(call.args[1] is False for call in resume.call_args_list))

    def test_empty_composer_wait_with_clipped_split_rule(self):
        for bar in ("│", "|"):
            for draft in ("", " retained | draft"):
                frame = committed("witness".ljust(40) + bar + " ›" + draft)._replace(cursor=Cursor(43, 0), visible=True)
                outcomes = []
                terminal = types.SimpleNamespace(wait=lambda predicate, *_args: outcomes.append(
                    predicate(types.SimpleNamespace(completed=frame.text, frame=frame))))
                with self.subTest(bar=bar, draft=draft):
                    self.helper["frame_wait"](None, terminal, "witness", empty_composer=True)
                    self.assertEqual(outcomes, [not draft])

    def test_empty_composer_wait_rejects_pre_enter_draft_and_accepts_feed_message(self):
        wait = self.helper["frame_wait"]
        samples = [committed("› witness"), committed("› witness\n›"), committed("› witness\n›")]
        samples[0] = samples[0]._replace(cursor=Cursor(9, 0), visible=True)
        samples[1] = samples[1]._replace(cursor=Cursor(2, 1), visible=True)
        samples[2] = samples[2]._replace(cursor=Cursor(2, 1), visible=False)
        outcomes = []
        terminal = types.SimpleNamespace(wait=lambda predicate, *_args: outcomes.extend(
            predicate(types.SimpleNamespace(completed=frame.text, frame=frame)) for frame in samples))
        wait(None, terminal, "witness", empty_composer=True)
        self.assertEqual(outcomes, [False, True, False])
        data = self.scenario()
        data["states"][0].update(steps=[{"wait": "witness", "empty_composer": True}])
        self.helper["validate_scenario"](data)
        for step in ({"gone": "witness", "empty_composer": True}, {"wait": "witness", "empty_composer": 1}):
            data["states"][0].update(steps=[step], expect=[])
            with self.assertRaisesRegex(ValueError, "empty_composer"):
                self.helper["validate_scenario"](data)

    def test_frame_glyph_owner_accepts_legacy_stitch_and_ascii_in_both_layouts(self):
        from terminal_screen import DIVIDER_GLYPHS, RULE_GLYPHS
        wait = self.helper["frame_wait"]
        ready = self.helper["frame_chat_ready"]
        for rule, divider in zip(RULE_GLYPHS, DIVIDER_GLYPHS):
            for split in (False, True):
                prefix = f"sidebar {divider} " if split else ""
                prompt = ">" if divider == "|" else "›"
                samples = [f"{prefix}{prompt} witness\n{prefix}{prompt}",
                           f"{prefix}{prompt} witness\n{prefix}{prompt} draft"]
                frames = [committed(text)._replace(cursor=Cursor(len(prefix) + len(prompt), 1), visible=True)
                          for text in samples]
                outcomes = []
                terminal = types.SimpleNamespace(wait=lambda predicate, *_args: outcomes.extend(
                    predicate(types.SimpleNamespace(completed=frame.text, frame=frame)) for frame in frames))
                with self.subTest(rule=rule, divider=divider, split=split):
                    wait(None, terminal, "witness", empty_composer=True)
                    self.assertEqual(outcomes, [True, False])
                    chat = "\n".join([prefix + "witness", prefix + rule * 12,
                                       prefix + prompt + " Type a task", prefix + rule * 12,
                                       prefix + "model · low"])
                    self.assertTrue(ready(chat, "witness", empty=True))
                    self.assertFalse(ready(chat.replace("Type a task", "draft"), empty=True))

    def test_dim_expectations_validate_and_assert_saved_cells_not_text_alone(self):
        for value in (None, {}, [{"text": "", "dim": True}], [{"text": "Row", "dim": 1}],
                      [{"text": "Row", "dim": True, "min_columns": False}],
                      [{"text": "Row", "dim": True, "unknown": 1}]):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "expect_dim"):
                data = self.scenario()
                data["states"][0]["expect_dim"] = value
                self.helper["validate_scenario"](data)
        for dim in (False, True):
            state = {"name": "dim-row", "steps": [], "expect": "Row",
                     "expect_dim": [{"text": "Row", "dim": dim}]}
            for drawn in (False, True):
                frame = committed("Row")
                frame = frame._replace(cells=tuple(tuple(cell._replace(faint=drawn) for cell in row)
                                                  for row in frame.cells))
                with self.subTest(want=dim, drawn=drawn), tempfile.TemporaryDirectory() as temp:
                    record = self.helper["frame_capture"](types.SimpleNamespace(meta={"sha": "a" * 40}),
                        types.SimpleNamespace(frame=frame), Path(temp), state, (100, 20), None)
                    self.assertEqual(record["ok"], dim == drawn)
                    self.assertTrue((Path(temp) / record["files"]["txt"]).exists())
            self.assertIsNotNone(self.helper["frame_dim_failure"](state, committed("Missing")))
            state["expect_dim"][0]["min_columns"] = 140
            self.assertIsNone(self.helper["frame_dim_failure"](state, committed("Missing", columns=46)))
        frame = committed("Row")
        frame = frame._replace(cells=((frame.cells[0][0]._replace(faint=True), *frame.cells[0][1:]),))
        self.assertIsNotNone(self.helper["frame_dim_failure"](
            {"expect_dim": [{"text": "Row", "dim": True}]}, frame))

    def test_peer_cast_configures_empty_and_relays_every_message_from_a_live_sender(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            run = types.SimpleNamespace(home=root, root=root, store=root / "store",
                                        meta={"sessions": {"Person": "person"}}, sid=lambda _name: "person")
            calls = []
            def command(*args, **kwargs):
                calls.append((args, kwargs))
                payload = {"work": {"state": {"kind": "finished"}}} if args[1] == "inspect" else {
                    "context": {"session": "agent1"}}
                return types.SimpleNamespace(returncode=0, stdout=json.dumps(payload), stderr="request: key\n")
            run.rui_cmd = command
            seed = self.helper["seed_cast"]
            with patch.dict(seed.__globals__, frame_request=unittest.mock.Mock()):
                seed(run, [{"label": "Agent", "sender": "Person", "workspace": "code/quiet",
                            "mode": "bypass", "messages": ["First", "Second"]}])
            self.assertEqual(calls[0][0][:2], ("session", "configure"))
            self.assertIsNone(calls[0][1]["input"])
            sends = [(args, kwargs) for args, kwargs in calls if args[1] == "send"]
            self.assertEqual([kwargs["input"] for _, kwargs in sends],
                             ["relay to agent1: First", "relay to agent1: Second"])
            self.assertTrue(all(args[-1] == "person" for args, _ in sends))
            self.assertEqual(run.meta["sessions"]["Agent"], "agent1")
        data = self.scenario()
        data["states"][1]["cast"][0]["sender"] = "missing"
        with self.assertRaisesRegex(ValueError, "sender"):
            self.helper["validate_scenario"](data)

        for sender in ([], {}, None):
            data["states"][1]["cast"][0]["sender"] = sender
            with self.subTest(sender=sender), self.assertRaisesRegex(ValueError, "sender"):
                self.helper["validate_scenario"](data)
        data = self.scenario()
        data["states"][1]["cast"][0].update(sender="Person", settle="stop")
        data["states"][0]["cast"] = [{"label": "Person", "workspace": "code/quiet",
                                      "mode": "bypass", "messages": ["Ready"]}]
        with self.assertRaisesRegex(ValueError, "sender cast supports"):
            self.helper["validate_scenario"](data)

    def test_min_columns_is_a_positive_integer_wait_or_gone_modifier_only(self):
        validate = self.helper["validate_scenario"]
        for action in ("wait", "gone"):
            data = self.scenario()
            data["states"][0].update(steps=[{action: "Sidebar", "min_columns": 140}], expect=[])
            self.assertEqual(validate(data)["states"][0]["steps"], data["states"][0]["steps"])
            for value in (None, 0, -1, True, 140.0, "140"):
                with self.subTest(action=action, value=value), self.assertRaisesRegex(ValueError, "min_columns"):
                    data["states"][0]["steps"][0]["min_columns"] = value
                    validate(data)
        for step in ({"text": "draft"}, {"keys": ["Enter"]}, {"sleep": 1},
                     {"mouse": {"at": "Settings", "do": "click"}}, {"exited": 0},
                     {"host": "pause"}, {"send": {"to": "Fix it", "text": "hello"}}):
            with self.subTest(step=step), self.assertRaisesRegex(ValueError, "min_columns"):
                data = self.scenario()
                data["states"][1].update(steps=[{**step, "min_columns": 140}], expect=[])
                validate(data)

    def test_min_columns_skips_only_narrow_waits_and_logs_the_reason(self):
        steps = [{"wait": "Sidebar", "min_columns": 140},
                 {"gone": "Old sidebar", "min_columns": 140, "timeout": 3},
                 {"wait": "Input"}, {"gone": "Loading"}]
        for columns in (46, 140, 180):
            with self.subTest(columns=columns), patch.dict(self.helper["frame_steps"].__globals__) as owner:
                wait = unittest.mock.Mock()
                owner["frame_wait"] = wait
                terminal = types.SimpleNamespace(frame=committed("Input", columns=columns), status=None)
                with contextlib.redirect_stderr(io.StringIO()) as log:
                    self.helper["frame_steps"](None, terminal, steps)
                expected = [] if columns < 140 else [
                    unittest.mock.call(None, terminal, "Sidebar", False, 20, False),
                    unittest.mock.call(None, terminal, "Old sidebar", True, 3, False),
                ]
                expected += [unittest.mock.call(None, terminal, "Input", False, 20, False),
                             unittest.mock.call(None, terminal, "Loading", True, 20, False)]
                self.assertEqual(wait.call_args_list, expected)
                if columns < 140:
                    self.assertIn("skip wait 'Sidebar': 46 columns < 140", log.getvalue())
                    self.assertIn("skip gone 'Old sidebar': 46 columns < 140", log.getvalue())
                else:
                    self.assertEqual(log.getvalue(), "")

    def test_mouse_steps_validate_shared_nested_shape(self):
        validate = self.helper["validate_scenario"]
        for action in ("move", "click", "press", "release", "wheel-up", "wheel-down"):
            for target in ("Settings", [0, 0], [139, 39]):
                for button in ("left", "right", "middle"):
                    data = self.scenario()
                    data["states"][0].update(steps=[{"mouse": {"at": target, "do": action, "button": button}}], expect=[])
                    self.assertEqual(validate(data)["states"][0]["steps"], data["states"][0]["steps"])
        for value in ("click", {}, {"at": "Settings"}, {"at": "Settings", "do": "hover"},
                      {"at": "", "do": "click"}, {"at": "bad\nrow", "do": "click"},
                      {"at": [-1, 0], "do": "click"}, {"at": [True, 0], "do": "click"},
                      {"at": [0], "do": "click"}, {"at": "Settings", "do": "click", "button": "four"},
                      {"at": "Settings", "do": "click", "on": "text"}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                data = self.scenario()
                data["states"][0]["steps"] = [{"mouse": value}]
                validate(data)
        data = self.scenario()
        data["states"][0]["record"] = "true"
        with self.assertRaisesRegex(ValueError, "record"):
            validate(data)

    def test_mouse_targets_first_drawn_cell_and_records_no_reporting_mode(self):
        import threading
        owner = self.helper["FrameTerminal"]
        frame = committed("中Settings Settings")
        row = (Cell("中", None, False), Cell("", None, False)) + frame.cells[0][1:]
        frame = frame._replace(cells=(row,))
        for payload in (b"", b"encoded"):
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as temp:
                terminal = owner.__new__(owner)
                terminal.condition = threading.Condition()
                terminal.process = types.SimpleNamespace(output=types.SimpleNamespace(check=lambda: None))
                terminal.pressed = None
                terminal.log = Path(temp)
                events, writes = [], []
                terminal.capture = types.SimpleNamespace(frame=frame, generation=1, mouse=lambda *args, **kw:
                    (events.append((args, kw)) or payload))
                terminal.write = lambda data, _kind: writes.append(data)
                terminal.mouse({"at": "Settings", "do": "click"}, repaint=False)
                self.assertEqual([event[0] for event in events], [("press", 2, 0, "left"), ("release", 2, 0, "left")])
                self.assertEqual([event[1]["pressed"] for event in events], [False, True])
                self.assertEqual(writes, [payload, payload] if payload else [])
                self.assertEqual([r["emitted"] for r in self.helper["read_jsonl"](terminal.log / "mouse.jsonl")], [bool(payload)] * 2)
                with self.assertRaisesRegex(self.helper["FrameFailure"], "absent from committed frame"):
                    terminal.mouse({"at": "absent", "do": "move"})
                with self.assertRaisesRegex(self.helper["FrameFailure"], "outside"):
                    terminal.mouse({"at": [100, 0], "do": "click"})

    def mouse_terminal(self, root, payload=b"encoded"):
        import threading
        terminal = self.helper["FrameTerminal"].__new__(self.helper["FrameTerminal"])
        terminal.condition = threading.Condition()
        terminal.process = types.SimpleNamespace(output=types.SimpleNamespace(check=lambda: None, complete=False))
        terminal.pressed = None
        terminal.log = root
        frame = committed("Settings")
        terminal.capture = types.SimpleNamespace(frame=frame, generation=1, completed=frame.text,
                                                 mouse=unittest.mock.Mock(return_value=payload))
        terminal.write = unittest.mock.Mock()
        return terminal

    def test_mouse_waits_for_delayed_committed_style_change_before_capture(self):
        for action in ("move", "click", "press", "release", "wheel-up", "wheel-down"):
            with self.subTest(action=action), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                terminal = self.mouse_terminal(root)
                before = terminal.frame
                hovered = before._replace(cells=((before.cells[0][0]._replace(bg="345678"),)
                                                 + before.cells[0][1:],))
                pending = iter(((1, hovered), (2, before), (3, hovered)))

                def repaint(_timeout):
                    terminal.write.assert_called()
                    terminal.capture.generation, terminal.capture.frame = next(pending)

                with patch.object(terminal.condition, "wait", side_effect=repaint) as waited:
                    self.helper["frame_steps"](None, terminal, [{"mouse": {"at": "Settings", "do": action}}])
                self.assertEqual(waited.call_count, 3)
                record = self.helper["frame_capture"](types.SimpleNamespace(meta={"sha": "a" * 40}),
                    terminal, root, {"name": "hover", "steps": [], "expect": "Settings"}, (100, 20), None)
                self.assertTrue(record["ok"])
                self.assertIn("background:#345678", (root / record["files"]["html"]).read_text())
                self.assertEqual((root / record["files"]["txt"]).read_text(), "Settings\n")

    def test_mouse_withheld_repaint_fails_even_after_an_identical_commit(self):
        for target in ("Settings", [0, 0]):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temp:
                terminal = self.mouse_terminal(Path(temp))

                def identical_commit(_timeout):
                    terminal.capture.generation += 1

                with patch.object(terminal.condition, "wait", side_effect=identical_commit) as waited, \
                        patch("time.monotonic", side_effect=[0, 0, 21]), \
                        self.assertRaises(self.helper["FrameFailure"]) as failure:
                    self.helper["frame_steps"](None, terminal, [{"mouse": {"at": target, "do": "move"}}])
                self.assertIn(f"mouse move at {target} did not repaint", str(failure.exception))
                self.assertEqual(waited.call_count, 1)
                terminal.write.assert_called_once_with(b"encoded", "mouse")

    def test_mouse_explicit_no_repaint_does_not_wait(self):
        with tempfile.TemporaryDirectory() as temp:
            terminal = self.mouse_terminal(Path(temp))
            with patch.object(terminal, "wait") as waited:
                self.helper["frame_steps"](None, terminal, [
                    {"mouse": {"at": "Settings", "do": "move"}, "repaint": False}])
            waited.assert_not_called()
            terminal.write.assert_called_once_with(b"encoded", "mouse")

    def test_mouse_no_emitted_bytes_does_not_wait_and_keeps_logging(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            terminal = self.mouse_terminal(root, payload=b"")
            with patch.object(terminal, "wait") as waited:
                self.helper["frame_steps"](None, terminal, [{"mouse": {"at": "Settings", "do": "click"}}])
            waited.assert_not_called()
            terminal.write.assert_not_called()
            events = self.helper["read_jsonl"](root / "mouse.jsonl")
            self.assertEqual([event["action"] for event in events], ["press", "release"])
            self.assertEqual([event["emitted"] for event in events], [False, False])

    def test_repaint_is_a_boolean_mouse_step_modifier_only(self):
        validate = self.helper["validate_scenario"]
        for repaint in (True, False):
            data = self.scenario()
            step = {"mouse": {"at": "Settings", "do": "move"}, "repaint": repaint}
            data["states"][0].update(steps=[step], expect=[])
            self.assertEqual(validate(data)["states"][0]["steps"], [step])
        for repaint in (None, 0, 1, "false", [], {}):
            data = self.scenario()
            data["states"][0].update(steps=[{"mouse": {"at": "Settings", "do": "move"}, "repaint": repaint}], expect=[])
            with self.subTest(repaint=repaint), self.assertRaisesRegex(ValueError, "invalid repaint"):
                validate(data)
        for step in ({"text": "draft"}, {"keys": ["Enter"]}, {"wait": "Settings"}, {"gone": "Settings"},
                     {"sleep": 1}, {"host": "pause"}, {"exited": 0},
                     {"send": {"to": "Fix it", "text": "message"}}):
            data = self.scenario()
            data["states"][1].update(steps=[{**step, "repaint": False}], expect=[])
            with self.subTest(step=step), self.assertRaisesRegex(ValueError, "invalid repaint"):
                validate(data)

    def test_playback_domain(self):
        playback = self.helper["playback"]
        cases = [
            ([(0, "one")], [("one", 2)]),
            ([(0, "one"), (1_000_000_000, "one"), (20_000_000_000, "two"),
              (20_000_000_001, "three"), (20_500_000_001, "last")],
             [("one", 1.5), ("three", .5), ("last", 2)]),
            ([(t, str(t)) for t in (0, 1, 79_999_999, 80_000_000, 90_000_000, 160_000_000)],
             [("79999999", .06), ("90000000", .07), ("160000000", 2)]),
            ([(0, "a"), (10_000_000, "b"), (20_000_000, "a"), (80_000_000, "a")], [("a", 2)]),
        ]
        for entries, expected in cases:
            with self.subTest(entries=entries):
                actual = playback((t, committed(text)) for t, text in entries)
                self.assertEqual([(frame.text, delay) for frame, delay in actual], expected)
        frame = committed("same")
        changed_cursor = frame._replace(cursor=Cursor(0, 0), visible=True)
        self.assertEqual(list(playback(iter([(0, frame), (100_000_000, changed_cursor)]))), [(frame, 2)])
        with self.assertRaisesRegex(self.helper["FrameFailure"], "no committed recording frames"):
            list(playback(iter([])))

    @unittest.skipUnless(os.environ.get("RUI_TEST_GHOSTTY_VT"), "native observer library not selected")
    def test_replay_timed_bytes_resize_stop_and_silent_queries(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            chunks = [b"\x1b]11;?\x1b\\\x1b[?2026hfirst\x1b[?2026l\x1b[?2026h\rsecond\x1b[?2026",
                      b"l\x1b[?2026h\rthird \x1b[?2026l", b"\x1b[?2026h\rignored\x1b[?2026l"]
            with open(root / "output.bin", "wb") as raw, open(root / "output.jsonl", "w") as events:
                for i, chunk in enumerate(chunks):
                    if i == 2:
                        events.write(json.dumps({"t_ns": 30, "resize": [20, 4]}) + "\n")
                    with patch("time.monotonic_ns", return_value=10 + i):
                        self.helper["timed_output"](raw, events, chunk)
            before = {path.name: path.read_bytes() for path in root.iterdir()}
            frames = list(self.helper["replay"](root, (12, 3), "day"))
            self.assertEqual([(t, frame.text.strip()) for t, frame in frames[:3]],
                             [(10, "first"), (11, "second"), (11, "third")])
            self.assertEqual(frames[0][1].background, self.helper["THEMES"]["day"][0].lstrip("#"))
            self.assertTrue(all("ignored" not in frame.text for _, frame in frames))
            self.assertEqual(before, {path.name: path.read_bytes() for path in root.iterdir()})
            self.assertEqual(frames, list(self.helper["replay"](root, (12, 3), "day")))
            (root / "output.bin").write_bytes(b"")
            with self.assertRaisesRegex(self.helper["FrameFailure"], "truncated"):
                list(self.helper["replay"](root, (12, 3), "day"))

    def test_renderer_jobs_for_stills_and_movie_and_concat_durations(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            jobs = io.StringIO()
            self.helper["render_job"](jobs, root / "still.html")
            function = self.helper["recording_jobs"]
            timed = [(0, committed("one")), (100_000_000, committed("two"))]
            with patch.dict(function.__globals__, {"replay": lambda *_args: iter(timed)}):
                concat = function(root, (100, 20), "night", root / "movie", jobs)
            entries = [json.loads(line) for line in jobs.getvalue().splitlines()]
            self.assertEqual(entries, [
                {"html": str(root / "still.html"), "png": str(root / "still.png"), "scale": 2, "opaque": False},
                *[{"html": str(root / f"movie/{i:06d}.html"), "png": str(root / f"movie/{i:06d}.png"),
                   "scale": 1, "opaque": True} for i in range(2)],
            ])
            self.assertIn("one", (root / "movie/000000.html").read_text())
            self.assertEqual(concat.read_text().splitlines(), [
                f"file '{root}/movie/000000.png'", "duration 0.100",
                f"file '{root}/movie/000001.png'", "duration 2.000", f"file '{root}/movie/000001.png'",
            ])

    def test_renderer_job_canonicalizes_absolute_and_relative_aliases(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            actual = root / "actual"
            actual.mkdir()
            alias = root / "alias"
            alias.symlink_to(actual, target_is_directory=True)
            with contextlib.chdir(root):
                for path in (alias / "still.html", Path("alias/still.html")):
                    for movie in (False, True):
                        with self.subTest(path=path, movie=movie):
                            jobs = io.StringIO()
                            self.helper["render_job"](jobs, path, movie=movie)
                            self.assertEqual(json.loads(jobs.getvalue()), {
                                "html": str(actual / "still.html"), "png": str(actual / "still.png"),
                                "scale": 1 if movie else 2, "opaque": movie,
                            })

    def test_encoder_uses_separate_palette_pass_and_same_concat(self):
        with patch("subprocess.run", return_value=types.SimpleNamespace(returncode=0, stderr="")) as run:
            self.helper["encode_recording"](Path("/tmp/frames.concat"), Path("/tmp/movie.gif"))
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(len(commands), 3)
        self.assertIn("palettegen=max_colors=128:stats_mode=diff", commands[0])
        self.assertIn("[0:v][1:v]paletteuse=diff_mode=rectangle:dither=bayer:bayer_scale=5", commands[1])
        self.assertIn("/tmp/palette.png", commands[0])
        self.assertIn("/tmp/palette.png", commands[1])
        for command in commands:
            self.assertEqual(command[command.index("-i") + 1], "/tmp/frames.concat")
            self.assertNotIn("split", " ".join(command))

    def test_ffmpeg_retains_canvas_and_update_only_changed_rectangles(self):
        try:
            from PIL import Image, ImageDraw
        except ImportError:
            self.skipTest("Pillow is optional")
        import shutil
        if not shutil.which("ffmpeg"):
            self.skipTest("ffmpeg is required for recordings")
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            for i in range(2):
                image = Image.new("RGB", (64, 32), (18, 25, 51))
                ImageDraw.Draw(image).rectangle((10 + i * 4, 10, 12 + i * 4, 12), fill="white")
                image.save(out / f"{i}.png")
            concat = out / "frames.concat"
            concat.write_text(f"file '{out}/0.png'\nduration 0.200\nfile '{out}/1.png'\nduration 2.000\nfile '{out}/1.png'\n")
            self.helper["encode_recording"](concat, out / "movie.gif")
            with Image.open(out / "movie.gif") as movie:
                movie.seek(1)
                extent = movie.tile[0].extents
                self.assertLess((extent[2] - extent[0]) * (extent[3] - extent[1]), 64 * 32 // 2)
                self.assertEqual(movie.disposal_method, 1)
                self.assertGreaterEqual(movie.info["duration"], 2000)
                self.assertEqual(movie.convert("RGB").getpixel((15, 11)), (255, 255, 255))
            record = {"name": "state", "size": "100x20", "files": {"png": "still.png", "gif": "movie.gif"},
                      "status": "ok", "ok": True, "note": "", "reason": None}
            self.helper["frames_index"](out, [record], True)
            self.assertIn('src="movie.gif"', (out / "index.html").read_text())

    def test_recordings_require_ffmpeg_before_allocating_any_run(self):
        command = self.helper["cmd_frames"]
        for cli_flag in (False, True):
            with self.subTest(cli_flag=cli_flag), tempfile.TemporaryDirectory() as temp:
                data = self.scenario()
                data["states"][0]["record"] = not cli_flag
                path = Path(temp) / "scenario.json"
                path.write_text(json.dumps(data))
                args = types.SimpleNamespace(sha="a" * 40, scenario=path, sizes=None,
                                             only="empty", no_png=False, record=cli_flag)
                with patch.dict(command.__globals__, {"load_build": lambda _sha: {"screen_library": "/test/library"},
                                                      "cmd_new": unittest.mock.Mock()}), patch.dict(os.environ), \
                        patch("shutil.which", return_value=None), patch("subprocess.run") as render, \
                        contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
                    allocate = command.__globals__["cmd_new"]
                    command(args)
                allocate.assert_not_called()
                render.assert_not_called()
                self.assertEqual(err.getvalue(), "verify-rui: recordings require ffmpeg\n")

    def test_frames_refuses_missing_screen_library_before_run_allocation(self):
        command = self.helper["cmd_frames"]
        for png in (True, False):
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "scenario.json"
                path.write_text(json.dumps(self.scenario()))
                args = types.SimpleNamespace(sha="a" * 40, scenario=path, sizes=None, only=None, no_png=png)
                with patch.dict(command.__globals__, {"load_build": lambda _sha: {"screen_library": None},
                                                      "cmd_new": unittest.mock.Mock()}) as _patch, \
                        contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
                    allocate = command.__globals__["cmd_new"]
                    command(args)
                allocate.assert_not_called()
                self.assertEqual(err.getvalue(), "verify-rui: this build has no screen library\n")

    @unittest.skipUnless(os.environ.get("RUI_TEST_GHOSTTY_VT"), "native observer library not selected")
    def test_plain_pty_sets_size_before_exec_answers_queries_and_commits_exit(self):
        program = r"""
import os, signal, tty
tty.setraw(0)
os.write(1, b'\x1b]11;?\x1b\\')
reply = os.read(0, 128)
def draw(text):
    width, height = os.get_terminal_size()
    os.write(1, ('\x1b[?2026h\x1b[2J\x1b[H' + str(width) + 'x' + str(height) + ':' + text + '\x1b[?2026l').encode())
signal.signal(signal.SIGWINCH, lambda *_args: draw('resized'))
draw(reply.hex() + (":foreground" if os.getsid(0) != os.getpid() and os.tcgetpgrp(0) == os.getpgrp() else ":leader"))
while True:
    data = os.read(0, 1)
    if data == b'q':
        os.write(1, b'\x1b[2J\x1b[Hexited')
        break
    draw(data.decode())
"""
        terminal_type = self.helper["FrameTerminal"]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            run = types.SimpleNamespace(evidence=root, project=root, env=lambda **_extra: dict(os.environ))
            with patch.dict(terminal_type.__init__.__globals__, {"session_argv": lambda *_args: [sys.executable, "-c", program]}):
                terminal = terminal_type(run, {"name": "native", "open": "overview", "theme": "day"}, (80, 8))
            try:
                terminal.wait(lambda c: "80x8:1b5d31313b7267623a663366332f656565652f653265321b5c" in c.completed,
                              "initial size and OSC answer")
                self.assertIn(":foreground", terminal.frame.text)
                terminal.write(b"x")
                terminal.wait(lambda c: "80x8:x" in c.completed, "typed x")
                terminal.resize((50, 10))
                self.assertIn("50x10:resized", terminal.frame.text)
                terminal.write(b"q")
                terminal.wait(lambda c: terminal.collected and "exited" in c.completed, "quiescent exit", allow_exit=True)
                self.assertEqual(terminal.status, 0)
                with self.assertRaisesRegex(self.helper["FrameFailure"], "Rui exited"):
                    terminal.wait(lambda _c: False, "unreachable")
            finally:
                terminal.close()
            events = self.helper["read_jsonl"](terminal.log / "output.jsonl")
            self.assertEqual([event["resize"] for event in events if "resize" in event], [[50, 10]])
            offset = 0
            for event in events:
                self.assertIn("t_ns", event)
                if "resize" not in event:
                    self.assertEqual(event["offset"], offset)
                    self.assertEqual(set(event), {"t_ns", "offset", "n"})
                    offset += event["n"]
            self.assertEqual(offset, (terminal.log / "output.bin").stat().st_size)
            with self.assertRaises(OSError):
                os.fstat(terminal.master)

    def assert_collector_failure_marks_state(self, phase):
        from host_process import wait_for
        command = self.helper["cmd_frames"]
        terminal_type = self.helper["FrameTerminal"]
        capture = self.helper["frame_capture"]
        feed, collected = terminal_type._feed, terminal_type._collected
        failure = RuntimeError("final commit failed" if phase == "final-commit" else "collection failed")
        seen = []
        program = r"""
import os, signal, tty
tty.setraw(0)
def draw():
    os.write(1, 'ESC[?2026hESC[2JESC[H› ReadyESC[?2026l'.replace('ESC', chr(27)).encode())
signal.signal(signal.SIGWINCH, lambda *_args: draw())
draw()
while True:
    data = os.read(0, 1)
    if data == b'f':
        os.write(1, b'x')
    elif data == b'q':
        break
"""

        def failing_feed(terminal, data):
            if getattr(terminal, "fail_feed", False):
                raise failure
            return feed(terminal, data)

        def failing_commit(terminal, error):
            if terminal.state["name"] == "failing" and phase == "final-commit":
                with patch.object(terminal.capture, "commit", side_effect=failure):
                    return collected(terminal, error)
            return collected(terminal, error)

        def fail_collection(terminal):
            terminal.fail_feed = phase != "final-commit"
            terminal.write(b"q" if phase == "final-commit" else b"f")
            wait_for(lambda: terminal.collected, "injected collector outcome", drain=False)
            self.assertNotIn("error", vars(terminal))
            for read in (lambda: terminal.frame,
                         lambda: terminal.wait(lambda _capture: True, "already visible", timeout=0, allow_exit=True)):
                with self.assertRaises(RuntimeError) as raised:
                    read()
                self.assertIs(raised.exception, failure)

        def capture_with_failure(run, terminal, out, state, size, reason):
            last = state["name"] == "failing" and size == state["sizes"][-1]
            if last and phase == "before-capture":
                fail_collection(terminal)
            record = capture(run, terminal, out, state, size, reason)
            seen.append((state["name"], size))
            if last and phase != "before-capture":
                fail_collection(terminal)
            return record

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "scenario.json"
            source.write_text(json.dumps({"sizes": ["80x8", "60x6"], "states": [
                {"name": name, "open": "overview", "steps": [], "expect": "Ready"}
                for name in ("failing", "healthy")]}))
            run = types.SimpleNamespace(root=root, home=root / "home", store=root / "store",
                                        project=root, evidence=root / "evidence", meta={"sha": "a" * 40},
                                        env=lambda **_extra: dict(os.environ))
            args = types.SimpleNamespace(sha="a" * 40, scenario=source, sizes=None, only=None,
                                         no_png=True, record=False, keep=False, out=str(root / "out"))
            replacements = {"Run": lambda _path: run, "cmd_new": lambda _args: print(root),
                            "cmd_cleanup": lambda _args: None,
                            "load_build": lambda _sha: {"screen_library": os.environ["RUI_TEST_GHOSTTY_VT"]},
                            "session_argv": lambda *_args: [sys.executable, "-c", program],
                            "frame_capture": capture_with_failure}
            with patch.dict(command.__globals__, replacements), patch.dict(os.environ), \
                    patch.object(terminal_type, "_feed", failing_feed), \
                    patch.object(terminal_type, "_collected", failing_commit), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as result:
                command(args)
            self.assertEqual(result.exception.code, 1)
            records = json.loads((root / "out/frames.json").read_text())
            self.assertIn("failed: " + str(failure), (root / "out/index.html").read_text())
            failed = [record for record in records if record["name"] == "failing"]
            healthy = [record for record in records if record["name"] == "healthy"]
            self.assertEqual(len(failed), 2)
            self.assertTrue(all(not record["ok"] and record["status"] == "failed"
                                and record["reason"] == str(failure) for record in failed))
            self.assertEqual(len(healthy), 2)
            self.assertTrue(all(record["ok"] for record in healthy))
            if phase == "before-capture":
                self.assertNotIn(("failing", (60, 6)), seen)
            else:
                self.assertIn(("failing", (60, 6)), seen)
                self.assertTrue(all("html" in record["files"] for record in failed))

    @unittest.skipUnless(os.environ.get("RUI_TEST_GHOSTTY_VT"), "native observer library not selected")
    def test_collection_failure_before_last_capture_fails_state(self):
        self.assert_collector_failure_marks_state("before-capture")

    @unittest.skipUnless(os.environ.get("RUI_TEST_GHOSTTY_VT"), "native observer library not selected")
    def test_collection_failure_after_last_capture_fails_state(self):
        self.assert_collector_failure_marks_state("after-capture")

    @unittest.skipUnless(os.environ.get("RUI_TEST_GHOSTTY_VT"), "native observer library not selected")
    def test_final_commit_failure_fails_state(self):
        self.assert_collector_failure_marks_state("final-commit")

    @unittest.skipUnless(os.environ.get("RUI_TEST_GHOSTTY_VT"), "native observer library not selected")
    def test_mouse_steps_send_first_matching_cell_and_exact_sgr_bytes(self):
        import threading
        from terminal_screen import ScreenCapture
        steps, owner = self.helper["frame_steps"], self.helper["FrameTerminal"]
        for action, expected in (("move", b"\x1b[<35;7;2M"),
                                 ("click", b"\x1b[<0;7;2M\x1b[<0;7;2m")):
            with self.subTest(action=action), tempfile.TemporaryDirectory() as temp:
                terminal = owner.__new__(owner)
                terminal.condition = threading.Condition()
                terminal.process = types.SimpleNamespace(output=types.SimpleNamespace(check=lambda: None, complete=False))
                terminal.pressed = None
                terminal.log = Path(temp)
                terminal.capture = ScreenCapture(40, 8)
                self.addCleanup(terminal.capture.free)
                terminal.capture.feed("\x1b[?1003h\x1b[?1006hHeader\r\n界e\u0301   Target Target\r\nTarget".encode())
                terminal.capture.commit()
                writes = []
                terminal.write = lambda data, _kind: writes.append(data)
                steps(None, terminal, [{"mouse": {"at": "Target", "do": action}, "repaint": False}])
                self.assertEqual(b"".join(writes), expected)
                self.assertTrue(all(row["at"] == [6, 1]
                                    for row in self.helper["read_jsonl"](terminal.log / "mouse.jsonl")))

    def test_mouse_absent_target_fails_without_injection(self):
        import threading
        owner = self.helper["FrameTerminal"]
        terminal = owner.__new__(owner)
        terminal.condition = threading.Condition()
        terminal.process = types.SimpleNamespace(output=types.SimpleNamespace(check=lambda: None))
        terminal.capture = types.SimpleNamespace(frame=committed("Other"), mouse=unittest.mock.Mock())
        terminal.write = unittest.mock.Mock()
        with self.assertRaisesRegex(self.helper["FrameFailure"], "mouse target absent from committed frame: 'Missing'"):
            self.helper["frame_steps"](None, terminal, [{"mouse": {"at": "Missing", "do": "move"}}])
        terminal.capture.mouse.assert_not_called()
        terminal.write.assert_not_called()

    def test_mouse_validation(self):
        for value in ({"at": "Target", "do": "move"}, {"at": "Target", "do": "click"}):
            data = self.scenario()
            data["states"][1].update(steps=[{"mouse": value}], expect="Target")
            self.helper["validate_scenario"](data)
        for value in (None, {}, {"at": "", "do": "move"}, {"at": "x", "do": "drag"},
                      {"at": "x\ny", "do": "move"}, {"at": "x\ry", "do": "move"},
                      {"at": "x", "do": "move", "extra": 1}):
            data = self.scenario()
            data["states"][1].update(steps=[{"mouse": value}], expect=[])
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "mouse"):
                self.helper["validate_scenario"](data)

    def test_sizes(self):
        parse = self.helper["parse_sizes"]
        self.assertEqual(parse("140x40,46x30"), [(140, 40), (46, 30)])
        self.assertEqual(parse(["1x1"]), [(1, 1)])
        for value in (None, [], "", "0x30", "46x0", "-1x3", "12X3", "12x", "2x3,", "2x3,2x3", [42], " 2x3"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse(value)

    def test_first_run_states_are_isolated_and_validate_before_launch(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        for name in ("first-run", "first-run-browser", "first-run-codex", "first-run-key"):
            self.assertTrue(states[name]["first_run"])
            self.assertEqual(states[name]["open"], "overview")
        for name in ("first-run-browser", "first-run-codex"):
            self.assertEqual(states[name]["env"]["RUI_TEST_LOGIN"], "waiting")
        for invalid in ("yes", 1, None):
            data = self.scenario()
            data["states"][0]["first_run"] = invalid
            with self.assertRaisesRegex(ValueError, "first_run must be a boolean"):
                self.helper["validate_scenario"](data)

    def test_load_and_validate_scenario(self):
        data = self.scenario()
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "scenario.json"
            path.write_text(json.dumps(data))
            loaded = self.helper["load_scenario"](path)
            self.assertEqual(loaded["sizes"], [(140, 40), (46, 30)])
            self.assertEqual(loaded["states"][0]["sizes"], [(140, 40), (46, 30)])
            self.assertEqual(loaded["states"][0]["expect"], [])
            self.assertEqual(loaded["states"][1]["expect"], ["Keys"])
            snapshot = self.helper["scenario_snapshot"](loaded)
            path.write_text(json.dumps(snapshot))
            self.assertEqual(self.helper["load_scenario"](path), loaded)
            self.assertEqual(data, self.scenario())
        default = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        self.assertEqual(default["sizes"], [(140, 40), (46, 30)])
        self.assertGreater(len(default["states"]), 25)

    def test_regex_absences_validate_and_roundtrip_before_launch(self):
        pattern = r"^ *○ [0123456789abcdefghjkmnpqrstvwxyz]{6} +(?:now|[0-9]+[mhd])\b"
        data = self.scenario()
        data["states"][0]["absent_regex"] = [pattern]
        validated = self.helper["validate_scenario"](data)
        self.assertEqual(validated["states"][0]["absent_regex"], [pattern])
        self.assertEqual(self.helper["validate_scenario"](self.helper["scenario_snapshot"](validated)), validated)
        for invalid in (None, "pattern", [""], [12], ["nul\0"], ["("], ["(?q)"]):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "absent_regex"):
                data["states"][0]["absent_regex"] = invalid
                self.helper["validate_scenario"](data)

    def test_regex_absences_reject_dynamic_rows_in_readiness_and_saved_captures(self):
        state = {"name": "no-empty-rows", "steps": [], "expect": ["Settings"],
                 "absent_regex": [r"^ *○ [0123456789abcdefghjkmnpqrstvwxyz]{6} +(?:now|[0-9]+[mhd])\b"]}
        clean = " + New Session\n   Existing conversation  3h\n   Settings"
        run = types.SimpleNamespace(meta={"sha": "a" * 40})
        for size in ((140, 40), (46, 30)):
            for sid, age in (("9xt4vy", "now"), ("emged6", "7m"), ("000000", "3h"), ("zzzzzz", "12d"),
                             ("9xt4vy", "now ┆"), ("emged6", "7m┆ Model")):
                with self.subTest(size=size, sid=sid, age=age), tempfile.TemporaryDirectory() as temp:
                    bad = f"{clean}\n ○ {sid}                  {age}"

                    def wait(predicate, description, **_kwargs):
                        self.assertIn("absent_regex", description)
                        self.assertFalse(predicate(types.SimpleNamespace(completed=bad)))
                        self.assertTrue(predicate(types.SimpleNamespace(completed=clean)))

                    self.helper["frame_ready"](types.SimpleNamespace(wait=wait), state)
                    for frame, expected in ((bad, False), (clean, True)):
                        terminal = types.SimpleNamespace(frame=committed(frame, *size))
                        record = self.helper["frame_capture"](run, terminal, Path(temp), state, size, None)
                        self.assertEqual(record["ok"], expected)
                        if not expected:
                            self.assertIn("unexpected row matching", record["reason"])
                            self.assertIn(sid, record["reason"])
                        self.assertEqual((Path(temp) / record["files"]["txt"]).read_text(), frame + "\n")
                    terminal = types.SimpleNamespace(wait=unittest.mock.Mock(), frame=committed(bad, *size))
                    transition = {**state, "first_frame": True}
                    self.helper["frame_ready"](terminal, transition)
                    terminal.wait.assert_not_called()
                    self.assertFalse(self.helper["frame_capture"](run, terminal, Path(temp), transition, size, None)["ok"])
        for row in (" ○ Existing 9xt4vy  2m", " ○ 9xt4vy extra  2m", " ○ 9xt4vy  text  2m",
                    " ○ 9xt4vy", "text mentions ○ 9xt4vy  2m"):
            with self.subTest(named_or_nonrow=row):
                self.assertIsNone(self.helper["frame_row_failure"](state, clean + "\n" + row))
        for row in (" ○ 9xt4vy  now ┆", " ○ emged6  now┆ Model", " ○ 000000  2m ┆chat text"):
            with self.subTest(raw_sidebar=row):
                self.assertIsNotNone(self.helper["frame_row_failure"](state, row))
        for row in (" ○ New Session  now ┆", " ○ New Session  now ┆Model",
                    " ○ Existing 9xt4vy  2m ┆chat", " ○ 9xt4vy extra  2m ┆chat"):
            with self.subTest(named_sidebar=row):
                self.assertIsNone(self.helper["frame_row_failure"](state, row))
        self.assertIsNone(self.helper["frame_row_failure"]({"name": "unrelated"}, " ○ 9xt4vy  now"))

    def test_raw_id_guard_recognizes_legacy_and_stitched_dividers_in_old_recipes(self):
        from terminal_screen import DIVIDER_GLYPHS
        failure = self.helper["frame_row_failure"]
        for recipe_glyph in DIVIDER_GLYPHS[:2]:
            pattern = r"^ *○ [0123456789abcdefghjkmnpqrstvwxyz]{6} +(?:now|[0-9]+[mhd]) *(?:" + recipe_glyph + r".*)?$"
            state = {"name": "read-image-approval", "absent_regex": [pattern]}
            for divider in DIVIDER_GLYPHS:
                with self.subTest(recipe=recipe_glyph, frame=divider):
                    self.assertIsNotNone(failure(state, f" ○ 9xt4vy  now {divider} chat"))
                    self.assertIsNone(failure(state, f" ○ New Session  now {divider} chat"))

    def test_read_image_raw_id_guard_uses_shared_divider_glyphs(self):
        from terminal_screen import DIVIDER_GLYPHS
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        state = next(state for state in scenario["states"] if state["name"] == "read-image-approval")
        for divider in DIVIDER_GLYPHS:
            with self.subTest(divider=divider):
                self.assertIsNotNone(self.helper["frame_row_failure"](state, f" ○ 9xt4vy  2s {divider} chat"))
                self.assertIsNone(self.helper["frame_row_failure"](state, f" ○ Named session  2s {divider} chat"))

    def test_empty_chat_roundtrips_and_current_chat_labels_exclude_raw_ids(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        for name in ("start-empty", "day-start", "start-busy", "overview-printable-ignored", "many-sessions",
                     "many-sessions-middle", "many-sessions-end", "many-sessions-pinned-end",
                     "empty-chat-left", "empty-chat-model-left", "empty-chat-two-left"):
            with self.subTest(state=name):
                state = states[name]
                self.assertEqual(set(state["sizes"]), {(140, 40), (46, 30)})
                self.assertIsNotNone(self.helper["frame_row_failure"](state, " ○ 9xt4vy                  2m"))
        for name, state in states.items():
            if state.get("first_run"):
                continue
            with self.subTest(raw_id_excluded_in_state=name):
                self.assertIsNotNone(self.helper["frame_row_failure"](state, "─" * 20 + "┼" + "─" * 20 + "\n" + " ○ 9xt4vy  now".ljust(20) + "│ chat"))
        for name in ("chat-empty", "start-model", "start-effort", "start-picked"):
            state = states[name]
            steps = state["steps"]
            typed_ready = steps.index({"wait": "Type a task"})
            self.assertEqual(steps[typed_ready + 1], {"wait": "○ New Session", "min_columns": 140})
            self.assertEqual(state["sizes"], [(140, 40), (46, 30)])
            self.assertIsNone(self.helper["frame_row_failure"](
                {"name": name, "absent_sidebar_regex": state["absent_sidebar_regex"]}, " ○ New Session  now │chat"))
        for name in ("empty-chat-left", "empty-chat-model-left", "empty-chat-two-left"):
            state = states[name]
            self.assertTrue(state["first_frame"])
            self.assertIn("Type a task", state["absent"])
            self.assertIn("Existing conversation", state["expect"])
            self.assertEqual(state["steps"][-1], {"gone": "Type a task"})
        model = states["empty-chat-model-left"]["steps"]
        opened = model.index({"mouse": {"at": "gpt-6.1-sol", "do": "click"}})
        typed = model.index({"text": "ter"})
        picked = model.index({"keys": ["Down", "Enter"]})
        self.assertEqual(model[opened + 1:typed], [{"wait": "Model"}])
        self.assertEqual(model[typed + 1:picked], [{"wait": "ter\n"}, {"wait": "gpt-6.1-terra"}])
        self.assertNotIn({"wait": "Model           ter"}, model)
        self.assertNotIn({"mouse": {"at": "gpt-6.1-terra", "do": "click"}}, model)
        self.assertIn({"wait": "gpt-6.1-terra ·"}, model)
        self.assertIn({"gone": "Model"}, model)
        self.assertEqual(sum(step == {"keys": ["Home", "Enter"]} for step in states["empty-chat-two-left"]["steps"]), 2)
        self.assertIn("Existing second conversation", states["empty-chat-two-left"]["expect"])
        self.assertTrue(states["empty-chat-left"]["cast"][0]["messages"])
        self.assertTrue(states["empty-chat-two-left"]["cast"][0]["messages"])

    def test_launch_frames_distinguish_resized_chat_and_fresh_narrow_overview(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        wide, narrow = states["wide-launch"], states["narrow-launch"]
        self.assertIn({"wait": "+ New Session"}, wide["steps"])
        self.assertIn({"wait": "Type a task", "min_columns": 100}, wide["steps"])
        self.assertEqual(wide["expect"], ["Type a task"])
        self.assertIn("enter open", wide["absent"])
        self.assertEqual(narrow["sizes"], [(46, 30)])
        self.assertEqual(narrow["expect"], ["+ New Session", "Settings"])
        self.assertIn("Type a task", narrow["absent"])
        self.assertIn("enter open", narrow["absent"])

    def test_settings_frame_opens_the_list_row_and_waits_for_the_page(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        state = next(state for state in scenario["states"] if state["name"] == "settings")
        self.assertEqual(state["open"], "overview")
        self.assertEqual(state["sizes"], [(140, 40), (46, 30)])
        self.assertEqual(state["steps"], [
            {"wait": "+ New Session"},
            {"wait": "Type a task", "min_columns": 100},
            {"keys": ["Esc"]},
            {"gone": "Type a task"},
            {"keys": ["End", "Enter"]},
            {"wait": "Rui"}, {"wait": "Notifications"},
        ])
        self.assertEqual(state["expect"], ["Rui", "Notifications", "Sign-in", "Version", "Keys"])

    def test_markdown_frames_show_the_compact_answer_at_both_sizes_and_colours(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        for name in ("markdown", "day-chat", "no-color"):
            with self.subTest(state=name):
                state = states[name]
                self.assertEqual(state["open"], "Markdown retry")
                self.assertEqual(state["sizes"], [(140, 40), (46, 30)])
                for text in ("What I changed", "retry.zig", "pub fn next",
                             "Late request  waits 30 s  fails at once", "retry policy notes"):
                    self.assertIn(text, state["expect"])
        self.assertEqual(states["day-chat"]["theme"], "day")
        self.assertEqual(states["no-color"]["env"]["NO_COLOR"], "1")
        text = states["markdown"]["cast"][0]["messages"][0]
        for mode in ("echo", "realistic"):
            answer = self.helper["fixture_answer"](text, 1, mode)
            for marker in ("## What I changed", "1. `retry.zig`", "```zig", "| Case |",
                           "return null; // expired\n\n", "[retry policy notes](https://"):
                self.assertIn(marker, answer)
        for name in ("chat", "chat-scrolled", "chat-top"):
            self.assertEqual(states[name]["open"], "Fix retry deadline")
            self.assertTrue(states[name]["expect"])

    def test_markdown_frame_pins_narrow_code_indent_before_the_split_layout(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        state = next(state for state in scenario["states"] if state["name"] == "markdown-wrapped")
        self.assertEqual(state["open"], "Markdown retry")
        self.assertEqual(state["sizes"], [(46, 30), (140, 40)])
        self.assertIn({"wait": "return null; //\n     expired"}, state["steps"])
        for text in ("return null; //", "expired", "Late request  waits 30 s  fails at once", "retry policy notes"):
            self.assertIn(text, state["expect"])

    def test_busy_frame_waits_for_work_text_not_a_rotating_spinner(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        state = next(state for state in scenario["states"] if state["name"] == "start-busy")
        self.assertIn({"wait": "Docs build"}, state["steps"])
        self.assertEqual(state["expect"], ["Docs build", "Benchmark idle memory", "Settings"])

    def test_fixture_summary_reads_current_and_historical_bash_sections(self):
        for label in ("stdout:", "stdout tail:"):
            with self.subTest(label=label):
                result = {"output": f"Bash succeeded. Exit code: 0.\n{label}\nprinted\nstdout:\nstdout tail:\n"}
                before = result.copy()
                self.assertEqual(self.helper["fixture_bash_stdout"](result), "printed\nstdout:\nstdout tail:")
                self.assertEqual(result, before)
        self.assertEqual(self.helper["fixture_bash_stdout"]({}), "")

    def test_default_frames_use_plain_endings_and_active_tool_marks(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        for name, words in (("stopped", "■ Stopped"),
                            ("chat-failed", "× Model reply unreadable · ctrl+r retries")):
            with self.subTest(state=name):
                self.assertEqual(states[name]["steps"], [{"wait": words}])
                self.assertEqual(states[name]["expect"], [words])
        self.assertEqual(states["tools-running"]["expect"],
                         ["⠹ Build the docs", "Run the slow tests", "ctrl+x stop"])

    def test_default_frames_cover_inline_tool_folds(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        self.assertEqual(self.helper["KEYS"]["C-o"], b"\x0f")
        self.assertEqual(self.helper["KEYS"]["S-Up"], b"\x1b[1;2A")
        for name in ("tool-open", "tool-open-two", "tool-open-long", "tool-open-nocolor"):
            with self.subTest(state=name):
                self.assertIn(name, states)
                state = states[name]
                keys = [key for step in state["steps"] for key in step.get("keys", [])]
                self.assertIn("C-o", keys)
                self.assertTrue(any(text.startswith(("✓ ", "× ")) for text in state["expect"]))
                self.assertIn({"gone": "▸"}, state["steps"])
                status = "    Bash succeeded. Exit code: 0." if name == "tool-open-long" else "    Bash failed. Exit code: 1."
                label = "    stdout:" if name == "tool-open-long" else "    stderr:"
                self.assertIn(status, state["expect"])
                self.assertIn(label, state["expect"])
                self.assertFalse(any(step.get("gone", "").startswith(("Bash ", "stdout:", "stderr:")) for step in state["steps"]))
                self.assertTrue(any(text.startswith("    ") for text in state["expect"]))
                self.assertIn({"gone": "Opening tool output…"}, state["steps"])
        self.assertEqual(states["tool-open-nocolor"]["env"], {"NO_COLOR": "1"})
        for name in ("tool-open", "tool-open-two", "tool-open-long", "tool-open-nocolor"):
            self.assertEqual(states[name]["sizes"], [(46, 30), (140, 40)])
        keys = [key for step in states["tool-open-two"]["steps"] for key in step.get("keys", [])]
        self.assertEqual(keys.count("C-o"), 2)
        self.assertIn("    output line 18", states["tool-open-long"]["expect"])
        self.assertIn("    … 14 more lines", states["tool-open-long"]["expect"])
        self.assertIn({"gone": "/details"}, states["slash"]["steps"])
        self.assertNotIn("help", states)
        self.assertIn("ctrl+o   tool output", states["keys"]["expect"])
        self.assertIn("ctrl+c   leave", states["keys"]["expect"])
        self.assertEqual(len(states["keys"]["expect"]), 14)
        for meaning in ("next focus", "previous focus", "list/chat · info actions"):
            self.assertIn(meaning, states["keys"]["expect"])
        self.assertIn("/help", states["keys"]["absent"])
        self.assertIn("× Fail with exit 127", states["chat"]["expect"])
        self.assertIn("exit 127", states["chat"]["expect"])

    def test_tool_frames_require_adjacent_rows_and_explicit_exit_fields(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        for name in ("chat", "tool-open", "tool-open-two", "tool-open-nocolor"):
            with self.subTest(state=name):
                self.assertIn("exit 127", states[name]["expect"])
                self.assertIn("exit 1", states[name]["expect"])
                self.assertEqual(states[name]["expect_next"]["× Fail with exit 127"], "× Fail with an excerpt")
                self.assertIn("Fail with exit 127 · 127", states[name]["absent"])

    def test_slashlist_frames_cover_both_themes_sizes_and_matched_spans(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        self.assertEqual(scenario["sizes"], [(140, 40), (46, 30)])
        self.assertIn("/model", states["slash"]["expect"])
        self.assertIn("code · file", states["slash"]["absent"])
        escape = states["draft-chat-choice-escape"]
        self.assertNotIn("Draft lifecycle", escape["expect"])  # Sidebar is hidden at 46 columns.
        self.assertIn("gpt-6.1-sol", escape["expect"])
        self.assertIn("alt+i info", escape["absent"])
        self.assertEqual(escape["steps"][-1], {"gone": "enter pick"})
        for suffix, theme, ink in (("", "night", "#a9b6ec"), ("-day", "day", "#1f2d6b")):
            with self.subTest(theme=theme):
                help_state = states["slashlist-help" + suffix]
                description = states["slashlist-description" + suffix]
                known = states["slashlist-known" + suffix]
                for state in (help_state, description, known):
                    self.assertEqual(state.get("theme", "night"), theme)
                    self.assertEqual(state.get("sizes", scenario["sizes"]), [(140, 40), (46, 30)])
                self.assertIn({"text": "help", "within": "/help", "bold": True}, help_state["expect_style"])
                self.assertIn({"text": "help", "within": "/review-help", "bold": True}, help_state["expect_style"])
                self.assertIn({"text": "/review-", "within": "/review-help", "bold": False}, help_state["expect_style"])
                self.assertIn({"text": "/verify"}, description["steps"])
                self.assertIn({"text": "Verify", "within": "Verify the project", "bold": True}, description["expect_style"])
                self.assertIn({"text": " the project", "within": "Verify the project", "bold": False}, description["expect_style"])
                self.assertIn({"text": "/help", "bold": False}, description["expect_style"])
                self.assertIn({"text": "/new", "within": "› /new", "foreground": ink}, known["expect_style"])
                body = "#2f2b25" if theme == "day" else "#d4cebf"
                wash = "#dedad5" if theme == "day" else "#2b2f45"
                self.assertIn({"text": "/help", "within": "› /help", "foreground": ink}, help_state["expect_style"])
                self.assertIn({"text": "/verify", "within": "› /verify", "foreground": body}, description["expect_style"])
                for state, marker, word in ((help_state, "/help           Verify", "/help"),
                                            (description, "/help           Verify", "/help"),
                                            (known, "/new            start", "/new")):
                    # Marker spans selected name, blank name-column padding and description.
                    self.assertEqual(state["expect_background"], {marker: wash})
                    self.assertIn({"text": word, "within": marker, "foreground": body}, state["expect_style"])

    def test_two_open_folds_select_list_before_resizing_to_the_split_layout(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        state = next(state for state in scenario["states"] if state["name"] == "tool-open-two")
        self.assertEqual(state["sizes"], [(46, 30), (140, 40)])
        self.assertEqual(state["steps"][:13], [
            {"wait": "The project has a README"},
            {"keys": ["C-o"]},
            {"wait": "    stderr:"},
            {"gone": "Opening tool output…"},
            {"keys": ["PgDn"]},
            {"wait": "    unknown option --help"},
            {"keys": ["Up"] * 12},
            {"wait": "✓ List project files"},
            {"gone": "× Fail with exit 127"},
            {"keys": ["C-o"]},
            {"wait": "    Bash succeeded. Exit code: 0."},
            {"gone": "Opening tool output…"},
            {"keys": ["PgDn"] * 3},
        ])
        for text in ("✓ List project files", "    README.md", "    src",
                     "× Fail with exit 127", "× Fail with an excerpt",
                     "    Bash succeeded. Exit code: 0.", "    stdout:", "    Bash failed. Exit code: 1.", "    stderr:",
                     "    usage: example", "    unknown option --help"):
            self.assertIn(text, state["expect"])

    def test_status_word_frames_reject_the_old_prose(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        for name, wanted, old in (
            ("tool-open-two", "× Fail with exit 127", " · exit 127"),
            ("fold-hover", "× Fail with exit 127", " · exit 127"),
            ("fold-hover", "× Fail with an excerpt", " · exit 1"),
            ("chat-working", "Thinking", "Waiting"),
            ("copy-no-code", "No code block", "No code block in the last answer."),
        ):
            with self.subTest(state=name):
                self.assertIn(wanted, states[name]["expect"])
                self.assertIn(old, states[name]["absent"])

    def test_no_frame_waits_for_or_expects_retired_status_words(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        retired = (" · exit ", "⠹ Waiting", "No answer to copy yet.",
                   "No code block in the last answer.")
        for state in scenario["states"]:
            markers = state.get("expect", [])
            if isinstance(markers, str):
                markers = [markers]
            markers = [*markers, *(step["wait"] for step in state["steps"] if "wait" in step)]
            for marker in markers:
                with self.subTest(state=state["name"], marker=marker):
                    for old in retired:
                        self.assertNotIn(old, marker)

    def test_stop_frame_owns_work_and_waits_for_the_stable_ending(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        self.assertNotIn("stopping", states)
        state = states["stop"]
        self.assertEqual(state["open"], "Stop the slow job")
        self.assertEqual(state["cast"][0]["label"], state["open"])
        self.assertEqual(state["cast"][0]["messages"], ["Ready."])
        self.assertEqual(state["sizes"], [(140, 40)])
        self.assertEqual(state["steps"], [
            {"send": {"to": state["open"], "text": "long bash", "wait": False}},
            {"wait": "⠹ Sleep eight seconds"}, {"keys": ["C-x"]},
            {"wait": "■ Stopped", "timeout": 60},
        ])
        self.assertEqual(state["expect"], ["■ Stopped", "   Stopped"])
        self.assertTrue(state["first_frame"])
        self.assertEqual(state["expect_next"], {"■ Stop the slow job": "   Stopped"})
        narrow = states["stop-narrow"]
        self.assertEqual(narrow["sizes"], [(46, 30)])
        self.assertNotEqual(narrow["open"], state["open"])
        self.assertEqual(narrow["cast"][0]["label"], narrow["open"])
        self.assertEqual(narrow["cast"][0]["messages"], ["Ready."])
        self.assertEqual(narrow["steps"][0], {"send": {"to": narrow["open"], "text": "long bash", "wait": False}})
        self.assertEqual(narrow["steps"][1:], state["steps"][1:])
        self.assertEqual(narrow["expect"], ["■ Stopped"])
        self.assertIn("ctrl+x stop", narrow["absent"])
        self.assertEqual(state["absent"], ["Stopping"])
        stopped = states["stopped"]
        self.assertEqual(stopped["open"], "Profile the Host under load")
        seeded = next(entry for state in scenario["states"] for entry in state.get("cast", [])
                      if entry["label"] == stopped["open"])
        self.assertEqual(seeded["settle"], "stop")
        self.assertIn("long bash", seeded["messages"][-1])

    def test_live_chat_frames_do_not_borrow_or_mutate_retry_work(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        labels = set()
        for name in ("chat-working", "chat-queued", "tools-running"):
            with self.subTest(state=name):
                state = states[name]
                self.assertNotEqual(state["open"], "Fix retry deadline")
                self.assertNotIn(state["open"], labels)
                labels.add(state["open"])
                self.assertEqual(state["cast"][0]["label"], state["open"])
                if name != "chat-working":
                    self.assertEqual(state["steps"][0]["send"]["to"], state["open"])
                    self.assertFalse(state["steps"][0]["send"]["wait"])
        self.assertIn("slow", states["chat-queued"]["steps"][0]["send"]["text"])

    def test_cumulative_cast_and_counted_labels(self):
        data = self.scenario()
        data["states"][1]["cast"].append({"label": "Batch {n}", "count": 3, "workspace": "code/batch",
                                           "mode": "ask", "messages": ["hello"], "settle": "pending"})
        data["states"].append({"name": "later", "open": "Batch 3", "steps": [
            {"send": {"to": "Fix it", "text": "follow up", "wait": False}}, {"host": "pause"},
            {"host": "start"}, {"sleep": 0}, {"gone": "Working", "timeout": 0.5},
        ], "theme": "day", "sizes": ["100x30"], "env": {"NO_COLOR": "1"}})
        self.helper["validate_scenario"](data)
        entries = list(self.helper["cast_entries"](data["states"][1]["cast"]))
        self.assertEqual([c["label"] for c in entries], ["Fix it", "Batch 1", "Batch 2", "Batch 3"])

    def test_invalid_scenarios(self):
        mutations = [
            lambda d: d.update(states=[]),
            lambda d: d["states"][0].update(open="Fix it"),
            lambda d: d["states"][1].update(open="missing"),
            lambda d: d["states"][1].update(open=[]),
            lambda d: d["states"][1].update(theme=[]),
            lambda d: d["states"][1].update(first_frame="yes"),
            lambda d: d["states"][1].update(expect_last=""),
            lambda d: d["states"][1].update(expect_last=[]),
            lambda d: d["states"][1].update(expect_last="line\nbreak"),
            lambda d: d["states"][1].update(expect_next=[]),
            lambda d: d["states"][1].update(expect_next={"label": 42}),
            lambda d: d["states"][1].update(expect_next={"label": "line\nbreak"}),
            lambda d: d["states"][1].update(expect=None),
            lambda d: d["states"][1].update(expect=["valid", 42]),
            lambda d: d["states"][1].update(expect=""),
            lambda d: d["states"][1].update(name="../escape"),
            lambda d: d["states"][1].update(name="empty"),
            lambda d: d["states"][1].update(steps=[{"unknown": "oops"}]),
            lambda d: d["states"][1].update(steps=[{"text": "x", "keys": ["Enter"]}]),
            lambda d: d["states"][1].update(steps=[{"keys": ["NotAKey"]}]),
            lambda d: d["states"][1].update(steps=[{"wait": "x", "timeout": -1}]),
            lambda d: d["states"][1].update(steps=[{"sleep": float("nan")}]),
            lambda d: d["states"][1].update(steps=[{"send": {"to": "missing", "text": "hi"}}]),
            lambda d: d["states"][1].update(steps=[{"send": {"to": [], "text": "hi"}}]),
            lambda d: d["states"][1].update(steps=[{"send": {"to": "Fix it", "text": "hi", "wait": "false"}}]),
            lambda d: d["states"][1]["cast"][0].update(workspace="../outside"),
            lambda d: d["states"][1]["cast"][0].update(workspace="/outside"),
            lambda d: d["states"][1]["cast"][0].update(mode="unsafe"),
            lambda d: d["states"][1]["cast"][0].update(messages=[]),
            lambda d: d["states"][1]["cast"][0].update(count=2),
            lambda d: d["states"][1]["cast"][0].update(count=True),
            lambda d: d["states"][1]["cast"].append(copy.deepcopy(d["states"][1]["cast"][0])),
        ]
        for i, mutate in enumerate(mutations):
            data = self.scenario()
            mutate(data)
            with self.subTest(mutation=i), self.assertRaises(ValueError):
                self.helper["validate_scenario"](data)

    def test_absent_requires_a_list_of_nonempty_text_markers(self):
        for value in (None, "Stopping", "", 1, {}, [""], ["Stopping", 42], ["bad\0marker"]):
            with self.subTest(absent=value):
                data = self.scenario()
                data["states"][1]["absent"] = value
                with self.assertRaisesRegex(ValueError, "chat: absent"):
                    self.helper["validate_scenario"](data)
        for value in ([], ["Stopping"], ["Stopping", "Loading"]):
            with self.subTest(absent=value):
                data = self.scenario()
                data["states"][1]["absent"] = value
                self.assertEqual(self.helper["validate_scenario"](data)["states"][1]["absent"], value)

    def test_absent_session_marker_resolves_the_actual_cast_id(self):
        data = self.scenario()
        data["states"][1]["absent"] = ["[Archived]", "/unarchive", "{session:Fix it}"]
        state = self.helper["validate_scenario"](data)["states"][1]
        self.assertEqual(self.helper["frame_absences"](state, {"Fix it": "tz05sr"}),
                         ["[Archived]", "/unarchive", "tz05sr"])
        data["states"][1]["absent"] = ["{session:Missing}"]
        with self.assertRaisesRegex(ValueError, "unknown cast label in absent"):
            self.helper["validate_scenario"](data)

    def test_answer_choices_preserve_echo_and_realistic_prose(self):
        answer = self.helper["fixture_answer"]
        self.assertEqual(answer('a "quote"', 7), 'Fixture answer 7: received "a \\"quote\\""'.replace('\\\\', '\\'))
        self.assertEqual(answer("hello", 2, "echo"), 'Fixture answer 2: received "hello"')
        realistic = answer("hello", 2, "realistic")
        self.assertIn("deadline check now runs before", realistic)
        self.assertNotIn("Fixture answer", realistic)
        self.assertIn("Ready. The project", answer("Seed history", 3, "realistic"))
        for mode in ("echo", "realistic"):
            rich = answer("rich answer", 1, mode)
            for marker in ("## What I changed", "1. `retry.zig`", "```zig", "| Case |", "https://example.com/"):
                self.assertIn(marker, rich)
            long = answer("long answer", 2, mode)
            self.assertEqual(long.count("Step "), 14)
            self.assertIn("Step 14.", long)
        summary = self.helper["fixture_summary"]
        self.assertEqual(summary("hello", 4, 3), 'Fixture tool summary 4: 3 tool results for "hello".')
        self.assertIn("Two of the three commands failed", summary("hello", 4, 3, "realistic"))
        self.assertEqual(summary("Show long tool output.", 4, 1, "realistic"),
                         "Printed thirty-two numbered lines.")

    def test_committed_cells_render_one_style_to_ansi_and_html(self):
        frame = committed("<script>&")
        cell = Cell("<script>&", 1, True, True, "0000ff", True, True, 3, True,
                    False, False, True, "ff0000", "00ff00")
        frame = frame._replace(cells=((cell,),), visible=True)
        plain, ansi, page = self.helper["cells_render"](frame)
        self.assertEqual(plain, "<script>&\n")
        for code in ("38;2;255;0;0", "48;2;0;0;255", "7", "4:3", "58;2;0;255;0"):
            self.assertIn(code, ansi)
        for snippet in ("&lt;script&gt;&amp;", "font-weight:700", "font-style:italic", "color-mix",
                        "text-decoration-style:wavy", "underline line-through overline", "left:2ch",
                        "width:100ch", ".r>span{display:inline-block;height:100%;vertical-align:top}"):
            self.assertIn(snippet, page)
        self.assertNotIn("<script>", page)
        hidden = self.helper["cells_render"](frame._replace(visible=False))[2]
        self.assertNotIn('<i id=c', hidden)

    def test_no_screen_guard_is_one_plain_line(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as result:
            self.helper["require_screen"]({"screen_library": None})
        self.assertEqual(result.exception.code, 2)
        self.assertEqual(err.getvalue(), "verify-rui: this build has no screen library\n")
        self.helper["require_screen"]({"screen_library": "/libghostty-vt.so"})

    def test_process_start_treats_zombie_as_exited(self):
        ps = self.helper["process_start"]
        with patch("subprocess.run", return_value=types.SimpleNamespace(returncode=0,
                   stdout="Z    Wed Nov 11 07:56:31 2026 [tmux: server] <defunct>\n")):
            self.assertIsNone(ps(42))
        with patch("subprocess.run", return_value=types.SimpleNamespace(returncode=0,
                   stdout="S    Wed Nov 11 07:56:31 2026 tmux -S /private/socket\n")):
            self.assertEqual(ps(42), ("Wed Nov 11 07:56:31 2026", "tmux -S /private/socket"))


    def test_invalid_build_jobs_fails_before_build(self):
        build = self.helper["cmd_build"]
        for value in ("", "0", "-1", "1.5", "abc"):
            with self.subTest(value=value), patch.dict(os.environ, {"RUI_BUILD_JOBS": value}), \
                    contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
                build(types.SimpleNamespace())
            self.assertIn("RUI_BUILD_JOBS must be a positive integer", err.getvalue())

    def test_no_screen_build_skips_emulator_and_records_null(self):
        build = self.helper["cmd_build"]
        sha = "a" * 40
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source"
            (source / "zig-out/bin").mkdir(parents=True)
            (source / "zig-out/bin/rui").write_bytes(b"pinned binary")

            def command(argv, **_kwargs):
                calls.append(argv)
                if argv[0] == "git":
                    text = "" if "status" in argv else "tree\n" if "HEAD^{tree}" in argv else sha + "\n"
                else:
                    text = "0.17.1\n" if argv[-1] == "version" else ""
                return types.SimpleNamespace(returncode=0, stdout=text)

            args = types.SimpleNamespace(sha=sha, source=str(source), repo=None, force=False, pkg_dir=None, no_screen=True)
            with patch.dict(os.environ, {"RUI_BUILD_JOBS": "2"}), patch.dict(build.__globals__, {"CACHE": root / "cache"}), patch("subprocess.run", command), \
                    contextlib.redirect_stdout(io.StringIO()):
                build(args)
            manifest = json.loads((root / "cache/builds" / sha / "manifest.json").read_text())
            self.assertIsNone(manifest["screen_library"])
            self.assertIsNone(manifest["screen_library_sha256"])
            self.assertEqual([c for c in calls if c[:2] == ["zig", "build"]],
                             [["zig", "build", "-Doptimize=ReleaseSafe", "-j2", "--summary", "all"]])
            self.assertTrue(Path(manifest["binary"]).exists())

    def test_screen_dependent_commands_refuse_before_opening_terminal(self):
        for name, args in (("cmd_term", types.SimpleNamespace(run="unused", no_tap=False)),
                           ("cmd_wait", types.SimpleNamespace(run="unused"))):
            command = self.helper[name]
            err = io.StringIO()
            with self.subTest(command=name), patch.dict(command.__globals__, {
                    "Run": lambda _path: types.SimpleNamespace(meta={"sha": "a" * 40}),
                    "load_build": lambda _sha: {"screen_library": None},
            }), contextlib.redirect_stderr(err), self.assertRaises(SystemExit):
                command(args)
            self.assertEqual(err.getvalue(), "verify-rui: this build has no screen library\n")

    def test_upgrade_context_never_overlaps_parent_host_and_restores_for_normal_states(self):
        active = {"parent": True, "child": False}
        events = []
        def pause(_run):
            self.assertTrue(active["parent"])
            self.assertFalse(active["child"])
            active["parent"] = False
            events.append("parent paused")
        def restore(_run):
            self.assertFalse(active["parent"])
            self.assertFalse(active["child"])
            active["parent"] = True
            events.append("parent restored")
        @contextlib.contextmanager
        def context(run, state, _build):
            if state.get("upgrade"):
                self.assertFalse(active["parent"])
                self.assertFalse(active["child"])
                active["child"] = True
                events.append("child entered")
            else:
                self.assertTrue(active["parent"])
            try:
                yield run, state, None
            finally:
                if state.get("upgrade"):
                    active["child"] = False
                    events.append("child retired")
        scenario = {"sizes": ["140x40"], "states": [
            {"name": "ordinary-first", "open": "overview", "steps": []},
            {"name": "upgrade-first", "upgrade": "current", "open": "overview", "steps": []},
            {"name": "upgrade-second", "upgrade": "available", "open": "overview", "steps": []},
            {"name": "ordinary-last", "open": "overview", "steps": []}]}
        self.run_frames_scenario(scenario, hooks={"frame_upgrade_run": context, "frame_pause_owned_host": pause,
                                                 "launch_host": restore, "upgrade_actor": lambda _build: None,
                                                 "require_upgrade_fixture_user": lambda: None})
        self.assertEqual(events, ["parent paused", "child entered", "child retired", "child entered", "child retired", "parent restored"])

    def run_frames_scenario(self, scenario, sizes=None, capture_ok=True, only=None, failing_state=None,
                            initial_frames=("›",), real_steps=False, hooks=None):
        command = self.helper["cmd_frames"]
        calls = []
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "scenario.json"
            source.write_text(json.dumps(scenario))
            run = types.SimpleNamespace(root=root, home=root / "home", store=root / "store",
                                        evidence=root / "evidence", project=root, rui=Path("/pinned/rui"),
                                        sock=root / "tmux.sock", meta={"sha": "a" * 40},
                                        env=lambda **extra: extra, own=lambda *_args, **_kw: None)
            args = types.SimpleNamespace(sha="a" * 40, scenario=str(source), only=only, sizes=sizes,
                                         out=str(root / "out"), no_png=True, keep=False, record=False)

            class Terminal:
                def __init__(self, _run, state, size):
                    self.state = state
                    self.status = None
                    self.frame = types.SimpleNamespace(columns=size[0], visible=False)
                    calls.append(("open", state["name"], size, state.get("theme", "night")))

                def wait(self, predicate, _description, *, allow_exit=False):
                    for screen in initial_frames:
                        calls.append(("initial-frame", screen, allow_exit))
                        if predicate(types.SimpleNamespace(completed=screen)):
                            return
                    raise AssertionError("initial readiness did not accept any committed frame")

                def write(self, data):
                    calls.append(("write", self.state["name"], data))

                def resize(self, size):
                    calls.append(("resize", size))

                def close(self):
                    calls.append(("close",))

            def capture(_run, _target, _out, state, size, reason):
                calls.append(("capture", size))
                return {"name": state["name"], "size": self.helper["size_name"](size), "files": {},
                        "ok": capture_ok, "status": "ok" if capture_ok else "failed", "note": "",
                        "reason": reason if capture_ok else "state left before capture: Working"}

            def steps(_run, target, _steps, **_kwargs):
                calls.append(("step-values", target.state["name"], _steps))
                calls.append(("steps",))
                if target.state["name"] == failing_state:
                    raise self.helper["FrameFailure"]("fixture state failed")
                return False

            replacements = {"Run": lambda _path: run, "cmd_new": lambda _args: print(root),
                            "cmd_cleanup": lambda _args: None,
                            "frame_wait": lambda _run, target, text, *a: calls.append(("wait", target.state["name"], text)),
                            "frame_ready": lambda target, state, **kw: calls.append(("ready", state["name"])), "FrameTerminal": Terminal,
                            "load_build": lambda _sha: {"screen_library": "/test/library"},
                            "frame_steps": self.helper["frame_steps"] if real_steps else steps, "frame_capture": capture}
            replacements.update(hooks or {})
            with patch.dict(command.__globals__, replacements), patch.dict(os.environ), \
                    patch("time.sleep", side_effect=AssertionError("frames must not sleep to settle")), \
                    contextlib.redirect_stdout(io.StringIO()):
                command(args)
            records = json.loads((root / "out/frames.json").read_text())
        return calls, records

    def test_shot_settle_tracks_commits_and_caps_continuous_repaints(self):
        terminal_type = self.helper["FrameTerminal"]
        settle = terminal_type.settle_shot
        commit = terminal_type._committed
        for offsets, expected in (([], 300_000_000),
                                  ([100_000_000, 250_000_000], 550_000_000),
                                  (list(range(100_000_000, 5_100_000_000, 100_000_000)), 5_000_000_000)):
            with self.subTest(offsets=len(offsets)), tempfile.TemporaryDirectory() as temp:
                clock = [0]
                pending = list(offsets)
                frame = types.SimpleNamespace(cursor=(0, 0), visible=True, columns=80, lines=24)
                capture = types.SimpleNamespace(frame=frame, generation=1)
                terminal = types.SimpleNamespace(capture=capture, last_commit_ns=0, status=None,
                    process=types.SimpleNamespace(output=types.SimpleNamespace(check=lambda: None)), log=Path(temp))
                class Condition:
                    def __enter__(self): return self
                    def __exit__(self, *_args): pass
                    def notify_all(self): pass
                    def wait(self, seconds):
                        end = clock[0] + round(seconds * 1_000_000_000)
                        if pending and pending[0] <= end:
                            clock[0] = pending.pop(0)
                            capture.generation += 1
                            commit(terminal, None, 0, 0)
                        else:
                            clock[0] = end
                terminal.condition = Condition()
                with patch.dict(settle.__globals__, {"now_ns": lambda: clock[0]}):
                    selected = settle(terminal)
                self.assertIs(selected, capture.frame)
                self.assertEqual(clock[0], expected)
                self.assertEqual(terminal.last_commit_ns, offsets[-1] if offsets else 0)
                if offsets:
                    events = [json.loads(line) for line in (terminal.log / "frames.jsonl").read_text().splitlines()]
                    self.assertEqual([event["generation"] for event in events], list(range(2, len(offsets) + 2)))

    def test_shot_settle_respects_exit_and_requires_a_committed_frame(self):
        settle = self.helper["FrameTerminal"].settle_shot
        condition = contextlib.nullcontext()
        terminal = types.SimpleNamespace(condition=condition, status=0, last_commit_ns=None,
            capture=types.SimpleNamespace(frame=None),
            process=types.SimpleNamespace(output=types.SimpleNamespace(check=lambda: None)))
        with self.assertRaisesRegex(self.helper["FrameFailure"], "exited"):
            settle(terminal)
        with self.assertRaisesRegex(self.helper["FrameFailure"], "no committed frame"):
            settle(terminal, allow_exit=True)

    def test_ordinary_first_frame_does_not_settle_after_transition(self):
        scenario = {"sizes": ["100x30"], "states": [{"name": "first", "open": "overview",
                    "steps": [], "first_frame": True, "expect": []}]}
        calls, records = self.run_frames_scenario(scenario)
        self.assertTrue(records[0]["ok"])
        self.assertLess(calls.index(("steps",)), calls.index(("capture", (100, 30))))

    def test_initial_readiness_waits_for_opening_read_before_driving_steps(self):
        cases = [
            (["› Opening…", "›"], None, False, 2),
            (["›", "› Opening…"], None, False, 1),
            (["Overview", "Opening…", "› Opening…", "›"], None, False, 4),
            (["›", "› Ready Opening…", "› Ready"], "Ready", False, 3),
            (["› Opening… The Host stopped.", "› The Host stopped."], "The Host stopped.", True, 2),
        ]
        for screens, first_wait, allow_exit, count in cases:
            with self.subTest(screens=screens, first_wait=first_wait):
                state = {"name": "initial", "open": "overview",
                         "steps": [{"wait": first_wait}] if first_wait else []}
                scenario = {"sizes": ["100x30"], "states": [state]}
                calls, records = self.run_frames_scenario(scenario, initial_frames=screens)
                self.assertEqual([call for call in calls if call[0] == "initial-frame"],
                                 [("initial-frame", screen, allow_exit) for screen in screens[:count]])
                self.assertEqual(calls[calls.index(("steps",)) - 2],
                                 ("initial-frame", screens[count - 1], allow_exit))
                self.assertTrue(records[0]["ok"])

    def test_initial_readiness_accepts_editorless_list_and_legacy_prompt(self):
        listed = " + New Session\n   Settings"
        self.assertNotIn("Type a task", listed)
        def accepts_list(predicate, _description, **_kwargs):
            self.assertTrue(predicate(types.SimpleNamespace(completed=listed)),
                            "committed overview list must not require an editor")
        self.helper["frame_initial_ready"](types.SimpleNamespace(wait=accepts_list))
        cases = [
            ([listed], None, 1),
            ([listed.replace("+ New Session", ""), listed], None, 2),
            ([listed.replace("Settings", ""), listed], None, 2),
            ([listed + " Opening…", listed], None, 2),
            ([listed, listed + " Ready"], "Ready", 2),
            ([" › Type a task"], None, 1),
            ([" › ChatGPT    API key"], None, 1),
        ]
        for screens, first_wait, count in cases:
            with self.subTest(screens=screens, first_wait=first_wait):
                state = {"name": "initial-list", "open": "overview",
                         "steps": [{"wait": first_wait}] if first_wait else []}
                calls, records = self.run_frames_scenario({"sizes": ["100x30"], "states": [state]},
                                                         initial_frames=screens)
                self.assertEqual([call for call in calls if call[0] == "initial-frame"],
                                 [("initial-frame", screen, False) for screen in screens[:count]])
                self.assertEqual(calls[calls.index(("steps",)) - 2],
                                 ("initial-frame", screens[count - 1], False))
                self.assertTrue(records[0]["ok"])

    def test_initial_readiness_requires_complete_guided_account_controls(self):
        modal = (
            '                                  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄\n'
            '                                   Sign in to Rui\n'
            '                                     Choose account  Credentials stay out of conversations.\n'
            '                                     ChatGPT         Use your subscription\n'
            '                                     API key         OpenAI or a custom Responses API\n'
            '                                     Close           Esc returns\n'
            '                                     Navigation      Tab / Shift-Tab move. Enter chooses. Esc back.\n'
        )
        cases = [("", False), ("Sign in to Rui", False), (modal, True),
                 (modal + "Opening…", False),
                 (" + New Session\n   Settings", True), (" › Type a task", True)]
        cases.extend((modal.replace(label, ""), False) for label in
                     ("Sign in to Rui", "ChatGPT", "API key", "Close", "Tab / Shift-Tab"))

        def check(predicate, _description, **_kwargs):
            for text, expected in cases:
                with self.subTest(text=text):
                    self.assertEqual(bool(predicate(types.SimpleNamespace(completed=text))), expected)

        self.helper["frame_initial_ready"](types.SimpleNamespace(wait=check))

    def test_initial_readiness_accepts_grouped_choices_buttons_and_wrapped_footer(self):
        modal = ("  Sign in to Rui\n"
                 "    Choose an account. Credentials stay out\n"
                 "    of conversations.\n"
                 "    ChatGPT         Use your subscription\n"
                 "    API key         OpenAI or a custom Responses API\n\n"
                 "    [ Close ]\n\n"
                 "    Tab / Shift-Tab move. Enter chooses.\n"
                 "    Esc back.\n")
        cases = [(modal, True), (modal + "Opening…", False)]
        cases.extend((modal.replace(marker, ""), False) for marker in
                     ("Sign in to Rui", "ChatGPT", "API key", "[ Close ]", "Tab / Shift-Tab"))
        cases.append((modal.replace("[ Close ]", "[ Close"), False))

        def check(predicate, _description, **_kwargs):
            for text, expected in cases:
                with self.subTest(text=text):
                    self.assertEqual(bool(predicate(types.SimpleNamespace(completed=text))), expected)

        self.helper["frame_initial_ready"](types.SimpleNamespace(wait=check))

    def test_frame_url_wrap_keeps_every_character_in_readiness_and_saved_capture(self):
        url = "https://auth.openai.com/codex/device"
        wrapped = "  Open URL        https://auth.openai.com/cod\n                  ex/device\n  [ Copy code ]\n  ABCD-1234\n"
        cases = [(wrapped, True), (url + "\n[ Copy code ]\nABCD-1234\n", True),
                 (wrapped.replace("ex/device", "ex/devic"), False),
                 (wrapped.replace("ex/device", "xe/device"), False),
                 (wrapped.replace("[ Copy code ]", "[ Copy\n code ]"), False),
                 (wrapped.replace("ABCD-1234", "ABCD-123"), False)]
        state = {"name": "device", "expect": [url, "[ Copy code ]", "ABCD-1234"]}
        run = types.SimpleNamespace(meta={"sha": "a" * 40})
        for text, expected in cases:
            with self.subTest(text=text), tempfile.TemporaryDirectory() as temp:
                terminal = types.SimpleNamespace(frame=committed(text, columns=46, lines=30))

                def wait(predicate, _description, **_kwargs):
                    self.assertEqual(bool(predicate(types.SimpleNamespace(completed=text))), expected)

                terminal.wait = wait
                self.helper["frame_ready"](terminal, state)
                captured = self.helper["frame_capture"](run, terminal, Path(temp), state, (46, 30), None)
                self.assertEqual(captured["ok"], expected)
                self.assertEqual((Path(temp) / captured["files"]["txt"]).read_text(), text)

    def test_frame_terminal_receives_initial_size_and_theme(self):
        scenario = {"sizes": ["100x30"], "states": [{"name": "empty", "open": "overview", "steps": [], "theme": "day"}]}
        calls, _records = self.run_frames_scenario(scenario)
        self.assertEqual(calls[0], ("open", "empty", (100, 30), "day"))
        self.assertNotIn("tmux", repr(calls))

    def test_comma_sizes_at_both_levels_execute_two_sizes_and_cli_overrides_both(self):
        scenario = {"sizes": "100x30,46x30", "states": [
            {"name": "default", "open": "overview", "steps": []},
            {"name": "override", "open": "overview", "steps": [], "sizes": "100x30,46x30"},
        ]}
        for override, expected in ((None, [(100, 30), (46, 30)]), ("90x20,50x15", [(90, 20), (50, 15)])):
            with self.subTest(override=override):
                calls, records = self.run_frames_scenario(scenario, override)
                self.assertEqual([c[1] for c in calls if c[0] == "capture"], expected * 2)
                self.assertEqual([r["size"] for r in records], [self.helper["size_name"](size) for size in expected] * 2)
                first = next(i for i, call in enumerate(calls) if call[0] == "capture")
                self.assertEqual(calls[first - 1], ("ready", "default"))
                second = next(i for i, call in enumerate(calls) if i > first and call[0] == "capture")
                self.assertEqual(calls[second - 2:second + 1], [("resize", expected[1]), ("ready", "default"), ("capture", expected[1])])

    def test_failed_capture_makes_the_command_fail(self):
        scenario = {"sizes": ["100x30"], "states": [{"name": "working", "open": "overview", "steps": []}]}
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
            self.run_frames_scenario(scenario, capture_ok=False)
        self.assertEqual(result.exception.code, 1)

    def test_only_runs_predecessor_wait_but_does_not_capture_it(self):
        scenario = {"sizes": ["100x30"], "states": [
            {"name": "earlier", "open": "overview", "steps": [
                {"text": "archive"}, {"wait": "archived"}]},
            {"name": "chosen", "open": "overview", "steps": []},
        ]}
        calls, records = self.run_frames_scenario(scenario, only="chosen", real_steps=True)
        self.assertLess(calls.index(("write", "earlier", b"archive")), calls.index(("wait", "earlier", "archived")))
        self.assertLess(calls.index(("wait", "earlier", "archived")), calls.index(("ready", "earlier")))
        self.assertEqual([r["name"] for r in records], ["chosen"])
        self.assertEqual(len([c for c in calls if c[0] == "capture"]), 1)

    def test_only_unknown_lists_valid_states(self):
        command = self.helper["cmd_frames"]
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "scenario.json"
            path.write_text(json.dumps({"sizes": ["100x30"], "states": [
                {"name": "valid", "open": "overview", "steps": []}]}))
            args = types.SimpleNamespace(scenario=str(path), sizes=None, only="bad")
            with contextlib.redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
                command(args)
            self.assertIn("unknown states: bad; valid states: valid", err.getvalue())

    def test_only_warns_for_failed_unselected_predecessor_and_records_selected_states(self):
        scenario = {"sizes": ["100x30"], "states": [
            {"name": "earlier", "open": "overview", "steps": []},
            {"name": "selected", "open": "overview", "steps": []},
        ]}
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            calls, records = self.run_frames_scenario(scenario, only="selected", failing_state="earlier")
        self.assertIn("warning: earlier: fixture state failed", err.getvalue())
        self.assertIn("not selected; its failure does not fail this run", err.getvalue())
        self.assertEqual([r["name"] for r in records], ["selected"])
        self.assertTrue(records[0]["ok"])
        self.assertEqual(calls.count(("steps",)), 2)
        for only in (None, "earlier,selected", "earlier"):
            with self.subTest(only=only), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit) as result:
                self.run_frames_scenario(scenario, only=only, failing_state="earlier")
            self.assertEqual(result.exception.code, 1)

    def test_expectation_defaults_to_last_wait_without_a_later_action(self):
        policy = self.helper["frame_expectations"]
        for suffix in ([], [{"sleep": 0.1}], [{"gone": "Loading"}],
                       [{"keys": ["PgDn"]}, {"wait": "After scrolling"}]):
            state = {"name": "default-policy", "steps": [{"wait": "Earlier"}, {"wait": "Before"}, *suffix]}
            expected = ["After scrolling"] if suffix and "wait" in suffix[-1] else ["Before"]
            self.assertEqual(policy(state), expected)
            data = self.scenario()
            data["states"][1] = {**data["states"][1], **state}
            self.assertEqual(self.helper["validate_scenario"](data)["states"][1]["expect"], expected)

    def test_validation_rejects_all_actions_after_last_wait_before_allocating(self):
        actions = [{"mouse": {"at": "Target", "do": "move"}}, {"keys": ["PgDn"]}, {"text": "new draft"},
                   {"send": {"to": "Fix it", "text": "new message"}}, {"host": "pause"}]
        command = self.helper["cmd_frames"]
        for action in actions:
            with self.subTest(action=action), tempfile.TemporaryDirectory() as temp:
                data = self.scenario()
                data["states"][1]["steps"] = [{"wait": "Before"}, action]
                with self.assertRaisesRegex(ValueError, "chat.*expect"):
                    self.helper["frame_expectations"](data["states"][1])
                with self.assertRaisesRegex(ValueError, "chat.*expect"):
                    self.helper["validate_scenario"](data)
                path = Path(temp) / "scenario.json"
                path.write_text(json.dumps(data))
                args = types.SimpleNamespace(scenario=str(path), sizes=None)
                err = io.StringIO()
                with patch.dict(command.__globals__, {"cmd_new": unittest.mock.Mock()}), \
                        contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as result:
                    allocate = command.__globals__["cmd_new"]
                    command(args)
                self.assertEqual(result.exception.code, 2)
                allocate.assert_not_called()
                self.assertIn("chat", err.getvalue())
                self.assertIn("expect", err.getvalue())

    def test_explicit_expectation_after_an_action_overrides_the_old_wait(self):
        for action in ({"keys": ["PgDn"]}, {"text": "new draft"},
                       {"send": {"to": "Fix it", "text": "new message"}}, {"host": "pause"}):
            for expect in ("After", ["After", "Other content"], []):
                with self.subTest(action=action, expect=expect):
                    data = self.scenario()
                    state = data["states"][1]
                    state.update(steps=[{"wait": "Before"}, action], expect=expect)
                    expected = [expect] if isinstance(expect, str) else expect
                    self.assertEqual(self.helper["frame_expectations"](state), expected)
                    self.assertEqual(self.helper["validate_scenario"](data)["states"][1]["expect"], expected)

    def test_capture_after_scrolling_can_pass_without_the_original_wait_heading(self):
        data = self.scenario()
        data["states"][1].update(steps=[{"wait": "This Session"}, {"keys": ["PgDn"]}], expect="New Sessions")
        state = self.helper["validate_scenario"](data)["states"][1]
        for screen, ok in (("New Sessions\n Model: example\n", True), ("This Session\n", False)):
            with self.subTest(screen=screen), tempfile.TemporaryDirectory() as temp:
                run = types.SimpleNamespace(meta={"sha": "a" * 40})
                terminal = types.SimpleNamespace(frame=committed(screen))
                out = Path(temp)
                record = self.helper["frame_capture"](run, terminal, out, state, (100, 20), None)
                self.assertEqual(record["ok"], ok)
                self.assertEqual(record["reason"], None if ok else "state left before capture: New Sessions")
                if ok:
                    self.assertNotIn("This Session", (out / record["files"]["txt"]).read_text())
                    self.assertIn("New Sessions", (out / record["files"]["txt"]).read_text())

    def test_background_expectations_validate_before_launch(self):
        for value in ({"› Type a task": "#e6ddc8"}, {"New Session": "#ABCDEF"}, {}):
            data = self.scenario()
            data["states"][0]["expect_background"] = value
            self.assertEqual(self.helper["validate_scenario"](data)["states"][0]["expect_background"], value)
        for value in (None, [], "#ffffff", {"": "#ffffff"}, {"a\nb": "#ffffff"},
                      {"a\rb": "#ffffff"}, {"a\0b": "#ffffff"}, {"x": "ffffff"},
                      {"x": "#fff"}, {"x": "#gggggg"}, {"x": None}):
            data = self.scenario()
            data["states"][0]["expect_background"] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "expect_background"):
                self.helper["validate_scenario"](data)

    def test_background_assertion_checks_committed_marker_cells_at_both_widths(self):
        marker = "› Type a task"
        for color, ground in (("e6ddc8", "f3eee2"), ("1a2246", "121933")):
            for width, prefix in ((140, "sidebar ┆ "), (46, " ")):
                for bad in (None, 0, len(marker) - 1):
                    with self.subTest(color=color, width=width, bad=bad), tempfile.TemporaryDirectory() as temp:
                        cells = tuple(Cell(char, None, False, bg=color if index != bad else ground)
                                      for index, char in enumerate(marker))
                        row = tuple(Cell(char, None, False, bg=ground) for char in prefix) + cells
                        frame = Frame(width, 30, Cursor(2, 3), False, (row,), ground, "d4cebf", "d4cebf")
                        state = {"name": "input", "steps": [], "expect": [marker],
                                 "expect_background": {marker: "#" + color}}
                        terminal = types.SimpleNamespace(frame=frame)
                        run = types.SimpleNamespace(meta={"sha": "a" * 40})
                        captured = self.helper["frame_capture"](run, terminal, Path(temp), state, (width, 30), None)
                        self.assertEqual(captured["ok"], bad is None)
                        self.assertEqual(captured["reason"],
                                         None if bad is None else f"{marker!r} must have background=#{color}")
                        self.assertTrue((Path(temp) / captured["files"]["txt"]).exists())
                        observed = []
                        terminal.wait = lambda check, *_args, **_kw: observed.append(check(
                            types.SimpleNamespace(completed=frame.text, frame=frame)))
                        self.helper["frame_ready"](terminal, state)
                        self.assertEqual(observed, [True])
                        self.assertEqual(self.helper["frame_background_failure"](
                            {"expect_background": {"missing": "#" + color}}, frame),
                            "missing background specimen 'missing'")

    def test_style_expectations_validate_and_check_only_the_span_inside_its_row(self):
        for value in ([], [{"text": "/new", "bold": True}], [{"text": "new", "within": "› /new", "foreground": "#ABCDEF"}]):
            data = self.scenario()
            data["states"][0]["expect_style"] = value
            self.assertEqual(self.helper["validate_scenario"](data)["states"][0]["expect_style"], value)
        for value in (None, {}, [{"text": "x"}], [{"text": "", "bold": True}], [{"text": "x", "bold": 1}],
                      [{"text": "x", "within": "y", "bold": True}], [{"text": "x", "foreground": "#fff"}],
                      [{"text": "x", "bold": True, "unknown": 1}], [{"text": "a\nb", "bold": True}]):
            data = self.scenario()
            data["states"][0]["expect_style"] = value
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "expect_style"):
                self.helper["validate_scenario"](data)
        row_text, ink, body = " › /new", "1f2d6b", "2f2b25"
        for bad in (None, 3, 4):
            with self.subTest(bad=bad):
                row = tuple(Cell(char, None, index == 5 or index == 4 and bad != 4,
                                 fg_rgb=ink if index >= 3 and not (bad == 3 and index == 3) else body)
                            for index, char in enumerate(row_text))
                frame = Frame(46, 30, Cursor(0, 0), False, (row,), "f3eee2", body, body)
                state = {"expect_style": [{"text": "/new", "within": "› /new", "foreground": "#" + ink},
                                          {"text": "ne", "within": "› /new", "bold": True}]}
                failure = self.helper["frame_style_failure"](state, frame)
                self.assertEqual(failure, None if bad is None else
                                 "'/new' in '› /new' must have foreground=#1f2d6b" if bad == 3 else
                                 "'ne' in '› /new' must have bold=True")
        # Only the span is checked: the prompt mark keeps the body colour.
        self.assertEqual(self.helper["frame_style_failure"](
            {"expect_style": [{"text": "missing", "bold": True}]}, committed("Row")), "missing style specimen 'missing'")

    def test_capture_expectations_over_sizes_and_state_transitions(self):
        capture = self.helper["frame_capture"]
        cases = [
            ("stop-clean", {"steps": [{"wait": "■ Stopped"}], "absent": ["Stopping"]},
             ["■ Stopped", "■ Stopped"], [None, None]),
            ("stop-stale", {"steps": [{"wait": "■ Stopped"}], "absent": ["Stopping"]},
             ["■ Stopped  Stopping…", "■ Stopped  Stopping…"],
             ["unexpected on screen: Stopping", "unexpected on screen: Stopping"]),
            ("raw-archive-id", {"steps": [], "absent": ["{session:Archive audit}"]},
             ["Archived tz05sr", "Archived Archive audit"],
             ["unexpected on screen: tz05sr", None]),
            ("stable", {"steps": [{"wait": "earlier"}, {"wait": "Ready"}]},
             ["Ready", "Ready"], [None, None]),
            ("transient", {"steps": [{"wait": "Working"}]},
             ["Working", "Finished"], [None, "state left before capture: Working"]),
            ("empty-expect", {"steps": [{"wait": "Working"}], "expect": []},
             ["Finished", "Finished"], [None, None]),
            ("explicit-list", {"steps": [{"wait": "irrelevant"}], "expect": ["Working", "Docs"]},
             ["Working Docs", "Working"], [None, "state left before capture: Docs"]),
            ("explicit-text", {"steps": [{"wait": "irrelevant"}], "expect": "Working"},
             ["Working", "Working"], [None, None]),
        ]
        for name, policy, screens, reasons in cases:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as temp:
                out = Path(temp)
                state = {"name": name, **policy}
                run = types.SimpleNamespace(meta={"sha": "a" * 40, "sessions": {"Archive audit": "tz05sr"}})
                records = []
                for size, screen, reason in zip(((100, 30), (46, 30)), screens, reasons):
                    terminal = types.SimpleNamespace(frame=committed(screen, *size))
                    record = capture(run, terminal, out, state, size, None)
                    records.append(record)
                    self.assertEqual(record["reason"], reason)
                    self.assertEqual(record["ok"], reason is None)
                    self.assertEqual(record["status"], "ok" if reason is None else "failed")
                    self.assertEqual((out / record["files"]["txt"]).read_text(), screen + "\n")
                    self.assertEqual((out / record["files"]["ansi"]).read_text(), self.helper["cells_render"](terminal.frame)[1])
                    self.assertIn(screen, (out / record["files"]["html"]).read_text())
                self.helper["frames_index"](out, records, False)
                self.assertEqual([r["ok"] for r in json.loads((out / "frames.json").read_text())],
                                 [reason is None for reason in reasons])

    def test_frame_exit_key_allows_dead_pane_but_text_does_not(self):
        steps = self.helper["frame_steps"]
        terminal = types.SimpleNamespace(status=0, write=lambda _data: None)
        self.assertTrue(steps(None, terminal, [{"keys": [steps.__globals__["EXIT_KEY"]]}]))
        with self.assertRaises(self.helper["FrameFailure"]):
            steps(None, terminal, [{"text": "/exit"}])

    def test_delayed_stop_ending_with_stale_stopping_fails_saved_captures(self):
        state = next(state for state in self.helper["load_scenario"](SCRIPT.with_name("frames.json"))["states"]
                     if state["name"] == "stop")
        stale = "■ Stopped\n   Stopped\n   Stopping…\n"
        run = types.SimpleNamespace(meta={"sha": "a" * 40}, store="/unused/store", sid=lambda _label: "session",
                                    rui_cmd=lambda *_args, **_kw: types.SimpleNamespace(returncode=0))
        terminal = types.SimpleNamespace(frame=committed(stale))
        ready = self.helper["frame_ready"]
        def wait(predicate, *_args, **_kwargs):
            self.assertFalse(predicate(types.SimpleNamespace(completed=stale)))
            self.assertTrue(predicate(types.SimpleNamespace(completed="■ Stopped\n   Stopped")))
        terminal.wait = wait
        ready(terminal, {**state, "first_frame": False, "expect_next": {}})
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            for size in state["sizes"]:
                with self.subTest(size=size):
                    record = self.helper["frame_capture"](run, terminal, out, state, size, None)
                    self.assertFalse(record["ok"])
                    self.assertEqual(record["reason"], "unexpected on screen: Stopping")
                    self.assertEqual((out / record["files"]["txt"]).read_text(), stale)

    def test_first_settled_frame_asserts_its_own_row_not_another_stopped_session(self):
        state = next(state for state in self.helper["load_scenario"](SCRIPT.with_name("frames.json"))["states"]
                     if state["name"] == "stop")
        terminal = types.SimpleNamespace(wait=unittest.mock.Mock(side_effect=AssertionError("must not poll past the observed ending")))
        self.helper["frame_ready"](terminal, state)
        terminal.wait.assert_not_called()
        failure = self.helper["frame_row_failure"]
        wrong = "■ Stop the slow job  now\n   Old completed answer\n■ Another Session\n   Stopped\n■ Stopped"
        self.assertIsNotNone(failure(state, wrong))
        self.assertIsNone(failure(state, wrong.replace("Old completed answer", "Stopped")))

    def test_chat_frames_require_loaded_sidebar_rows_and_a_last_row_footer(self):
        states = {state["name"]: state for state in self.helper["load_scenario"](SCRIPT.with_name("frames.json"))["states"]}
        for name in ("chat-no-new-session", "chat-sidebar-rows"):
            state = states[name]
            self.assertIn("+ New Session", state["absent"])
            self.assertEqual(state["expect_last"], "gpt-6.1-sol")
            self.assertIn("alt+i info", state["absent"])
        self.assertEqual(states["chat-no-new-session"]["sizes"][0], (140, 40))
        self.assertIn({"wait": "Schema migration"}, states["chat-no-new-session"]["steps"])
        self.assertEqual(states["chat-sidebar-rows"]["sizes"], [(140, 40)])
        for label in ("Schema migration", "Sidebar chat", "Batch job"):
            self.assertIn(label, states["chat-sidebar-rows"]["expect"])
        failure = self.helper["frame_row_failure"]
        state = {"expect_last": "gpt-6.1-sol"}
        for height in (30, 40):
            good = "\n" * (height - 1) + "gpt-6.1-sol · high\n"
            self.assertIsNone(failure(state, good))
            self.assertIsNotNone(failure(state, good + "\n"))
            self.assertIsNotNone(failure(state, good + "   Settings  ┆\n"))

    def test_chat_footer_frames_hide_permanent_info_and_unused_context(self):
        states = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))["states"]
        for state in states:
            with self.subTest(state=state["name"]):
                self.assertNotIn("alt+i info", state["expect"])
                self.assertNotEqual(state.get("expect_last"), "alt+i info")
                for step in state["steps"]:
                    if "wait" in step:
                        self.assertNotIn("alt+i info", step["wait"])
                        self.assertNotRegex(step["wait"], r"\d+% left")
        effort = next(state for state in states if state["name"] == "chat-effort")
        self.assertIn({"wait": "gpt-6.1-sol · low"}, effort["steps"])
        fresh = next(state for state in states if state["name"] == "chat-footer-below-half")
        self.assertEqual(fresh["sizes"], [(140, 40), (46, 30)])
        self.assertEqual(fresh["open"], "Context budget witness")
        self.assertEqual(fresh["cast"][0]["messages"], ["Check context budget"])
        self.assertEqual(fresh["expect_last"], "gpt-6.1-sol")
        for text in ("context left", "100% left", "alt+i info"):
            self.assertIn(text, fresh["absent"])

    def test_panels_chat_info_requires_numeric_context_at_both_sizes(self):
        states = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))["states"]
        state = next(state for state in states if state["name"] == "panels-chat-info")
        self.assertEqual(state["sizes"], [(140, 40), (46, 30)])
        self.assertIn("Context", state["expect"])
        self.assertNotIn("Context", state["absent"])
        self.assertIn("unknown of", state["absent"])
        for text in ("Allowed tools", "Copy last answer", "The retry draft is ready.", "› keep this retry draft"):
            self.assertIn(text, state["expect"])
        failure = self.helper["frame_row_failure"]
        self.assertIsNone(failure(state, "Context         18 of 244,800"))
        self.assertIsNotNone(failure(state, "Context         unknown of 244,800"))
        self.assertIsNotNone(failure(state, "Model           gpt-6.1-sol"))

    def test_stop_waits_for_a_running_bash_not_an_approval(self):
        running = self.helper["frame_bash_running"]
        for kind, count, expected in (("bash", "0", False), ("bash", "1", True),
                                      ("bash", "2", True), ("model", "1", False), ("finished", "0", False)):
            with self.subTest(kind=kind, running=count):
                self.assertEqual(running({"work": {"state": {"kind": kind, "running": count}}}), expected)
        self.assertFalse(running({}))

    def test_frames_index_preserves_order_and_escapes_failure_text(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            records = [{"name": name, "size": "46x30", "files": {"txt": name + ".txt", "html": name + ".html"},
                        "status": "failed", "ok": False, "reason": "<not markup>", "note": "shot & note"}
                       for name in ("z-first", "a-second")]
            self.helper["frames_index"](out, records, False)
            page = (out / "index.html").read_text()
            self.assertLess(page.index("z-first · 46x30"), page.index("a-second · 46x30"))
            self.assertIn("&lt;not markup&gt;", page)
            self.assertIn("shot &amp; note", page)
            self.assertEqual(json.loads((out / "frames.json").read_text()), records)


class EvidencePublicationTest(unittest.TestCase):
    def setUp(self):
        self.helper = runpy.run_path(str(SCRIPT))
        self.head, self.base = "a" * 40, "b" * 40

    def capture(self, out, name="overview", size="140x40", cells="same", sha=None):
        stem = f"{name}@{size}"
        out.mkdir(parents=True, exist_ok=True)
        files = {ext: stem + "." + ext for ext in ("png", "gif")}
        for ext, file in files.items():
            (out / file).write_bytes((cells + ext).encode())
        return dict(name=name, size=size, files=files, ok=True, status="ok", reason=None,
                    sha=sha or self.head, cells_sha256=cells, note="")

    def comparison(self, out):
        before = [self.capture(out / "before", name="same", sha=self.base),
                  self.capture(out / "before", name="changed", cells="old", sha=self.base)]
        after = [self.capture(out / "after", name="same"),
                 self.capture(out / "after", name="changed", cells="new")]
        for side, rows in (("before", before), ("after", after)):
            (out / side / "frames.json").write_text(json.dumps(rows))
        return self.helper["paired_frames"](out, self.head, self.base)

    def test_pairs_order_cell_identity_and_shared_renderer_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            result = self.comparison(out)
            self.assertEqual([(r["name"], r["same"]) for r in result["pairs"]], [("changed", False), ("same", True)])
            self.assertEqual(result, json.loads((out / "pairs.json").read_text()))
            page = (out / "index.html").read_text()
            self.assertLess(page.index("changed ·"), page.index("same ·"))
            self.assertIn("same · 140x40 — same", page)
            self.assertIn('src="before/changed@140x40.gif"', page)
            self.assertIn('src="after/changed@140x40.gif"', page)
            with self.assertRaisesRegex(ValueError, "different states"):
                (out / "before/frames.json").write_text("[]")
                self.helper["paired_frames"](out, self.head, self.base)

    def test_committed_cell_hash_detects_style_and_text_but_ignores_cursor(self):
        capture = self.helper["frame_capture"]
        run = types.SimpleNamespace(meta={"sha": self.head})
        state = dict(name="test", expect=[])
        frame = committed("same text")
        changed = frame._replace(cells=tuple(tuple(c._replace(bold=True) for c in row) for row in frame.cells))
        with tempfile.TemporaryDirectory() as directory:
            hashes = [capture(run, types.SimpleNamespace(frame=f), Path(directory), state, (100, 20), None)["cells_sha256"]
                      for f in (frame, frame._replace(cursor=Cursor(0, 0)), changed, committed("different"))]
        self.assertEqual(hashes[0], hashes[1])
        self.assertEqual(len(set(hashes)), 3)

    def test_manifest_selection_changed_default_all_states_gifs_and_failures(self):
        select = self.helper["publication_frames"]
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            data = self.comparison(out)
            head, base, rows, files = select(out)
            self.assertEqual((head, base), (self.head, self.base))
            self.assertEqual([r["name"] for r in rows], ["changed"])
            self.assertEqual(set(files), {f"{side}/changed@140x40.{ext}" for side in ("before", "after") for ext in ("png", "gif")})
            self.assertEqual(len(select(out, include_same=True)[2]), 2)
            self.assertEqual([r["name"] for r in select(out, "same", True)[2]], ["same"])
            with self.assertRaisesRegex(ValueError, "no changed captures"):
                select(out, "same")
            with self.assertRaisesRegex(ValueError, "unknown states"):
                select(out, "absent")
            data["pairs"][0]["before"].update(ok=False, reason="did not load")
            (out / "pairs.json").write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, "failed capture.*did not load"):
                select(out)

    def test_frames_before_reuses_both_runs_checks_builds_first_and_keeps_failure(self):
        command = self.helper["cmd_frames"]
        scope = command.__globals__
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "pairs"
            calls = []
            def run(args):
                calls.append((args.sha, args.only, args.sizes, args.record))
                target = Path(args.out)
                record = self.capture(target, sha=args.sha)
                (target / "frames.json").write_text(json.dumps([record]))
                if args.sha == self.base:
                    raise SystemExit(1)
            scenario = Path(directory) / "explicit.json"
            scenario.write_text(json.dumps({"sizes": "140x40,46x30", "states": [
                {"name": "overview", "open": "overview", "steps": []}]}))
            args = types.SimpleNamespace(sha=self.head, before=self.base, out=str(out), only="overview",
                                         sizes="140x40,46x30", record=True, scenario=str(scenario))
            with (patch.dict(scope, run_frames=run, load_build=lambda sha: calls.append(("build", sha)),
                             require_screen=lambda _: None),
                  patch("subprocess.check_output", side_effect=[self.head + "\n", self.base + "\n"]),
                  contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as result):
                command(args)
            self.assertEqual(result.exception.code, 1)
            self.assertEqual(calls[:2], [("build", self.head), ("build", self.base)])
            self.assertEqual([r[0] for r in calls[2:]], [self.base, self.head])
            self.assertTrue((out / "pairs.json").is_file())
        with patch.dict(scope, run_frames=lambda args: "single"):
            self.assertEqual(command(types.SimpleNamespace(before=None)), "single")
        def missing(sha):
            self.assertEqual(sha, self.head)
            raise SystemExit(2)
        with (patch.dict(scope, load_build=missing, run_frames=lambda args: self.fail("allocated run")),
              patch("subprocess.check_output", side_effect=[self.head, self.base]), self.assertRaises(SystemExit)):
            command(args)

    def compare_recipes(self, head_recipe, base_recipe, *, selected="overview", explicit=False, fail_before=False, checkout_recipe=None):
        command = self.helper["cmd_frames"]
        scope = command.__globals__
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_script = root / "a/b/c/d/verify-rui"
            fake_script.parent.mkdir(parents=True)
            head_path = fake_script.with_name("frames.json")
            head_path.write_text(json.dumps(head_recipe if checkout_recipe is None else checkout_recipe))
            calls = []
            shown = []
            def run(args):
                recipe = self.helper["load_scenario"](args.scenario or head_path, args.sizes)
                chosen = set(args.only.split(",")) if args.only else {state["name"] for state in recipe["states"]}
                self.assertTrue(chosen <= {state["name"] for state in recipe["states"]})
                records = []
                for state in recipe["states"]:
                    if state["name"] not in chosen:
                        continue
                    calls.append((args.sha, state["name"], state["steps"], state["expect"]))
                    self.assertEqual(state["expect"], head_recipe["states"][-1]["expect"] if args.sha == self.head
                                     else (head_recipe if explicit else base_recipe)["states"][0]["expect"])
                    for size in state["sizes"]:
                        record = self.capture(Path(args.out), name=state["name"], size=self.helper["size_name"](size),
                                              cells=state["expect"][0], sha=args.sha)
                        if args.sha == self.base and fail_before:
                            record.update(ok=False, reason="base readiness failed", status="failed")
                        records.append(record)
                (Path(args.out) / "frames.json").write_text(json.dumps(records))
                if args.sha == self.base and fail_before:
                    raise SystemExit(1)
            args = types.SimpleNamespace(sha=self.head, before=self.base, out=str(root / "out"),
                                         only=selected, sizes=None, scenario=str(head_path) if explicit else None,
                                         record=False)
            def output(argv, **_kwargs):
                if argv[1] == "rev-parse":
                    return self.head if argv[-1].startswith(self.head) else self.base
                self.assertIn("show", argv)
                revision, path = argv[-1].split(":", 1)
                self.assertEqual(path, ".claude/skills/verify-rui/scripts/frames.json")
                self.assertIn(revision, (self.head, self.base))
                shown.append(revision)
                return json.dumps(head_recipe if revision == self.head else base_recipe)
            with (patch.dict(scope, HERE=fake_script, run_frames=run, load_build=lambda sha: {}, require_screen=lambda _: None),
                  patch("subprocess.check_output", side_effect=output), contextlib.redirect_stdout(io.StringIO())):
                if fail_before:
                    with self.assertRaises(SystemExit) as failure:
                        command(args)
                    self.assertEqual(failure.exception.code, 1)
                else:
                    command(args)
            self.assertEqual(shown, [] if explicit else [self.head, self.base])
            out = root / "out"
            data = json.loads((out / "pairs.json").read_text())
            if fail_before:
                with self.assertRaisesRegex(ValueError, "base readiness failed"):
                    self.helper["publication_frames"](out)
            else:
                _head, _base, _rows, files = self.helper["publication_frames"](out, include_same=True)
                self.assertTrue(files)
                screens, _attachments = self.helper["screens_markdown"](self.head, self.base, data["pairs"])
                if data["pairs"][0]["new"]:
                    self.assertIn("New screen", screens)
                    self.assertEqual(set(files), {"after/overview@140x40.png", "after/overview@140x40.gif"})
                    self.assertNotIn("before", data["pairs"][0])
            return calls, data

    def recipe(self, text="Same screen", name="overview"):
        return {"sizes": "140x40", "states": [{"name": name, "open": "overview", "steps": [{"wait": text}], "expect": [text]}]}

    def test_comparison_unchanged_screen_uses_base_recipe(self):
        calls, data = self.compare_recipes(self.recipe(), self.recipe())
        self.assertEqual([call[0] for call in calls], [self.base, self.head])
        self.assertTrue(data["pairs"][0]["same"])
        self.assertFalse(data["pairs"][0]["new"])

    def test_comparison_changed_expectation_uses_each_revisions_own_recipe(self):
        calls, data = self.compare_recipes(self.recipe("New label"), self.recipe("Old label"))
        self.assertEqual([call[-1] for call in calls], [["Old label"], ["New label"]])
        self.assertEqual([call[2] for call in calls], [[{"wait": "Old label"}], [{"wait": "New label"}]])
        self.assertFalse(data["pairs"][0]["same"])
        self.assertFalse(data["pairs"][0]["new"])

    def test_comparison_new_screen_has_only_an_after_capture(self):
        calls, data = self.compare_recipes(self.recipe("New screen"), self.recipe("Existing", "older"))
        self.assertEqual([call[0] for call in calls], [self.head])
        self.assertTrue(data["pairs"][0]["new"])

    def test_comparison_matching_checkout_reads_both_pinned_recipes(self):
        self.compare_recipes(self.recipe("HEAD"), self.recipe("BASE"), checkout_recipe=self.recipe("HEAD"))

    def test_comparison_historical_head_ignores_current_checkout_recipe(self):
        calls, _data = self.compare_recipes(self.recipe("Historical HEAD"), self.recipe("Older BASE"),
                                          checkout_recipe=self.recipe("Current checkout"))
        self.assertEqual([call[-1] for call in calls], [["Older BASE"], ["Historical HEAD"]])

    def test_comparison_dirty_working_tree_recipe_is_not_implicit_override(self):
        calls, _data = self.compare_recipes(self.recipe("Committed HEAD"), self.recipe("BASE"),
                                          checkout_recipe=self.recipe("Uncommitted edit"))
        self.assertEqual(calls[-1][-1], ["Committed HEAD"])

    def test_comparison_state_introduced_after_head_is_refused(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as result:
            self.compare_recipes(self.recipe(), self.recipe(), selected="future-screen",
                                 checkout_recipe=self.recipe("Future", "future-screen"))
        self.assertEqual(result.exception.code, 2)
        self.assertIn("unknown states: future-screen", stderr.getvalue())

    def test_comparison_explicit_scenario_is_used_for_both_builds(self):
        calls, _data = self.compare_recipes(self.recipe("Explicit"), self.recipe("Old"), explicit=True)
        self.assertEqual([call[-1] for call in calls], [["Explicit"], ["Explicit"]])

    def test_comparison_failure_under_the_base_recipe_still_fails(self):
        self.compare_recipes(self.recipe("New"), self.recipe("Old"), fail_before=True)

    def test_missing_build_names_head_or_base_before_allocating_either_run(self):
        command = self.helper["cmd_frames"]
        scope = command.__globals__
        for missing in (self.head, self.base):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as directory:
                cache = Path(directory)
                if missing == self.base:
                    manifest = cache / "builds" / self.head / "manifest.json"
                    manifest.parent.mkdir(parents=True)
                    manifest.write_text("{}")
                stderr = io.StringIO()
                args = types.SimpleNamespace(sha=self.head, before=self.base, out=str(cache / "out"))
                with (patch.dict(scope, CACHE=cache, require_screen=lambda _: None,
                                 run_frames=lambda args: self.fail("allocated a run before checking builds")),
                      patch("subprocess.check_output", side_effect=[self.head, self.base]),
                      contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit)):
                    command(args)
                self.assertIn(f"no build for {missing}", stderr.getvalue())
                self.assertIn(f"verify-rui build {missing}", stderr.getvalue())
                self.assertFalse((cache / "out").exists())



    def test_native_publish_remote_spellings_and_invalid_capture_paths(self):
        for url in ("https://github.com/owner/repo", "https://github.com/owner/repo.git",
                    "git@github.com:owner/repo.git", "ssh://git@github.com/owner/repo.git"):
            self.assertEqual(self.helper["github_repository"](url), "owner/repo")
        with self.assertRaisesRegex(ValueError, "GitHub"):
            self.helper["github_repository"]("https://example.test/owner/repo")
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            record = self.capture(out)
            for name in ("../outside.png", str(out / "overview@140x40.png")):
                record["files"]["png"] = name
                (out / "frames.json").write_text(json.dumps([record]))
                with self.subTest(name=name), self.assertRaisesRegex(ValueError, "invalid capture file"):
                    self.helper["publication_frames"](out)

    def publish(self, out, pr="1549", ssh=False, **options):
        """Exercise the real CLI boundary with a fake gh executable on PATH."""
        fake = out.parent / "fake-gh"
        fake.mkdir(exist_ok=True)
        config = fake / "config.json"
        log = fake / "commands.jsonl"
        log.write_text("")
        config.write_text(json.dumps({"body": "attribution\n\n## Summary\nsummary\n\n## Screens\npending\n\n## Evidence\nkeep evidence\n\n## Merge danger\nkeep danger\nfooter\n", **options}))
        # Make origin deterministic on forks; reject any attempt to write through git.
        git = fake / "git"
        git.write_text("#!" + sys.executable + "\nimport sys\nassert sys.argv[-3:] == ['remote', 'get-url', 'origin']\nprint('https://github.com/DivyanshGolyan/rui.git')\n")
        git.chmod(0o755)
        executable = fake / "gh"
        executable.write_text("#!" + sys.executable + "\n" + r'''import hashlib, json, os, re, sys
from pathlib import Path
from urllib.parse import quote
config = Path(os.environ["FAKE_GH_CONFIG"])
data = json.loads(config.read_text())
args = sys.argv[1:]
event = {"argv": args, "cwd": os.getcwd()}
if args[:2] == ["pr", "edit"] and "--body-file" in args:
    event["body"] = Path(args[args.index("--body-file") + 1]).read_text()
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps(event) + "\n")
if args == ["--version"]:
    version = "2.89.0" if data.get("local_old") and not Path.cwd().name.startswith("verify-rui-attachments.") else data.get("version", "2.104.0")
    print("gh version " + version)
elif args == ["pr", "edit", "--help"]:
    print("--attach file" if data.get("attach_help", True) else "--body-file file")
elif args == ["auth", "token"]:
    if data.get("no_token"):
        sys.exit(1)
    print(data.get("token", "ghp_fake_test_token"))
elif args[0] == "api":
    endpoint = args[1]
    if "/pulls?" in endpoint:
        print(json.dumps([{"number": 1549}] if not data.get("no_pr") else []))
    elif "/pulls/" in endpoint:
        print(json.dumps({"body": data["body"]}))
    else:
        print(json.dumps({"permissions": {"push": data.get("push", True)}}))
elif args[:2] == ["pr", "edit"]:
    body = event["body"]
    files = [args[i + 1] for i, value in enumerate(args) if value == "--attach"]
    if data.get("partial_failure"):
        files = files[:1]
    for attachment in files:
        name, alt = attachment.rsplit("#", 1)
        assert Path(name).is_file(), name
        reference = "![" + alt + "](" + quote(name, safe="/@") + ")"
        url = "https://github.com/user-attachments/assets/" + hashlib.sha256(name.encode()).hexdigest()
        body = body.replace(reference, "![" + alt + "](" + url + ")")
    if data.get("mangle"):
        body = body.replace("![", "[")
    if data.get("inline_code"):
        body = re.sub(r"^(!\[[^\n]+)$", r"`\1`", body, flags=re.M)
    data["body"] = body
    config.write_text(json.dumps(data))
    print("https://github.com/DivyanshGolyan/rui/pull/1549")
    sys.exit(1 if data.get("partial_failure") else 0)
else:
    raise AssertionError(args)
''')
        executable.chmod(0o755)
        if ssh:
            transport = r'''import json, os, shlex, shutil, subprocess, sys, tempfile
from pathlib import Path
args = sys.argv[1:]
kind = Path(sys.argv[0]).name
config = json.loads(Path(os.environ["FAKE_GH_CONFIG"]).read_text())
event = {"transport": kind, "argv": args, "cwd": os.getcwd()}
if kind == "scp":
    source, target = args[-2:]
    destination = target.split(":", 1)[1]
    event["files"] = sorted(str(p.relative_to(Path(source))) for p in Path(source).rglob("*") if p.is_file())
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps(event) + "\n")
if kind == "scp":
    if config.get("scp_failure"):
        print("copy failed", file=sys.stderr)
        sys.exit(1)
    shutil.copytree(source, destination, dirs_exist_ok=True)
else:
    command = shlex.split(args[-1])
    if command[0] == "mktemp":
        print(tempfile.mkdtemp(prefix="verify-rui-attachments."))
    elif command[0] == "rm":
        shutil.rmtree(command[-1])
    elif command[0] == "python3":
        sys.exit(subprocess.run([sys.executable, *command[1:]]).returncode)
    else:
        raise AssertionError(command)
'''
            for name in ("ssh", "scp"):
                program = fake / name
                program.write_text("#!" + sys.executable + "\n" + transport)
                program.chmod(0o755)
        command = [sys.executable, str(SCRIPT), "publish", str(out)]
        if ssh:
            command += ["--ssh", "test-box"]
        if pr is not None:
            command += ["--pr", pr]
        result = subprocess.run(command, capture_output=True, text=True,
            env={**os.environ, "PATH": str(fake) + os.pathsep + os.environ["PATH"],
                 "FAKE_GH_CONFIG": str(config), "FAKE_GH_LOG": str(log)})
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        for call in calls:
            if call.get("transport") == "scp":
                self.addCleanup(shutil.rmtree, call["argv"][-1].split(":", 1)[1], ignore_errors=True)
        return result, calls, json.loads(config.read_text())["body"]

    def test_native_publish_command_alt_text_placement_and_readback(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "captures with spaces"
            self.comparison(out)
            result, calls, body = self.publish(out)
            self.assertEqual(result.returncode, 0, result.stderr)
            edits = [call for call in calls if "--body-file" in call["argv"]]
            self.assertEqual(len(edits), 1)
            args = edits[0]["argv"]
            self.assertEqual(args[:5], ["pr", "edit", "1549", "-R", "DivyanshGolyan/rui"])
            self.assertEqual(edits[0]["cwd"], str(out))
            attachments = [args[i + 1] for i, value in enumerate(args) if value == "--attach"]
            self.assertEqual(attachments, [f"{side}/changed@140x40.{ext}#changed 140x40 {side}" +
                                          (" recording" if ext == "gif" else "")
                                          for side in ("before", "after") for ext in ("png", "gif")])
            self.assertIn("![changed 140x40 before](before/changed@140x40.png)", edits[0]["body"])
            from pr_shape import screen_evidence
            self.assertTrue(screen_evidence(body))
            self.assertIn("#### 140x40\n\nBefore\n\n![", body)
            self.assertIn("\n\nAfter\n\n![", body)
            self.assertIn(self.head, body)
            self.assertIn(self.base, body)
            self.assertIn("Sizes: 140x40", body)
            self.assertIn("Surface: plain PTY, L1 synthetic input", body)
            self.assertNotIn("pending", body)
            self.assertNotIn("same@", body)
            self.assertTrue(body.startswith("attribution\n\n## Summary\nsummary"))
            self.assertTrue(body.endswith("keep danger\nfooter\n"))
            self.assertEqual(body.count("## Screens"), 1)
            self.assertEqual(body.count("https://github.com/user-attachments/assets/"), 4)
            self.assertEqual(calls[-1]["argv"], ["api", "repos/DivyanshGolyan/rui/pulls/1549"])
            self.assertIn("4 embedded Screens attachments verified by readback", result.stdout)

    def test_native_publish_single_build_requires_explicit_pr(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "frames"
            record = self.capture(out)
            (out / "frames.json").write_text(json.dumps([record]))
            result, calls, body = self.publish(out)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(any("/pulls?" in str(c["argv"]) for c in calls))
            self.assertIn("Base: none (single build)", body)
            self.assertIn("![overview 140x40 after](https://github.com/user-attachments/", body)
            self.assertIn("2 embedded Screens attachments", result.stdout)
            result, calls, _body = self.publish(out, pr=None)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("required: --pr", result.stderr)
            self.assertEqual(calls, [])

    def test_native_publish_refuses_missing_cli_capability_or_push_token(self):
        cases = (({"version": "2.103.0"}, "gh 2.104.0+"),
                 ({"attach_help": False}, "gh 2.104.0+"),
                 ({"no_token": True}, "classic PAT or gh OAuth token"),
                 ({"token": "github_pat_fine_grained"}, "classic PAT or gh OAuth token"),
                 ({"push": False}, "push access"))
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "frames"
            self.comparison(out)
            for options, reason in cases:
                with self.subTest(options=options):
                    result, calls, _body = self.publish(out, **options)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(len(result.stderr.splitlines()), 1)
                    self.assertIn(reason, result.stderr)
                    self.assertFalse(any("--body-file" in c["argv"] for c in calls))
                    self.assertEqual(result.stdout, "")
                    self.assertNotIn("ghp_fake_test_token", result.stderr)

    def test_native_publish_detects_filtered_readback_and_partial_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "frames"
            self.comparison(out)
            for options, message in (({"mangle": True}, "missing embedded Screens attachments"),
                                     ({"inline_code": True}, "missing embedded Screens attachments"),
                                     ({"partial_failure": True}, "PR may be partially updated")):
                with self.subTest(options=options):
                    result, calls, _body = self.publish(out, **options)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertEqual(calls[-1]["argv"], ["api", "repos/DivyanshGolyan/rui/pulls/1549"])
                    self.assertIn("inspect", result.stderr)

    def test_native_publish_batches_at_cli_limit_and_preserves_previous_uploads(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "frames"
            records = [self.capture(out, name=f"state-{i}") for i in range(26)]
            (out / "frames.json").write_text(json.dumps(records))
            result, calls, body = self.publish(out, token="gho_fake_oauth_token")
            self.assertEqual(result.returncode, 0, result.stderr)
            edits = [c for c in calls if "--body-file" in c["argv"]]
            self.assertEqual([c["argv"].count("--attach") for c in edits], [50, 2])
            self.assertEqual(edits[1]["body"].count("https://github.com/user-attachments/"), 50)
            self.assertEqual(body.count("https://github.com/user-attachments/"), 52)
            self.assertIn("52 embedded Screens attachments", result.stdout)

    def test_ssh_publisher_uses_same_worker_copies_only_selected_files_and_cleans(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "frames"
            self.comparison(out)
            (out / "secret.txt").write_text("must not copy")
            result, calls, body = self.publish(out, ssh=True, local_old=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            copies = [c for c in calls if c.get("transport") == "scp"]
            self.assertEqual(len(copies), 1)
            self.assertEqual(set(copies[0]["files"]), {"__verify_publish_helper__.py", "__publish_job__.json",
                *(f"{side}/changed@140x40.{ext}" for side in ("before", "after") for ext in ("png", "gif"))})
            edits = [c for c in calls if "--body-file" in c["argv"]]
            self.assertEqual(len(edits), 1)
            remote = Path(edits[0]["cwd"])
            self.assertTrue(remote.name.startswith("verify-rui-attachments."))
            self.assertFalse(remote.exists())
            self.assertEqual(calls[-1]["transport"], "ssh")
            self.assertIn("rm -rf -- /tmp/verify-rui-attachments.", calls[-1]["argv"][-1])
            self.assertEqual(body.count("https://github.com/user-attachments/assets/"), 4)
            self.assertTrue(body.startswith("attribution"))
            self.assertTrue(body.endswith("keep danger\nfooter\n"))

    def test_ssh_publisher_cleans_after_copy_or_readback_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "frames"
            self.comparison(out)
            for options in ({"scp_failure": True}, {"mangle": True}, {"no_token": True}):
                with self.subTest(options=options):
                    result, calls, _body = self.publish(out, ssh=True, **options)
                    self.assertNotEqual(result.returncode, 0)
                    cleanup = calls[-1]
                    self.assertEqual(cleanup.get("transport"), "ssh")
                    self.assertIn("rm -rf -- /tmp/verify-rui-attachments.", cleanup["argv"][-1])
                    self.assertFalse(Path(cleanup["argv"][-1].split()[-1]).exists())

    def test_screens_parts_preserves_fenced_example_and_other_sections(self):
        body = "## Summary\n```md\n## Screens\nfake\n```\n\n## Screens\nold\n\n## Evidence\nproof\n"
        prefix, screens, suffix = self.helper["screens_parts"](body)
        self.assertIn("fake", prefix)
        self.assertEqual(screens, "## Screens\nold\n\n")
        self.assertEqual(suffix, "## Evidence\nproof\n")


class UpgradeFramesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helper = runpy.run_path(str(SCRIPT))

    def test_upgrade_frames_refuse_root_before_build_or_run_allocation(self):
        frames = self.helper["run_frames"]
        with tempfile.TemporaryDirectory() as directory:
            scenario = Path(directory) / "scenario.json"
            scenario.write_text(json.dumps({"sizes": ["140x40"], "states": [
                {"name": "current", "upgrade": "current", "open": "overview", "steps": []}]}))
            args = types.SimpleNamespace(scenario=str(scenario), sizes=None, only="current", sha="a" * 40)
            with patch("os.getuid", return_value=0), patch("os.geteuid", return_value=0), \
                    patch.dict(frames.__globals__, {"load_build": lambda *_args: self.fail("loaded build before root refusal"),
                                                   "cmd_new": lambda *_args: self.fail("launched run as root")}), \
                    contextlib.redirect_stderr(io.StringIO()) as error, self.assertRaises(SystemExit):
                frames(args)
            self.assertIn("UID-global", error.getvalue())

    def test_upgrade_fixture_identity_requires_explicit_matching_dedicated_account(self):
        import pwd
        guard = self.helper["require_upgrade_fixture_user"]
        with patch("os.getuid", return_value=1234), patch("os.geteuid", return_value=1234), \
                patch.object(pwd, "getpwuid", return_value=types.SimpleNamespace(pw_name="rui-s7-sidebar")):
            for expected in ("", "ordinary-user"):
                with self.subTest(expected=expected), patch.dict(os.environ, {"VERIFY_RUI_UPGRADE_FIXTURE_USER": expected}), \
                        contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    guard()
            with patch.dict(os.environ, {"VERIFY_RUI_UPGRADE_FIXTURE_USER": "rui-s7-sidebar"}):
                guard()

    def test_actor_manifest_rejects_missing_modified_and_wrong_lineage(self):
        check = self.helper["upgrade_actor"]
        with tempfile.TemporaryDirectory() as directory:
            actor = Path(directory) / "actor"
            actor.write_bytes(b"release actor")
            build = {"sha": "a" * 40, "tree": "tree", "upgrade_actor": {
                "binary": str(actor), "sha256": self.helper["sha256"](actor), "sha": "a" * 40, "tree": "tree"}}
            self.assertEqual(check(build), actor)
            for key, value in (("sha", "b" * 40), ("tree", "other"), ("sha256", "wrong"),
                               ("binary", str(actor.parent / "absent"))):
                invalid = copy.deepcopy(build)
                invalid["upgrade_actor"][key] = value
                with self.subTest(key=key), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    check(invalid)
            actor.write_bytes(b"changed actor")
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                check(build)

    def test_comparison_oracles_have_full_schema_validation(self):
        validate = self.helper["validate_scenario"]
        for override in ({"expect": 17}, {"absent": {}}, {"expect_regex": ["["]},
                         {"expect_next": {"Settings": 1}}, {"expect_last": []},
                         {"expect_dim": [{"text": "version", "dim": "yes"}]}):
            scenario = {"sizes": ["140x40"], "states": [{"name": "current", "open": "overview", "steps": [],
                         "comparison": {"before": override}}]}
            with self.subTest(override=override), self.assertRaises((ValueError, __import__("re").error)):
                validate(scenario)

    def test_upgrade_matrix_has_distinct_exact_baseline_oracles_and_saved_chat(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = [state for state in scenario["states"] if state.get("upgrade")]
        self.assertEqual(len(states), 10)
        self.assertEqual({state.get("theme") for state in states}, {"day", "night"})
        for state in states:
            self.assertEqual(state["sizes"], [(140, 40), (46, 30)])
            if state["upgrade"] == "chat":
                self.assertEqual(state["open"], state["cast"][0]["label"])
                self.assertEqual(state["cast"][0]["messages"], [state["cast"][0]["label"]])
                self.assertIn(state["cast"][0]["label"], state["expect"])
                self.assertIn("Upgraded to ", state["absent"])
                before = state["comparison"]["before"]
                self.assertIn("Upgraded to {upgrade_version}", before["expect"])
                self.assertNotIn("Upgraded to ", before["absent"])
                self.assertNotIn("alt+i info", before["expect"])
                after_only = "› Upgrade witness\n gpt-6.1-sol · low"
                self.assertFalse(all(text in after_only for text in before["expect"]))
            else:
                before = state["comparison"]["before"]
                self.assertTrue(before["expect_sidebar_regex"])
                self.assertNotEqual(before["expect_sidebar_regex"], state["expect_sidebar_regex"])
                if state["upgrade"] == "failure":
                    self.assertIn("! Couldn't reach GitHub; nothing changed", before["expect"])
                if state["upgrade"] == "updating":
                    self.assertIn("Publishing; cancelling no longer rolls back", before["expect"])

    def test_failure_frames_wait_for_public_chat_readiness_without_open_hints(self):
        settle = self.helper["frame_failure_settled"]
        reason = "Update failed"
        for before in (False, True):
            marker = "! Couldn't reach GitHub; nothing changed" if before else reason
            chat = "  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄\n  › Type a task\n  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄\n gpt-6.1-sol · low · ~/code/rui"
            screens = [marker + "\nReading this Session…\n" + chat,
                       marker + "\nHost paused\n" + chat,
                       marker + "\nSettings\n gpt-6.1-sol · low",
                       marker + "\n" + chat.replace("Type a task", "wrong chat draft"),
                       marker + "\n" + chat]
            observed = []
            def wait(predicate, _description):
                for index, plain in enumerate(screens):
                    observed.append(index)
                    if predicate(types.SimpleNamespace(completed=plain)):
                        return
                self.fail("settled failure conversation was not accepted")
            with self.subTest(before=before):
                settle(types.SimpleNamespace(wait=wait), before)
                self.assertEqual(observed, [0, 1, 2, 3, 4])
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        for state in (entry for entry in scenario["states"] if entry.get("upgrade") == "failure"):
            self.assertNotIn("expect_last", state)
            self.assertIn("Host paused", state["absent"])
            self.assertIn("Reading this Session", state["absent"])
            self.assertIn("enter open", state["absent"])
            self.assertIn("enter open", state["comparison"]["before"]["absent"])
            self.assertIn(reason, state["expect"])
            self.assertEqual(state["expect_next"], {})
            self.assertIn("Update failed:", state["absent"])
            for size in state["sizes"]:
                layout = "chat" if size[0] == 140 else "overview"
                suffix = "│ actual chat" if size[0] == 140 else ""
                rows = sidebar_rows(reason, layout) + "\n"
                screens = [rows + "Reading this Session…", rows + "Host paused", rows]
                observed = []
                def wait(predicate, _description, **_kwargs):
                    for index, plain in enumerate(screens):
                        observed.append(index)
                        if predicate(types.SimpleNamespace(completed=plain)):
                            return
                    self.fail("settled failure frame was not accepted")
                with self.subTest(theme=state["theme"], size=size):
                    self.helper["frame_ready"](types.SimpleNamespace(wait=wait), state)
                    self.assertEqual(observed, [0, 1, 2])
                    self.assertIsNotNone(self.helper["frame_row_failure"](state, "Settings\nrui 7 MB " + reason))
                    self.assertIsNotNone(self.helper["frame_row_failure"](state, "Settings\nUpdate failed" + suffix))
                    self.assertIsNone(self.helper["frame_row_failure"](state, rows))
                    self.assertIsNotNone(self.helper["frame_row_failure"](state, rows.replace(reason, "7 MB  " + reason)))
                    self.assertIsNotNone(self.helper["frame_row_failure"](state, rows.replace(reason, reason + ": Couldn't reach GitHub")))
                    self.assertIsNotNone(self.helper["frame_row_failure"](state, rows.split("\n", 1)[1]))

    def test_chat_readiness_requires_settled_composer_and_footer_in_chat_pane(self):
        ready = self.helper["frame_chat_ready"]
        for split in (False, True):
            for prompt, rule in (("›", "┄"), (">", "-")):
                for model in ("gpt-6.1-sol", "gpt-5.5", "vendor/model-v2"):
                    with self.subTest(split=split, prompt=prompt, model=model):
                        prefix = " Upgrade witness " + ("│" if rule == "─" else "|") if split else ""
                        bottom = rule * (len(prefix) - 1) + ("┼" if rule == "─" else "+") + rule * 30 if split else " " + rule * 30
                        lines = [prefix + " › Upgrade witness", prefix + " " + rule * 30,
                                 prefix + " " + prompt + " retained draft", bottom,
                                 prefix + f" {model} · low"]
                        chat = "\n".join(lines)
                        self.assertTrue(ready(chat))
                        self.assertFalse(ready(chat, empty=True))
                        self.assertTrue(ready(chat.replace("retained draft", "Type a task"), empty=True))
                        self.assertTrue(ready(chat, "Upgrade witness"))
                        self.assertFalse(ready(chat, "Different witness"))
                        for stale in ("Opening…", "Reading this Session…", "Host paused", "Notifications"):
                            self.assertFalse(ready(chat + "\n" + stale))
                        self.assertTrue(ready("\n".join(lines[:-1] + [prefix + " low"])))
                        self.assertTrue(ready("\n".join(lines[:-1] + [prefix + " Update failed"])))
                        self.assertFalse(ready("\n".join(lines[:-1] + [prefix + " "])))
                        multiline = lines[:3] + [prefix + "   another line"] + lines[3:]
                        self.assertTrue(ready("\n".join(multiline), "Upgrade witness"))
                        self.assertFalse(ready("\n".join(multiline), empty=True))
                        self.assertFalse(ready("\n".join(lines[:1] + [prefix + " " + rule * 30,
                                                    prefix + " " + prompt + " Upgrade witness"] + lines[3:])
                                               .replace("› Upgrade witness", "› Other chat"), "Upgrade witness"))
                        self.assertFalse(ready("\n".join(lines[:2] + [prefix + " no composer"] + lines[3:])))
                        if split:
                            wrong = "\n".join(line.replace("› Upgrade witness", "› Another chat") for line in lines)
                            self.assertTrue(ready(wrong))
                            self.assertFalse(ready(wrong, "Upgrade witness"))
        self.assertFalse(ready("Upgrade witness\nSettings\ngpt-6.1-sol · low"))
        self.assertTrue(ready(" Upgrade witness │ details\n ──────\n › draft\n ──────\n model · low", "Upgrade witness"))
        self.assertTrue(ready(" 界 │ Upgrade witness │ detail\n    │ ──────\n    │ › draft\n────┼──────\n    │ model · low", "Upgrade witness"))

    def test_rendered_junctions_and_content_in_chat_readiness(self):
        split = self.helper["frame_split_row"]
        ready = self.helper["frame_chat_ready"]
        settle = self.helper["frame_failure_settled"]
        self.assertEqual(split("draft │ content | more + text"), ("", "", "draft │ content | more + text"))
        for rule, junction, bar in (("─", "┼", "│"), ("-", "+", "|")):
            boundary = rule * 12 + junction + rule * 20
            self.assertEqual(split(boundary), (rule * 12, junction, rule * 20))
            for draft in ("Type a task", "retained │ draft | content + more"):
                lines = [" witness".ljust(12) + bar + " witness │ content",
                         "".ljust(12) + bar + " " + rule * 20, "".ljust(12) + bar + " › " + draft,
                         boundary, "".ljust(12) + bar + " model · low"]
                screen = "\n".join(lines)
                with self.subTest(junction=junction, draft=draft):
                    self.assertTrue(ready(screen, "witness"))
                    self.assertEqual(ready(screen, empty=True), draft == "Type a task")
                    self.assertFalse(ready(screen, "missing witness"))
                    for before in (False, True):
                        marker = "! Couldn't reach GitHub; nothing changed" if before else "Update failed"
                        accepted = []
                        def wait(predicate, _description):
                            accepted.append(predicate(types.SimpleNamespace(completed=marker + "\n" + screen)))
                        settle(types.SimpleNamespace(wait=wait), before)
                        self.assertEqual(accepted, [draft == "Type a task"])
        self.assertTrue(ready("witness | content\n ───────\n › retained | draft\n ───────\n model · low", "witness"))

    def test_sidebar_rule_junctions_and_legacy_vertical_endings(self):
        split = self.helper["frame_split_row"]
        failure = self.helper["frame_row_failure"]
        for line, separator in (("─" * 20 + "┤ Notifications", "┤"),
                                ("-" * 20 + "+ Notifications", "+"),
                                ("─" * 20 + "│ status", "│"),
                                ("-" * 20 + "| ", "|")):
            left, found, pane = split(line)
            with self.subTest(separator=separator):
                self.assertEqual((left, found, pane), (line[:20], separator, line[21:]))
                bar = "|" if separator in "+|" else "│"
                screen = line[:20] + separator + pane + "\n" + " Settings 0.78.10000".ljust(20) + bar + " chat"
                self.assertIsNone(failure({"expect_sidebar_regex": [r" *Settings +0\.78\.10000 *"]}, screen))
                result = failure({"expect_sidebar_regex": [r" *Settings +0\.78\.10000 *"],
                                  "expect_sidebar_rule": True}, screen)
                self.assertEqual(result is None, separator in "┤+")

    def test_before_upgrade_regex_accepts_ascii_sidebar_divider(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        failure = self.helper["frame_row_failure"]
        for state in (entry for entry in scenario["states"] if entry.get("upgrade") not in (None, "chat")):
            patterns = [pattern.replace("{upgrade_version}", r"0\.78\.10000") for pattern in state["comparison"]["before"]["expect_sidebar_regex"]]
            for divider in self.helper["DIVIDER_GLYPHS"]:
                with self.subTest(state=state["name"], divider=divider):
                    self.assertIsNone(failure({"expect_sidebar_regex": patterns}, "─" * 35 + ("┼" if divider == "│" else "+") + "─" * 20 + "\n" + " Settings rui 7 MB 0.78.10000".ljust(35) + divider + " Type a task"))
                    self.assertIsNotNone(failure({"expect_sidebar_regex": patterns}, "─" * 35 + ("┼" if divider == "│" else "+") + "─" * 20 + "\n" + " Settings 0.77.10000".ljust(35) + divider + " 0.78.10000"))

    def test_sidebar_absence_regex_rejects_ascii_divider(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        pattern = next(pattern for state in scenario["states"] for pattern in state.get("absent_sidebar_regex", [])
                       if "[0123456789abcdefghjkmnpqrstvwxyz]{6}" in pattern)
        for divider in self.helper["DIVIDER_GLYPHS"]:
            with self.subTest(divider=divider):
                self.assertIsNotNone(self.helper["frame_row_failure"](
                    {"name": "test", "absent_sidebar_regex": [pattern]}, "─" * 20 + "┼" + "─" * 20 + "\n" + " ○ abcdef  now".ljust(20) + divider + " chat"))

    def test_upgrade_relaunch_waits_for_the_same_settled_chat_on_both_sides(self):
        drive = self.helper["frame_drive_upgrade"]
        marker = "Upgrade witness"
        def chat(witness=marker, stale=""):
            return (f" {witness}\n ┄┄┄┄┄┄┄┄┄┄┄┄┄┄\n › retained draft\n ┄┄┄┄┄┄┄┄┄┄┄┄┄┄\n"
                    f" gpt-6.1-sol · low{stale}")
        for before in (False, True):
            version = "0.78.10000"
            notice = f"\nUpgraded to {version}" if before else ""
            screens = [chat("Another chat") + notice, chat(stale="\nReading this Session…") + notice,
                       chat() + ("" if before else "\nNotifications"), chat() + notice]
            observed = []
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                selected = root / ".local/bin/rui"
                process = types.SimpleNamespace(pid=42)
                def wait(predicate, _description, **_kwargs):
                    for index, plain in enumerate(screens):
                        observed.append(index)
                        if predicate(types.SimpleNamespace(completed=plain)):
                            return
                    self.fail("settled same-chat relaunch was not accepted")
                terminal = types.SimpleNamespace(wait=wait, mouse=lambda _event: None, process=process)
                run = types.SimpleNamespace(home=root, store=root / "store",
                                            meta={"upgrade_previous_instance": "old"},
                                            rui_cmd=lambda *_args: types.SimpleNamespace(returncode=0, stderr="", stdout='{"instance":"new"}'))
                state = {"upgrade": "chat", "open": marker, "comparison_side": "before" if before else "after"}
                os_semantics = types.SimpleNamespace(process_executable=lambda _pid: selected.resolve())
                with self.subTest(before=before), patch.dict(sys.modules, {"os_semantics": os_semantics}), \
                        patch.dict(drive.__globals__, {"frame_wait": lambda *_a, **_k: None,
                                                       "frame_steps": lambda *_a, **_k: None}):
                    drive(run, terminal, state, (None, None, version))
                self.assertEqual(observed, [0, 1, 2, 3])

    def test_upgrade_and_failure_predicates_cover_layouts_and_drafts(self):
        drive = self.helper["frame_drive_upgrade"]
        settle = self.helper["frame_failure_settled"]
        for split in (False, True):
            for rule, bar, junction in (("─", "│", "┼"), ("-", "|", "+")):
                for draft in ("Type a task", "retained draft"):
                    prefix = " ".ljust(20) + bar if split else ""
                    top = prefix + " " + rule * 20
                    bottom = rule * 20 + junction + rule * 20 if split else " " + rule * 20
                    screen = "\n".join([prefix + " Upgrade witness", top, prefix + " › " + draft,
                                         bottom, prefix + " model · low"])
                    for before in (False, True):
                        with self.subTest(split=split, rule=rule, draft=draft, before=before), tempfile.TemporaryDirectory() as directory:
                            marker = "! Couldn't reach GitHub; nothing changed" if before else "Update failed"
                            results = []
                            settle(types.SimpleNamespace(wait=lambda pred, _description: results.append(
                                pred(types.SimpleNamespace(completed=marker + "\n" + screen)))), before)
                            self.assertEqual(results, [draft == "Type a task"])
                            root = Path(directory)
                            selected = root / ".local/bin/rui"
                            notice = "\nUpgraded to 0.78.10000" if before else ""
                            terminal = types.SimpleNamespace(process=types.SimpleNamespace(pid=42),
                                wait=lambda pred, _description, **_kw: results.append(pred(types.SimpleNamespace(completed=screen + notice))))
                            run = types.SimpleNamespace(home=root, store=root / "store", meta={"upgrade_previous_instance": "old"},
                                rui_cmd=lambda *_args: types.SimpleNamespace(returncode=0, stderr="", stdout='{"instance":"new"}'))
                            state = {"upgrade": "chat", "open": "Upgrade witness", "comparison_side": "before" if before else "after"}
                            with patch.dict(sys.modules, {"os_semantics": types.SimpleNamespace(process_executable=lambda _pid: selected.resolve())}), \
                                 patch.dict(drive.__globals__, {"frame_wait": lambda *_a, **_k: None, "frame_steps": lambda *_a, **_k: None}):
                                drive(run, terminal, state, (None, None, "0.78.10000"))
                            self.assertTrue(results[-1])

    def test_narrow_upgrade_resize_reveals_the_list_without_closing_chat_specimens(self):
        reveal = self.helper["frame_upgrade_viewport"]
        calls = []
        terminal = types.SimpleNamespace(frame=types.SimpleNamespace(columns=46, visible=False),
                                         capture=types.SimpleNamespace(completed="Type a task"))
        with patch.dict(reveal.__globals__, {"frame_steps": lambda _run, _terminal, steps: calls.extend(steps)}):
            reveal(None, terminal, {"upgrade": "updating"})
            self.assertEqual(calls, [{"keys": ["Esc"]}, {"wait": "Settings"}])
            calls.clear()
            reveal(None, terminal, {"upgrade": "chat"})
            terminal.capture.completed = "Settings"
            reveal(None, terminal, {"upgrade": "failure"})
            terminal.frame.columns = 140
            terminal.capture.completed = "Type a task"
            reveal(None, terminal, {"upgrade": "available"})
            self.assertEqual(calls, [])

    def test_wide_upgrade_viewport_moves_visible_cursor_to_native_list_focus(self):
        reveal = self.helper["frame_upgrade_viewport"]
        events = []
        frame = types.SimpleNamespace(columns=140, visible=True)
        terminal = types.SimpleNamespace(frame=frame)
        def steps(_run, _terminal, actions):
            self.assertEqual(actions, [{"keys": ["Left"]}])
            events.append("Left")
            frame.visible = False
        def wait(predicate, description):
            self.assertTrue(predicate(types.SimpleNamespace(frame=frame)))
            self.assertIn("input cursor", description)
            events.append("committed hidden cursor")
        terminal.wait = wait
        with patch.dict(reveal.__globals__, {"frame_steps": steps}):
            reveal(None, terminal, {"upgrade": "updating", "comparison_side": "before"})
            self.assertEqual(events, ["Left", "committed hidden cursor"])
            events.clear()
            reveal(None, terminal, {"upgrade": "updating"})
            frame.visible = True
            reveal(None, terminal, {"upgrade": "chat"})
            self.assertEqual(events, [])

    def test_shared_sidebar_row_requires_divider_and_bounds_controls_before_chat_content(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        row_failure = self.helper["frame_row_failure"]
        for state in (entry for entry in scenario["states"] if entry.get("upgrade") not in (None, "chat")):
            patterns = [pattern.replace("{available_version}", r"0\.99\.99999") for pattern in state["expect_sidebar_regex"]]
            oracle = {"expect_sidebar_regex": patterns, "expect_sidebar_rule": True}
            label = {"current": "", "available": "Update to 0.99.99999", "updating": "Updating…", "failure": "Update failed"}[state["upgrade"]]
            for layout in ("chat", "settings", "ascii-chat", "ascii-settings", "overview", "wide-overview", "ascii-overview", "ascii-wide-overview"):
                rendered = "Updating..." if layout.startswith("ascii") and label == "Updating…" else label
                rows = sidebar_rows(rendered or "7 MB", layout)
                rule, row = rows.split("\n")
                with self.subTest(theme=state["theme"], kind=state["upgrade"], layout=layout):
                    self.assertIn("{upgrade_version}", state["absent"])
                    self.assertIsNone(row_failure(oracle, rows))
                    if rendered:
                        self.assertIsNotNone(row_failure(oracle, rows.replace(rendered, "7 MB  " + rendered, 1)))
                    for wrong in (row, rule + "\n" + row.replace("Settings  ", "Settings\n"),
                                  rule + "\n" + row.replace("Settings  ", "Settings  rui "),
                                  rule + "\n" + row.replace("Settings  ", "Settings  tools 120 MB "),
                                  rule + "\n" + row.replace("Settings  ", "Settings  0.78.10000 ")):
                        self.assertIsNotNone(row_failure(oracle, wrong))
                    if label:
                        self.assertIsNotNone(row_failure(oracle, rule + "\n Settings 7 MB │ " + label))
                    if layout == "chat":
                        self.assertIsNotNone(row_failure(oracle, rows.replace("┼", "│", 1)))
                    if state["upgrade"] == "available":
                        self.assertIsNotNone(row_failure(oracle, rows.replace("0.99.99999", "0x99x99999")))
        current = next(state for state in scenario["states"] if state["name"] == "sidebar-current")
        before = {"expect_sidebar_regex": [pattern.replace("{upgrade_version}", r"0\.78\.10000") for pattern in current["comparison"]["before"]["expect_sidebar_regex"]]}
        self.assertIsNone(row_failure(before, "─" * 35 + "┼" + "─" * 20 + "\n" + " Settings rui 7 MB 0.78.10000".ljust(35) + "│ Type a task"))
        self.assertIsNotNone(row_failure(before, "─" * 35 + "┼" + "─" * 20 + "\n" + " Settings 0.77.10000".ljust(35) + "│ 0.78.10000"))

    def test_held_upgrade_after_readiness_uses_publication_and_control_not_chat_status(self):
        drive = self.helper["frame_drive_upgrade"]
        events = []
        def wait(predicate, description, **_kwargs):
            self.assertTrue(predicate(types.SimpleNamespace(completed="Updating…")))
            events.append(description)
        terminal = types.SimpleNamespace(wait=wait, mouse=lambda event: events.append(event["at"]))
        with tempfile.TemporaryDirectory() as directory, patch.dict(drive.__globals__, {
                "frame_wait": lambda _run, _terminal, marker, **_kwargs: events.append(marker),
                "frame_steps": lambda _run, _terminal, steps: events.append(steps)}):
            run = types.SimpleNamespace(home=Path(directory))
            drive(run, terminal, {"upgrade": "updating", "comparison_side": "after"}, (None, object(), "0.78.10000"))
        self.assertEqual(events, ["Type a task",
                                 [{"mouse": {"at": "Settings", "do": "click"}}, {"wait": "Notifications"},
                                  {"keys": ["Down"] * 5 + ["Enter"]}],
                                 " · publishing", [{"keys": ["Esc"]}, {"gone": "Notifications"}],
                                 "published release held before Host activation"])

    def test_failure_row_oracle_rejects_expanded_reason_and_split_row(self):
        state = next(state for state in self.helper["load_scenario"](SCRIPT.with_name("frames.json"))["states"]
                     if state["name"] == "sidebar-failure")
        row_failure = self.helper["frame_row_failure"]
        self.assertIsNone(row_failure(state, "─" * 40 + "\n     Settings   Update failed"))
        for row in ("Settings\n38 MB Update failed", "Settings 38 MB Update failed", "Settings Update failed: Couldn't reach GitHub",
                    "Settings 38 MB │ Update failed"):
            with self.subTest(row=row):
                self.assertIsNotNone(row_failure(state, "─" * 40 + "\n" + row))

    def test_native_retry_journey_waits_for_archive_gate_before_release_and_settings(self):
        journey = self.helper["frame_upgrade_journey"]
        events = []
        class Release:
            def set(self):
                events.append("release archive")
        gate = types.SimpleNamespace(entered=types.SimpleNamespace(is_set=lambda: True), release=Release())
        releases = types.SimpleNamespace(status={"/releases/latest": 403}, gate_archive=lambda: gate)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = types.SimpleNamespace(home=root, store=root / "store", meta={"upgrade_previous_instance": "old"},
                                        rui_cmd=lambda *_args: types.SimpleNamespace(returncode=0, stderr="", stdout='{"status":"ready","instance":"new"}'))
            terminal = types.SimpleNamespace(capture=types.SimpleNamespace(generation=3),
                                            mouse=lambda event: events.append(event["at"]),
                                            wait=lambda _predicate, description, **_kwargs: events.append(description))
            def capture(_run, _terminal, _out, specimen, _size, _reason):
                events.append(specimen["name"])
                if specimen["name"] == "retry-completed":
                    self.assertEqual(specimen["expect"], ["Settings"])
                    self.assertIn("0.70.10000", specimen["absent"])
                    for layout in ("chat", "settings", "ascii-chat", "ascii-settings", "overview", "wide-overview", "ascii-overview", "ascii-wide-overview"):
                        with self.subTest(retry_completed=layout):
                            rows = sidebar_rows("7 MB", layout)
                            self.assertIsNone(self.helper["frame_row_failure"](specimen, rows))
                            self.assertIsNotNone(self.helper["frame_row_failure"](specimen, rows.replace("Settings  7 MB", "Settings  0.70.10000")))
                    self.assertIsNotNone(self.helper["frame_row_failure"](specimen, "Settings\n7 MB 0.70.10000"))
                return {"ok": True}
            with patch.dict(journey.__globals__, {"frame_ready": lambda *_args: None, "frame_capture": capture,
                                                 "frame_steps": lambda *_args: events.append("Settings Version")}):
                journey(run, terminal, {"name": "failure", "upgrade": "failure", "comparison_side": "after"},
                        (releases, None, "0.70.10000"), root, (46, 30))
            self.assertNotIn("/releases/latest", releases.status)
            self.assertLess(events.index("Update failed"), events.index("retry archive HTTP gate"))
            self.assertLess(events.index("retry-updating"), events.index("release archive"))
            self.assertLess(events.index("retry-completed"), events.index("Settings Version"))
            self.assertIn("settings-version-up-to-date", events)
            evidence = json.loads((root / "journeys/failure/journey.json").read_text())
            self.assertEqual(evidence["steps"][0]["name"], "failed-both-viewports-captured")
            self.assertEqual(len(evidence["records"]), 3)

    def test_replacement_host_requires_confirmed_current_instance_retirement(self):
        pause = self.helper["frame_pause_owned_host"]
        for retirement in ("unconfirmed", "confirmed"):
            with self.subTest(retirement=retirement), tempfile.TemporaryDirectory() as directory:
                events = []
                stopped = False
                def command(*args, **_kwargs):
                    nonlocal stopped
                    events.append(args)
                    if args[:2] == ("host", "pause"):
                        self.assertEqual(args[-2:], ("--instance", "replacement-instance"))
                        stopped = True
                        body = {"status": "acknowledged", "instance": "replacement-instance", "retirement": retirement}
                    else:
                        body = {"status": "unavailable"} if stopped else {"status": "ready", "instance": "replacement-instance"}
                    return types.SimpleNamespace(returncode=0, stdout=json.dumps(body), stderr="")
                run = types.SimpleNamespace(store=Path(directory) / "store", evidence=Path(directory), rui_cmd=command,
                                            owned=lambda: [{"kind": "host", "pid": 123, "lstart": "retired-original"}])
                with patch.dict(pause.__globals__, {"process_start": lambda _pid: None}):
                    if retirement == "unconfirmed":
                        with self.assertRaises(self.helper["FrameFailure"]):
                            pause(run)
                        self.assertFalse((Path(directory) / "upgrade-host-lifecycle.jsonl").exists())
                    else:
                        pause(run)
                        receipt = json.loads((Path(directory) / "upgrade-host-lifecycle.jsonl").read_text())
                        self.assertEqual(receipt["instance"], "replacement-instance")
                        self.assertEqual(receipt["retirement"], "confirmed")
                self.assertEqual(events[0][:2], ("host", "status"))
                self.assertEqual(events[1][:2], ("host", "pause"))
                self.assertEqual(len(events), 2 if retirement == "unconfirmed" else 3)

    def test_shots_upgrade_stages_cast_before_clean_restartable_host(self):
        import upgrade_fixture
        frame_run = self.helper["frame_upgrade_run"]
        class Releases:
            origin = "http://127.0.0.1:1"
            def __init__(self, _actor, _version):
                self.status = {}
                self.requests = []
            def close(self):
                pass
        for has_cast, refused in ((False, False), (True, False), (True, True)):
            with self.subTest(has_cast=has_cast, refused=refused), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "evidence").mkdir()
                (root / "home/.config/rui").mkdir(parents=True)
                project = root / "home/code/rui"
                project.mkdir(parents=True)
                (root / "scratch").mkdir()
                actor = root / "actor"
                actor.write_bytes(b"actor")
                meta = {"scratch": str(root / "scratch"), "home": str(root / "home"),
                        "store": str(root / "store"), "binary": str(actor), "project": str(project),
                        "sessions": {}, "frame_env": {"LD_PRELOAD": "/fixture.so"}}
                (root / "run.json").write_text(json.dumps(meta))
                run = self.helper["Run"](root)
                events = []
                run._shot_clock = types.SimpleNamespace(reset=lambda: events.append("reset"))
                build = {"sha": "a" * 40, "tree": "tree", "upgrade_actor": {
                    "binary": str(actor), "sha256": self.helper["sha256"](actor),
                    "sha": "a" * 40, "tree": "tree"}}
                cast = [{"label": "fixture"}] if has_cast else []
                def launch(isolated, *, restartable, without_preload=False):
                    events.append(("launch", without_preload))
                    self.assertTrue(restartable)
                    self.assertEqual(isolated.meta["frame_env"]["LD_PRELOAD"], "/fixture.so")
                    return types.SimpleNamespace(stdout='{"instance":"clean"}')
                def seed(_run, entries, *, ordered):
                    self.assertEqual(entries, cast)
                    self.assertTrue(ordered)
                    events.append("seed")
                def pause(_run):
                    events.append("retire")
                    if refused:
                        raise self.helper["FrameFailure"]("retirement unconfirmed")
                with patch.object(upgrade_fixture, "Releases", Releases), \
                     patch("subprocess.check_output", return_value="rui 0.70.10000 (fixture)"), \
                     patch("subprocess.run", return_value=types.SimpleNamespace(returncode=0, stdout="", stderr="")), \
                     patch.dict(frame_run.__wrapped__.__globals__, {"launch_host": launch, "seed_cast": seed,
                                                                    "frame_pause_owned_host": pause}):
                    expectation = self.assertRaises(self.helper["FrameFailure"]) if refused else contextlib.nullcontext()
                    with expectation:
                        with frame_run(run, {"name": "chat", "upgrade": "chat", "cast": cast}, build) as (isolated, _, _fixture):
                            self.assertFalse(refused)
                            self.assertEqual(isolated.meta["upgrade_previous_instance"], "clean")
                            self.assertEqual(getattr(isolated, "_upgrade_seeded", False), has_cast)
                expected = [("launch", False), "seed", "reset", "retire"] if has_cast else []
                self.assertEqual(events, expected + ([] if refused else [("launch", True)]))

    def test_upgrade_host_launch_removes_preload_only_from_host_environment(self):
        launch = self.helper["launch_host"]
        for clean in (False, True):
            with self.subTest(clean=clean), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                env = {"LD_PRELOAD": "/fixture.so", "FAKETIME_TIMESTAMP_FILE": "/clock"}
                run = types.SimpleNamespace(meta={"host_options": {"active_capacity": 2, "host_setenv": []},
                                                  "fixture_url": "http://fixture"},
                    rui=root / "rui", store=root / "store", project=root, evidence=root,
                    env=lambda: env.copy(), own=lambda *_a, **_k: None,
                    rui_cmd=lambda *_a, **_k: types.SimpleNamespace(returncode=0, stdout='{"status":"ready"}', stderr=""))
                seen = []
                def spawn(_argv, **kwargs):
                    seen.append(kwargs["env"])
                    kwargs["stdout"].close()
                    kwargs["stderr"].close()
                    return types.SimpleNamespace(pid=123)
                with patch("subprocess.Popen", side_effect=spawn):
                    launch(run, restartable=True, without_preload=clean)
                self.assertEqual("LD_PRELOAD" in seen[0], not clean)
                self.assertEqual(seen[0]["FAKETIME_TIMESTAMP_FILE"], "/clock")
                self.assertEqual(env["LD_PRELOAD"], "/fixture.so")

    def test_upgrade_host_uses_a_populated_isolated_project(self):
        import upgrade_fixture
        frame_run = self.helper["frame_upgrade_run"]
        class Releases:
            origin = "http://127.0.0.1:1"
            def __init__(self, _binary, _version):
                self.status = {}
                self.requests = []
                self.closed = False
            def close(self):
                self.closed = True
        for mode in ("current", "available", "updating", "failure", "chat"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "evidence").mkdir()
                (root / "home/.config/rui").mkdir(parents=True)
                project = root / "home/code/rui"
                (project / "src").mkdir(parents=True)
                (project / "README.md").write_text("parent readme\n")
                (project / "src/example.txt").write_text("parent source\n")
                (root / "scratch").mkdir()
                actor = root / "actor"
                actor.write_bytes(b"actor")
                meta = {"scratch": str(root / "scratch"), "home": str(root / "home"),
                        "store": str(root / "store"), "binary": str(actor), "project": str(project),
                        "sessions": {"original": "abc123"}}
                (root / "run.json").write_text(json.dumps(meta))
                run = self.helper["Run"](root)
                build = {"sha": "a" * 40, "tree": "tree", "upgrade_actor": {
                    "binary": str(actor), "sha256": self.helper["sha256"](actor),
                    "sha": "a" * 40, "tree": "tree"}}
                launched = []
                def launch(isolated, *, restartable):
                    self.assertTrue(restartable)
                    self.assertEqual(isolated.project, isolated.home / "code/rui")
                    self.assertEqual(isolated.meta["project"], str(isolated.project))
                    self.assertEqual((isolated.project / "README.md").read_text(), "parent readme\n")
                    self.assertEqual((isolated.project / "src/example.txt").read_text(), "parent source\n")
                    (isolated.project / "src/example.txt").write_text("isolated source\n")
                    self.assertEqual((project / "src/example.txt").read_text(), "parent source\n")
                    launched.append(isolated.project)
                    return types.SimpleNamespace(stdout='{"instance":"fixture-host"}')
                with patch.object(upgrade_fixture, "Releases", Releases), \
                     patch("subprocess.check_output", return_value="rui 0.70.10000 (fixture)"), \
                     patch("subprocess.run", return_value=types.SimpleNamespace(returncode=0, stdout="", stderr="")), \
                     patch.dict(frame_run.__wrapped__.__globals__, {"launch_host": launch}):
                    with frame_run(run, {"name": mode, "upgrade": mode}, build) as (isolated, _state, fixture):
                        self.assertEqual(launched, [isolated.home / "code/rui"])
                        self.assertEqual(isolated.project, Path(isolated.meta["project"]))
                        self.assertNotEqual(isolated.project, run.project)
                        releases = fixture[0]
                    self.assertTrue(releases.closed)
                self.assertEqual(json.loads((root / "run.json").read_text()), meta)

    def test_upgrade_setup_failure_retires_server_and_preserves_primary(self):
        self.upgrade_cleanup_case(setup_failure=True)

    def test_upgrade_body_failure_retires_host_and_server_and_restores_parent(self):
        self.upgrade_cleanup_case(setup_failure=False)

    def upgrade_cleanup_case(self, setup_failure):
        import upgrade_fixture
        frame_run = self.helper["frame_upgrade_run"]
        events = []
        class Releases:
            origin = "http://127.0.0.1:1"
            status = {}
            requests = []
            def __init__(self, _binary, version):
                self.version = version
            def close(self):
                events.append("server closed")
                raise RuntimeError("cleanup failed")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "evidence").mkdir()
            (root / "home/.config/rui").mkdir(parents=True)
            project = root / "home/code/rui"
            (project / "src").mkdir(parents=True)
            (project / "README.md").write_text("project fixture\n")
            (project / "src/example.txt").write_text("source fixture\n")
            (root / "scratch").mkdir()
            actor = root / "actor"
            actor.write_bytes(b"actor")
            meta = {"scratch": str(root / "scratch"), "home": str(root / "home"),
                    "store": str(root / "store"), "binary": str(actor), "project": str(project),
                    "sessions": {"original": "abc123"}}
            (root / "run.json").write_text(json.dumps(meta))
            run = self.helper["Run"](root)
            build = {"sha": "a" * 40, "tree": "tree", "upgrade_actor": {
                "binary": str(actor), "sha256": self.helper["sha256"](actor), "sha": "a" * 40, "tree": "tree"}}
            def launch(isolated, *, restartable=False):
                self.assertTrue(restartable)
                self.assertEqual(isolated.project, isolated.home / "code/rui")
                self.assertEqual(Path(isolated.meta["project"]), isolated.project)
                self.assertEqual((isolated.project / "README.md").read_text(), "project fixture\n")
                self.assertEqual((isolated.project / "src/example.txt").read_text(), "source fixture\n")
                (isolated.project / "src/example.txt").write_text("isolated change\n")
                self.assertEqual((project / "src/example.txt").read_text(), "source fixture\n")
                isolated.store.mkdir()
                events.append("host started")
                return types.SimpleNamespace(stdout='{"instance":"old-instance"}')
            def command(_run, *args, **_kwargs):
                events.append(tuple(args[:2]))
                if args[:2] == ("host", "pause"):
                    body = {"status": "acknowledged", "instance": "replacement", "retirement": "confirmed"}
                else:
                    body = {"status": "unavailable"} if ("host", "pause") in events else {"status": "ready", "instance": "replacement"}
                return types.SimpleNamespace(returncode=0, stdout=json.dumps(body), stderr="")
            failure = OSError("setup failed") if setup_failure else RuntimeError("body failed")
            with patch.object(upgrade_fixture, "Releases", Releases), \
                    patch("subprocess.check_output", return_value="rui 0.70.10000 (fixture)"), \
                    patch("subprocess.run", return_value=types.SimpleNamespace(returncode=0, stdout="", stderr="")), \
                    patch.object(type(run), "rui_cmd", command), \
                    patch.dict(frame_run.__wrapped__.__globals__, {"launch_host": launch}):
                with contextlib.ExitStack() as patches:
                    if setup_failure:
                        patches.enter_context(patch("shutil.copytree", side_effect=failure))
                    with self.assertRaises(type(failure)) as caught:
                        with frame_run(run, {"name": "failure", "upgrade": "failure"}, build) as (isolated, _state, fixture):
                            self.assertNotEqual(isolated.home, run.home)
                            self.assertNotEqual(isolated.store, run.store)
                            self.assertEqual(isolated.env()["HOME"], str(isolated.home))
                            self.assertEqual(fixture[0].status["/releases/latest"], 403)
                            (root / "run.json").write_text(json.dumps(isolated.meta))
                            raise failure
                self.assertIs(caught.exception, failure)
                self.assertTrue(any("cleanup failed" in note for note in failure.__notes__))
            self.assertIn("server closed", events)
            self.assertEqual(json.loads((root / "run.json").read_text()), meta)
            if setup_failure:
                self.assertNotIn("host started", events)
                self.assertNotIn(("host", "pause"), events)
            else:
                self.assertIn(("host", "pause"), events)


if __name__ == "__main__":
    unittest.main()

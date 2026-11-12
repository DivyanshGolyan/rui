import contextlib
import copy
import io
import json
import os
from pathlib import Path
import runpy
import site
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).parents[2] / ".claude/skills/verify-rui/scripts/verify-rui"


sys.path.insert(0, str(SCRIPT.parents[4] / "tests/integration"))
from terminal_screen import Cell, Cursor, Frame


def committed(text, columns=100, lines=20):
    rows = tuple(tuple(Cell(char, None, False) for char in row) for row in text.rstrip("\n").split("\n"))
    return Frame(columns, lines, Cursor(2, 3), False, rows, "121933", "d4cebf", "d4cebf")


class VerifyRuiTest(unittest.TestCase):
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
                # Neither uncommitted changes nor new identical commits confirm input.
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
        # Cursor-only changes are not a new cell picture.
        frame = committed("same")
        changed_cursor = frame._replace(cursor=Cursor(0, 0), visible=True)
        self.assertEqual(list(playback(iter([(0, frame), (100_000_000, changed_cursor)]))), [(frame, 2)])
        with self.assertRaisesRegex(self.helper["FrameFailure"], "no committed recording frames"):
            list(playback(iter([])))

    @unittest.skipUnless(os.environ.get("RUI_TEST_GHOSTTY_VT"), "native observer library not selected")
    def test_replay_timed_bytes_resize_stop_and_silent_queries(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            # Multiple commits in one chunk and a frame close split across chunks.
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
            root = Path(temp)
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

    def test_encoder_uses_separate_palette_pass_and_same_concat(self):
        with patch("subprocess.run", return_value=types.SimpleNamespace(returncode=0, stderr="")) as run:
            self.helper["encode_recording"](Path("/tmp/frames.concat"), Path("/tmp/movie.gif"))
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(len(commands), 3)  # Palette, GIF, optional MP4.
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
            self.assertNotIn("error", vars(terminal))  # There is no adapter-owned copy.
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
        for name in ("first-run", "first-run-codex", "first-run-key"):
            self.assertTrue(states[name]["first_run"])
            self.assertEqual(states[name]["open"], "overview")
        self.assertEqual(states["first-run-codex"]["env"]["RUI_TEST_LOGIN"], "waiting")
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
            self.assertEqual(data, self.scenario())  # Loading leaves caller data untouched.
        default = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        self.assertEqual(default["sizes"], [(140, 40), (46, 30)])
        self.assertGreater(len(default["states"]), 25)

    def test_regex_absences_validate_and_roundtrip_before_launch(self):
        pattern = r"^ *○ [0123456789abcdefghjkmnpqrstvwxyz]{6} +[0-9]+[smhd] *$"
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
                 "absent_regex": [r"^ *○ [0123456789abcdefghjkmnpqrstvwxyz]{6} +[0-9]+[smhd] *$"]}
        clean = "  + New Session\n ✓ Existing conversation  3h\n  Settings\nenter open"
        run = types.SimpleNamespace(meta={"sha": "a" * 40})
        for size in ((140, 40), (46, 30)):
            for sid, age in (("9xt4vy", "42s"), ("emged6", "7m"), ("000000", "3h"), ("zzzzzz", "12d")):
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
                    # Transition captures may skip readiness, never the saved oracle.
                    terminal = types.SimpleNamespace(wait=unittest.mock.Mock(), frame=committed(bad, *size))
                    transition = {**state, "first_frame": True}
                    self.helper["frame_ready"](terminal, transition)
                    terminal.wait.assert_not_called()
                    self.assertFalse(self.helper["frame_capture"](run, terminal, Path(temp), transition, size, None)["ok"])
        for row in (" ○ Existing 9xt4vy  2m", " ○ 9xt4vy extra  2m", " ○ 9xt4vy  text  2m",
                    " ○ 9xt4vy", "text mentions ○ 9xt4vy  2m"):
            with self.subTest(named_or_nonrow=row):
                self.assertIsNone(self.helper["frame_row_failure"](state, clean + "\n" + row))
        # Regex absence is opt-in: a current empty chat may own its sidebar row.
        self.assertIsNone(self.helper["frame_row_failure"]({"name": "current-chat"}, " ○ 9xt4vy  0s"))

    def test_empty_chat_roundtrips_exclude_abandoned_rows_without_rejecting_current_chat(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        for name in ("start-empty", "day-start", "start-busy", "overview-printable-ignored", "many-sessions",
                     "many-sessions-middle", "many-sessions-end", "many-sessions-pinned-end",
                     "empty-chat-left", "empty-chat-model-left", "empty-chat-two-left"):
            with self.subTest(state=name):
                state = states[name]
                self.assertEqual(set(state["sizes"]), {(140, 40), (46, 30)})
                self.assertIsNotNone(self.helper["frame_row_failure"](state, " ○ 9xt4vy                  2m"))
        for name in ("chat-empty", "start-model", "start-effort", "start-picked"):
            self.assertNotIn("absent_regex", states[name], "the currently open empty sidebar row is allowed")
        for name in ("empty-chat-left", "empty-chat-model-left", "empty-chat-two-left"):
            state = states[name]
            self.assertTrue(state["first_frame"])
            self.assertIn("Type a task", state["absent"])
            self.assertIn("Existing conversation", state["expect"])
            self.assertEqual(state["steps"][-1], {"wait": "enter open"})
        model = states["empty-chat-model-left"]["steps"]
        self.assertIn({"mouse": {"at": "gpt-6.1-terra", "do": "click"}}, model)
        self.assertIn({"wait": "gpt-6.1-terra ·"}, model)
        self.assertIn({"gone": "Model"}, model)
        self.assertEqual(sum(step == {"keys": ["Home", "Enter"]} for step in states["empty-chat-two-left"]["steps"]), 2)
        self.assertIn("Existing second conversation", states["empty-chat-two-left"]["expect"])
        self.assertTrue(states["empty-chat-left"]["cast"][0]["messages"])
        self.assertTrue(states["empty-chat-two-left"]["cast"][0]["messages"])

    def test_settings_frame_opens_the_list_row_and_waits_for_the_page(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        state = next(state for state in scenario["states"] if state["name"] == "settings")
        self.assertEqual(state["open"], "overview")
        self.assertEqual(state["sizes"], [(140, 40), (46, 30)])
        self.assertEqual(state["steps"], [
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
                label = "    stdout tail:" if name == "tool-open-long" else "    stderr tail:"
                self.assertIn(status, state["expect"])
                self.assertIn(label, state["expect"])
                self.assertFalse(any(step.get("gone", "").startswith(("Bash ", "stdout tail:", "stderr tail:")) for step in state["steps"]))
                self.assertTrue(any(text.startswith("    ") for text in state["expect"]))
                # Do not capture the asynchronous opening notice as the finished fold.
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
        self.assertEqual(len(states["keys"]["expect"]), 11)
        self.assertIn("/help", states["keys"]["absent"])
        self.assertIn("× Fail with exit 127 · 127", states["chat"]["expect"])

    def test_two_open_folds_select_list_before_resizing_to_the_split_layout(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        state = next(state for state in scenario["states"] if state["name"] == "tool-open-two")
        self.assertEqual(state["sizes"], [(46, 30), (140, 40)])
        # Reach a known narrow tail, then move rows rather than four half-pages:
        # the wider terminal now gives only 99 columns to the chat beside the list.
        self.assertEqual(state["steps"][:13], [
            {"wait": "The project has a README"},
            {"keys": ["C-o"]},
            {"wait": "    stderr tail:"},
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
                     "× Fail with exit 127 · 127", "× Fail with an excerpt · 1",
                     "    Bash succeeded. Exit code: 0.", "    stdout tail:", "    Bash failed. Exit code: 1.", "    stderr tail:",
                     "    usage: example", "    unknown option --help"):
            self.assertIn(text, state["expect"])

    def test_status_word_frames_reject_the_old_prose(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        for name, wanted, old in (
            ("tool-open-two", "× Fail with exit 127 · 127", " · exit 127"),
            ("fold-hover", "× Fail with exit 127 · 127", " · exit 127"),
            ("fold-hover", "× Fail with an excerpt · 1", " · exit 1"),
            ("chat-working", "Thinking", "Waiting"),
            ("copy-last-answer", "Sent to clipboard", "No code block in the last answer."),
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

    def test_cast_skills_are_safe_unique_fixture_names(self):
        for value in ([], ["review"], ["review", "check-project"]):
            data = self.scenario()
            data["states"][1]["cast"][0]["skills"] = value
            self.helper["validate_scenario"](data)
        for value in (None, "review", ["../escape"], ["/absolute"], ["review", "review"], [42], [""]):
            data = self.scenario()
            data["states"][1]["cast"][0]["skills"] = value
            with self.subTest(skills=value), self.assertRaisesRegex(ValueError, "invalid cast skills"):
                self.helper["validate_scenario"](data)

    def test_invalid_scenarios(self):
        mutations = [
            lambda d: d.update(states=[]),
            lambda d: d["states"][0].update(open="Fix it"),  # Not seeded yet.
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
            lambda d: d["states"][1]["cast"][0].update(count=2),  # Missing {n}.
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
            with patch.dict(build.__globals__, {"CACHE": root / "cache"}), patch("subprocess.run", command), \
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

    def run_frames_scenario(self, scenario, sizes=None, capture_ok=True, only=None, failing_state=None,
                            initial_frames=("›",)):
        """Run the real loader/orchestrator with an inert OS and capture adapter."""
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
                    calls.append(("open", state["name"], size, state.get("theme", "night")))

                def wait(self, predicate, _description, *, allow_exit=False):
                    for screen in initial_frames:
                        calls.append(("initial-frame", screen, allow_exit))
                        if predicate(types.SimpleNamespace(completed=screen)):
                            return
                    raise AssertionError("initial readiness did not accept any committed frame")

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
                calls.append(("steps",))
                if target.state["name"] == failing_state:
                    raise self.helper["FrameFailure"]("fixture state failed")
                return False

            replacements = {"Run": lambda _path: run, "cmd_new": lambda _args: print(root),
                            "cmd_cleanup": lambda _args: None, "frame_wait": lambda *_args, **_kw: None,
                            "frame_ready": lambda *_args, **_kw: None, "FrameTerminal": Terminal,
                            "load_build": lambda _sha: {"screen_library": "/test/library"},
                            "frame_steps": steps, "frame_capture": capture}
            with patch.dict(command.__globals__, replacements), patch.dict(os.environ), \
                    patch("time.sleep", side_effect=AssertionError("frames must not sleep to settle")), \
                    contextlib.redirect_stdout(io.StringIO()):
                command(args)
            records = json.loads((root / "out/frames.json").read_text())
        return calls, records

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
                self.assertEqual(calls[calls.index(("steps",)) - 1],
                                 ("initial-frame", screens[count - 1], allow_exit))
                self.assertTrue(records[0]["ok"])

    def test_initial_readiness_accepts_editorless_list_and_legacy_prompt(self):
        listed = "  + New Session\n  Settings\nenter open"
        self.assertNotIn("Type a task", listed)
        def accepts_list(predicate, _description, **_kwargs):
            self.assertTrue(predicate(types.SimpleNamespace(completed=listed)),
                            "committed overview list must not require an editor")
        self.helper["frame_initial_ready"](types.SimpleNamespace(wait=accepts_list))
        cases = [
            ([listed], None, 1),
            ([listed.replace("+ New Session", ""), listed], None, 2),
            ([listed.replace("Settings", ""), listed], None, 2),
            ([listed.replace("enter open", ""), listed], None, 2),
            ([listed + " Opening…", listed], None, 2),
            ([listed, listed + " Ready"], "Ready", 2),
            # Before captures use the old image with the same new recipes.
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
                self.assertEqual(calls[calls.index(("steps",)) - 1],
                                 ("initial-frame", screens[count - 1], False))
                self.assertTrue(records[0]["ok"])

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
                self.assertEqual(calls[first - 1], ("steps",))  # No first-size resize or sleep after the wait.
                second = next(i for i, call in enumerate(calls) if i > first and call[0] == "capture")
                self.assertEqual(calls[second - 1], ("resize", expected[1]))

    def test_failed_capture_makes_the_command_fail(self):
        scenario = {"sizes": ["100x30"], "states": [{"name": "working", "open": "overview", "steps": []}]}
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
            self.run_frames_scenario(scenario, capture_ok=False)
        self.assertEqual(result.exception.code, 1)

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
        self.assertEqual(calls.count(("steps",)), 2)  # Still drive the predecessor for side effects.
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
        # A Rui that has already exited: only the exit key expects that.
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
        # Combined readiness must reject an old sidebar's Stopping text even
        # when the conversation already contains the stopped ending.
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
        wrong = "■ Stop the slow job  0s\n   Old completed answer\n■ Another Session\n   Stopped\n■ Stopped"
        self.assertIsNotNone(failure(state, wrong))
        self.assertIsNone(failure(state, wrong.replace("Old completed answer", "Stopped")))

    def test_chat_frames_require_loaded_sidebar_rows_and_a_last_row_footer(self):
        states = {state["name"]: state for state in self.helper["load_scenario"](SCRIPT.with_name("frames.json"))["states"]}
        for name in ("chat-no-new-session", "chat-sidebar-rows"):
            state = states[name]
            self.assertIn("+ New Session", state["absent"])
            self.assertEqual(state["expect_last"], "alt+i info")
        self.assertEqual(states["chat-no-new-session"]["sizes"][0], (140, 40))
        self.assertIn({"wait": "Schema migration"}, states["chat-no-new-session"]["steps"])
        self.assertEqual(states["chat-sidebar-rows"]["sizes"], [(140, 40)])
        for label in ("Schema migration", "Sidebar chat", "Batch job"):
            self.assertIn(label, states["chat-sidebar-rows"]["expect"])
        failure = self.helper["frame_row_failure"]
        state = {"expect_last": "alt+i info"}
        for height in (30, 40):
            good = "\n" * (height - 1) + "Sidebar chat  alt+i info\n"
            self.assertIsNone(failure(state, good))
            self.assertIsNotNone(failure(state, good + "\n"))
            # A nonempty sidebar tail must not hide the chat's blank last row.
            self.assertIsNotNone(failure(state, good + "  Settings  │\n"))

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


if __name__ == "__main__":
    unittest.main()

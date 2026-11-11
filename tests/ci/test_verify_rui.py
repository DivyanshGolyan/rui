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

    def test_sizes(self):
        parse = self.helper["parse_sizes"]
        self.assertEqual(parse("140x40,46x30"), [(140, 40), (46, 30)])
        self.assertEqual(parse(["1x1"]), [(1, 1)])
        for value in (None, [], "", "0x30", "46x0", "-1x3", "12X3", "12x", "2x3,", "2x3,2x3", [42], " 2x3"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse(value)

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

    def test_narrow_markdown_frame_pins_the_code_continuation_indent(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        state = next(state for state in scenario["states"] if state["name"] == "markdown-wrapped")
        self.assertEqual(state["open"], "Markdown retry")
        self.assertEqual(state["sizes"], [(46, 30)])
        self.assertIn("return null; //\n    expired", state["expect"])

    def test_busy_frame_waits_for_work_text_not_a_rotating_spinner(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        state = next(state for state in scenario["states"] if state["name"] == "start-busy")
        self.assertIn({"wait": "Run the slow tests"}, state["steps"])
        self.assertEqual(state["expect"], ["Docs build", "Run the slow tests"])

    def test_default_frames_use_plain_endings_and_active_tool_marks(self):
        scenario = self.helper["load_scenario"](SCRIPT.with_name("frames.json"))
        states = {state["name"]: state for state in scenario["states"]}
        for name, words in (("stopped", "■ Stopped"),
                            ("chat-failed", "× Model reply unreadable")):
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
                self.assertIn("ctrl+o close", state["expect"])
                self.assertTrue(any(text.startswith(("✓ ", "× ")) for text in state["expect"]))
                for text in ("▸", "Bash failed. Exit code:", "Bash succeeded. Exit code:", "stdout tail:", "stderr tail:"):
                    self.assertIn({"gone": text}, state["steps"])
                self.assertTrue(any(text.startswith("    ") for text in state["expect"]))
                # Do not capture the asynchronous opening notice as the finished fold.
                self.assertIn({"gone": "Opening tool output…"}, state["steps"])
        self.assertEqual(states["tool-open-nocolor"]["env"], {"NO_COLOR": "1"})
        for name in ("tool-open", "tool-open-long", "tool-open-nocolor"):
            self.assertEqual(states[name]["sizes"], [(46, 30), (140, 40)])
        keys = [key for step in states["tool-open-two"]["steps"] for key in step.get("keys", [])]
        self.assertEqual(keys.count("C-o"), 2)
        self.assertTrue(any(text.startswith("    … ") and text.endswith(" more lines")
                            for text in states["tool-open-long"]["expect"]))
        for name in ("help", "slash"):
            self.assertIn({"gone": "/details"}, states[name]["steps"])
        self.assertIn("ctrl+o                 open", states["help"]["expect"])
        self.assertIn("× Fail with exit 127 · exit 127", states["chat"]["expect"])

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
            lambda d: d["states"][0].update(open="Fix it"),  # Not seeded yet.
            lambda d: d["states"][1].update(open="missing"),
            lambda d: d["states"][1].update(open=[]),
            lambda d: d["states"][1].update(theme=[]),
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

    def test_ansi_sgr_and_html_escaping(self):
        render = self.helper["ansi_render"]
        bg, fg = "#121933", "#d4cebf"
        cases = [
            ("\x1b[31mred\x1b[0mplain", ['color:#cd3131">red', f'color:{fg}">plain']),
            ("\x1b[91;104mbright", ["color:#f14c4c", "background:#3b8eea"]),
            ("\x1b[38;5;196mred\x1b[48;5;232mblack", ["color:#ff0000", "background:#080808"]),
            ("\x1b[38;2;10;20;30;1mRGB", ["color:#0a141e", "font-weight:700"]),
            ("\x1b[38:2::10:20:30mRGB", ["color:#0a141e"]),
            ("\x1b[48:5:21mblue", ["background:#0000ff"]),
            ("\x1b[1;2;3;4;9mstyled\x1b[22;23;24;29mnormal", ["font-weight:700", "opacity:.6", "font-style:italic", "underline line-through", f'color:{fg}">normal']),
            ("\x1b[7minverse\x1b[27mnormal", [f"color:{bg};background:{fg}", f'color:{fg}">normal']),
            ("\x1b[31;44mcolour\x1b[39;49mdefault", [f'color:{fg}">default']),
        ]
        for ansi, snippets in cases:
            with self.subTest(ansi=ansi):
                rendered = render(ansi, bg, fg)
                self.assertNotIn("\x1b", rendered)
                for snippet in snippets:
                    self.assertIn(snippet, rendered)
        link = '\x1b]8;;https://example.com\x1b\\<script>&\x1b]8;;\x1b\\'
        self.assertIn("&lt;script&gt;&amp;", render(link, bg, fg))
        self.assertNotIn("https:", render(link, bg, fg))
        self.assertIn("color:#cd3131", render("\x1b[31mone\ntwo", bg, fg))
        page = self.helper["ansi_page"]("body", bg, fg, 46, 30, (2, 3))
        for snippet in ("width:46ch", "height:40.5em", "left:2ch", bg, fg):
            self.assertIn(snippet, page)

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
                             [["zig", "build", "-Doptimize=ReleaseSafe", "--summary", "all"]])
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

    def run_frames_scenario(self, scenario, sizes=None, capture_ok=True):
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
            run.tmux = lambda *argv, **_kw: (calls.append(argv) or types.SimpleNamespace(returncode=0, stdout="999\n", stderr=""))
            args = types.SimpleNamespace(sha="a" * 40, scenario=str(source), only=None, sizes=sizes,
                                         out=str(root / "out"), no_png=True, keep=False)

            def capture(_run, _target, _out, state, size, reason):
                calls.append(("capture", size))
                return {"name": state["name"], "size": self.helper["size_name"](size), "files": {},
                        "ok": capture_ok, "status": "ok" if capture_ok else "failed", "note": "",
                        "reason": reason if capture_ok else "state left before capture: Working"}

            replacements = {"Run": lambda _path: run, "cmd_new": lambda _args: print(root),
                            "cmd_cleanup": lambda _args: None, "frame_wait": lambda *_args, **_kw: None,
                            "frame_steps": lambda *_args, **_kw: calls.append(("steps",)), "frame_capture": capture}
            with patch.dict(command.__globals__, replacements), patch("shutil.which", return_value="/bin/tmux"), \
                    patch("time.sleep", side_effect=lambda seconds: calls.append(("sleep", seconds))), \
                    contextlib.redirect_stdout(io.StringIO()):
                command(args)
            records = json.loads((root / "out/frames.json").read_text())
        return calls, records

    def test_frame_window_gets_its_size_before_rui_exec(self):
        scenario = {"sizes": ["100x30"], "states": [{"name": "empty", "open": "overview", "steps": []}]}
        calls, _records = self.run_frames_scenario(scenario)
        initial_size = [i for i, c in enumerate(calls) if c == ("set-option", "-g", "default-size", "100x30")]
        self.assertEqual(len(initial_size), 1)
        create = next(i for i, c in enumerate(calls) if c[0] == "new-window")
        self.assertLess(initial_size[0], create)
        colour = next(i for i, c in enumerate(calls) if "window-style" in c)
        self.assertLess(colour, create)

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
                self.assertEqual(calls[second - 1], ("sleep", 0.8))

    def test_failed_capture_makes_the_command_fail(self):
        scenario = {"sizes": ["100x30"], "states": [{"name": "working", "open": "overview", "steps": []}]}
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
            self.run_frames_scenario(scenario, capture_ok=False)
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
        actions = [{"keys": ["PgDn"]}, {"text": "new draft"},
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
                run = types.SimpleNamespace(meta={"sha": "a" * 40}, tmux=lambda *argv, **_kw:
                    types.SimpleNamespace(returncode=0, stderr="", stdout=screen if argv[0] == "capture-pane" else "0 0 0\n"))
                out = Path(temp)
                record = self.helper["frame_capture"](run, "pane", out, state, (100, 20), None)
                self.assertEqual(record["ok"], ok)
                self.assertEqual(record["reason"], None if ok else "state left before capture: New Sessions")
                if ok:
                    self.assertNotIn("This Session", (out / record["files"]["txt"]).read_text())
                    self.assertIn("New Sessions", (out / record["files"]["txt"]).read_text())

    def test_capture_expectations_over_sizes_and_state_transitions(self):
        capture = self.helper["frame_capture"]
        cases = [
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
                run = types.SimpleNamespace(meta={"sha": "a" * 40})
                records = []
                for size, screen, reason in zip(((100, 30), (46, 30)), screens, reasons):
                    ansi = "\x1b[31m" + screen + "\x1b[0m  \n"

                    def tmux(*argv, **_kwargs):
                        self.assertIn(argv[0], ("capture-pane", "display-message"))
                        if argv[0] == "capture-pane":
                            self.assertIn("-e", argv)  # The text and HTML share this one snapshot.
                        return types.SimpleNamespace(returncode=0, stderr="", stdout=ansi if argv[0] == "capture-pane" else "0 0 0\n")

                    run.tmux = tmux
                    record = capture(run, "pane", out, state, size, None)
                    records.append(record)
                    self.assertEqual(record["reason"], reason)
                    self.assertEqual(record["ok"], reason is None)
                    self.assertEqual(record["status"], "ok" if reason is None else "failed")
                    self.assertEqual((out / record["files"]["txt"]).read_text(), screen + "\n")
                    self.assertEqual((out / record["files"]["ansi"]).read_text(), ansi)
                    self.assertIn(screen, (out / record["files"]["html"]).read_text())
                self.helper["frames_index"](out, records, False)
                self.assertEqual([r["ok"] for r in json.loads((out / "frames.json").read_text())],
                                 [reason is None for reason in reasons])

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

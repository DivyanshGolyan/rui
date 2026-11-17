"""Pure checks for Upgrade fixture ownership and readiness; no native fixture is launched."""
import copy
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch


FIXTURE = Path(__file__).resolve().parents[1] / "integration/upgrade_integration.py"


class NotReady(Exception):
    pass


def committed_once(observe, description, *, timeout, ready):
    frame = observe()
    if not ready(frame):
        raise NotReady(description)
    return frame


class UpgradeEmptyChatTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("upgrade_screen_cases", FIXTURE)
        cls.fixture = importlib.util.module_from_spec(spec)
        with patch.object(sys, "path", [str(FIXTURE.parent), *sys.path]), \
                patch.object(subprocess, "run", side_effect=AssertionError("readiness tests must not launch a process")):
            spec.loader.exec_module(cls.fixture)

    def setUp(self):
        self.session = "a1b2c3"
        self.notice = "Upgraded to 0.71.10000 · Host restarted"
        self.report = {"session": {"reference": self.session, "model": "gpt-6-luna"},
                       "selected_message": None, "recent_messages": []}
        self.listing = {"sessions": [{"reference": self.session}]}
        self.screen = self.fixture.TerminalScreen.__new__(self.fixture.TerminalScreen)
        self.case = SimpleNamespace(store="/fixture/store", json=Mock())
        self.wait = patch.object(self.fixture, "wait_for", side_effect=committed_once)
        self.wait.start()
        self.addCleanup(self.wait.stop)

    def observe(self, footer, *, report=None, listing=None, model="gpt-6-luna"):
        self.case.json.side_effect = [copy.deepcopy(self.report if report is None else report),
                                      copy.deepcopy(self.listing if listing is None else listing)]
        frame = f"{self.fixture.VERTICAL_DIVIDER} › conversation β draft\n{self.fixture.VERTICAL_DIVIDER} {model} · low    {footer}"
        self.screen.observe = lambda: frame
        return self.screen.empty_chat(self.case, self.session)

    def test_case_disk_lifetime_follows_successful_process_retirement(self):
        for body_fails, cleanup_fails in ((False, False), (True, False), (False, True)):
            with self.subTest(body_fails=body_fails, cleanup_fails=cleanup_fails), tempfile.TemporaryDirectory() as root:
                directory = Path(root) / "case"
                directory.mkdir()
                (directory / "diagnostics").write_text("retained on failure")
                def retire():
                    self.assertTrue(directory.exists(), "files removed before process retirement")
                    if cleanup_fails:
                        raise RuntimeError("cleanup")
                value = SimpleNamespace(root=directory, close=Mock(side_effect=retire))
                releases = SimpleNamespace(gates={}, status={}, latest_location="old", sums_name="old")
                with patch.object(self.fixture, "Case", return_value=value):
                    try:
                        with self.fixture.case(Path(root), None, releases, "case"):
                            if body_fails:
                                raise ValueError("body")
                    except (RuntimeError, ValueError):
                        self.assertTrue(body_fails or cleanup_fails)
                    else:
                        self.assertFalse(body_fails or cleanup_fails)
                value.close.assert_called_once_with()
                self.assertEqual(directory.exists(), body_fails or cleanup_fails)
                self.assertIsNone(releases.latest_location)
                self.assertIsNone(releases.sums_name)

    def test_shared_home_cases_can_start_distinct_default_retained_installations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary_a, binary_b = root / "binary-a", root / "binary-b"
            binary_a.write_bytes(b"first retained native artifact")
            binary_b.write_bytes(b"second retained native artifact")
            releases = SimpleNamespace(origin="http://fixture.invalid")
            first = self.fixture.Case(root, binary_a, releases, "first")
            second = self.fixture.Case(root, binary_b, releases, "second")
            second.home, second.env, second.link = first.home, first.env, first.link
            children = [SimpleNamespace(pid=101), SimpleNamespace(pid=102)]
            ready = [{"socket": "first.sock"}, {"socket": "second.sock"}]
            first.status = Mock(return_value={"status": "ready", "instance": "first"})
            second.status = Mock(return_value={"status": "ready", "instance": "second"})
            # Exercise the actual Case.start_host -> Case.build path and its
            # file copies; only the native launch/socket observation is mocked.
            with patch.object(self.fixture, "start_ready_process", side_effect=zip(children, ready)) as start, \
                    patch.object(self.fixture, "peer_pid", side_effect=[101, 102]):
                first_child, first_status = first.start_host(sources_only=True)
                first_executable = Path(start.call_args.args[0][0])
                original = first_executable.read_bytes()
                second_child, second_status = second.start_host(sources_only=True)
                second_executable = Path(start.call_args.args[0][0])
            self.assertEqual([first_child, second_child], children)
            self.assertEqual([first_status["instance"], second_status["instance"]], ["first", "second"])
            self.assertEqual(first.hosts, [children[0]])
            self.assertEqual(second.hosts, [children[1]])
            self.assertNotEqual(first_executable, second_executable)
            self.assertFalse(first_executable.samefile(second_executable))
            self.assertEqual(first_executable.read_bytes(), original)
            self.assertEqual(original, binary_a.read_bytes())
            self.assertEqual(second_executable.read_bytes(), binary_b.read_bytes())
            for executable in (first_executable, second_executable):
                build = executable.parent.parent
                self.assertEqual(build.parent, first.home / ".local/lib/rui")
                self.assertEqual(executable.relative_to(build), Path("bin/rui"))
                self.assertTrue(build.name.endswith("-retained-real-host"))
                self.assertTrue((build / "THIRD_PARTY_NOTICES.md").is_file())
            self.assertEqual(start.call_count, 2)

    def test_case_build_never_reuses_or_overwrites_its_existing_installation(self):
        for managed in (False, True):
            for version in (None, "0.1.0"):
                with self.subTest(managed=managed, version=version), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    binary = root / "binary"
                    binary.write_bytes(b"original native artifact")
                    owner = self.fixture.Case(root, binary, SimpleNamespace(origin="http://fixture.invalid"), "owner")
                    build = owner.build("retained", version, managed=managed)
                    executable = build / "bin/rui"
                    original = executable.read_bytes()
                    notices = (build / "THIRD_PARTY_NOTICES.md").read_bytes()
                    binary.write_bytes(b"replacement must not overwrite a retained artifact")
                    with self.assertRaises(FileExistsError):
                        owner.build("retained", None if version is None else "0.2.0", managed=managed)
                    self.assertEqual(executable.read_bytes(), original)
                    self.assertEqual((build / "THIRD_PARTY_NOTICES.md").read_bytes(), notices)
                    if managed:
                        self.assertEqual(build.parent, owner.home / ".local/lib/rui")
                    else:
                        self.assertEqual(build, owner.root / "retained")

    def test_chat_footer_rejects_upgrade_notices_before_and_after_relaunch(self):
        self.assertIn("gpt-6-luna", self.observe(""))
        for footer in (self.notice, "Upgraded to another version · Host restarted", "alt+i info",
                       "alt+i info · upgraded to 0.76.0", "alt+i info  Upgraded to 0.76.0"):
            with self.subTest(footer=footer), self.assertRaises(NotReady):
                self.observe(footer)
        with self.assertRaises(NotReady):
            self.observe("", model="wrong-model")

    def test_quiet_version_is_below_settings_not_a_version_elsewhere(self):
        version = "0.76.0"
        valid = [f"Settings\n  38 MB    {version} ", f"Settings {self.fixture.VERTICAL_DIVIDER} chat\n {version} {self.fixture.VERTICAL_DIVIDER} model"]
        invalid = [f"Settings {version}\n footer", f"Settings\nUpdate to {version}",
                   f"Settings\nrui 38 MB {version}", f"Settings\n38 MB tools 12 MB {version}",
                   f"Settings\n{version}\nUpgraded to {version}",
                   f"Settings\n{version}\n · upgraded to {version}",
                   f"Settings\n0.76.1\n{version}", f"Settings\n38 MB\n{version}"]
        for frame in valid:
            self.screen.observe = lambda: frame
            with self.subTest(frame=frame):
                self.assertEqual(frame, self.screen.quiet_version(version))
        for frame in invalid:
            self.screen.observe = lambda: frame
            with self.subTest(frame=frame), self.assertRaises(NotReady):
                self.screen.quiet_version(version)

    def test_public_identity_and_zero_messages_remain_required(self):
        footer = ""
        self.case.json.reset_mock()
        self.observe(footer)
        self.assertEqual(self.case.json.call_args_list, [
            call("session", "inspect", "--store", self.case.store, "--session", self.session),
            call("session", "list", "--store", self.case.store, "--all")])
        for field, value in (("session", {"reference": "wrong1", "model": "gpt-6-luna"}),
                             ("selected_message", "message1"), ("recent_messages", [{"message": "message1"}])):
            report = {**self.report, field: value}
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.observe(footer, report=report)
        for sessions in ([], [{"reference": "wrong1"}],
                         [{"reference": self.session}, {"reference": "wrong1"}]):
            with self.subTest(sessions=sessions), self.assertRaises(AssertionError):
                self.observe(footer, listing={"sessions": sessions})


    def hidden(self, frame, *, report=None, listing=None):
        self.case.json.side_effect = [copy.deepcopy(self.report if report is None else report),
                                      copy.deepcopy(self.listing if listing is None else listing)]
        self.screen.observe = lambda: frame
        return self.screen.empty_overview(self.case, self.session)

    def test_hidden_empty_overview_requires_real_list_and_no_editor_or_chat(self):
        frame = "+ New Session\nSettings"
        self.assertEqual(frame, self.hidden(frame))
        for extra in (self.session, "alt+i info"):
            with self.subTest(extra=extra), self.assertRaises(AssertionError):
                self.hidden(frame + "\n" + extra)
        for extra in ("Type a task", "› hidden draft"):
            with self.subTest(extra=extra), self.assertRaises(NotReady):
                self.hidden(frame + "\n" + extra)
        for wrong in ("Settings", "+ New Session", "Notifications"):
            with self.subTest(wrong=wrong), self.assertRaises(NotReady):
                self.hidden(wrong)

    def test_overview_waits_past_sidebar_controls_for_the_full_list(self):
        sidebar = f" + New Session                Archived {self.fixture.VERTICAL_DIVIDER}\n   Settings {self.fixture.VERTICAL_DIVIDER} gpt-6-luna · low\n"
        frames = [sidebar + f"{self.fixture.VERTICAL_DIVIDER} › Type a task", sidebar + f"{self.fixture.VERTICAL_DIVIDER} › unsent draft",
                  "+ New Session                Archived\nSettings"]
        self.screen.observe = Mock(side_effect=frames)
        self.case.json.side_effect = [copy.deepcopy(self.report), copy.deepcopy(self.listing)]
        readiness = []

        def committed_frames(observe, description, *, timeout, ready):
            for _ in frames:
                frame = observe()
                readiness.append(ready(frame))
                if readiness[-1]:
                    return frame
            raise NotReady(description)

        with patch.object(self.fixture, "wait_for", side_effect=committed_frames):
            self.assertEqual(frames[-1], self.screen.empty_overview(self.case, self.session))
        self.assertEqual(readiness, [False, False, True])
        self.assertEqual(self.screen.observe.call_count, 3)

    def test_legacy_and_stitch_dividers_preserve_overview_and_upgrade_readiness(self):
        for divider in self.fixture.DIVIDER_GLYPHS:
            with self.subTest(divider=divider):
                sidebar = f"+ New Session {divider} chat\nSettings {divider} model\n"
                with self.assertRaises(NotReady):
                    self.hidden(sidebar + f"{divider} › unsent draft")
                self.screen.observe = lambda: f"Settings {divider} chat\n 38 MB 0.76.0 {divider} model"
                self.assertIn("0.76.0", self.screen.quiet_version("0.76.0"))
                self.case.json.side_effect = [copy.deepcopy(self.report), copy.deepcopy(self.listing)]
                self.screen.observe = lambda: f"{divider} gpt-6-luna · low"
                self.assertIn("gpt-6-luna", self.screen.empty_chat(self.case, self.session))

    def test_hidden_projection_does_not_weaken_stored_identity_or_zero_messages(self):
        frame = "+ New Session\nSettings"
        self.case.json.reset_mock()
        self.hidden(frame)
        self.assertEqual(self.case.json.call_args_list, [
            call("session", "inspect", "--store", self.case.store, "--session", self.session),
            call("session", "list", "--store", self.case.store, "--all")])
        for field, value in (("session", {"reference": "wrong1", "model": "gpt-6-luna"}),
                             ("selected_message", "message1"), ("recent_messages", [{"message": "message1"}])):
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.hidden(frame, report={**self.report, field: value})
        for sessions in ([], [{"reference": "wrong1"}],
                         [{"reference": self.session}, {"reference": "wrong1"}]):
            with self.subTest(sessions=sessions), self.assertRaises(AssertionError):
                self.hidden(frame, listing={"sessions": sessions})


    def test_leave_empty_chat_acknowledges_modal_and_editor_before_escape(self):
        events = Mock()
        self.screen.capture = SimpleNamespace(completed="chat footer")
        self.screen.send = Mock()
        self.screen.until = Mock(side_effect=lambda predicate, description: self.assertTrue(predicate()))
        self.screen.draft = Mock()
        self.screen.empty_overview = Mock(return_value="hidden empty")
        for name in ("send", "until", "draft", "empty_overview"):
            events.attach_mock(getattr(self.screen, name), name)
        self.assertEqual("hidden empty", self.screen.leave_empty_chat(self.case, self.session))
        self.assertEqual(events.mock_calls[0], call.send("\x1b"))
        self.assertEqual(events.mock_calls[1][0], "until")
        self.assertEqual(events.mock_calls[2:], [call.send("\x05\x15"), call.draft("", 2),
                                               call.send("\x1b"), call.empty_overview(self.case, self.session)])


if __name__ == "__main__":
    unittest.main()

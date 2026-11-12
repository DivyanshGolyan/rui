"""Pure checks for Upgrade screen readiness; no native fixture is launched."""
import copy
import importlib.util
from pathlib import Path
import subprocess
import sys
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

    def observe(self, footer, *, notice=None, report=None, listing=None, model="gpt-6-luna"):
        self.case.json.side_effect = [copy.deepcopy(self.report if report is None else report),
                                      copy.deepcopy(self.listing if listing is None else listing)]
        frame = f"│ › conversation β draft\n│ {model} · low    {footer}"
        self.screen.observe = lambda: frame
        return self.screen.empty_chat(self.case, self.session, expected_notice=notice)

    def test_initial_info_action_and_explicit_relaunch_notice(self):
        self.assertIn("alt+i info", self.observe("alt+i info"))
        with self.assertRaises(NotReady):
            self.observe(self.notice)
        self.assertIn(self.notice, self.observe(self.notice, notice=self.notice))
        for footer in ("alt+i info", "Upgraded to another version · Host restarted", ""):
            with self.subTest(footer=footer), self.assertRaises(NotReady):
                self.observe(footer, notice=self.notice)
        for notice in (None, self.notice):
            with self.subTest(notice=notice), self.assertRaises(NotReady):
                self.observe(notice or "alt+i info", notice=notice, model="wrong-model")

    def test_public_identity_and_zero_messages_remain_required_in_both_paths(self):
        for notice in (None, self.notice):
            footer = notice or "alt+i info"
            self.case.json.reset_mock()
            self.observe(footer, notice=notice)
            self.assertEqual(self.case.json.call_args_list, [
                call("session", "inspect", "--store", self.case.store, "--session", self.session),
                call("session", "list", "--store", self.case.store, "--all")])
            for field, value in (("session", {"reference": "wrong1", "model": "gpt-6-luna"}),
                                 ("selected_message", "message1"), ("recent_messages", [{"message": "message1"}])):
                report = {**self.report, field: value}
                with self.subTest(notice=notice, field=field), self.assertRaises(AssertionError):
                    self.observe(footer, notice=notice, report=report)
            for sessions in ([], [{"reference": "wrong1"}],
                             [{"reference": self.session}, {"reference": "wrong1"}]):
                with self.subTest(notice=notice, sessions=sessions), self.assertRaises(AssertionError):
                    self.observe(footer, notice=notice, listing={"sessions": sessions})


    def hidden(self, frame, *, report=None, listing=None):
        self.case.json.side_effect = [copy.deepcopy(self.report if report is None else report),
                                      copy.deepcopy(self.listing if listing is None else listing)]
        self.screen.observe = lambda: frame
        return self.screen.empty_overview(self.case, self.session)

    def test_hidden_empty_overview_requires_real_list_and_no_editor_or_chat(self):
        frame = "+ New Session\nSettings\nenter open"
        self.assertEqual(frame, self.hidden(frame))
        for extra in (self.session, "Type a task", "› hidden draft", "alt+i info"):
            with self.subTest(extra=extra), self.assertRaises(AssertionError):
                self.hidden(frame + "\n" + extra)
        for wrong in ("Settings\nenter open", "+ New Session\nenter open", "Notifications"):
            with self.subTest(wrong=wrong), self.assertRaises(NotReady):
                self.hidden(wrong)

    def test_hidden_projection_does_not_weaken_stored_identity_or_zero_messages(self):
        frame = "+ New Session\nSettings\nenter open"
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


if __name__ == "__main__":
    unittest.main()

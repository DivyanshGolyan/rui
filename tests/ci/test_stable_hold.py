from datetime import datetime, timezone
import unittest

from stable_hold import status, uncited

ISSUES = [(711, "CI red: human_cli a", ["tests/integration/human_cli_integration.py"]),
          (712, "CI red: human_cli b", ["tests/integration/human_cli_integration.py", "src/cli.zig"]),
          (759, "CI red: unparsed", [])]


class StableHoldTest(unittest.TestCase):
    def test_a_change_to_a_held_fixture_must_cite_each_issue(self):
        paths = ["tests/integration/human_cli_integration.py", "README.md"]
        self.assertEqual([number for number, _, _ in uncited(ISSUES, paths, "Pad the fixture roots")], [711, 712])
        self.assertEqual([number for number, _, _ in uncited(ISSUES, paths, "Fixes #711\nRefs: #712")], [])
        self.assertEqual([number for number, _, _ in uncited(ISSUES, paths, "Fixes other/repo#711, fixes #7120")],
                         [711, 712])
        self.assertEqual(uncited(ISSUES, ["docs/host.md"], ""), [])

    def test_status_groups_the_hold_by_fixture(self):
        now = datetime(2026, 11, 2, 12, tzinfo=timezone.utc)
        self.assertEqual(status(ISSUES, "2026-10-31T12:00:00Z", now), [
            "Last release 48 h ago.",
            "Stable is held by 3 open stable-red issue(s):",
            "  (no fixture recorded)", "    #759 CI red: unparsed",
            "  src/cli.zig", "    #712 CI red: human_cli b",
            "  tests/integration/human_cli_integration.py",
            "    #711 CI red: human_cli a", "    #712 CI red: human_cli b"])
        self.assertEqual(status([], None, now), ["Stable is not held: no open stable-red issues."])


if __name__ == "__main__":
    unittest.main()

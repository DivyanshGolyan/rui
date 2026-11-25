import unittest
from datetime import datetime, timezone

from main_red import blocking


NOW = datetime(2026, 11, 25, 12, tzinfo=timezone.utc)


def issue(number, updated_at="2026-11-25T09:00:00Z", **extra):
    return {"number": number, "updated_at": updated_at, **extra}


class BlockingTest(unittest.TestCase):
    def test_no_open_main_red_issue_blocks_nothing(self):
        self.assertEqual(blocking([], "Fixes #7", NOW), [])

    def test_silent_body_is_blocked_by_open_issue(self):
        self.assertEqual(blocking([issue(41)], "Unrelated change", NOW), [41])

    def test_body_naming_the_issue_is_not_blocked(self):
        self.assertEqual(blocking([issue(41)], "Fixes #41", NOW), [])

    def test_body_naming_one_of_two_issues_is_not_blocked(self):
        self.assertEqual(blocking([issue(41), issue(42)], "Fixes #42", NOW), [])

    def test_two_issues_with_silent_body_block_both_in_order(self):
        self.assertEqual(blocking([issue(42), issue(41)], "", NOW), [41, 42])

    def test_pull_request_items_are_ignored(self):
        pull = issue(50, pull_request={"url": "https://example.invalid/pull/50"})
        self.assertEqual(blocking([pull], "Unrelated change", NOW), [])

    def test_number_match_is_whole_number(self):
        self.assertEqual(blocking([issue(12)], "See #123", NOW), [12])
        self.assertEqual(blocking([issue(123)], "See #12", NOW), [123])
        self.assertEqual(blocking([issue(12)], "See #12.", NOW), [])


    def test_issue_untouched_for_a_day_does_not_block(self):
        self.assertEqual(blocking([issue(41, updated_at="2026-11-24T11:00:00Z")], "", NOW), [])

if __name__ == "__main__":
    unittest.main()

import unittest

from main_red import blocking


def issue(number, **extra):
    return {"number": number, **extra}


class BlockingTest(unittest.TestCase):
    def test_no_open_main_red_issue_blocks_nothing(self):
        self.assertEqual(blocking([], "Fixes #7"), [])

    def test_silent_body_is_blocked_by_open_issue(self):
        self.assertEqual(blocking([issue(41)], "Unrelated change"), [41])

    def test_body_naming_the_issue_is_not_blocked(self):
        self.assertEqual(blocking([issue(41)], "Fixes #41"), [])

    def test_body_naming_one_of_two_issues_is_not_blocked(self):
        self.assertEqual(blocking([issue(41), issue(42)], "Fixes #42"), [])

    def test_two_issues_with_silent_body_block_both_in_order(self):
        self.assertEqual(blocking([issue(42), issue(41)], ""), [41, 42])

    def test_pull_request_items_are_ignored(self):
        pull = issue(50, pull_request={"url": "https://example.invalid/pull/50"})
        self.assertEqual(blocking([pull], "Unrelated change"), [])

    def test_number_match_is_whole_number(self):
        self.assertEqual(blocking([issue(12)], "See #123"), [12])
        self.assertEqual(blocking([issue(123)], "See #12"), [123])
        self.assertEqual(blocking([issue(12)], "See #12."), [])


if __name__ == "__main__":
    unittest.main()

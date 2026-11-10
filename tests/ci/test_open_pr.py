import unittest

import open_pr


class OpenPrTest(unittest.TestCase):
    def test_opens_only_drafts(self):
        args = open_pr.create_args("Title", "body.md", "main", "fix-x")
        self.assertIn("--draft", args)
        self.assertEqual(args[:2], ["pr", "create"])
        self.assertEqual(args[args.index("--head") + 1], "fix-x")

    def test_opens_only_a_pushed_head(self):
        self.assertIsNone(open_pr.open_refusal("a" * 40, "a" * 40))
        self.assertIn("no upstream", open_pr.open_refusal("a" * 40, None))
        self.assertIn("Push the branch first", open_pr.open_refusal("a" * 40, "b" * 40))

    def test_ready_only_after_the_last_planned_push(self):
        head = "c" * 40
        draft = {"number": 9, "isDraft": True, "headRefOid": head}
        self.assertIsNone(open_pr.ready_refusal(draft, head, dirty=False))
        self.assertIn("no open PR", open_pr.ready_refusal(None, head, dirty=False))
        self.assertIn("already ready", open_pr.ready_refusal(dict(draft, isDraft=False), head, dirty=False))
        self.assertIn("local changes", open_pr.ready_refusal(draft, head, dirty=True))
        self.assertIn("push the last planned commit", open_pr.ready_refusal(draft, "d" * 40, dirty=False))


if __name__ == "__main__":
    unittest.main()

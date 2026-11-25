import unittest

from fresh_candidate import Stale, fresh_merge

REPO = "o/r"


def api_for(states, main="m2"):
    """states: per poll, (mergeable, merge sha, merge's first parent)."""
    polls = iter(states)
    current = {}

    def api(method, path):
        if path.endswith("/branches/main"):
            return {"commit": {"sha": main}}
        if "/pulls/" in path:
            current["state"] = next(polls)
            mergeable, merge, _ = current["state"]
            return {"mergeable": mergeable, "merge_commit_sha": merge}
        if "/commits/" in path:
            return {"parents": [{"sha": current["state"][2]}]}
        raise AssertionError(path)
    return api


class FreshMergeTest(unittest.TestCase):
    def test_merge_on_current_main_is_used_at_once(self):
        self.assertEqual(fresh_merge(api_for([(True, "x", "m2")]), REPO, 1, sleep=lambda _: None), ("x", "m2"))

    def test_stale_merge_waits_for_github_to_rebuild_it(self):
        sleeps = []
        api = api_for([(True, "old", "m1"), (None, None, None), (True, "new", "m2")])
        self.assertEqual(fresh_merge(api, REPO, 1, sleep=sleeps.append), ("new", "m2"))
        self.assertEqual(len(sleeps), 2)

    def test_conflict_with_current_main_fails(self):
        with self.assertRaisesRegex(Stale, "conflicts with main"):
            fresh_merge(api_for([(False, None, None)]), REPO, 1, sleep=lambda _: None)

    def test_merge_never_rebuilt_fails_instead_of_testing_old_main(self):
        with self.assertRaisesRegex(Stale, "did not rebuild"):
            fresh_merge(api_for([(True, "old", "m1")] * 12), REPO, 1, sleep=lambda _: None)


if __name__ == "__main__":
    unittest.main()

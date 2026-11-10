import unittest

import pr_overlap


class OverlapTest(unittest.TestCase):
    def test_lists_shared_and_renamed_paths_and_skips_own_pr(self):
        prs = [
            {"number": 1, "head": {"ref": "mine", "repo": {"full_name": "a/r"}}},
            {"number": 2, "head": {"ref": "other", "repo": {"full_name": "a/r"}}},
            {"number": 3, "head": {"ref": "mine", "repo": {"full_name": "fork/r"}}},
        ]

        def api(method, path):
            if "/pulls?" in path:
                return prs
            if "/pulls/2/files?" in path:
                return [{"filename": "new.zig", "previous_filename": "old.zig"}]
            return [{"filename": "shared.zig"}]

        self.assertEqual(pr_overlap.overlaps(api, "a/r", "mine", {"old.zig", "shared.zig"}),
                         [(2, ["old.zig"]), (3, ["shared.zig"])])

    def test_rejects_github_file_list_limit(self):
        def api(method, path):
            if "/pulls?" in path:
                return [{"number": 7, "head": {"ref": "other", "repo": None}}]
            page = int(path.split("page=")[-1])
            return [{"filename": f"f{page}-{i}"} for i in range(100)] if page <= 30 else []

        with self.assertRaisesRegex(ValueError, "3000"):
            pr_overlap.overlaps(api, "a/r", "mine", {"x"})


if __name__ == "__main__":
    unittest.main()

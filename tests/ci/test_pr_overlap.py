import unittest

import pr_overlap


class OverlapTest(unittest.TestCase):
    def test_reads_owner_and_name_from_every_origin_url_shape(self):
        for url in ("https://github.com/DivyanshGolyan/rui.git\n",
                    "https://github.com/DivyanshGolyan/rui",
                    "git@github.com:DivyanshGolyan/rui.git",
                    "ssh://git@github.com/DivyanshGolyan/rui.git",
                    "http://local_proxy@127.0.0.1:43215/git/DivyanshGolyan/rui"):
            with self.subTest(url=url):
                self.assertEqual(pr_overlap.repo_from_remote(url), "DivyanshGolyan/rui")
        with self.assertRaises(ValueError):
            pr_overlap.repo_from_remote("rui")

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
                         [(2, ["old.zig"], []), (3, ["shared.zig"], [])])

    def test_lists_prs_whose_added_lines_use_a_removed_name(self):
        # #1180 renamed build.zig's `screen_build` to `screen_module`; PRs adding
        # uses of the old name broke on their next merge of main.
        diff = """--- a/build.zig
+++ b/build.zig
-const screen_build = @import("build/screen.zig");
+const screen_module = @import("build/screen.zig");
-    const local = screen_build.screenCommand(b, screen, &.{});
-pub fn shared(b: *Build) void {}
-    pub const Member = struct {};
-def helper():
"""
        # `shared` is still declared elsewhere in the tree; a local is not API.
        removed = pr_overlap.removed_names(diff, {"screen_module", "shared", "std"})
        self.assertEqual(removed, {"screen_build", "Member", "helper"})
        files = {
            "/pulls/4/files?": [{"filename": "build.zig", "patch": "@@ -1 +1 @@\n const a = 1;\n"
                                 "+    const s = screen_build.screenCommand(b);\n-    helper()\n"}],
            "/pulls/5/files?": [{"filename": "src/x.zig", "patch": "+const screen_builder = 1;\n screen_build\n"}],
            "/pulls/6/files?": [{"filename": "big.bin"}],
        }

        def api(method, path):
            if "/pulls?" in path:
                return [{"number": n, "head": {"ref": f"b{n}", "repo": None}} for n in (4, 5, 6)]
            return next(rows for key, rows in files.items() if key in path)

        # Context and removed lines, longer words and patchless files do not count.
        self.assertEqual(pr_overlap.overlaps(api, "a/r", "mine", set(), removed),
                         [(4, [], ["screen_build"])])

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

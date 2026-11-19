import contextlib
import io
import subprocess
import unittest
from pathlib import Path

from dependency_lag import (
    MARKER,
    Pin,
    Source,
    body,
    newest,
    numbers,
    pins,
    run,
    tracked,
)

MANIFEST = Path(__file__).resolve().parents[2] / "build.zig.zon"

SMALL = """.{
    .dependencies = .{
        .nghttp2 = .{
            .url = "https://github.com/nghttp2/nghttp2/releases/download/v1.71.0/nghttp2-1.71.0.tar.xz",
            .hash = "x",
        },
        .openssl = .{
            .url = "https://github.com/openssl/openssl/releases/download/openssl-3.6.5/openssl-3.6.5.tar.gz",
            .hash = "x",
        },
        .vaxis = .{
            .url = "git+https://github.com/DivyanshGolyan/libvaxis#d2276b086c33395354a3e4dd25fd0cd3b5b1d3d6",
            .hash = "x",
        },
    },
    .paths = .{ "build.zig.zon" },
}
"""

SQLITE_PAGE = "download sqlite-amalgamation-3530400.zip and sqlite-amalgamation-3540000.zip"


class FakeGitHub:
    """Routes the REST paths run() uses to in-memory state and records every write."""

    def __init__(self, releases=None, tags=None, issues=(), failing=()):
        self.releases = releases or {}
        self.tags = tags or {}
        self.issues = [dict(issue) for issue in issues]
        self.failing = set(failing)
        self.writes = []

    def __call__(self, method, path, fields=()):
        route, _, query = path.partition("?")
        page = int(query.rsplit("page=", 1)[1]) if "page=" in query else 1
        if method == "POST":
            issue = {"number": 100 + len(self.issues), "body": dict(fields)["body"]}
            self.issues.append(issue)
            self.writes.append(("POST", route, dict(fields)))
            return {"number": issue["number"]}
        if method == "PATCH":
            number = int(route.rsplit("/", 1)[1])
            self.writes.append(("PATCH", route, dict(fields)))
            next(issue for issue in self.issues if issue["number"] == number)["body"] = dict(fields)["body"]
            return {}
        if route in self.failing:
            raise subprocess.CalledProcessError(1, "gh", stderr="HTTP 502: bad gateway\nmore")
        if route.endswith("/issues"):
            found = [issue for issue in self.issues if "labels=deps-behind" in query]
            return found if page == 1 else []
        table = self.releases if route.endswith("/releases") else self.tags
        repo = route.split("/")[1] + "/" + route.split("/")[2]
        rows = table.get(repo, [])
        if route.endswith("/releases"):
            rows = [{"tag_name": tag, "draft": False, "prerelease": False} for tag in rows]
        else:
            rows = [{"name": tag} for tag in rows]
        return rows if page == 1 else []


def fetch_from(pages_by_url):
    def fetch_text(url):
        if url not in pages_by_url:
            raise OSError(f"no route for {url}")
        value = pages_by_url[url]
        if isinstance(value, Exception):
            raise value
        return value
    return fetch_text


def run_quietly(*args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = run(*args)
    return code, out.getvalue()


SQLITE_OK = fetch_from({"https://sqlite.org/download.html": SQLITE_PAGE})
SQLITE_CURRENT = fetch_from({"https://sqlite.org/download.html": "sqlite-amalgamation-3530400.zip"})
TODAY = "2026-11-17"


class PinParsingTest(unittest.TestCase):
    def test_real_manifest_pins_and_sources(self):
        real = {pin.name: pin for pin in pins(MANIFEST.read_text())}
        self.assertEqual(set(real), {"yaml", "translate_c", "sqlite", "nghttp2", "openssl", "vaxis"})
        self.assertEqual(tracked(real["yaml"]), Source("tags", "yaml/libyaml", "0.2.5"))
        self.assertEqual(tracked(real["sqlite"]), Source("sqlite", None, "3530400"))
        self.assertEqual(tracked(real["nghttp2"]), Source("releases", "nghttp2/nghttp2", "v1.71.0"))
        self.assertEqual(tracked(real["openssl"]), Source("releases", "openssl/openssl", "openssl-3.6.5"))
        self.assertIsNone(tracked(real["translate_c"]))
        self.assertIsNone(tracked(real["vaxis"]))

    def test_only_dependency_entries_are_pins(self):
        self.assertEqual([pin.name for pin in pins(SMALL)], ["nghttp2", "openssl", "vaxis"])

    def test_unknown_url_shapes_are_not_tracked(self):
        self.assertIsNone(tracked(Pin("x", "https://example.com/x-1.0.tar.gz")))


class VersionTest(unittest.TestCase):
    def test_numbers_and_prereleases(self):
        self.assertEqual(numbers("v1.71.0"), (1, 71, 0))
        self.assertEqual(numbers("openssl-3.6.5"), (3, 6, 5))
        self.assertEqual(numbers("0.2.5"), (0, 2, 5))
        self.assertEqual(numbers("3530400"), (3530400,))
        self.assertIsNone(numbers("v1.71.0-rc1"))
        self.assertIsNone(numbers("openssl-3.6.6-alpha1"))
        self.assertIsNone(numbers("v2.0.0-Beta"))
        self.assertIsNone(numbers("nightly"))

    def test_newest_domain(self):
        cases = [
            ("nghttp2", "v1.70.0", ["v1.71.0", "v1.71.0-rc1", "v1.69.0"], "v1.71.0"),
            ("nghttp2", "v1.71.0", ["v1.71.0", "v1.71.0-rc1", "v1.69.0"], None),
            ("openssl", "openssl-3.6.3", ["openssl-4.0.1", "openssl-3.6.5", "openssl-3.5.9",
                                          "openssl-3.6.6-alpha1"], "openssl-3.6.5"),
            ("sqlite", "3530400", ["3530400", "3540000"], "3540000"),
            ("yaml", "0.2.5", ["0.2.5", "0.2.4", "v0.3.0"], None),
            ("yaml", "0.2.5", ["release notes", "0.2.6"], "0.2.6"),
        ]
        for name, current, candidates, expected in cases:
            with self.subTest(name=name, current=current):
                self.assertEqual(newest(name, current, candidates), expected)


class RunTest(unittest.TestCase):
    def behind_fake(self, **extra):
        return FakeGitHub(releases={"nghttp2/nghttp2": ["v1.72.0", "v1.71.0"],
                                    "openssl/openssl": ["openssl-3.6.6", "openssl-3.6.5", "openssl-4.0.0"]}, **extra)

    def test_behind_without_issue_opens_one_labelled_issue(self):
        github = self.behind_fake()
        code, out = run_quietly(github, "o/r", SMALL, SQLITE_OK, TODAY)
        self.assertEqual(code, 0)
        self.assertEqual(len(github.writes), 1)
        method, route, fields = github.writes[0]
        self.assertEqual((method, route), ("POST", "repos/o/r/issues"))
        self.assertEqual(fields["labels[]"], "deps-behind")
        self.assertEqual(fields["title"], "Pinned dependencies behind upstream")
        self.assertTrue(fields["body"].startswith(MARKER))
        self.assertIn("| nghttp2 | v1.71.0 | [v1.72.0](https://github.com/nghttp2/nghttp2/releases/tag/v1.72.0) |",
                      fields["body"])
        self.assertIn("Not checked (pinned to a commit): vaxis", fields["body"])
        self.assertIn("Fixes #N", fields["body"])
        self.assertIn("opened the issue", out)

    def test_behind_with_stale_issue_patches_it_and_never_posts(self):
        stale = [{"number": 7, "body": "old"}]
        github = self.behind_fake(issues=stale)
        self.assertEqual(run_quietly(github, "o/r", SMALL, SQLITE_OK, TODAY)[0], 0)
        self.assertEqual([write[0] for write in github.writes], ["PATCH"])
        self.assertEqual(github.writes[0][1], "repos/o/r/issues/7")
        self.assertIn("| nghttp2 |", github.issues[0]["body"])

    def test_identical_body_causes_no_write(self):
        first = self.behind_fake()
        run_quietly(first, "o/r", SMALL, SQLITE_OK, TODAY)
        second = self.behind_fake(issues=first.issues)
        self.assertEqual(run_quietly(second, "o/r", SMALL, SQLITE_OK, TODAY)[0], 0)
        self.assertEqual(second.writes, [])

    def test_nothing_behind_and_no_issue_writes_nothing(self):
        github = FakeGitHub(releases={"nghttp2/nghttp2": ["v1.71.0"], "openssl/openssl": ["openssl-3.6.5"]})
        code, out = run_quietly(github, "o/r", SMALL, SQLITE_CURRENT, TODAY)
        self.assertEqual((code, github.writes), (0, []))
        self.assertIn("nothing behind, no issue", out)

    def test_nothing_behind_with_open_issue_says_current(self):
        github = FakeGitHub(releases={"nghttp2/nghttp2": ["v1.71.0"], "openssl/openssl": ["openssl-3.6.5"]},
                            issues=[{"number": 3, "body": "old list"}])
        run_quietly(github, "o/r", SMALL, SQLITE_CURRENT, TODAY)
        self.assertEqual([write[0] for write in github.writes], ["PATCH"])
        self.assertIn(f"All checked pins are current as of {TODAY}.", github.issues[0]["body"])

    def test_pull_requests_are_not_the_tracking_issue(self):
        github = self.behind_fake(issues=[{"number": 5, "body": "x", "pull_request": {}}])
        run_quietly(github, "o/r", SMALL, SQLITE_OK, TODAY)
        self.assertEqual([write[0] for write in github.writes], ["POST"])

    def test_one_failing_source_is_listed_and_run_still_succeeds(self):
        github = self.behind_fake(failing={"repos/nghttp2/nghttp2/releases"})
        code, out = run_quietly(github, "o/r", SMALL, SQLITE_OK, TODAY)
        self.assertEqual(code, 0)
        self.assertIn("Could not check: nghttp2 (HTTP 502: bad gateway)", github.writes[-1][2]["body"])
        self.assertIn("::warning::nghttp2", out)

    def test_every_tracked_source_failing_returns_zero_and_lists_each(self):
        github = FakeGitHub(failing={"repos/nghttp2/nghttp2/releases", "repos/openssl/openssl/releases"})
        code, out = run_quietly(github, "o/r", SMALL, SQLITE_OK, TODAY)
        self.assertEqual(code, 0)
        self.assertEqual([write[0] for write in github.writes], ["POST"])
        body_text = github.writes[0][2]["body"]
        self.assertIn("Could not check: nghttp2 (HTTP 502: bad gateway)", body_text)
        self.assertIn("Could not check: openssl (HTTP 502: bad gateway)", body_text)
        self.assertNotIn("All checked pins are current", body_text)
        self.assertIn("::warning::every upstream check failed", out)

    def test_only_failures_without_open_issue_opens_one(self):
        github = FakeGitHub(releases={"openssl/openssl": ["openssl-3.6.5"]},
                            failing={"repos/nghttp2/nghttp2/releases"})
        code, out = run_quietly(github, "o/r", SMALL, SQLITE_CURRENT, TODAY)
        self.assertEqual(code, 0)
        self.assertEqual([write[0] for write in github.writes], ["POST"])
        body_text = github.writes[0][2]["body"]
        self.assertIn("Could not check: nghttp2 (HTTP 502: bad gateway)", body_text)
        self.assertNotIn("| Dependency |", body_text)
        self.assertNotIn("The PR that bumps these pins", body_text)
        self.assertIn("opened the issue", out)

    def test_body_marks_failures_and_commit_pins(self):
        text = body([], ["vaxis", "translate_c"], [("sqlite", "timed out")], TODAY)
        self.assertTrue(text.startswith(MARKER))
        self.assertIn("Not checked (pinned to a commit): vaxis, translate_c", text)
        self.assertIn("Could not check: sqlite (timed out)", text)
        self.assertNotIn("Fixes #N", text)


if __name__ == "__main__":
    unittest.main()

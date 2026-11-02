"""The Store schema version moves only past a release, and a released row of
bootstrap_digests is never edited.

Concurrent PRs that change the schema share main's unreleased number and
update its row's digest in place, instead of each appending the next number:
web search was renumbered 46 -> 48 -> 49 on 2026-11-02 as other schema PRs
landed first.
"""
from pathlib import Path
import re
import unittest

from release_numbers import bump_error, git, main_base, released_tag

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = "src/store/schema.zig"
VERSION = re.compile(r"^pub const schema_version: u32 = (\d+);$", re.MULTILINE)
ROW = re.compile(r"\.\{ \.schema_version = (\d+), \.digest = (0x[0-9a-f]+) \}")
TAG = re.compile(r"v0\.(\d+)\.\d+")


def schema_version(source):
    match = VERSION.search(source)
    if match is None:
        raise AssertionError(f"{SCHEMA} declares no schema_version")
    return int(match[1])


def rows(source):
    return {int(version): digest for version, digest in ROW.findall(source)}


def edited_released_rows(candidate, released_rows, released):
    """The released rows the candidate dropped or changed."""
    return sorted(version for version, digest in released_rows.items()
                  if version <= released and candidate.get(version) != digest)


class StoreSchemaVersionTest(unittest.TestCase):
    def test_reads_the_owner(self):
        source = (ROOT / SCHEMA).read_text()
        self.assertEqual(max(rows(source)), schema_version(source), "the last row is the current version")

    def test_released_rows_rule(self):
        released = {45: "0xa", 46: "0xb"}
        self.assertEqual(edited_released_rows({45: "0xa", 46: "0xb", 47: "0xc"}, released, 46), [])
        self.assertEqual(edited_released_rows({45: "0xa", 46: "0xd"}, released, 46), [46])
        self.assertEqual(edited_released_rows({46: "0xb"}, released, 46), [45])
        self.assertEqual(edited_released_rows({45: "0xa", 46: "0xd"}, released, 45), [],
                         "an unreleased row is updated in place")

    def test_schema_version_moves_once_per_release(self):
        tag = released_tag(ROOT)
        if tag is None or not TAG.fullmatch(tag):
            self.skipTest("no v0.S.N release tags in this checkout; the policy job checks out with fetch-depth 0")
        base_commit = main_base(ROOT)
        if base_commit is None:
            self.skipTest("no origin/main in this checkout to take the merge base from")
        released = int(TAG.fullmatch(tag)[1])
        source = (ROOT / SCHEMA).read_text()
        base = schema_version(git(ROOT, "show", f"{base_commit}:{SCHEMA}"))
        error = bump_error("schema_version", schema_version(source), base, released)
        if error:
            self.fail(f"{error} (release {tag}, main at {base_commit[:12]}): update that row's digest in place")
        if git(ROOT, "ls-tree", "--name-only", tag, "--", SCHEMA):
            edited = edited_released_rows(rows(source), rows(git(ROOT, "show", f"{tag}:{SCHEMA}")), released)
            self.assertEqual(edited, [], f"bootstrap_digests rows {edited} shipped by {tag} must stay as released")


if __name__ == "__main__":
    unittest.main()

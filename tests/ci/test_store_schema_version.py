"""Each format PR appends its own schema version and forward step (D226).

Main's existing digests and migration steps are immutable, unreleased ones
included. Released formats also remain checked against their release tag.
Every step is string literals only, so the source compared is what runs.
"""
from pathlib import Path
import re
import textwrap
import unittest

from release_numbers import digest_rows, drifted_row_fix, git, main_base, released_tag

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = "src/store/schema.zig"
VERSION = re.compile(r"^pub const schema_version: u32 = (\d+);$", re.MULTILINE)
TAG = re.compile(r"v0\.(\d+)\.\d+")
MIGRATIONS = re.compile(r"^pub const migrations = \[_\]Migration\{", re.MULTILINE)
FROM = re.compile(r"\.from\s*=\s*(\d+)")
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
LITERALS = r'(?:"(?:,")*,?)?'
LITERAL_STEP = re.compile(r"\{\.from=\d+,\.sqlite=&\.\{" + LITERALS + r"\},\.mysql=&\.\{" + LITERALS + r"\},?\}")


def schema_version(source):
    match = VERSION.search(source)
    if match is None:
        raise AssertionError(f"{SCHEMA} declares no schema_version")
    return int(match[1])


def migration_steps(source):
    """Each step of `migrations` as its `from` and its entry's source text.

    Splits the array literal at its top-level `.{` entries, skipping string
    literals and comments, and drops whitespace outside strings so that a
    reformat is no edit. A revision without the array has no steps.
    """
    match = MIGRATIONS.search(source)
    if match is None:
        return {}
    steps, depth, entry, position = {}, 0, [], match.end()
    while True:
        char = source[position]
        if char == '"':
            end = position + 1
            while source[end] != '"':
                end += 2 if source[end] == "\\" else 1
            entry.append(source[position:end + 1])
            position = end + 1
            continue
        if source.startswith("//", position):
            position = source.index("\n", position)
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            if depth == 0:
                return steps
            depth -= 1
        if depth > 0 or char == "}":
            if not char.isspace():
                entry.append(char)
        if char == "}" and depth == 0:
            text = "".join(entry).removesuffix(",")
            steps[int(FROM.search(text)[1])] = text
            entry = []
        position += 1


def non_literal_steps(steps):
    """The `from` of each step whose statements are not all string literals:
    a helper call or a `++` would let shared code change a step's text."""
    return sorted(start for start, text in steps.items() if not LITERAL_STEP.fullmatch(STRING.sub('"', text)))


def edited_shipped_steps(candidate, shipped, released):
    """The `from` of each shipped step (from below `released`) that the
    candidate dropped, added or changed against the release's text."""
    return sorted(start for start in set(candidate) | set(shipped)
                  if start < released and candidate.get(start) != shipped.get(start))


def edited_released_rows(candidate, released_rows, released):
    """The released rows the candidate dropped or changed."""
    return sorted(version for version, digest in released_rows.items()
                  if version <= released and candidate.get(version) != digest)


def schema_bump_error(candidate, base):
    """A format PR may preserve main's format or append exactly one (D226)."""
    if candidate < base:
        return f"schema_version {candidate} goes back below main's {base}"
    if candidate > base + 1:
        return f"schema_version {candidate} skips past {base + 1}, one past main's {base}"
    return None


class StoreSchemaVersionTest(unittest.TestCase):
    def test_reads_the_owner(self):
        source = (ROOT / SCHEMA).read_text()
        self.assertEqual(max(digest_rows(source)), schema_version(source), "the last row is the current version")

    def test_a_drifted_released_row_names_its_repair(self):
        self.assertEqual(drifted_row_fix(48, 0xaa, 0xbb),
                         "schema 48 shipped with digest 0x00000000000000aa, but this revision's row 48 holds "
                         "0x00000000000000bb: restore row 48 to 0x00000000000000aa, set schema_version to 49 "
                         "and append .{ .schema_version = 49, .digest = 0x00000000000000bb }")

    def test_released_rows_rule(self):
        released = {45: "0xa", 46: "0xb"}
        self.assertEqual(edited_released_rows({45: "0xa", 46: "0xb", 47: "0xc"}, released, 46), [])
        self.assertEqual(edited_released_rows({45: "0xa", 46: "0xd"}, released, 46), [46])
        self.assertEqual(edited_released_rows({46: "0xb"}, released, 46), [45])
        self.assertEqual(edited_released_rows({45: "0xa", 46: "0xd"}, released, 45), [],
                         "the release comparison excludes newer rows; the main-prefix check protects those")

    def test_shipped_steps_rule(self):
        released_source = textwrap.dedent("""\
            pub const schema_version: u32 = 53;
            pub const migrations = [_]Migration{
                .{ .from = 51, .sqlite = &.{"CREATE TABLE a(x INTEGER) STRICT"}, .mysql = &.{"CREATE TABLE a(x BIGINT)"} },
                .{ .from = 52, .sqlite = &.{ "CREATE INDEX a_x ON a(x)", "SELECT '}'" }, .mysql = &.{} }, // ends 53
            };
            """)
        released = migration_steps(released_source)
        self.assertEqual(sorted(released), [51, 52])
        reformatted = released_source.replace(".{ .from = 52, .sqlite = &.{ ", ".{\n    .from = 52,\n    .sqlite = &.{\n        ")
        self.assertEqual(migration_steps(reformatted), released, "a reformat is no edit")
        # A shipped step's text edited, with its neighbours and the version moved too.
        candidate = migration_steps(released_source
                                    .replace("a(x INTEGER)", "a(x INTEGER, y INTEGER)")
                                    .replace("SELECT '}'", "SELECT 1")
                                    .replace("= 53;", "= 54;")
                                    .replace("};\n", '    .{ .from = 53, .sqlite = &.{"DROP INDEX a_x"}, .mysql = &.{} },\n};\n'))
        self.assertEqual(edited_shipped_steps(candidate, released, 53), [51, 52])
        self.assertEqual(edited_shipped_steps(candidate, released, 52), [51], "the step from 52 is unreleased at 52")
        self.assertEqual(edited_shipped_steps({51: released[51]}, released, 53), [52], "a dropped shipped step")
        self.assertEqual(edited_shipped_steps(released, {}, 52), [51], "a step added below the release")
        self.assertEqual(migration_steps("pub const schema_version: u32 = 50;\n"), {})

    def test_steps_are_literals_only(self):
        steps = migration_steps(textwrap.dedent("""\
            pub const migrations = [_]Migration{
                .{ .from = 51, .sqlite = &.{ "A", "B \\"q\\" ++", }, .mysql = &.{} },
                .{ .from = 52, .sqlite = &.{"CREATE TABLE t(x INTEGER CHECK(" ++ migrationExpression(.sqlite, "t", "x>0") ++ "))"}, .mysql = &.{} },
                .{ .from = 53, .sqlite = &.{"A"}, .mysql = &.{ "B" ++ "C" } },
                .{ .from = 54, .sqlite = rebuild, .mysql = &.{} },
            };
            """))
        self.assertEqual(non_literal_steps(steps), [52, 53, 54])

    def test_reads_the_steps_owner(self):
        source = (ROOT / SCHEMA).read_text()
        self.assertIsNotNone(MIGRATIONS.search(source), "schema.zig declares `migrations` as this test reads it")
        self.assertEqual(len(migration_steps(source)), schema_version(source) - 51)
        self.assertEqual(non_literal_steps(migration_steps(source)), [],
                         "each statement of a migration step is one string literal: write out the text that runs")

    def test_a_format_pr_appends_after_main_even_before_release(self):
        self.assertIsNone(schema_bump_error(54, 54))
        self.assertIsNone(schema_bump_error(55, 54))
        self.assertIsNotNone(schema_bump_error(53, 54))
        self.assertIsNotNone(schema_bump_error(56, 54))
        # The same prefix checks used below protect unreleased main formats,
        # not just the rows and steps covered by the last release.
        self.assertEqual(edited_released_rows({53: 1, 54: 3, 55: 4}, {53: 1, 54: 2}, 54), [54])
        self.assertEqual(edited_shipped_steps({53: "changed", 54: "new"}, {53: "original"}, 54), [53])
        self.assertEqual(edited_shipped_steps({53: "original", 54: "new"}, {53: "original"}, 54), [])

    def test_schema_version_appends_without_rewriting_main_or_releases(self):
        base_commit = main_base(ROOT)
        if base_commit is None:
            self.skipTest("no origin/main in this checkout to take the merge base from")
        source = (ROOT / SCHEMA).read_text()
        base_source = git(ROOT, "show", f"{base_commit}:{SCHEMA}")
        base = schema_version(base_source)
        error = schema_bump_error(schema_version(source), base)
        self.assertIsNone(error, f"{error} (main at {base_commit[:12]}); each format PR appends its own step (D226)")
        rows = edited_released_rows(digest_rows(source), digest_rows(base_source), base)
        self.assertEqual(rows, [], f"main's bootstrap_digests rows {rows} are immutable, even unreleased: append a new version")
        steps = edited_shipped_steps(migration_steps(source), migration_steps(base_source), base)
        self.assertEqual(steps, [], f"main's migration steps from {steps} are immutable, even unreleased: append a new step")
        tag = released_tag(ROOT)
        if tag is None or not TAG.fullmatch(tag):
            self.skipTest("no v0.S.N release tags in this checkout; the policy job checks out with fetch-depth 0")
        released = int(TAG.fullmatch(tag)[1])
        if git(ROOT, "ls-tree", "--name-only", tag, "--", SCHEMA):
            shipped, rows = digest_rows(git(ROOT, "show", f"{tag}:{SCHEMA}")), digest_rows(source)
            edited = edited_released_rows(rows, shipped, released)
            fixes = [drifted_row_fix(version, shipped[version], rows[version]) for version in edited if version in rows]
            self.assertEqual(edited, [], f"bootstrap_digests rows {edited} shipped by {tag} must stay as released. "
                             + " ".join(fixes))
            steps = edited_shipped_steps(migration_steps(source), migration_steps(git(ROOT, "show", f"{tag}:{SCHEMA}")), released)
            self.assertEqual(steps, [], f"migration steps from {steps} shipped by {tag} must keep their released text: "
                             "restore them, and put the change in a new step")


if __name__ == "__main__":
    unittest.main()

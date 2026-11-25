from pathlib import Path
import re
import subprocess
import textwrap
import unittest

from release_numbers import (MIGRATIONS, SCHEMA, check_clause_lint, check_clause_message, digest_rows, drifted_row_fix,
                             git, main_base, migration_steps, quoted_check_needles, released_tag, schema_version,
                             touches_mysql_migration)

ROOT = Path(__file__).resolve().parents[2]
BASELINES = ("src/store/migration_baseline.sqlite.sql", "src/store/migration_baseline.mysql.sql",
             "src/store/migration_baseline_rows.sql")
BASELINE_VERSION = re.compile(r"^pub const migration_baseline: u32 = (\d+);$", re.MULTILINE)
TAG = re.compile(r"v0\.(\d+)\.\d+")
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
LITERALS = r'(?:"(?:,")*,?)?'
LITERAL_STEP = re.compile(r"\{\.from=\d+,\.sqlite=&\.\{" + LITERALS + r"\},\.mysql=&\.\{" + LITERALS + r"\},?\}")
# Format 94's MySQL step as main carries it (from 93), and as this revision repairs it.
MAIN_94_FIELD_DDL = """SET @rui_field_ddl=(SELECT CONCAT('ALTER TABLE session_change DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`, ADD CHECK((field=''provider'' OR field=''model'' OR field=''instructions'' OR field=''tools'' OR field=''loaded_tools'' OR field=''permission_mode'' OR field=''output_schema'' OR field=''compaction_trigger'' OR field=''output_reservation'' OR field=''reasoning_effort'' OR field=''label'' OR field=''reasoning_effort_refused'' OR field=''app_tools''))') FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.TABLE_NAME='session_change' AND tc.CONSTRAINT_TYPE='CHECK' AND LOCATE('''provider''',cc.CHECK_CLAUSE)>0 AND LOCATE('provider_text',cc.CHECK_CLAUSE)=0)"""
REPAIRED_94_FIELD_DDL = """SET @rui_field_ddl=(SELECT CONCAT('ALTER TABLE session_change DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`, ADD CHECK((field=''provider'' OR field=''model'' OR field=''instructions'' OR field=''tools'' OR field=''loaded_tools'' OR field=''permission_mode'' OR field=''output_schema'' OR field=''compaction_trigger'' OR field=''output_reservation'' OR field=''reasoning_effort'' OR field=''label'' OR field=''reasoning_effort_refused'' OR field=''app_tools''))') FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.TABLE_NAME='session_change' AND tc.CONSTRAINT_TYPE='CHECK' AND LOCATE('loaded_tools',cc.CHECK_CLAUSE)>0)"""


def baseline_version(source):
    match = BASELINE_VERSION.search(source)
    if match is None:
        raise AssertionError(f"{SCHEMA} declares no migration_baseline")
    return int(match[1])


def baseline_changed_without_bump(candidate_version, reference_version, candidate, reference):
    return candidate_version == reference_version and candidate != reference


def non_literal_steps(steps):
    return sorted(start for start, text in steps.items() if not LITERAL_STEP.fullmatch(STRING.sub('"', text)))


def edited_shipped_steps(candidate, shipped, released):
    return sorted(start for start in set(candidate) | set(shipped)
                  if start < released and candidate.get(start) != shipped.get(start))


def locked_main_steps(edited, released):
    """The edited main steps a PR may not change: each one a release shipped (its start is below the newest
    release's format). A step no release carries may be repaired in place without asking (owner, 2026-11-25), as
    format 92's and 94's MySQL steps were. With no release tag to tell them apart, every main step stays locked."""
    return list(edited) if released is None else [start for start in edited if start < released]


def edited_released_rows(candidate, released_rows, released):
    return sorted(version for version, digest in released_rows.items()
                  if version <= released and candidate.get(version) != digest)


def schema_bump_error(candidate, base):
    if candidate < base:
        return f"schema_version {candidate} goes back below main's {base}"
    if candidate > base + 1:
        return f"schema_version {candidate} skips past {base + 1}, one past main's {base}"
    return None


class StoreSchemaVersionTest(unittest.TestCase):
    def test_baseline_snapshot_rule(self):
        self.assertTrue(baseline_changed_without_bump(51, 51, b"changed", b"original"))
        self.assertFalse(baseline_changed_without_bump(52, 51, b"changed", b"original"))
        self.assertFalse(baseline_changed_without_bump(51, 51, b"original", b"original"))

    def test_baseline_snapshots_stay_unchanged(self):
        base = main_base(ROOT)
        if base is None:
            self.skipTest("no origin/main in this checkout to take the merge base from")
        candidate_version = baseline_version((ROOT / SCHEMA).read_text())
        tag = released_tag(ROOT)
        references = [("main merge base", base)]
        if tag is not None:
            references.append((f"release {tag}", tag))
        for label, ref in references:
            reference_version = baseline_version(git(ROOT, "show", f"{ref}:{SCHEMA}"))
            if candidate_version != reference_version:
                continue
            for path in BASELINES:
                with self.subTest(reference=label, path=path):
                    reference = subprocess.run(["git", "-C", str(ROOT), "show", f"{ref}:{path}"],
                                               check=True, capture_output=True).stdout
                    changed = baseline_changed_without_bump(candidate_version, reference_version,
                                                            (ROOT / path).read_bytes(), reference)
                    self.assertFalse(changed, f"{path} differs from {label} with unchanged migration_baseline: "
                                     "append a migration step instead")
        if tag is None:
            self.skipTest("no v0.S.N release tags in this checkout; the policy job checks out with fetch-depth 0")

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

    def test_only_released_main_steps_are_locked(self):
        main = {90: "released", 91: "released", 93: "unreleased step on main"}
        candidate = {90: "released", 91: "edited", 93: "repaired"}
        edited = edited_shipped_steps(candidate, main, 94)
        self.assertEqual(edited, [91, 93])
        self.assertEqual(locked_main_steps(edited, 93), [91], "v0.93 shipped the step from 91, not the one from 93")
        self.assertEqual(locked_main_steps(edited, 94), [91, 93], "v0.94 shipped both")
        self.assertEqual(locked_main_steps(edited, None), [91, 93], "no tag: every main step stays locked")

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
        tag = released_tag(ROOT)
        released = int(TAG.fullmatch(tag)[1]) if tag is not None and TAG.fullmatch(tag) else None
        steps = locked_main_steps(edited_shipped_steps(migration_steps(source), migration_steps(base_source), base), released)
        self.assertEqual(steps, [], f"main's migration steps from {steps} shipped in a release and are immutable: "
                         "append a new step (an unreleased step may be repaired in place)")
        if tag is None or not TAG.fullmatch(tag):
            self.skipTest("no v0.S.N release tags in this checkout; the policy job checks out with fetch-depth 0")
        if git(ROOT, "ls-tree", "--name-only", tag, "--", SCHEMA):
            shipped, rows = digest_rows(git(ROOT, "show", f"{tag}:{SCHEMA}")), digest_rows(source)
            edited = edited_released_rows(rows, shipped, released)
            fixes = [drifted_row_fix(version, shipped[version], rows[version]) for version in edited if version in rows]
            self.assertEqual(edited, [], f"bootstrap_digests rows {edited} shipped by {tag} must stay as released. "
                             + " ".join(fixes))
            steps = edited_shipped_steps(migration_steps(source), migration_steps(git(ROOT, "show", f"{tag}:{SCHEMA}")), released)
            self.assertEqual(steps, [], f"migration steps from {steps} shipped by {tag} must keep their released text: "
                             "restore them, and put the change in a new step")


class MySqlMigrationOwnerTest(unittest.TestCase):
    """touches_mysql_migration: the rule that makes a ready PR start MySQL 8.4 for the migration check."""

    STEPS = textwrap.dedent("""\
        pub const schema_version: u32 = 92;
        pub const migrations = [_]Migration{
            .{ .from = 91, .sqlite = &.{"A"}, .mysql = &.{"B"} },
            .{ .from = 92, .sqlite = &.{"C"}, .mysql = &.{"D"} },
        };
        """)

    def test_the_rule_over_the_domain_of_changes(self):
        base = self.STEPS
        cases = (
            ('a step text changed', [SCHEMA], base.replace('.mysql = &.{"D"}', '.mysql = &.{"E"}'), True),
            ('a step added', [SCHEMA], base.replace('};', '    .{ .from = 93, .sqlite = &.{}, .mysql = &.{} },\n};'), True),
            ('a step removed', [SCHEMA], base.replace('    .{ .from = 92, .sqlite = &.{"C"}, .mysql = &.{"D"} },\n', ''), True),
            ('schema.zig whitespace only', [SCHEMA],
             base.replace('.sqlite = &.{"C"}', '.sqlite = &.{ "C" }'), False),
            ('schema.zig comment only', [SCHEMA], base.replace('u32 = 92;', 'u32 = 92;\n// a note'), False),
            ('schema.zig comment inside the step table', [SCHEMA],
             base.replace('    .{ .from = 92', '    // a note\n    .{ .from = 92'), False),
            ('schema.zig unchanged text', [SCHEMA], base, False),
            ('schema.zig code outside the step table', [SCHEMA],
             base.replace('pub const migrations', 'pub const other: u32 = 1;\npub const migrations'), True),
            ('schema.zig MySQL helper appended', [SCHEMA], base + 'pub fn mysqlKeyPart() void {}\n', True),
            ('schema.zig multiline string changed', [SCHEMA], base + '\\\\SELECT 1\n', True),
        )
        for name, paths, after, expected in cases:
            with self.subTest(case=name):
                self.assertEqual(touches_mysql_migration(paths, {SCHEMA: (base, after)}), expected)
        # Each migration input, and a glob match of a new one, is a MySQL migration change whatever schema.zig did.
        for path in ('src/store/migration_baseline.mysql.sql', 'src/store/migration_baseline.sqlite.sql',
                     'src/store/migration_baseline_rows.sql', 'src/store/migration_expected_content.mysql.sql',
                     'src/store/migration_expected_rows.sql', 'src/store/migration_window_rows.sql',
                     'src/store/migration_future_input.sql'):
            with self.subTest(path=path):
                self.assertTrue(touches_mysql_migration([path], {}))
        for paths in (['README.md'], ['src/store/store_helpers.zig'], []):
            with self.subTest(paths=paths):
                self.assertFalse(touches_mysql_migration(paths, {}))
        # The live check's own sources trigger whatever schema.zig did.
        for path in ('src/store/mysql_dialect_check.zig', 'src/store/testing.zig'):
            with self.subTest(path=path):
                self.assertTrue(touches_mysql_migration([path], {}))
                self.assertTrue(touches_mysql_migration([path, SCHEMA], {SCHEMA: (self.STEPS, self.STEPS)}))

    def test_a_multiline_string_line_is_code_not_a_comment(self):
        # A line of a Zig multiline string (\\) holds its text, so a change to a "comment" inside one still counts.
        before = self.STEPS + '\\\\// a\n'
        self.assertTrue(touches_mysql_migration([SCHEMA], {SCHEMA: (before, self.STEPS + '\\\\// b\n')}))
        self.assertFalse(touches_mysql_migration([SCHEMA], {SCHEMA: (before, before)}))
        same_line = self.STEPS + 'const q = \\\\SELECT a  b // x\n'
        for after in (same_line.replace('// x', '// y'), same_line.replace('a  b', 'a b')):
            self.assertTrue(touches_mysql_migration([SCHEMA], {SCHEMA: (same_line, after)}), after)

    def test_a_string_literal_change_counts_even_when_it_looks_like_a_comment_or_layout(self):
        before = self.STEPS + 'const q = "a // b  c";\n'
        for after in (before.replace('// b', '// d'), before.replace('b  c', 'b c')):
            self.assertTrue(touches_mysql_migration([SCHEMA], {SCHEMA: (before, after)}), after)

    def test_a_step_table_that_cannot_be_read_counts_as_changed(self):
        self.assertTrue(touches_mysql_migration([SCHEMA], {SCHEMA: (self.STEPS, 'pub const migrations = [_]Migration{ .{ .from = 9')}))
        self.assertTrue(touches_mysql_migration([SCHEMA], {}), 'a schema.zig change without its text')
        self.assertFalse(touches_mysql_migration([SCHEMA], {SCHEMA: (None, None)}))


class CheckClauseLintTest(unittest.TestCase):
    def test_a_quoted_needle_is_rejected_and_a_bare_token_accepted(self):
        cases = [
            ("main's format 94 step", MAIN_94_FIELD_DDL, ["'provider'"]),
            ("repaired format 94 step", REPAIRED_94_FIELD_DDL, []),
            ("INSTR with a quoted needle", "SELECT 1 WHERE INSTR(cc.CHECK_CLAUSE,'''provider''')>0", ["'provider'"]),
            ("LIKE with a quoted needle", "SELECT 1 WHERE cc.CHECK_CLAUSE LIKE '%''provider''%'", ["%'provider'%"]),
            ("reversed LIKE with a quoted needle", "SELECT 1 WHERE '%''provider''%' LIKE cc.CHECK_CLAUSE", ["%'provider'%"]),
            ("reversed equality with a quoted needle", "SELECT 1 WHERE '''x''' = cc.CHECK_CLAUSE", ["'x'"]),
            ("POSITION with a quoted needle", "SELECT 1 WHERE POSITION('''x''' IN cc.CHECK_CLAUSE)>0", ["'x'"]),
            ("a bare token in LOCATE", "SELECT 1 WHERE LOCATE('loaded_tools',cc.CHECK_CLAUSE)>0", []),
            ("a bare token in LIKE", "SELECT 1 WHERE cc.CHECK_CLAUSE LIKE '%read_only%'", []),
            ("CHECK_CLAUSE only mentioned, not searched",
             "SELECT cc.CHECK_CLAUSE, 'a''b' FROM information_schema.CHECK_CONSTRAINTS cc "
             "WHERE LOWER(REPLACE(cc.CHECK_CLAUSE,'`',''))='x'", []),
            ("a quoted literal beside an unrelated search",
             "SELECT 1 WHERE LOCATE('''x''',t.name)>0 AND cc.CHECK_CLAUSE IS NOT NULL", []),
            ("LOWER wrapped, then LIKE with a quoted needle",
             "SELECT 1 WHERE LOWER(cc.CHECK_CLAUSE) LIKE '%''x''%'", ["%'x'%"]),
            ("REPLACE wrapped, then LIKE with a quoted needle",
             "SELECT 1 WHERE REPLACE(cc.CHECK_CLAUSE,'a','b') LIKE '%''x''%'", ["%'x'%"]),
            ("REPLACE with quoted arguments and a bare needle",
             "SELECT 1 WHERE REPLACE(cc.CHECK_CLAUSE,'''a''','b') LIKE '%loaded_tools%'", []),
            ("LOCATE over LOWER with a quoted needle", "SELECT 1 WHERE LOCATE('''x''',LOWER(cc.CHECK_CLAUSE))>0", ["'x'"]),
            ("LOCATE with CHECK_CLAUSE as the needle", "SELECT 1 WHERE LOCATE(cc.CHECK_CLAUSE,'''x''')>0", []),
            ("NOT LIKE with a quoted needle", "SELECT 1 WHERE cc.CHECK_CLAUSE NOT LIKE '%''x''%'", ["%'x'%"]),
            ("NOT REGEXP with a quoted needle", "SELECT 1 WHERE cc.CHECK_CLAUSE NOT REGEXP '''x'''", ["'x'"]),
            ("reversed NOT LIKE with a quoted needle", "SELECT 1 WHERE '''x''' NOT LIKE cc.CHECK_CLAUSE", ["'x'"]),
            ("a backtick needle", "SELECT 1 WHERE LOCATE('`provider_text`',cc.CHECK_CLAUSE)>0", []),
            ("a backtick needle over LOWER", "SELECT 1 WHERE LOCATE('`provider_text`',LOWER(cc.CHECK_CLAUSE))>0", []),
            ("a double-quoted needle", "SELECT 1 WHERE LOCATE('\"x\"',cc.CHECK_CLAUSE)>0", ['"x"']),
            ("a quoted needle inside a wrapper that is not a search",
             "SELECT 1 WHERE CONCAT(cc.CHECK_CLAUSE,'''x''')", []),
        ]
        for label, sql, expected in cases:
            with self.subTest(case=label):
                self.assertEqual(quoted_check_needles(sql), expected)

    def test_the_message_says_why_and_names_the_fix(self):
        message = check_clause_message(93, "'provider'")
        self.assertIn("charset introducer", message)
        self.assertIn("1064", message)
        self.assertIn("LOCATE('loaded_tools',cc.CHECK_CLAUSE)", message)

    def test_the_lint_reports_only_the_quoted_search_and_its_format(self):
        steps = {92: '{.from=92,.sqlite=&.{"SELECT 1"},.mysql=&.{"SELECT LOCATE(\'provider\',cc.CHECK_CLAUSE)"},}',
                 93: '{.from=93,.sqlite=&.{"SELECT 1"},.mysql=&.{"' + MAIN_94_FIELD_DDL + '"},}'}
        failures = check_clause_lint(steps)
        self.assertEqual(failures, {93: ["'provider'"]})

    def test_every_current_step_passes_the_lint(self):
        source = (ROOT / SCHEMA).read_text()
        failures = check_clause_lint(migration_steps(source))
        self.assertEqual(failures, {}, "; ".join(check_clause_message(start, needle)
                                               for start, needles in failures.items() for needle in needles))


if __name__ == "__main__":
    unittest.main()

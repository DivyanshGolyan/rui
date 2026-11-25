from pathlib import Path
import hashlib
import re
import subprocess
import textwrap
import unittest

from release_numbers import (MIGRATIONS, SCHEMA, check_clause_lint, check_clause_message, digest_rows, drifted_row_fix,
                             git, main_base, migration_steps, quoted_check_needles, released_tag, schema_version)

ROOT = Path(__file__).resolve().parents[2]
BASELINES = ("src/store/migration_baseline.sqlite.sql", "src/store/migration_baseline.mysql.sql",
             "src/store/migration_baseline_rows.sql")
BASELINE_VERSION = re.compile(r"^pub const migration_baseline: u32 = (\d+);$", re.MULTILINE)
TAG = re.compile(r"v0\.(\d+)\.\d+")
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
LITERALS = r'(?:"(?:,")*,?)?'
LITERAL_STEP = re.compile(r"\{\.from=\d+,\.sqlite=&\.\{" + LITERALS + r"\},\.mysql=&\.\{" + LITERALS + r"\},?\}")
# Steps main may carry in a repaired form. Each entry pins the exact repaired text by SHA-256, so any further
# edit is refused again. Format 92's MySQL step (from 91) never ran: its owner-CHECK SET lacked a closing
# parenthesis, so MySQL refused it with error 1064 and no MySQL Store took it. Owner approved 2026-11-24. The repair
# also matches the owner CHECK by LOCATE('provider'), because information_schema's CHECK_CLAUSE text did not equal the
# normalised literal on MySQL 8.4.
# Format 94's MySQL step (from 93) found the session_change field CHECK by the quoted literal 'provider', which MySQL
# 8.4's CHECK_CLAUSE stores with a charset introducer, so its SET was NULL and PREPARE refused it (1064); no MySQL Store
# took it and no release carries it. Owner approved 2026-11-25. The repair matches the bare 'loaded_tools', which only
# the field CHECK names.
REPAIRED_STEPS = {91: "9f9e6210d1278947bcb8a8d51868fe62d31dc1ed16e9ef06f1ce26672f876bfa",
                  93: "7064e3c27f815b0f201e5ea9ce673a94e09bc843afb2373ca2088135a1c71e47"}


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


def unrepaired(edited, candidate_steps, repaired=REPAIRED_STEPS):
    return [start for start in edited
            if candidate_steps.get(start) is None
            or hashlib.sha256(candidate_steps[start].encode()).hexdigest() != repaired.get(start)]


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

    def test_a_pinned_repair_is_the_only_allowed_edit_to_a_main_step(self):
        repaired = "ALTER TABLE t ADD CHECK((owner='app'))"
        pins = {91: hashlib.sha256(repaired.encode()).hexdigest()}
        base = {91: "ALTER TABLE t ADD CHECK(owner='app'"}
        def edited(text):
            return edited_shipped_steps({91: text}, base, 92)
        self.assertEqual(unrepaired(edited(repaired), {91: repaired}, pins), [])
        self.assertEqual(unrepaired(edited(repaired + "!"), {91: repaired + "!"}, pins), [91],
                         "one more character is a new edit and is refused")
        self.assertEqual(unrepaired(edited("changed"), {91: "changed"}, pins), [91])
        self.assertEqual(unrepaired([91], {}, pins), [91], "a dropped pinned step is refused")

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
        candidate_steps = migration_steps(source)
        steps = unrepaired(edited_shipped_steps(candidate_steps, migration_steps(base_source), base), candidate_steps)
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

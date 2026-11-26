#!/usr/bin/env python3
"""Schema-change rules a migration step is checked against, and the per-release scoreboard.

`check` fails when a step this branch adds to `schema.migrations` breaks a mechanical rule of the Store format
contract (docs/contracts/store.md, "Schema-change rules"). `scoreboard` prints, for each release, what its formats
cost a database team. Both read `schema.migrations` through release_numbers.migration_steps.
"""
import re
import sys
from pathlib import Path

from release_numbers import (SCHEMA, ZIG_STRING, git, main_base, migration_steps, schema_version, zig_string_value)

ROOT = Path(__file__).resolve().parents[2]
# The tables rebuilt most often (issue #2367): a new fact goes in a side table, never a new column here.
SIDE_TABLE_ONLY = ("core_command", "model_operation", "tool_record", "message_admission")
ALTER = re.compile(r"ALTER TABLE (\w+) ", re.IGNORECASE)
RENAME = re.compile(r"ALTER TABLE \w+ RENAME TO ", re.IGNORECASE)
MYSQL_RENAME = re.compile(r"RENAME TABLE (\w+) TO ", re.IGNORECASE)
ADD_COLUMN = re.compile(r"\bADD\s+(?:COLUMN\b|\()", re.IGNORECASE)
CREATE = re.compile(r"CREATE TABLE (\w+)\s*\(", re.IGNORECASE)
INSERT = re.compile(r"INSERT INTO (\w+)\s*\(([^)]*)\)\s*SELECT", re.IGNORECASE)
COLUMN_LINE = re.compile(r"^\s*(\w+)\s+\w+", re.MULTILINE)
NOT_COLUMNS = {"check", "foreign", "primary", "unique", "constraint", "key", "index"}
# What forces MySQL 8.4 to copy a table instead of changing it in place when a step also adds a column to it:
# measured live on 8.4.13 (2,000,000 rows), an inline or separate CHECK refuses ALGORITHM=INSTANT (error 1845, a
# 7.67 s copy against 0.10 s without) and a foreign key refuses it too (error 1846); a key or index is never instant
# and MODIFY changes a column's definition.
COPY_FORCING = re.compile(r"\bADD\s+(?:CHECK|FOREIGN KEY|UNIQUE|INDEX|KEY|CONSTRAINT)\b|\bCHECK\s*\(|\bREFERENCES\b"
                          r"|\bMODIFY\b|\bCHANGE\b", re.IGNORECASE)


def statements(step, dialect):
    """The SQL texts of one step's `.sqlite` or `.mysql` list, as migration_steps returns the step."""
    marker = f".{dialect}=&.{{"
    if marker not in step:
        return []
    body = step[step.index(marker) + len(marker):]
    if dialect == "sqlite" and ".mysql=&.{" in body:
        body = body[:body.index(".mysql=&.{")]
    return [zig_string_value(literal) for literal in ZIG_STRING.findall(body)]


def added_to(sql):
    """The table an `ALTER TABLE ... ADD COLUMN` statement adds a column to, else None."""
    match = ALTER.match(sql)
    return match[1] if match and ADD_COLUMN.search(sql) else None


def created_columns(sql):
    """The (table, column names) a `CREATE TABLE t(...)` statement defines, else None."""
    match = CREATE.match(sql)
    if match is None:
        return None
    body = sql[match.end():]
    names = [name for name in COLUMN_LINE.findall(body) if name.lower() not in NOT_COLUMNS]
    return match[1], names


def new_steps(base, head):
    """The steps `head` adds or edits beyond `base`, both as migration_steps returns them: an edit of an unreleased
    step counts as much as a new one."""
    return {start: text for start, text in head.items() if base.get(start) != text}


def side_table_violations(steps, base=None):
    """Each way a step gives a SIDE_TABLE_ONLY table a column, as (from, dialect, table).

    SQLite adds a column by rebuilding the table (rename aside, CREATE TABLE, INSERT ... SELECT), so a CREATE TABLE
    column the INSERT never lists is a new column; MySQL adds one by ALTER ... ADD COLUMN or by building a new table
    and renaming it over the old one. `base` maps from to the step main carries, so a statement main already has is
    not charged to this branch."""
    found = []
    for start, step in sorted(steps.items()):
        old = {dialect: set(statements((base or {}).get(start, ""), dialect)) for dialect in ("sqlite", "mysql")}
        for dialect in ("sqlite", "mysql"):
            texts = [sql for sql in statements(step, dialect) if sql not in old[dialect]]
            for sql in texts:
                table = added_to(sql)
                if table in SIDE_TABLE_ONLY:
                    found.append((start, dialect, table))
                rename = MYSQL_RENAME.match(sql)
                if dialect == "mysql" and rename and rename[1] in SIDE_TABLE_ONLY:
                    found.append((start, dialect, rename[1]))
                created = created_columns(sql)
                if dialect == "sqlite" and created and created[0] in SIDE_TABLE_ONLY:
                    listed = next((set(name.strip().lower() for name in m[2].split(",")) for later in texts
                                   if (m := INSERT.match(later)) and m[1] == created[0]), set())
                    if any(name.lower() not in listed for name in created[1]):
                        found.append((start, dialect, created[0]))
    return found


def side_table_message(start, dialect, table):
    return (f"the {dialect} step from {start} gives {table} a column, and it is one of the tables a format rebuilds most "
            f"often ({', '.join(SIDE_TABLE_ONLY)}). Fix: put the new fact in its own table (CREATE TABLE) keyed by the "
            "row it describes")


def copy_forcing(step):
    """Count of tables a MySQL step adds a column to and also gives a CHECK, foreign key, key, index or MODIFY,
    in the same statement or another statement of the step: each is a full table copy."""
    texts = statements(step, "mysql")
    added = {table for sql in texts if (table := added_to(sql))}
    return sum(1 for table in added
               if any((m := ALTER.match(sql)) and m[1] == table and COPY_FORCING.search(sql) for sql in texts))


def rebuilds(step):
    """Count of SQLite table rebuilds in a step: each rebuild renames the old table aside."""
    return sum(1 for sql in statements(step, "sqlite") if RENAME.match(sql))


def scoreboard(releases):
    """One row per release after the first, from [(tag, schema.zig source), ...] oldest first.

    Each row: tag, formats shipped since the previous release, steps shipped, SQLite table rebuilds, MySQL
    statements the database team applies, and the MySQL tables a step adds a column to and also gives a CHECK, key or MODIFY, which copy the table."""
    rows = []
    for (_, before), (tag, after) in zip(releases, releases[1:]):
        low, high = schema_version(before), schema_version(after)
        steps = {start: text for start, text in migration_steps(after).items() if low <= start < high}
        rows.append({"release": tag, "formats": high - low, "steps": len(steps),
                     "sqlite_rebuilds": sum(rebuilds(text) for text in steps.values()),
                     "mysql_statements": sum(len(statements(text, "mysql")) for text in steps.values()),
                     "mysql_copies": sum(copy_forcing(text) for text in steps.values())})
    return rows


def render(rows):
    header = ("release", "formats", "steps", "sqlite rebuilds", "mysql statements", "mysql copies")
    lines = [header] + [(r["release"], r["formats"], r["steps"], r["sqlite_rebuilds"], r["mysql_statements"],
                         r["mysql_copies"]) for r in rows]
    widths = [max(len(str(line[i])) for line in lines) for i in range(len(header))]
    return "\n".join("  ".join(str(cell).rjust(widths[i]) for i, cell in enumerate(line)) for line in lines)


def release_sources(root):
    tags = [tag for tag in git(root, "tag", "--list", "v0.*", "--sort=v:refname").split()
            if re.fullmatch(r"v0\.\d+\.\d+", tag)]
    ordered = sorted(tags, key=lambda t: tuple(map(int, t[1:].split("."))))
    return [(tag, git(root, "show", f"{tag}:{SCHEMA}")) for tag in ordered] + [("unreleased", (root / SCHEMA).read_text())]


def check(root):
    base = main_base(root)
    if base is None:
        return []
    head = migration_steps((root / SCHEMA).read_text())
    reference = migration_steps(git(root, "show", f"{base}:{SCHEMA}"))
    return [side_table_message(*found) for found in side_table_violations(new_steps(reference, head), reference)]


def main(argv):
    if argv[1:] == ["scoreboard"]:
        print(render(scoreboard(release_sources(ROOT))))
        return 0
    if argv[1:] == ["check"]:
        failures = check(ROOT)
        print("\n".join(failures))
        return 1 if failures else 0
    print("usage: schema_rules.py check | scoreboard", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

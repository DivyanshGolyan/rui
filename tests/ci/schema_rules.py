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
ALTER = re.compile(r"ALTER TABLE (\w+) ")
RENAME = re.compile(r"ALTER TABLE \w+ RENAME TO ")
# What forces MySQL 8.4 to copy a table instead of changing it in place when it comes with ADD COLUMN: measured live
# on 8.4.13 (2,000,000 rows): an inline or separate CHECK refuses ALGORITHM=INSTANT (error 1845, a 7.67 s copy against
# 0.10 s without), and a foreign key refuses it too (error 1846).
COPY_FORCING = re.compile(r"\bADD CHECK\b|\bADD FOREIGN KEY\b|\bCHECK\s*\(|\bREFERENCES\b")


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
    return match[1] if match and "ADD COLUMN" in sql else None


def new_steps(base, head):
    """The steps `head` adds beyond `base`, both as migration_steps returns them."""
    return {start: text for start, text in head.items() if start not in base}


def side_table_violations(steps):
    """Each added column on a SIDE_TABLE_ONLY table, as (from, dialect, table)."""
    found = []
    for start, step in sorted(steps.items()):
        for dialect in ("sqlite", "mysql"):
            for sql in statements(step, dialect):
                table = added_to(sql)
                if table in SIDE_TABLE_ONLY:
                    found.append((start, dialect, table))
    return found


def side_table_message(start, dialect, table):
    return (f"the {dialect} step from {start} adds a column to {table}, one of the tables a format rebuilds most often "
            f"({', '.join(SIDE_TABLE_ONLY)}). Fix: put the new fact in its own table (CREATE TABLE) keyed by the "
            "row it describes")


def copy_forcing(step):
    """Count of MySQL statements in a step that add a column and force a table copy."""
    return sum(1 for sql in statements(step, "mysql") if added_to(sql) and COPY_FORCING.search(sql))


def rebuilds(step):
    """Count of SQLite table rebuilds in a step: each rebuild renames the old table aside."""
    return sum(1 for sql in statements(step, "sqlite") if RENAME.match(sql))


def scoreboard(releases):
    """One row per release after the first, from [(tag, schema.zig source), ...] oldest first.

    Each row: tag, formats shipped since the previous release, steps shipped, SQLite table rebuilds, MySQL
    statements the database team applies, and the MySQL column adds that force a table copy."""
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
    return [side_table_message(*found) for found in side_table_violations(new_steps(reference, head))]


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

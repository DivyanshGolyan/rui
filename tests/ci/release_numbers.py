import fnmatch
import re
import subprocess

SCHEMA = "src/store/schema.zig"
VERSION = re.compile(r"^pub const schema_version: u32 = (\d+);$", re.MULTILINE)
ROW = re.compile(r"\.\{ \.schema_version = (\d+), \.digest = 0x([0-9a-fA-F]+) \}")
MIGRATIONS = re.compile(r"^pub const migrations = \[_\]Migration\{", re.MULTILINE)
FROM = re.compile(r"\.from\s*=\s*(\d+)")
# The Store migration inputs a MySQL 8.4 migration check reads beyond the step table.
MIGRATION_INPUTS = "src/store/migration_*"


def bump_error(name, candidate, base, released):
    if candidate < base:
        return f"{name} {candidate} goes back below main's {base}"
    allowed = base if base > released else released + 1
    if candidate <= allowed:
        return None
    if base > released:
        return (f"{name} {candidate} goes past main's unreleased {base}; "
                f"the last release has {released}, so reuse {base}")
    return f"{name} {candidate} skips past {allowed}, one past the last release's {released}"


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def released_tag(root):
    tags = [tag for tag in git(root, "tag", "--list", "v0.*", "--sort=-v:refname").split()
            if re.fullmatch(r"v0\.\d+\.\d+", tag)]
    return tags[0] if tags else None


def main_base(root):
    if subprocess.run(["git", "-C", str(root), "rev-parse", "--verify", "-q", "origin/main"],
                      capture_output=True).returncode:
        return None
    return git(root, "merge-base", "HEAD", "origin/main").strip()


def digest_rows(source):
    return {int(version): int(digest, 16) for version, digest in ROW.findall(source)}


def drifted_row_fix(version, released, current):
    return (f"schema {version} shipped with digest 0x{released:016x}, but this revision's row {version} holds "
            f"0x{current:016x}: restore row {version} to 0x{released:016x}, set schema_version to {version + 1} "
            f"and append .{{ .schema_version = {version + 1}, .digest = 0x{current:016x} }}")


def schema_version(source):
    match = VERSION.search(source)
    if match is None:
        raise AssertionError(f"{SCHEMA} declares no schema_version")
    return int(match[1])


def migration_steps(source):
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


def migration_text_changed(before, after):
    """Whether the migration step table's entries differ between two revisions of schema.zig.

    Entries are compared as parsed {from: text}, so an edit outside the table is no change. A table that
    cannot be parsed counts as changed.
    """
    if before == after:
        return False
    try:
        old, new = (migration_steps(source) if source is not None else {} for source in (before, after))
    except (AttributeError, IndexError, TypeError, ValueError):
        return True
    return old != new


def touches_mysql_migration(paths, contents):
    """Whether a change touches a Store migration step, so a ready PR must run the live MySQL migration check.

    True when a migration input (MIGRATION_INPUTS) changed, or when schema.zig changed and an entry of its step
    table did. `contents` maps each changed schema.zig to its (base, head) text, as select_tests.revision_contents does.
    """
    if any(fnmatch.fnmatchcase(path, MIGRATION_INPUTS) for path in paths):
        return True
    if SCHEMA not in paths:
        return False
    if SCHEMA not in contents:
        return True
    return migration_text_changed(*contents[SCHEMA])

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


# MySQL migration SQL, not the SQLite text beside it. A search of CHECK_CLAUSE by a needle with a quote character
# never matches on MySQL 8.4, which stores each literal with a charset introducer (_utf8mb4'provider') and escapes its
# quotes, so the generated DDL is NULL and PREPARE refuses it with 1064. PR CI runs SQLite only, so this reached Promote.
ZIG_STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
ZIG_ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}
SQL_TOKEN = re.compile(r"""
    (?P<str>'(?:[^'\\]|\\.|'')*')
  | (?P<ident>`(?:[^`]|``)*`|[A-Za-z_][A-Za-z0-9_$.]*)
  | (?P<op><>|!=|<=|>=|=|<|>)
  | (?P<punct>[(),])
  | (?P<other>\S)
""", re.VERBOSE | re.DOTALL)
CHECK_SEARCH_CALLS = {"LOCATE", "INSTR", "POSITION"}
CHECK_SEARCH_OPERATORS = {"LIKE", "REGEXP", "RLIKE", "="}
QUOTES = set("'\"`")


def zig_string_value(literal):
    return re.sub(r"\\(.)", lambda match: ZIG_ESCAPES.get(match[1], match[1]), literal[1:-1])


def sql_tokens(sql):
    tokens = []
    for match in SQL_TOKEN.finditer(sql):
        kind = match.lastgroup
        if kind == "str":
            tokens.append(("str", re.sub(r"''|\\(.)", lambda m: "'" if m[1] is None else m[1], match[0][1:-1])))
        elif kind in ("ident", "op", "punct"):
            tokens.append((kind, match[0]))
    return tokens


def is_check_clause(token):
    return token[0] == "ident" and token[1].rsplit(".", 1)[-1].strip("`").upper() == "CHECK_CLAUSE"


def search_needles(tokens, index):
    """The literal needles a CHECK_CLAUSE token at index is searched with, by its nearest call or direct operator."""
    needles = []
    depth, start = 0, None
    for position in range(index - 1, -1, -1):
        kind, text = tokens[position]
        if (kind, text) == ("punct", ")"):
            depth += 1
        elif (kind, text) == ("punct", "("):
            if depth == 0:
                start = position
                break
            depth -= 1
    if start is not None and start > 0 and tokens[start - 1][0] == "ident" \
            and tokens[start - 1][1].upper() in CHECK_SEARCH_CALLS:
        depth = 0
        for kind, text in tokens[start + 1:]:
            if (kind, text) == ("punct", "("):
                depth += 1
            elif (kind, text) == ("punct", ")"):
                if depth == 0:
                    break
                depth -= 1
            elif kind == "str" and depth == 0:
                needles.append(text)
    if index + 2 < len(tokens) and tokens[index + 1][0] in ("ident", "op") \
            and tokens[index + 1][1].upper() in CHECK_SEARCH_OPERATORS and tokens[index + 2][0] == "str":
        needles.append(tokens[index + 2][1])
    if index >= 2 and tokens[index - 1][0] in ("ident", "op") and tokens[index - 1][1].upper() in CHECK_SEARCH_OPERATORS \
            and tokens[index - 2][0] == "str":
        needles.append(tokens[index - 2][1])
    return needles


def quoted_check_needles(sql):
    """The needle values, with quotes decoded, that a MySQL statement searches CHECK_CLAUSE for and that contain a quote."""
    tokens = sql_tokens(sql)
    return [needle for index, token in enumerate(tokens) if is_check_clause(token)
            for needle in search_needles(tokens, index) if QUOTES & set(needle)]


def check_clause_lint(steps):
    """Each MySQL step's search of CHECK_CLAUSE by a quoted needle, as {from: [needle, ...]}."""
    failures = {}
    for start, text in steps.items():
        if ".mysql=&.{" not in text:
            continue
        body = text[text.index(".mysql=&.{") + len(".mysql=&.{"):]
        for literal in ZIG_STRING.findall(body):
            needles = quoted_check_needles(zig_string_value(literal))
            if needles:
                failures.setdefault(start, []).extend(needles)
    return failures


def check_clause_message(start, needle):
    return (f"the MySQL step from {start} searches CHECK_CLAUSE for {needle!r}, which contains a quote: MySQL 8.4 stores "
            "a CHECK literal with a charset introducer (_utf8mb4'...') and escapes its quotes, so this search never matches, "
            "the generated DDL is NULL and PREPARE fails with 1064. Fix: search a needle without quote characters, a bare "
            "identifier token only the target CHECK contains, e.g. LOCATE('loaded_tools',cc.CHECK_CLAUSE)")

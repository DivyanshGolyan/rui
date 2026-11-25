import fnmatch
import re
import subprocess

SCHEMA = "src/store/schema.zig"
VERSION = re.compile(r"^pub const schema_version: u32 = (\d+);$", re.MULTILINE)
ROW = re.compile(r"\.\{ \.schema_version = (\d+), \.digest = 0x([0-9a-fA-F]+) \}")
MIGRATIONS = re.compile(r"^pub const migrations = \[_\]Migration\{", re.MULTILINE)
FROM = re.compile(r"\.from\s*=\s*(\d+)")
# The inputs a MySQL 8.4 migration check reads beyond schema.zig's code: the migration fixtures and the check's own sources.
MIGRATION_INPUTS = ("src/store/migration_*", "src/store/mysql_dialect_check.zig", "src/store/testing.zig")


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


ZIG_TOKEN = re.compile(r"""
    (?P<multi>^[ \t]*\\\\[^\n]*)
  | (?P<gap>[^\S\n]+|\n)
  | (?P<comment>//[^\n]*)
  | (?P<str>"(?:[^"\\\n]|\\.)*")
  | (?P<chr>'(?:[^'\\\n]|\\.)*')
  | (?P<word>[A-Za-z0-9_]+)
  | (?P<other>.)
""", re.VERBOSE | re.MULTILINE)


def zig_code(source):
    """The tokens of Zig source with comments and layout removed. Multiline string lines are kept whole."""
    return [match[0] for match in ZIG_TOKEN.finditer(source) if match.lastgroup not in ("gap", "comment")]


def code_changed(before, after):
    """Whether two revisions of schema.zig differ in code, so not only in comments or layout."""
    if before == after:
        return False
    if before is None or after is None:
        return True
    return zig_code(before) != zig_code(after)


def touches_mysql_migration(paths, contents):
    """Whether a change touches what the live MySQL 8.4 migration check reads, so a ready PR must run it.

    True when a migration input (MIGRATION_INPUTS) changed, or when schema.zig changed in code. schema.zig's MySQL
    DDL is generated from the same tables, indexes and helpers as its SQLite DDL, and its step table is one part of
    that code, so a comment or layout edit is the only schema.zig change that does not trigger. `contents` maps each
    changed schema.zig to its (base, head) text, as select_tests.revision_contents does.
    """
    if any(fnmatch.fnmatchcase(path, pattern) for path in paths for pattern in MIGRATION_INPUTS):
        return True
    if SCHEMA not in paths:
        return False
    if SCHEMA not in contents:
        return True
    return code_changed(*contents[SCHEMA])


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
# The search functions, each with the argument index of the haystack; the other argument is the needle.
SEARCH_HAYSTACK = {"LOCATE": 1, "INSTR": 0, "POSITION": 1}
CHECK_SEARCH_CALLS = set(SEARCH_HAYSTACK)
CHECK_SEARCH_OPERATORS = {"LIKE", "REGEXP", "RLIKE", "="}
# A backtick is a legitimate identifier quote: MySQL 8.4 writes column names in CHECK_CLAUSE with backticks.
QUOTES = set("'\"")


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


def is_word(token, words):
    return token[0] == "ident" and token[1].upper() in words


def is_operator(token):
    return token[0] in ("ident", "op") and token[1].upper() in CHECK_SEARCH_OPERATORS


def open_of(tokens, position):
    """The index of the '(' that directly encloses the token at position, or None at the top level."""
    depth = 0
    for index in range(position - 1, -1, -1):
        if tokens[index] == ("punct", ")"):
            depth += 1
        elif tokens[index] == ("punct", "("):
            if depth == 0:
                return index
            depth -= 1
    return None


def close_of(tokens, open_):
    depth = 0
    for index in range(open_, len(tokens)):
        if tokens[index] == ("punct", "("):
            depth += 1
        elif tokens[index] == ("punct", ")"):
            depth -= 1
            if depth == 0:
                return index
    return None


def operator_needles(tokens, first, last):
    """The string literal a search operator compares the expression tokens[first..last] with, on either side."""
    needles = []
    after = last + 1
    if after < len(tokens) and is_word(tokens[after], {"NOT"}):
        after += 1
    if after + 1 < len(tokens) and is_operator(tokens[after]) and tokens[after + 1][0] == "str":
        needles.append(tokens[after + 1][1])
    before = first - 1
    if before >= 0 and is_operator(tokens[before]):
        operand = before - 1
        if operand >= 0 and is_word(tokens[operand], {"NOT"}):
            operand -= 1
        if operand >= 0 and tokens[operand][0] == "str":
            needles.append(tokens[operand][1])
    return needles


def search_call_needles(tokens, open_):
    """The needles of a search call whose haystack argument holds CHECK_CLAUSE; literal arguments elsewhere are needles."""
    name = tokens[open_ - 1][1].upper()
    close = close_of(tokens, open_)
    parts, current, depth = [], [], 0
    for index in range(open_ + 1, close):
        token = tokens[index]
        if token == ("punct", "("):
            depth += 1
        elif token == ("punct", ")"):
            depth -= 1
        separator = token == ("punct", ",") or (name == "POSITION" and is_word(token, {"IN"}))
        if depth == 0 and separator:
            parts.append(current)
            current = []
        else:
            current.append(index)
    parts.append(current)
    haystack = SEARCH_HAYSTACK[name]
    holding = [number for number, part in enumerate(parts)
               if any(is_check_clause(tokens[index]) for index in part)]
    if len(parts) <= haystack or holding != [haystack]:
        return []  # CHECK_CLAUSE is the needle, searched for inside a literal: no quoted needle is searched
    return [tokens[part[0]][1] for number, part in enumerate(parts)
            if number != haystack and len(part) == 1 and tokens[part[0]][0] == "str"]


def search_needles(tokens, index):
    """The literal needles a CHECK_CLAUSE token at index is searched with.

    The searched expression is the token itself, widened through each enclosing call that takes it as a whole
    argument (LOWER, REPLACE, ...). At each width the neighbouring search operator (LIKE, NOT LIKE, REGEXP, NOT REGEXP,
    =) gives the needle; a search function that takes the expression as its haystack gives its literal arguments.
    """
    needles = []
    first = last = index
    while True:
        needles += operator_needles(tokens, first, last)
        open_ = open_of(tokens, first)
        before, after = tokens[first - 1] if first > 0 else None, tokens[last + 1] if last + 1 < len(tokens) else None
        whole_argument = before is not None and (before == ("punct", "(") or before == ("punct", ",")
                                                 or is_word(before, {"IN"})) \
            and after is not None and (after == ("punct", ")") or after == ("punct", ","))
        if open_ is None or not whole_argument or open_ == 0 or tokens[open_ - 1][0] != "ident":
            return needles
        if tokens[open_ - 1][1].upper() in CHECK_SEARCH_CALLS:
            return needles + search_call_needles(tokens, open_)
        first, last = open_ - 1, close_of(tokens, open_)


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
    return (f"the MySQL step from {start} searches CHECK_CLAUSE for {needle!r}, which contains a ' or \" quote: MySQL 8.4 "
            "stores a CHECK literal with a charset introducer (_utf8mb4'...') and escapes its quotes, so this search never "
            "matches, the generated DDL is NULL and PREPARE fails with 1064. Fix: search a needle without ' or \" characters, "
            "a bare identifier token only the target CHECK contains, e.g. LOCATE('loaded_tools',cc.CHECK_CLAUSE)")

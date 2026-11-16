
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TESTS = "src/store/tests.zig"
SQLITE_TESTS = "src/store/sqlite_tests.zig"

SQLITE_CODE = re.compile(
    r"\bsqlite\.|\bc\.(?:sqlite3|SQLITE)|\.database\b|\bStatementCache\b|\bsqlite_heap_bytes\b|"
    r"\.passes\b|\.statements\b|\btesting_content_work\.(?:read|blob|closes)\b|\.read_blob\b|"
    r"\.open\(\s*(?:std\.testing\.)?io\s*,|\bopenWithOptions\b|\bsqlite_only\b")
SQLITE_IMPORT = '@import("sqlite.zig")'
NEUTRAL_HELPERS = {"testingStore"}

TOKEN = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'')


def code_only(text):
    def blank(match):
        token = match.group()
        if token.startswith("//"):
            return ""
        return '""'
    return TOKEN.sub(blank, text)


class Item:
    def __init__(self, kind, name, lines):
        self.kind, self.name, self.lines = kind, name, lines

    @property
    def text(self):
        return "\n".join(self.lines)


DECL = re.compile(r'^(?:pub )?(?:(test) "((?:\\.|[^"\\])*)"|(test) \{|(?:noinline )?fn (\w+)|(?:const|var) (\w+))')


def depth_change(line):
    code = code_only(line)
    return code.count("{") + code.count("(") + code.count("[") - code.count("}") - code.count(")") - code.count("]")


def parse(source):
    lines = source.split("\n")
    header, items, pending = [], [], []
    index = 0
    started = False
    while index < len(lines):
        line = lines[index]
        match = DECL.match(line)
        if not match or (not started and not (match.group(1) or match.group(3) or match.group(4))):
            if not started and not match and not line.startswith("///"):
                header.extend(pending)
                pending = []
                header.append(line)
            elif not started and match:
                header.extend(pending)
                pending = []
                header.append(line)
                depth = depth_change(line)
                while depth > 0:
                    index += 1
                    header.append(lines[index])
                    depth += depth_change(lines[index])
            else:
                pending.append(line)
            index += 1
            continue
        started = True
        kind = "test" if match.group(1) or match.group(3) else ("fn" if match.group(4) else "const")
        name = match.group(2) if match.group(1) else (match.group(4) or match.group(5) or "")
        body = [line]
        depth = depth_change(line)
        while depth > 0:
            index += 1
            body.append(lines[index])
            depth += depth_change(lines[index])
        items.append(Item(kind, name, pending + body))
        pending = []
        index += 1
    trailer = pending
    return header, items, trailer


STRING = r'"(?:\\.|[^"\\\n])*"'
STRINGS = re.compile(r'\s*' + STRING + r'(?:\s*\+\+\s*' + STRING + r')*\s*$')
RAW = {"sqlite.exec": ("exec", 0), "queryU64": ("queryU64", 0),
       "execSessionSql": ("exec", 1), "querySessionU64": ("queryU64", 1)}
CALL = re.compile(r'(?<![\w.])(sqlite\.exec|queryU64|execSessionSql|querySessionU64|failAtStepForTesting)\(')
FORMAT = re.compile(r'^\s*try std\.(?:fmt\.bufPrintSentinel|mem\.printSentinel)\(&(\w+),(.*),\s*\.\{(.*)\},\s*0\s*\)\s*$', re.S)
PLACEHOLDER = re.compile(r"(?<!\w)'\{s\}'|\{d\}|\{\}")
FK = re.compile(r'^(\s*)try sqlite\.exec\((\w+)\.database, "PRAGMA foreign_keys=(OFF|ON)"\);$')


def zig_strings(path, name):
    source = (ROOT / path).read_text()
    table = source[source.index(f"const {name} = "):]
    return re.findall(r'"((?:\\.|[^"\\])*)"', table[:table.index("};")])


def rsql_words():
    source = (ROOT / "src/store/rsql.zig").read_text()
    table = source[source.index("const forbidden_words"):]
    table = table[:table.index("};")]
    return re.findall(r'\.word = "(\w+)"', table)


REFUSED_WORD = re.compile(
    r"\b(?:" + "|".join(rsql_words() + zig_strings("src/store/testing.zig", "fixture_sqlite_words")) + r")\b|"
    r"\b(?:" + "|".join(zig_strings("src/store/testing.zig", "fixture_sqlite_prefixes")) + r")\w*|"
    r"\bAS\s+TEXT\b", re.I)


def fixture_verdict(sql):
    sql = re.sub(r"'(?:[^']|'')*'", "''", sql)
    return bool(REFUSED_WORD.search(sql) or re.search(r'\|\||--|/\*|"|\bINSERT\s+OR\b', sql, re.I))


def not_portable(literal):
    return fixture_verdict("".join(text[1:-1].replace('\\"', '"') for text in re.findall(STRING, literal)))


def call_end(text, open_index):
    depth = 0
    args, start = [], open_index + 1
    index = open_index
    while index < len(text):
        char = text[index]
        if char == '"':
            index += 1
            while text[index] != '"':
                index += 2 if text[index] == "\\" else 1
        elif char == "'":
            index += 1
            while text[index] != "'":
                index += 2 if text[index] == "\\" else 1
        elif text.startswith("//", index):
            index = text.index("\n", index)
            continue
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
            if depth == 0:
                args.append(text[start:index])
                return index, [a for a in args if a.strip()]
        elif char == "," and depth == 1:
            args.append(text[start:index])
            start = index + 1
        index += 1
    raise ValueError("unbalanced call")


def fixture_text(item_text, expression):
    expression = expression.strip()
    if STRINGS.match(expression):
        text, values, buffer = expression, [], None
    elif re.fullmatch(r"\w+", expression):
        bound = re.search(r"\bconst " + expression + r"(?:: \[:0\]const u8)? = ((?:" + STRING + r"|\s|\+\+)+);", item_text)
        if not bound or not STRINGS.match(bound.group(1)) or not_portable(bound.group(1)):
            return None
        text, values, buffer = expression, [], None
    else:
        formatted = FORMAT.match(expression)
        if not formatted or not STRINGS.match(formatted.group(2)):
            return None
        values = [value.strip() for value in formatted.group(3).split(",") if value.strip()]
        slots = iter(range(1, len(values) + 2))
        text = PLACEHOLDER.sub(lambda _: f"?{next(slots)}", formatted.group(2).strip())
        if next(slots) != len(values) + 1 or re.search(r"\{[^}]*\}", text) or re.search(r"'[^']*\?\d[^']*'", text):
            return None
        buffer = formatted.group(1)
    if not_portable(text):
        return None
    return text, values, buffer


def rewrite_calls(item):
    text = item.text
    out, position, freed = [], 0, []
    for match in CALL.finditer(text):
        if match.start() < position:
            continue
        name = match.group(1)
        close, args = call_end(text, match.end() - 1)
        replacement = None
        store = re.fullmatch(r"\s*(\w+)\.database\s*", args[0]) if args else None
        if store:
            pointer = pointer_of(text, store.group(1), match.start())
            if name == "failAtStepForTesting" and len(args) == 2 and re.fullmatch(r'\s*"\w+"\s*', args[1]):
                replacement = f"store_testing.failReadsOf({pointer}, {args[1].strip()})"
            elif name in RAW and len(args) == 2 + RAW[name][1]:
                found = fixture_text(text, args[1])
                if found:
                    literal, values, buffer = found
                    if buffer:
                        freed.append(buffer)
                    rendered = ", ".join(values + [arg.strip() for arg in args[2:]])
                    replacement = f"store_testing.{RAW[name][0]}({pointer}, {literal}, .{{{rendered}}})"
        if replacement is None:
            continue
        out.append(text[position:match.start()])
        out.append(replacement)
        position = close + 1
    out.append(text[position:])
    text = "".join(out)
    for buffer in set(freed):
        declaration = re.compile(r"\n[ \t]*var " + buffer + r": \[[^\]]+\]u8 = undefined;")
        found = list(declaration.finditer(text))
        for this, following in reversed(list(zip(found, found[1:] + [None]))):
            span = text[this.end():following.start() if following else len(text)]
            if not re.search(r"\b" + buffer + r"\b", code_only(span)):
                text = text[:this.start()] + text[this.end():]
    item.lines = text.split("\n")


def rewrite_foreign_keys(item):
    lines = item.lines
    out, index = [], 0
    while index < len(lines):
        off = FK.match(lines[index])
        if off and off.group(3) == "OFF":
            end = index + 1
            while end < len(lines) and not FK.match(lines[end]):
                end += 1
            on = FK.match(lines[end]) if end < len(lines) else None
            span = "\n".join(lines[index + 1:end])
            code = code_only(span)
            calls = re.findall(r"([\w.]+)\(", code)
            if on and on.group(3) == "ON" and on.group(2) == off.group(2) and calls and all(
                    call == "store_testing.exec" for call in calls) and not SQLITE_CODE.search(code):
                out.extend(span.replace("store_testing.exec(", "store_testing.withoutForeignKeys(").split("\n"))
                index = end + 1
                continue
        out.append(lines[index])
        index += 1
    item.lines = out


def pointer_of(text, name, position):
    declared = [(m.start(), "&" + name) for m in re.finditer(r"\bvar " + name + r": Store\b", text[:position])]
    for signature in re.finditer(r"\bfn \w+\(", text[:position]):
        close, params = call_end(text, signature.end() - 1)
        if any(re.fullmatch(r"\s*" + name + r": \*Store\s*", param) for param in params):
            declared.append((signature.start(), name))
    return max(declared)[1] if declared else "&" + name


def rewrite_sql(item):
    rewrite_calls(item)
    rewrite_foreign_keys(item)


def references(item, names):
    code = code_only(item.text)
    found = set(re.findall(r"(?<![\w.])\w+", code)) & names
    found.discard(item.name)
    return found


def classify(items):
    named = {item.name: item for item in items if item.kind != "test" and item.name}
    names = set(named)
    refs = {id(item): references(item, names) for item in items}
    sqlite_only = {id(item) for item in items
                   if item.name not in NEUTRAL_HELPERS and SQLITE_CODE.search(code_only(item.text))}
    opens = {id(item) for item in items if re.search(r"(?<![\w.])testingStore\(", code_only(item.text))
             and item.name != "testingStore"}
    changed = True
    while changed:
        changed = False
        for item in items:
            for name in refs[id(item)]:
                target = id(named[name])
                if target in sqlite_only and id(item) not in sqlite_only:
                    sqlite_only.add(id(item))
                    changed = True
                if target in opens and id(item) not in opens:
                    opens.add(id(item))
                    changed = True
    return sqlite_only, opens, refs, named


def indent(lines, spaces):
    return [(" " * spaces + line) if line.strip() else line for line in lines]


def case_name(item):
    return "store_case" if re.search(r"\bcase\b", code_only(item.text)) else "case"


def wrap_test(item, case):
    lines = item.lines
    start = next(i for i, line in enumerate(lines) if DECL.match(line))
    assert lines[-1] == "}", item.name
    body = lines[start + 1:-1]
    item.lines = lines[:start + 1] + [
        "    try store_testing.forEachEngine(struct {",
        f"        fn run({case}: *store_testing.Case) !void {{",
    ] + indent(body, 8) + [
        "        }",
        "    }.run);",
        "}",
    ]


def thread_case(item, helpers, case):
    text = item.text
    text = re.sub(r"(?<![\w.])testingStore\(", f"store_testing.testingStore({case}, ", text)
    for name in helpers:
        text = re.sub(r"(?<![\w.])" + name + r"\(", f"{name}({case}, ", text)
    if item.kind == "fn" and item.name in helpers:
        text = re.sub(r"\bfn " + item.name + r"\(" + case + ", ", f"fn {item.name}({case}: *store_testing.Case, ", text, count=1)
    item.lines = text.split("\n")


def make_pub(item):
    for index, line in enumerate(item.lines):
        if DECL.match(line) and not line.startswith("pub "):
            item.lines[index] = "pub " + line
        elif item.kind == "const" and re.match(r"^    (?:fn|const|var) \w", line):
            item.lines[index] = "    pub " + line[4:]


SQLITE_HEADER = """//! The Store's tests that observe a SQLite mechanism: VM steps, the
//! statement cache, engine passes, blob handles, PRAGMAs and the schema
//! catalog, or raw SQL the engine fixtures do not cover. tests.zig holds
//! the tests every engine runs; tests/ci/store_conformance.py split them."""


def rewrite(pre_split):
    header, items, trailer = parse(pre_split)
    for item in items:
        rewrite_sql(item)
    sqlite_only, opens, refs, named = classify(items)
    kept = [item for item in items if id(item) not in sqlite_only]
    moved_tests = [item for item in items if item.kind == "test" and id(item) in sqlite_only]
    used_by_kept = set()
    for item in kept:
        used_by_kept |= refs[id(item)]
    closure = set()
    frontier = [name for item in moved_tests for name in refs[id(item)]]
    while frontier:
        name = frontier.pop()
        if name in closure:
            continue
        closure.add(name)
        frontier.extend(refs[id(named[name])])
    moving = {id(item) for item in moved_tests}
    shared = set()
    for name in closure:
        target = named[name]
        if id(target) in sqlite_only or name not in used_by_kept or name == "testingStore":
            moving.add(id(target))
        else:
            shared.add(name)
    named_anywhere = set().union(*refs.values())
    dropped = {id(item) for item in items if item.kind != "test" and id(item) in sqlite_only
               and id(item) not in moving and item.name not in named_anywhere}
    for item in items:
        if item.kind != "test" and id(item) in sqlite_only and id(item) not in moving | dropped:
            raise SystemExit(f"{item.name} is SQLite-only and a kept item names it; rewrite it by hand")
    conformance_helpers = {item.name for item in kept if item.kind != "test" and id(item) in opens}
    for item in kept:
        if id(item) in opens:
            case = case_name(item) if item.kind == "test" else "case"
            thread_case(item, conformance_helpers, case)
            if item.kind == "test":
                wrap_test(item, case)
    for item in kept:
        if item.name in shared:
            make_pub(item)
    kept_header = [line for line in header if not re.search(r"\bsqlite\b|\bc\.|StatementCache|sqlite_heap_bytes", line)]
    tests = "\n".join(kept_header + [line for item in items if id(item) not in moving | dropped
                                      for line in item.lines] + trailer)
    aliases = [f"const {name} = tests.{name};" for name in sorted(shared)]
    body_header = [line for line in header if not line.startswith("//!") and not re.match(r"^test \{", line)]
    moved = "\n".join([SQLITE_HEADER] + body_header[:1] + ['const tests = @import("tests.zig");'] + body_header[1:]
                      + aliases + [line for item in items if id(item) in moving for line in item.lines]) + "\n"
    stats = {
        "kept_tests": sum(1 for item in kept if item.kind == "test" and item.name),
        "conformance": sum(1 for item in kept if item.kind == "test" and "store_testing.forEachEngine(" in item.text),
        "moved_tests": len(moved_tests),
    }
    return tests, moved, stats


REASONS = (
    ("VM steps, statements or passes", re.compile(
        r"progress_handler|stmt_status|STMTSTATUS|trace_v2|\.passes\b|\.statements\b|StatementCache|next_stmt|"
        r"\bTestingSteps\b|\bTestingStatements\b|\bcachedWorkForTesting\b|\bstatementWorkSince\b|\btestingRuns\b|"
        r"\bdigestReadsForTesting\b|\bactivityPageSteps\b|\bTestingStatementFault\b|\bQueryCost\b|\bbusyStatements\b")),
    ("a SQLite mechanism", re.compile(
        r"PRAGMA|pragmaInt|blob|wal_checkpoint|sqlite3_limit|heap|sqlite3_open|sqlite3_close|\.open\(\s*(?:std\.testing\.)?io\s*,|"
        r"openWithOptions|get_autocommit|txn_state|sqlite3_changes|sqlite_schema|TEMP TRIGGER|ALTER TABLE|CREATE |"
        r"probeConstraint|touch_oracle_tables|sqliteDiagnostic|db_status|testing_content_work\.(?:read|blob|closes)|read_blob|rawContentCount")),
    ("raw SQL the fixtures do not cover", re.compile(r".")),
)


def table(pre_split):
    _, items, _ = parse(pre_split)
    for item in items:
        rewrite_sql(item)
    sqlite_only, opens, refs, named = classify(items)
    rows = []
    for item in items:
        if item.kind != "test" or not item.name:
            continue
        if id(item) not in sqlite_only:
            engines = id(item) in opens or "store_testing.forEachEngine(" in item.text
            rows.append((item.name, "tests.zig", "every engine" if engines else "opens no Store"))
            continue
        reached, frontier = [item], list(refs[id(item)])
        while frontier:
            name = frontier.pop()
            if named[name] not in reached:
                reached.append(named[name])
                frontier.extend(refs[id(named[name])])
        text = "\n".join(other.text for other in reached if id(other) in sqlite_only)
        reason = next(label for label, pattern in REASONS if pattern.search(text))
        rows.append((item.name, "sqlite_tests.zig", reason))
    return rows


def conformance_sources(root=ROOT):
    directory = root / Path(TESTS).with_suffix("")
    return [(TESTS, (root / TESTS).read_text())] + [
        (path.relative_to(root).as_posix(), path.read_text()) for path in sorted(directory.rglob("*.zig"))]


SQLITE_MODULE_IMPORT = re.compile(r'@import\("(?:\.\./)*(?:sqlite(?:_tests)?\.zig|sqlite_tests/[^"\n]+\.zig)"\)')


def check(sources):
    destination = "the SQLite test files under src/store/sqlite_tests/"
    for name, source in sources:
        if SQLITE_MODULE_IMPORT.search(source):
            return f"{name} imports a SQLite module; SQLite-only tests belong in {destination}"
        for number, line in enumerate(code_only(source).split("\n"), 1):
            match = SQLITE_CODE.search(line)
            if match:
                return f"{name}:{number} names {match.group()!r}, a SQLite mechanism; move the test to {destination}"
    return None


def main(argv):
    if argv[1:2] == ["rewrite"]:
        if len(argv) < 3:
            print("rewrite needs the pre-split tests.zig", file=sys.stderr)
            return 2
        text = Path(argv[2]).read_text()
        if check([(TESTS, text)]) is None:
            print(f"{argv[2]} is already split; rewrite takes the pre-split tests.zig", file=sys.stderr)
            return 1
        tests, moved, stats = rewrite(text)
        (ROOT / TESTS).write_text(tests)
        (ROOT / SQLITE_TESTS).write_text(moved)
        print(stats)
        return 0
    if argv[1:2] == ["table"]:
        for name, file, reason in table(Path(argv[2]).read_text()):
            print(f"{file}\t{reason}\t{name}")
        return 0
    if argv[1:2] == ["check"]:
        problem = check(conformance_sources())
        if problem:
            print(problem, file=sys.stderr)
            return 1
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

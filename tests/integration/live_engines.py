"""The environment that hands a live engine server to the native unit binary.

This module owns the variable names. CI writes them through `export`, the
fixture launcher `host_process.py` keeps them (its INHERITED reads
VARIABLES), and the unit binary reads them; tests/ci checks that every
`RUI_TEST_MYSQL_*` and `RUI_TEST_PG_*` name the Zig source reads is listed
here.

CI's steps run it through tests/ci/live_engine_step.py.
"""

REQUIRE = "RUI_TEST_REQUIRE_ENGINES"
MYSQL_SOCKET = "RUI_TEST_MYSQL_SOCKET"
MYSQL_ROOT_PASSWORD = "RUI_TEST_MYSQL_ROOT_PASSWORD"
# The file the live dialect check rewrites with what it did
# (src/store/mysql_dialect_check.zig).
MYSQL_RECORD = "RUI_TEST_MYSQL_RECORD"
ENGINES = {
    "mysql": (MYSQL_SOCKET, MYSQL_ROOT_PASSWORD, MYSQL_RECORD),
    "postgres": ("RUI_TEST_PG_PORT", "RUI_TEST_PG_PASSWORD", "RUI_TEST_PG_CA_FILE"),
}
VARIABLES = (REQUIRE, *(name for names in ENGINES.values() for name in names))


def export_lines(engine, values, environ):
    """The `NAME=VALUE` lines that hand `engine`'s server to later steps."""
    names = ENGINES[engine]
    if len(values) != len(names):
        raise ValueError(f"{engine} takes {len(names)} values: {', '.join(names)}")
    required = environ.get(REQUIRE, "")
    lines = [f"{REQUIRE}={required + ',' if required else ''}{engine}"]
    return lines + [f"{name}={value}" for name, value in zip(names, values)]


def parse_record(text):
    """The counts of a dialect-check record, as name to integer."""
    counts = {}
    for field in text.split():
        name, _, value = field.partition("=")
        counts[name] = int(value)
    return counts


def verify_mysql(environ):
    """A failure message, or None when the record shows the check ran."""
    path = environ.get(MYSQL_RECORD)
    if not path:
        return f"{MYSQL_RECORD} is not set, so the live dialect check kept no record"
    try:
        with open(path, encoding="utf-8") as record:
            text = record.read()
    except FileNotFoundError:
        return f"{path} is missing: the unit binary never opened the live dialect check"
    print(f"MySQL dialect check record: {text.strip()}")
    counts = parse_record(text)
    if counts.get("prepares", 0) == 0:
        return f"{path} counts no PREPARE: the live dialect check checked nothing"
    if counts.get("migrations", 0) == 0:
        return f"{path} counts no passed migration test: the MySQL migration gate did not run or failed"
    return None

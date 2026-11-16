
REQUIRE = "RUI_TEST_REQUIRE_ENGINES"
MYSQL_SOCKET = "RUI_TEST_MYSQL_SOCKET"
MYSQL_ROOT_PASSWORD = "RUI_TEST_MYSQL_ROOT_PASSWORD"
MYSQL_RECORD = "RUI_TEST_MYSQL_RECORD"
ENGINES = {
    "mysql": (MYSQL_SOCKET, MYSQL_ROOT_PASSWORD, MYSQL_RECORD),
    "postgres": ("RUI_TEST_PG_PORT", "RUI_TEST_PG_PASSWORD", "RUI_TEST_PG_CA_FILE"),
}
VARIABLES = (REQUIRE, *(name for names in ENGINES.values() for name in names))


def export_lines(engine, values, environ):
    names = ENGINES[engine]
    if len(values) != len(names):
        raise ValueError(f"{engine} takes {len(names)} values: {', '.join(names)}")
    required = environ.get(REQUIRE, "")
    lines = [f"{REQUIRE}={required + ',' if required else ''}{engine}"]
    return lines + [f"{name}={value}" for name, value in zip(names, values)]


def parse_record(text):
    counts = {}
    for field in text.split():
        name, _, value = field.partition("=")
        counts[name] = int(value)
    return counts


def verify_mysql(environ):
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
    if counts.get("conformance", 0) == 0:
        return f"{path} counts no passed conformance test: the MySQL Store gate did not run or failed"
    return None

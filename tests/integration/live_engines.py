from contextlib import ExitStack, contextmanager
import hashlib
import os
from pathlib import Path
import tempfile
import time


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


def accepted(record):
    """Where store_shards.py joins its Store shards' records. Only that join writes it: any other test binary
    that inherits MYSQL_RECORD writes the record path itself, and the last such writer would otherwise decide
    the gate (#2306's first two attempts: a later test-logic run left prepares=57, conformance=0)."""
    return record + ".accepted"


def verify_mysql(environ):
    record = environ.get(MYSQL_RECORD)
    if not record:
        return f"{MYSQL_RECORD} is not set, so the live dialect check kept no record"
    path = accepted(record)
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


@contextmanager
def mysql_lease(environ, *, exclusive=False, timeout=1200, stop=None):
    from host_process import wait_for
    import os_semantics
    socket = environ.get(MYSQL_SOCKET)
    if not socket:
        yield None
        return
    key = hashlib.sha256(os.path.realpath(socket).encode()).hexdigest()
    path = Path(tempfile.gettempdir()) / f"rui-unit-mysql-{key}.lock"
    deadline = time.monotonic() + timeout
    with ExitStack() as cleanup:
        def open_lock(path, shared, description):
            descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
            cleanup.callback(os.close, descriptor)
            def acquire():
                if stop is not None and stop.is_set():
                    raise InterruptedError("unit root interrupted while waiting for MySQL")
                return os_semantics.try_lock(descriptor, shared=shared)
            wait_for(acquire, description, deadline=deadline, interval=.01)
            return descriptor
        if exclusive:
            # Portable EX-to-SH conversion can briefly drop the main lock. Keep
            # other writers out until the entire downgraded cohort has finished.
            open_lock(path.with_suffix(".writer.lock"), False, "MySQL fixture writer turn")
        descriptor = open_lock(path, not exclusive,
                               "exclusive MySQL fixture phase" if exclusive else "shared MySQL fixture phase")
        yield descriptor
        # ExitStack closes the main lock before releasing the writer turn.

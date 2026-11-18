"""Generate or check the Store statement table, src/store/rsql_table.zig.

    python3 tests/ci/rsql_table.py generate   rewrite the table from a collect build
    python3 tests/ci/rsql_table.py check      fail when the checked-in table differs from a collect build
    python3 tests/ci/rsql_table.py fingerprint  fail when the table records other inputs than the files hold (cheap; policy)
    (either takes --zig PATH, the compiler to build with; default zig on PATH)

A collect build (-Drsql-collect=true) compiles the product and the unit roots on rsql's comptime path, and every
statement and every Store test fixture text exports one record of what that path produced. This script reads the records back from the binaries
and writes them as the table rsql.Read and rsql.Write look statements up in. Linux only: it reads ELF symbols.
"""
import hashlib
import os
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / "src/store/rsql_table.zig"
TARGETS = "test-native,test-store,session-list-integration"
PREFIX = b"rsqlstmt_"
REGENERATE = "python3 tests/ci/rsql_table.py generate"


def fingerprint(root):
    """build/product.zig's fingerprint of the files rsql_table_inputs names, which that file owns."""
    names = re.search(r"pub const rsql_table_inputs = \[_\]\[\]const u8\{([^}]*)\}", (root / "build/product.zig").read_text())
    if names is None:
        raise ValueError("build/product.zig declares no rsql_table_inputs")
    digest = hashlib.sha256()
    for name in re.findall(r'"([^"]+)"', names[1]):
        digest.update(name.encode() + b"\0" + (root / name).read_bytes() + b"\0")
    return digest.digest()[:16].hex()


def recorded(root):
    found = re.search(r'^pub const inputs = "([0-9a-f]*)";$', (root / "src/store/rsql_table.zig").read_text(), re.M)
    return found[1] if found else None


def fingerprint_error(root):
    expected = fingerprint(root)
    if recorded(root) == expected:
        return None
    return (f"src/store/rsql_table.zig records inputs {recorded(root)!r}, but the files rsql_table_inputs names hash to "
            f"{expected!r}: every Store statement would compile on the slow comptime path. Run `{REGENERATE}` and commit it")


def elf_records(data):
    """Bytes of every defined rsqlstmt_* symbol of a 64-bit little-endian ELF image."""
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return []
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum = struct.unpack_from("<HH", data, 0x3A)
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize) for i in range(shnum)]
    found = []
    for _, kind, _, _, offset, size, link, _, _, entsize in sections:
        if kind not in (2, 11):  # SHT_SYMTAB, SHT_DYNSYM
            continue
        strings = sections[link]
        for at in range(offset, offset + size, entsize):
            name_at, _, _, index, value, length = struct.unpack_from("<IBBHQQ", data, at)
            name_start = strings[4] + name_at
            if not data.startswith(PREFIX, name_start) or index == 0 or index >= len(sections):
                continue
            _, home_kind, _, address, home_offset, _, _, _, _, _ = sections[index]
            if home_kind == 8:  # SHT_NOBITS
                continue
            start = home_offset + value - address
            found.append(data[start:start + length])
    return found


def literal(raw):
    return '"' + "".join(chr(c) if 0x20 <= c < 0x7F and c not in (0x22, 0x5C) else "\\x%02x" % c for c in raw) + '"'


def slot(text):
    if text == "n":
        return ".now"
    if text[0] == "a":
        return ".{ .argument = %d }" % int(text[1:])
    return ".{ .served = .%s }" % text[1:]


def mysql_template(parts, slots):
    return ".{ .parts = &.{ %s }, .slots = &.{ %s } }" % (
        ", ".join(literal(p) for p in parts.split(b"\x1e")), ", ".join(slot(s) for s in slots.decode().split(",") if s))


def statement(record, statements):
    """kind (read or write), text, signature, SQLite text, MySQL parts, slots, uses_now, shape, inputs."""
    _, sql, signature, sqlite, parts, slots, uses_now, shape, inputs = record
    entry = statements.setdefault(sql, dict(parts=parts, slots=slots, uses_now=uses_now, shape=shape, variants={}))
    if (entry["parts"], entry["slots"], entry["uses_now"], entry["shape"]) != (parts, slots, uses_now, shape):
        raise ValueError(f"one statement text rendered two ways: {sql[:120]!r}")
    if entry["variants"].setdefault(signature, sqlite) != sqlite:
        raise ValueError(f"one statement and signature rendered two SQLite texts: {sql[:120]!r}")
    return inputs


def fixture(record, fixtures):
    """fixture, text, MySQL parts, slots, inputs."""
    _, text, parts, slots, inputs = record
    if fixtures.setdefault(text, (parts, slots)) != (parts, slots):
        raise ValueError(f"one fixture text rendered two ways: {text[:120]!r}")
    return inputs


HANDLERS = {b"read": ("statements", statement), b"write": ("statements", statement), b"fixture": ("fixtures", fixture)}


def block(name, lines):
    return [f"pub const {name} = struct {{"] + lines + ["};"] if lines else [f"pub const {name} = struct {{}};"]


def render(records):
    """The table's source text for a set of records, and its count of statements; one line per text, sorted."""
    found = {name: {} for name, _ in HANDLERS.values()}
    fingerprints = set()
    for raw in records:
        if not raw.endswith(b"\x1c"):
            raise ValueError(f"unterminated record {raw[:80]!r}")
        record = raw[:-1].split(b"\x1f")
        if record[0] not in HANDLERS:
            raise ValueError(f"record of unknown kind {record[0][:40]!r}")
        name, handler = HANDLERS[record[0]]
        fingerprints.add(handler(record, found[name]))
    if len(fingerprints) > 1:
        raise ValueError(f"the binaries were built from different table inputs: {sorted(fingerprints)}")
    inputs = fingerprints.pop().decode() if fingerprints else ""
    statements, fixtures = found["statements"], found["fixtures"]
    entries = []
    for sql in sorted(statements):
        entry = statements[sql]
        variants = ", ".join(".{ .signature = %s, .sqlite = %s }" % (literal(s), literal(t)) for s, t in sorted(entry["variants"].items()))
        shape = entry["shape"].decode()
        entries.append(
            f"    pub const @{literal(sql)}: rsql.TableEntry = .{{ .variants = &.{{ {variants} }}, "
            f".mysql = {mysql_template(entry['parts'], entry['slots'])}, "
            f".facts = .{{ .uses_now = {'true' if entry['uses_now'] == b'1' else 'false'}, .shape = .{shape}, "
            f".single_row = {'true' if shape == 'select_one' else 'false'} }} }};")
    fixture_lines = [f"    pub const @{literal(text)}: rsql.Template = {mysql_template(*fixtures[text])};" for text in sorted(fixtures)]
    lines = [
        "//! Generated by tests/ci/rsql_table.py from a collect build; do not edit. Regenerate with",
        f"//! `{REGENERATE}`. Each line holds one statement or fixture text: rsql.zig serves it only while",
        "//! its signature and `inputs` match, so a stale line costs compile time, never a different render.",
        'const rsql = @import("rsql.zig");',
        "",
        f"pub const inputs = {literal(inputs.encode())};",
        "",
    ] + block("entries", entries) + [""] + block("fixtures", fixture_lines)
    return "\n".join(lines) + "\n", len(statements), len(fixtures)


def collect(zig):
    with tempfile.TemporaryDirectory(prefix="rsql-table-") as prefix:
        command = [zig, "build", "ci-build", "-Dpr-ci=true", "-Drsql-collect=true", f"-Dci-targets={TARGETS}",
                   "-Dci-part=all", "--prefix", prefix]
        subprocess.run(command, cwd=ROOT, check=True)
        records = set()
        for binary in sorted((Path(prefix) / "bin").iterdir()):
            records.update(elf_records(binary.read_bytes()))
    if not records:
        raise SystemExit("the collect build exported no statements")
    return records


def main(argv):
    zig = "zig"
    if len(argv) == 3 and argv[1] == "--zig":
        argv, zig = argv[:1], argv[2]
    if argv == ["fingerprint"]:
        error = fingerprint_error(ROOT)
        print(error or "src/store/rsql_table.zig records the current inputs", file=sys.stderr if error else sys.stdout)
        return 1 if error else 0
    if argv not in (["generate"], ["check"]):
        raise SystemExit(__doc__)
    text, count, fixtures = render(collect(zig))
    text = subprocess.run([zig, "fmt", "--stdin"], input=text, capture_output=True, text=True, check=True).stdout
    if argv == ["generate"]:
        TABLE.write_text(text)
        print(f"{TABLE.relative_to(ROOT)}: {count} statements, {fixtures} fixture texts")
        return 0
    if TABLE.read_text() != text:
        print(f"{TABLE.relative_to(ROOT)} differs from what the comptime path renders; run `{REGENERATE}` and commit it",
              file=sys.stderr)
        return 1
    print(f"{TABLE.relative_to(ROOT)}: {count} statements and {fixtures} fixture texts, as the comptime path renders them")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

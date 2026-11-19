"""Check build/link_table.json, the dependency packages each build target links.

    python3 tests/ci/link_table.py check GENERATED   fail unless the checked-in table equals GENERATED
                                                     (`zig build check` passes the walk's output)
    python3 tests/ci/link_table.py fingerprint        cheap: fail when the table records other build inputs
                                                     than the files hold (policy)

build/link_table.zig walks the build graph at configure time and writes the table; `zig build link-table`
rewrites build/link_table.json. select_tests.py reads the table, which is data only.
"""
import hashlib
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
TABLE = ROOT / "build/link_table.json"
REGENERATE = "zig build link-table"


def inputs(root=ROOT):
    """The digest build/link_table.zig computes: build.zig, build.zig.zon and build/*.zig, in byte order of name."""
    names = ["build.zig", "build.zig.zon", *(f"build/{path.name}" for path in (root / "build").glob("*.zig"))]
    digest = hashlib.sha256()
    for name in sorted(names):
        digest.update(name.encode() + b"\0" + (root / name).read_bytes() + b"\0")
    return digest.digest()[:16].hex()


def recorded(root=ROOT):
    text = (root / "build/link_table.json").read_text()
    prefix = '  "inputs": "'
    start = text.find(prefix)
    if start < 0:
        return None
    return text[start + len(prefix):text.index('"', start + len(prefix))]


def fingerprint_error(root=ROOT):
    expected = inputs(root)
    if recorded(root) == expected:
        return None
    return (f"build/link_table.json records inputs {recorded(root)!r}, but the build files hash to {expected!r}: "
            f"a dependency change would select the wrong targets. Run `{REGENERATE}` and commit it")


def main(argv):
    if argv == ["fingerprint"]:
        error = fingerprint_error()
        print(error or "build/link_table.json records the current build inputs", file=sys.stderr if error else sys.stdout)
        return 1 if error else 0
    if len(argv) != 2 or argv[0] != "check":
        raise SystemExit(__doc__)
    fresh = Path(argv[1]).read_text()
    if TABLE.read_text() != fresh:
        print(f"build/link_table.json differs from the build graph; run `{REGENERATE}` and commit it", file=sys.stderr)
        return 1
    print("build/link_table.json matches the build graph")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

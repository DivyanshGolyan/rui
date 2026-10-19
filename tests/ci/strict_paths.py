#!/usr/bin/env python3
"""Store, recovery and upgrade paths that need the strict landing gates.

The previous-release upgrade workflow repeats these patterns as its path
filter; test_landing.py keeps both lists identical.
"""
import fnmatch
import sys

STRICT = (
    "src/store*", "src/*schema*", "src/server*", "src/execution*", "src/*recovery*",
    "tests/integration/*recovery*", "tests/integration/bash*",
    "build.zig", "build.zig.zon", "install.sh",
)


def strict(paths):
    # GitHub path filters do not let `*` cross `/`; fnmatch does, so check
    # the directory depth as well.
    return sorted({path for path in paths for pattern in STRICT
                   if fnmatch.fnmatchcase(path, pattern) and path.count("/") == pattern.count("/")})


if __name__ == "__main__":
    # Paths on stdin, one per line; prints the strict ones.
    print("\n".join(strict(line.strip() for line in sys.stdin if line.strip())))

#!/usr/bin/env python3
import fnmatch
import sys

STRICT = (
    "src/store*", "src/store/", "src/*schema*", "src/server*", "src/execution*", "src/*recovery*",
    "tests/integration/*recovery*", "tests/integration/bash*",
    "build.zig", "build.zig.zon", "install.sh",
)


def matches(path, pattern):
    # A pattern ending in `/` covers its whole tree. GitHub path filters do
    # not let `*` cross `/`; fnmatch does, so check the directory depth as well.
    if pattern.endswith("/"):
        return path.startswith(pattern)
    return fnmatch.fnmatchcase(path, pattern) and path.count("/") == pattern.count("/")


def strict(paths):
    return sorted({path for path in paths for pattern in STRICT if matches(path, pattern)})


if __name__ == "__main__":
    print("\n".join(strict(line.strip() for line in sys.stdin if line.strip())))

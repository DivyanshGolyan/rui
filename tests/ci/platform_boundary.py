#!/usr/bin/env python3
"""Name the code that may behave differently on macOS than on Linux.

Linux CI predicts Mac CI only while platform differences stay where a reader,
and the selector, can find them. Only a Mac path may name the platform
(`builtin.os`, `sys.platform`) or call a syscall whose Linux and Darwin
semantics diverge. PRs run Mac Selected when they change a Mac path; stable
still runs it on every main SHA.
"""
import argparse
import fnmatch
import io
from pathlib import Path
import re
import sys
import tokenize


ROOT = Path(__file__).resolve().parents[2]

# Changing any of these can change Mac behaviour by itself.
MAC_PATHS = (
    "src/os/*", "tests/integration/os_semantics.py",
    "src/*.c", "src/*.h", "src/*.inc", "src/*.patch", "src/*.sh", "tests/integration/*.c",
    "build.zig", "build.zig.zon",
    ".github/actions/setup/*", ".github/workflows/daily-macos.yml", ".github/workflows/qualify-macos.yml",
    "tests/ci/qualification.py",
    "install.sh", "release/*",
)

SCANNED = ("src/*.zig", "tests/integration/*.zig", "tests/integration/*.py")

# Darwin differs on these: shutdown of a closed or listening socket returns
# ENOTCONN, a full backlog refuses connect, kill(-pgid) of a zombie group is
# EPERM (so only a negative pid counts), and descriptor limits have a
# separate kernel ceiling.
DIVERGENT_SYSCALLS = ("shutdown", "kill", "listen", "setrlimit")
SYSCALL_NAMESPACES = ("c", "posix", "system")
PYTHON_PLATFORM = (("sys", "platform"), ("platform", "system"), ("os", "uname"))

# Zig tokens with comments and multiline string lines removed; strings stay
# whole so `@import("builtin")` is recognizable and string contents are inert.
ZIG_TOKEN = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|@?[A-Za-z_][A-Za-z_0-9]*|[^\s]')


def zig_sites(source):
    tokens = [m.group() for m in ZIG_TOKEN.finditer(source) if not m.group().startswith(("//", "\\\\"))]
    sites = 0
    for i, token in enumerate(tokens):
        following = tokens[i + 1:i + 3]
        if token == "builtin" and following == [".", "os"]:
            sites += 1
        elif token == "@import" and tokens[i + 1:i + 6] == ["(", '"builtin"', ")", ".", "os"]:
            sites += 1
        elif (token in SYSCALL_NAMESPACES and following[:1] == ["."] and following[1:] and following[1] in DIVERGENT_SYSCALLS
              and (following[1] != "kill" or tokens[i + 3:i + 5] == ["(", "-"])
              and (i == 0 or tokens[i - 1] != "." or tokens[i - 2:i] == ["std", "."])):
            sites += 1
    return sites


def python_sites(source):
    tokens = [t.string for t in tokenize.generate_tokens(io.StringIO(source).readline)
              if t.type in (tokenize.NAME, tokenize.OP)]
    return sum(1 for i in range(len(tokens) - 2)
               if (tokens[i], tokens[i + 2]) in PYTHON_PLATFORM and tokens[i + 1] == "."
               and (i == 0 or tokens[i - 1] != "."))


def mac_path(path):
    """Whether a change to `path` needs Mac evidence before merge."""
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in MAC_PATHS)


def sites(root=ROOT):
    found = {}
    for pattern in SCANNED:
        for file in sorted(root.glob(pattern)):
            path = file.relative_to(root).as_posix()
            if mac_path(path):
                continue
            source = file.read_text()
            count = python_sites(source) if file.suffix == ".py" else zig_sites(source)
            if count:
                found[path] = count
    return found


def violations(found):
    return [f"{path}: {count} platform sites outside src/os/ and tests/integration/os_semantics.py. "
            "Move them there; see tests/ci/platform_boundary.py" for path, count in sorted(found.items())]


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    messages = violations(sites())
    for message in messages:
        print(message, file=sys.stderr)
    return 1 if messages else 0


if __name__ == "__main__":
    sys.exit(main())

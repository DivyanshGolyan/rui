#!/usr/bin/env python3
"""Name the code that may behave differently on macOS than on Linux.

Linux CI predicts Mac CI only while platform differences stay where a reader,
and the selector, can find them. A file may name the platform (`builtin.os`,
`sys.platform`) or call a syscall whose Linux and Darwin semantics diverge
only under a Mac path or with an allowance below. PRs run Mac Selected when
they change any of those files; stable still runs it on every main SHA.

Allowances record today's sites exactly. Moving a site into `src/os/` or
`tests/integration/os_semantics.py` deletes its allowance.
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
# EPERM, and descriptor limits have a separate kernel ceiling.
DIVERGENT_SYSCALLS = ("shutdown", "kill", "listen", "setrlimit")
SYSCALL_NAMESPACES = ("c", "posix", "system")
PYTHON_PLATFORM = (("sys", "platform"), ("platform", "system"), ("os", "uname"))

# Platform sites outside the Mac paths: path -> count.
ALLOWANCES = {
    "src/TestObservation.zig": 4,
    "src/bash.zig": 3,
    "src/cli.zig": 1,
    "src/client.zig": 2,
    "src/codex_auth.zig": 1,
    "src/codex_credentials.zig": 2,
    "src/descriptor_limit.zig": 5,
    "src/platform.zig": 1,
    "src/provider.zig": 1,
    "src/server.zig": 8,
    "src/store.zig": 1,
}

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
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in MAC_PATHS)


def mac_specific(path):
    """Whether a change to `path` needs Mac evidence before merge."""
    return mac_path(path) or path in ALLOWANCES


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


def violations(found, allowances=ALLOWANCES):
    messages = []
    for path in sorted(set(found) | set(allowances)):
        actual, allowed = found.get(path, 0), allowances.get(path, 0)
        if actual > allowed:
            messages.append(f"{path}: {actual} platform sites, {allowed} allowed. Put the difference in src/os/ "
                            "or tests/integration/os_semantics.py; see tests/ci/platform_boundary.py")
        elif actual < allowed:
            messages.append(f"{path}: {actual} platform sites, {allowed} allowed. Lower its allowance to {actual}"
                            + (" by deleting the entry" if actual == 0 else ""))
    return messages


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    messages = violations(sites())
    for message in messages:
        print(message, file=sys.stderr)
    return 1 if messages else 0


if __name__ == "__main__":
    sys.exit(main())

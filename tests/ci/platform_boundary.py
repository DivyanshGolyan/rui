#!/usr/bin/env python3
"""Name the code that may behave differently on macOS than on Linux.

Linux CI predicts Mac CI only while platform differences stay where a reader,
and the selector, can find them. Only a Mac path may name the platform
(`builtin.os`, `sys.platform`) or call a syscall whose Linux and Darwin
semantics diverge. Mac paths are the code Linux never executes the way a
Mac does; PRs run Mac Selected only when they change one, and each promotion
runs it before a release.
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
    # The PTY launcher: Darwin revokes a terminal when its session leader
    # exits and keeps different hangup and EOF rules, so Linux can't vouch.
    "tests/integration/terminal_process.py", "tests/integration/terminal_leader.py",
    # The self-contained HTTP/2 client cannot import src/os, so its sockets,
    # waker and trust paths name the platform themselves.
    "src/h2/*",
    # Trust loading reads the host's bundles, which differ on macOS.
    "src/tls_client/*",
    "src/*.c", "src/*.h", "src/*.inc", "src/*.patch", "src/*.sh", "tests/integration/*.c",
    ".github/workflows/qualify-macos.yml",
    "install.sh", "release/*",
    "build/darwin.zig",
)
# Other build plumbing (build.zig, build.zig.zon, the setup action, the CI qualification
# helpers) is not here: Linux runs it, typecheck-macos compiles Rui for
# Darwin on every PR, and promotion links and runs it on a Mac.

# fnmatch patterns, as prepush.py and the selector read them: `*` spans
# directories, so src/*.zig covers src/http1/Exchange.zig too.
SCANNED = ("src/*.zig", "tests/integration/*.zig", "tests/integration/*.py", "tests/integration/*.sh", "clients/ts/test/*.ts")

# Darwin differs on these: shutdown of a closed or listening socket returns
# ENOTCONN, a full backlog refuses connect, kill(-pgid) of a zombie group is
# EPERM (so only a negative pid counts), and descriptor limits have a
# separate kernel ceiling. getpeername can return EINVAL after a reset on
# Darwin; the socket owner rereads SO_ERROR (#1106).
DIVERGENT_SYSCALLS = ("shutdown", "kill", "listen", "setrlimit", "getpeername")
SYSCALL_NAMESPACES = ("c", "posix", "system")
PYTHON_PLATFORM = (("sys", "platform"), ("platform", "system"), ("os", "uname"))

# A Host trusts OpenSSL's store on Linux, which these variables extend, and
# Apple SecTrust on Darwin, which ignores them (#990, #997). A fixture that
# trusts its CA through them passes only on Linux, so outside Mac paths a
# fixture names neither: it hands the CA over explicitly (--provider-ca-file,
# the launch frame's caFile), or asks os_semantics for system trust.
TRUST_VARIABLE = re.compile(r"\bSSL_CERT_(?:FILE|DIR)\b")
# Python 3.12 splits f-strings into parts; earlier versions keep them whole.
STRING_TOKENS = (tokenize.NAME, tokenize.STRING, getattr(tokenize, "FSTRING_MIDDLE", tokenize.STRING))
TS_COMMENT = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)

# Zig tokens with comments and multiline string lines removed; strings stay
# whole so `@import("builtin")` is recognizable and string contents are inert.
ZIG_TOKEN = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|@?[A-Za-z_][A-Za-z_0-9]*|[^\s]')


def build_violations(source):
    """Keep Darwin-only build branches in the native Mac CI path."""
    tokens = [m.group() for m in ZIG_TOKEN.finditer(source) if not m.group().startswith(("//", "\\\\", '"', "'"))]
    code = " ".join(tokens)
    # These target declarations and the portable transport predicate execute on Linux.
    code = re.sub(r'\bos_tag = \. macos\b', 'os_tag = portable_target', code)
    code = code.replace('target . result . os . tag = = . macos or target . result . os . tag = = . linux',
                        'portable_transport_predicate')
    code = code.replace('. macos = > { macos_cross_step . dependOn ( & executable . step ) ; }',
                        'portable_cross_check_arm')
    # A Darwin branch may only invoke helpers with simple arguments.
    call = (r'darwin \. [A-Za-z_][\w]* \( '
            r'(?:[A-Za-z_][\w.]*(?: [.,] [A-Za-z_][\w]*)* )?\)')
    code = re.sub(r'\bif \( [A-Za-z_][\w]*(?: \. [A-Za-z_][\w]*)* '
                  r'= = \. macos \) \{ (?:' + call + r' ; )+\}',
                  'darwin_delegation', code)
    if re.search(r'\bisDarwin\b|\. (?:macos|ios|tvos|watchos|visionos|driverkit)\b', code):
        return ["build.zig: move Darwin-only build logic to build/darwin.zig"]
    return []


def zig_sites(source):
    tokens = [m.group() for m in ZIG_TOKEN.finditer(source) if not m.group().startswith(("//", "\\\\"))]
    sites = 0
    for i, token in enumerate(tokens):
        following = tokens[i + 1:i + 3]
        if token == "builtin" and following == [".", "os"]:
            sites += 1
        elif token == "@import" and tokens[i + 1:i + 6] == ["(", '"builtin"', ")", ".", "os"]:
            sites += 1
        # Linux uses MSG_NOSIGNAL; Darwin configures SO_NOSIGPIPE on the socket.
        elif (token, *following) in (("MSG", ".", "NOSIGNAL"), ("SO", ".", "NOSIGPIPE")):
            sites += 1
        elif (token in SYSCALL_NAMESPACES and following[:1] == ["."] and following[1:] and following[1] in DIVERGENT_SYSCALLS
              and (following[1] != "kill" or tokens[i + 3:i + 5] == ["(", "-"])
              and (i == 0 or tokens[i - 1] != "." or tokens[i - 2:i] == ["std", "."])):
            sites += 1
    return sites


def python_sites(source):
    generated = list(tokenize.generate_tokens(io.StringIO(source).readline))
    trust = sum(len(TRUST_VARIABLE.findall(t.string)) for t in generated
                if t.type in STRING_TOKENS)
    tokens = [t.string for t in generated if t.type in (tokenize.NAME, tokenize.OP)]
    platform = sum(1 for i in range(len(tokens) - 2)
                   if (tokens[i], tokens[i + 2]) in PYTHON_PLATFORM and tokens[i + 1] == "."
                   and (i == 0 or tokens[i - 1] != "."))
    sockets = unix_socket_sites(tokens)
    return trust + platform + sockets


def unix_socket_sites(tokens):
    return sum(tokens[i:i + 7] == ["socket", ".", "socket", "(", "socket", ".", "AF_UNIX"]
               for i in range(len(tokens)))


def shell_sites(source):
    # Shell fixtures embed Python in PY* heredocs; tokenize only their bodies.
    lines = iter(source.splitlines(keepends=True))
    count = 0
    for line in lines:
        match = re.search(r"<<['\"]?(PY[A-Z]*)['\"]?", line)
        if not match:
            continue
        body = []
        for line in lines:
            if line.strip() == match[1]:
                break
            body.append(line)
        generated = tokenize.generate_tokens(io.StringIO("".join(body)).readline)
        tokens = [t.string for t in generated if t.type in (tokenize.NAME, tokenize.OP)]
        count += unix_socket_sites(tokens)
    return count


def typescript_sites(source):
    return len(TRUST_VARIABLE.findall(TS_COMMENT.sub("", source)))


def unlistened_binds(source):
    """Zig functions and tests that bind a socket but never listen on it.

    Linux refuses a connection to such a port; Darwin drops its SYN without a
    reset, so a connect waits out its deadline (#999). A test that wants a
    refusing port takes socket_fixture.refusedPort().
    """
    tokens = [m.group() for m in ZIG_TOKEN.finditer(source) if not m.group().startswith(("//", "\\\\"))]
    found = []
    for start, token in enumerate(tokens):
        if token not in ("fn", "test"):
            continue
        name = next((tokens[i] for i in range(start + 1, min(start + 3, len(tokens)))
                     if tokens[i] != "("), "")
        try:
            body = tokens.index("{", start)
        except ValueError:
            continue
        depth, end = 0, body
        for end in range(body, len(tokens)):
            depth += {"{": 1, "}": -1}.get(tokens[end], 0)
            if depth == 0:
                break
        inside = tokens[body:end]
        binds = any(inside[i] in SYSCALL_NAMESPACES and inside[i + 1:i + 4] == [".", "bind", "("]
                    for i in range(len(inside) - 3))
        listens = any(inside[i] == "listen" and inside[i + 1] == "(" for i in range(len(inside) - 1))
        if binds and not listens:
            found.append(name)
    return found


def mac_path(path):
    """Whether a change to `path` needs Mac evidence before merge."""
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in MAC_PATHS)


def scanned(root=ROOT):
    """Every file under SCANNED, at any depth."""
    tops = sorted({pattern.split("/*", 1)[0] for pattern in SCANNED})
    for file in sorted(f for top in tops for f in (root / top).rglob("*") if f.is_file()):
        path = file.relative_to(root).as_posix()
        if any(fnmatch.fnmatchcase(path, pattern) for pattern in SCANNED):
            yield file, path


def sites(root=ROOT):
    found = {}
    for file, path in scanned(root):
        if mac_path(path):
            continue
        count = {".py": python_sites, ".sh": shell_sites, ".ts": typescript_sites}.get(file.suffix, zig_sites)(file.read_text())
        if count:
            found[path] = count
    return found


def violations(found):
    return [f"{path}: {count} platform sites outside src/os/ and tests/integration/os_semantics.py. "
            "Move them there; use os_semantics.unix_stream() for fixture Unix sockets; "
            "see tests/ci/platform_boundary.py" for path, count in sorted(found.items())]


def bind_sites(root=ROOT):
    """Each Zig file's functions and tests that bind a socket without listening on it."""
    found = {}
    for pattern in ("src/**/*.zig", "tests/integration/*.zig"):
        for file in sorted(root.glob(pattern)):
            names = unlistened_binds(file.read_text())
            if names:
                found[file.relative_to(root).as_posix()] = names
    return found


def bind_violations(found):
    return [f"{path}: {name} binds a socket it never listens on; Darwin drops connections to it "
            "instead of refusing them. Take socket_fixture.refusedPort() for a refusing port"
            for path, names in sorted(found.items()) for name in names]


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    messages = build_violations((ROOT / "build.zig").read_text()) + violations(sites()) + bind_violations(bind_sites())
    for message in messages:
        print(message, file=sys.stderr)
    return 1 if messages else 0


if __name__ == "__main__":
    sys.exit(main())

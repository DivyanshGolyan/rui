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
import ast
import fnmatch
import io
from pathlib import Path
import re
import sys
import tokenize

import build_files


ROOT = Path(__file__).resolve().parents[2]

MAC_PATHS = (
    "src/os/*", "src/cli.zig", "src/client.zig", "src/platform.zig", "src/HostLifecycle.zig",
    "src/host_coordinator.zig", "src/host_restart_all.zig", "src/host_start.zig", "src/host_identity.zig",
    "src/upgrade.zig", "src/upgrade_process.zig",
    "tests/integration/upgrade_integration.py", "src/store/mysql_testing.zig",
    "tests/integration/activity_integration.py", "tests/integration/bash_fixture.py",
    "tests/integration/codex_credential_integration.py", "tests/integration/codex_integration.py",
    "tests/integration/conversation_page_fixture.py",
    "tests/integration/live_engines.py", "tests/integration/proc_sample.py",
    "tests/integration/server_delivery_integration.py", "tests/integration/session_list_fixture.py",
    "tests/integration/transport_h2_cases.py",
    "tests/integration/os_semantics.py",
    "tests/integration/terminal_process.py", "tests/integration/terminal_leader.py",
    "tests/integration/terminal_restoration_cases.py",
    "src/h2/*",
    "src/tls_client/*",
    "src/*.c", "src/*.h", "src/*.inc", "src/*.patch", "src/*.sh", "tests/integration/*.c",
    ".github/workflows/qualify-macos.yml",
    "install.sh", "release/*",
    "build/darwin.zig", "tests/ci/build_artifact.py",
)

SCANNED = ("src/*.zig", "tests/integration/*.zig", "tests/integration/*.py", "tests/integration/*.sh", "clients/ts/test/*.ts")

# Process table observation and Store lease release on process exit also differ
# across kernels. Consumers of the retirement observation belong to Mac paths.
# Darwin differs on these: shutdown of a closed or listening socket returns
# ENOTCONN, a full backlog refuses connect, kill(-pgid) of a zombie group is
# EPERM (so only a negative pid counts), and descriptor limits have a
# separate kernel ceiling. getpeername can return EINVAL after a reset on
# Darwin; the socket owner rereads SO_ERROR (#1106).
DIVERGENT_SYSCALLS = ("shutdown", "kill", "listen", "setrlimit", "getpeername", "flock")
SYSCALL_NAMESPACES = ("c", "posix", "system")
PYTHON_PLATFORM = (("sys", "platform"), ("platform", "system"), ("os", "uname"))

# A Host trusts OpenSSL's store on Linux, which these variables extend, and
# Apple SecTrust on Darwin, which ignores them (#990, #997). A fixture that
# trusts its CA through them passes only on Linux, so outside Mac paths a
# fixture names neither: it hands the CA over explicitly (--set network.caFile=PATH,
# the settings document's network.caFile), or asks os_semantics for system trust.
TRUST_VARIABLE = re.compile(r"\bSSL_CERT_(?:FILE|DIR)\b")
# Python 3.12 splits f-strings into parts; earlier versions keep them whole.
STRING_TOKENS = (tokenize.NAME, tokenize.STRING, getattr(tokenize, "FSTRING_MIDDLE", tokenize.STRING))
TS_COMMENT = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)

ZIG_TOKEN = re.compile(r'//[^\n]*|\\\\[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|@?[A-Za-z_][A-Za-z_0-9]*|[^\s]')


def build_violations(source, name="build.zig"):
    tokens = [m.group() for m in ZIG_TOKEN.finditer(source) if not m.group().startswith(("//", "\\\\", '"', "'"))]
    code = " ".join(tokens)
    code = re.sub(r'\bos_tag = \. macos\b', 'os_tag = portable_target', code)
    code = code.replace('target . result . os . tag = = . macos or target . result . os . tag = = . linux',
                        'portable_transport_predicate')
    code = code.replace('. macos = > { macos_cross_step . dependOn ( & executable . step ) ; }',
                        'portable_cross_check_arm')
    call = (r'darwin \. [A-Za-z_][\w]* \( '
            r'(?:[A-Za-z_][\w.]*(?: [.,] [A-Za-z_][\w]*)* )?\)')
    code = re.sub(r'\bif \( [A-Za-z_][\w]*(?: \. [A-Za-z_][\w]*)* '
                  r'= = \. macos \) \{ (?:' + call + r' ; )+\}',
                  'darwin_delegation', code)
    if re.search(r'\bisDarwin\b|\. (?:macos|ios|tvos|watchos|visionos|driverkit)\b', code):
        return [f"{name}: move Darwin-only build logic to build/darwin.zig"]
    return []


def zig_sites(source):
    tokens = [m.group() for m in ZIG_TOKEN.finditer(source) if not m.group().startswith(("//", "\\\\"))]
    sites = 0
    lifecycle_calls = {
        'HostLifecycle.zig': {"observe", "activate", "awaitRetirement"},
        'host_coordinator.zig': {"restart", "restartAll", "run"},
        'host_restart_all.zig': {"discover", "restart", "run"},
        'host_identity.zig': {"generation", "peer", "snapshot"},
        'host_start.zig': {"spawn"},
    }
    def module_name(token):
        return token[1:-1].rsplit("/", 1)[-1] if token.startswith('"') and token.endswith('"') else ""

    lifecycle_aliases = {tokens[i + 1]: lifecycle_calls[module_name(tokens[i + 5])]
                         for i in range(len(tokens) - 7)
                         if tokens[i] == "const" and tokens[i + 2:i + 5] == ["=", "@import", "("]
                         and module_name(tokens[i + 5]) in lifecycle_calls and tokens[i + 6:i + 8] == [")", ";"]}
    for i, token in enumerate(tokens):
        following = tokens[i + 1:i + 3]
        if token == '"/bin/ps"' or token.startswith(('"/proc/', '"/proc"')):
            sites += 1
        elif token in ("rui_launch_detached_reported", "rui_process_generation", "rui_process_snapshot"):
            sites += 1
        elif (token in lifecycle_aliases and following[:1] == ["."]
              and following[1] in lifecycle_aliases[token]):
            sites += 1
        elif (token == "@import" and i + 5 < len(tokens) and tokens[i + 1] == "("
              and module_name(tokens[i + 2]) in lifecycle_calls and tokens[i + 3:i + 5] == [")", "."]
              and tokens[i + 5] in lifecycle_calls[module_name(tokens[i + 2])]):
            sites += 1
        elif token == "StoreLease" and following == [".", "observe"]:
            sites += 1
        elif token == "upgradeGenerationRetired" and following[:1] == ["("]:
            sites += 1
        elif token == "builtin" and following == [".", "os"]:
            sites += 1
        elif token == "@import" and tokens[i + 1:i + 6] == ["(", '"builtin"', ")", ".", "os"]:
            sites += 1
        elif (token, *following) in (("MSG", ".", "NOSIGNAL"), ("SO", ".", "NOSIGPIPE")):
            sites += 1
        elif (token in SYSCALL_NAMESPACES and following[:1] == ["."] and following[1:] and following[1] in DIVERGENT_SYSCALLS
              and (following[1] != "kill" or tokens[i + 3:i + 5] == ["(", "-"])
              and (i == 0 or tokens[i - 1] != "." or tokens[i - 2:i] == ["std", "."]
                   or tokens[i - 4:i] == ["std", ".", "posix", "."])):
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
    tree = ast.parse(source)
    fcntl_modules = {"fcntl"} | {alias.asname or alias.name for node in ast.walk(tree)
                     if isinstance(node, ast.Import) for alias in node.names if alias.name == "fcntl"}
    flock_names = {alias.asname or alias.name for node in ast.walk(tree)
                   if isinstance(node, ast.ImportFrom) and node.module == "fcntl"
                   for alias in node.names if alias.name == "flock"}
    subprocess_modules = {"subprocess"} | {alias.asname or alias.name for node in ast.walk(tree)
                          if isinstance(node, ast.Import) for alias in node.names if alias.name == "subprocess"}
    subprocess_names = {alias.asname or alias.name for node in ast.walk(tree)
                        if isinstance(node, ast.ImportFrom) and node.module == "subprocess"
                        for alias in node.names if alias.name in {"run", "Popen", "call", "check_call", "check_output"}}
    process_sites = 0
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and (node.value == "/proc" or node.value.startswith("/proc/")):
            process_sites += 1
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        if ((isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name)
             and func.value.id in fcntl_modules and func.attr == "flock")
                or isinstance(func, ast.Name) and func.id in flock_names):
            process_sites += 1
        is_subprocess = ((isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name)
                          and func.value.id in subprocess_modules and func.attr in {"run", "Popen", "call", "check_call", "check_output"})
                         or isinstance(func, ast.Name) and func.id in subprocess_names)
        argv = node.args[0] if node.args else next((kw.value for kw in node.keywords if kw.arg == "args"), None)
        if (is_subprocess and isinstance(argv, (ast.List, ast.Tuple)) and argv.elts
                and isinstance(argv.elts[0], ast.Constant) and argv.elts[0].value in {"ps", "/bin/ps", "/usr/bin/ps"}):
            process_sites += 1
    return trust + platform + sockets + process_sites


def unix_socket_sites(tokens):
    return sum(tokens[i:i + 7] == ["socket", ".", "socket", "(", "socket", ".", "AF_UNIX"]
               for i in range(len(tokens)))


def shell_sites(source):
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
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in MAC_PATHS)


def scanned(root=ROOT):
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
    return [f"{path}: {count} platform sites outside Mac paths. "
            "Move them to an appropriate Mac owner; use os_semantics.unix_stream() for fixture Unix sockets; "
            "see tests/ci/platform_boundary.py" for path, count in sorted(found.items())]


def bind_sites(root=ROOT):
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


def pty_close_violations(source, name="fixture.py"):
    tree = ast.parse(source, filename=name)
    violations = []
    for scope in (node for node in ast.walk(tree) if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef))):
        owned = set()
        for node in ast.walk(scope):
            if not isinstance(node, ast.Assign) or not any(
                    isinstance(call, ast.Call) and isinstance(call.func, ast.Name) and call.func.id == "open_pty"
                    for call in ast.walk(node.value)):
                continue
            for target in node.targets:
                targets = target.elts if isinstance(target, (ast.Tuple, ast.List)) else [target]
                owned.update(ast.unparse(item) for item in targets if isinstance(item, (ast.Name, ast.Attribute)))
        containers = set()
        for node in ast.walk(scope):
            if isinstance(node, ast.AugAssign) and any(ast.unparse(item) in owned for item in ast.walk(node.value)):
                containers.add(ast.unparse(node.target))
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and node.func.attr in ("append", "extend")
                    and any(ast.unparse(item) in owned for arg in node.args for item in ast.walk(arg))):
                containers.add(ast.unparse(node.func.value))
        for node in ast.walk(scope):
            if (isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension))
                    and ast.unparse(node.iter) in containers):
                owned.add(ast.unparse(node.target))
        for node in ast.walk(scope):
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "close"
                    and isinstance(node.func.value, ast.Name) and node.func.value.id == "os" and node.args
                    and ast.unparse(node.args[0]) in owned):
                message = f"{name}:{node.lineno}: close PTY descriptors with close_pty, not os.close"
                if message not in violations:
                    violations.append(message)
    return violations


def flag_violations(root=ROOT):
    messages = []

    def getfl(node):
        return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name) and node.func.value.id == "fcntl"
                and node.func.attr == "fcntl" and len(node.args) >= 2
                and isinstance(node.args[1], ast.Attribute) and node.args[1].attr == "F_GETFL"
                and isinstance(node.args[1].value, ast.Name) and node.args[1].value.id == "fcntl")

    class FunctionScan(ast.NodeVisitor):
        def __init__(self, path):
            self.path = path
            self.names = set()
            self.comparisons = []

        def visit_FunctionDef(self, node):
            scan = FunctionScan(self.path)
            for statement in node.body:
                scan.visit(statement)
            scan.report()

        def report(self):
            for comparison in self.comparisons:
                operands = [comparison.left, *comparison.comparators]
                if any(isinstance(op, (ast.Eq, ast.NotEq)) and
                       any(getfl(operand) or (isinstance(operand, ast.Name) and operand.id in self.names)
                           for operand in operands[i:i + 2])
                       for i, op in enumerate(comparison.ops)):
                    messages.append(f"{self.path}:{comparison.lineno}: raw F_GETFL comparison; "
                                    "use assert_file_flags or os_semantics.user_file_flags")

        visit_AsyncFunctionDef = visit_FunctionDef

        def visit_Assign(self, node):
            if getfl(node.value):
                self.names.update(target.id for target in node.targets if isinstance(target, ast.Name))
            self.generic_visit(node)

        def visit_AnnAssign(self, node):
            if node.value and getfl(node.value) and isinstance(node.target, ast.Name):
                self.names.add(node.target.id)
            self.generic_visit(node)

        def visit_Compare(self, node):
            self.comparisons.append(node)
            self.generic_visit(node)

    for file, path in scanned(root):
        if file.suffix == ".py" and not mac_path(path) and path != "tests/integration/terminal_restoration_fixture.py":
            scan = FunctionScan(path)
            scan.visit(ast.parse(file.read_text(), filename=path))
            scan.report()
    return messages


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    builds = [(path.relative_to(ROOT).as_posix(), path.read_text()) for path in build_files.files()]
    messages = ([message for name, source in builds if not mac_path(name) for message in build_violations(source, name)]
                + violations(sites()) + bind_violations(bind_sites()) + flag_violations()
                + [message for folder in ("integration", "qualification")
                   for path in sorted((ROOT / "tests" / folder).rglob("*.py"))
                   for message in pty_close_violations(path.read_text(), path.relative_to(ROOT).as_posix())])
    for message in messages:
        print(message, file=sys.stderr)
    return 1 if messages else 0


if __name__ == "__main__":
    sys.exit(main())

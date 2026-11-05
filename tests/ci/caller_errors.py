#!/usr/bin/env python3
"""Keep CLI-owned failures classified without exposing Zig error names.

Inventory only src/cli.zig, src/cli_args.zig, src/client.zig,
src/preferences.zig and root-level src/caller_*.zig. The same predicate selects
candidate coverage and trusted bootstrap sources. Pending can only shrink from
the trusted origin/main merge base; before that tuple existed, bootstrap from
those trusted CLI sources and the pinned Zig standard library, never from the
candidate's pending names. After rollout only the trusted tuple's names that
occur in the trusted CLI inventory remain eligible.

Closed error sets are also checked by caller_error.of at compile time. Errors
from other owners that widen to anyerror remain internal_unexpected, exit 1
(unclassified); adding a Host-internal error must not require a CLI catalog edit.
This is a source inventory, not transitive call-graph inference. Test blocks are
excluded; helpers outside test blocks remain in scope. Comments and strings are
never code.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[2]
CATALOG = "src/caller_error.zig"
CALLER = {"src/cli.zig", "src/cli_args.zig"}
INVENTORY = CALLER | {"src/client.zig", "src/preferences.zig"}
TOKEN = re.compile(
    r'//[^\n]*|\\\\[^\n]*|@"(?:\\.|[^"\\])*"|"(?:\\.|[^"\\])*"|'
    r"'(?:\\.|[^'\\])*'|@?[A-Za-z_][A-Za-z_0-9]*|=>|[^\s]"
)
NAME = re.compile(r"[A-Za-z_][A-Za-z_0-9]*\Z")


class Token(NamedTuple):
    text: str
    line: int


def lex(source):
    tokens = []
    line, end = 1, 0
    for match in TOKEN.finditer(source):
        line += source.count("\n", end, match.start())
        text = match.group()
        if not text.startswith(("//", "\\\\")):
            tokens.append(Token(text, line))
        line += text.count("\n")
        end = match.end()
    return tokens


def close_brace(tokens, start):
    depth = 0
    for i in range(start, len(tokens)):
        if tokens[i].text == "{":
            depth += 1
        elif tokens[i].text == "}":
            depth -= 1
            if depth == 0:
                return i
    raise ValueError(f"line {tokens[start].line}: unclosed block")


def production(tokens):
    """Remove balanced test blocks; braces in strings cannot end a block."""
    kept = []
    i = 0
    while i < len(tokens):
        if tokens[i].text == "test":
            start = i + 1
            if start < len(tokens) and (tokens[start].text.startswith(('"', '@"'))
                                        or NAME.fullmatch(tokens[start].text)):
                start += 1
            if start >= len(tokens) or tokens[start].text != "{":
                raise ValueError(f"line {tokens[i].line}: expected a test block")
            i = close_brace(tokens, start) + 1
        else:
            kept.append(tokens[i])
            i += 1
    return kept


def caller_path(name):
    path = Path(name)
    return name in CALLER or (path.parent.as_posix() == "src" and path.match("caller_*.zig"))


def inventory_path(name):
    return name in INVENTORY or caller_path(name)


def read_sources(root=ROOT):
    return {path.relative_to(root).as_posix(): path.read_text()
            for path in sorted((root / "src").glob("*.zig"))
            if inventory_path(path.relative_to(root).as_posix())}


def error_identifier(token):
    name = token.text
    if name.startswith('@"'):
        return json.loads(name[1:])
    if not NAME.fullmatch(name):
        raise ValueError(f"line {token.line}: unsupported error identifier {name!r}")
    return name


def error_sites(tokens):
    """Both literal error.Name uses and names declared in error{...} sets."""
    for i in range(len(tokens) - 1):
        if tokens[i].text != "error":
            continue
        if tokens[i + 1].text == ".":
            if i + 2 >= len(tokens):
                raise ValueError(f"line {tokens[i].line}: missing error identifier")
            yield error_identifier(tokens[i + 2]), tokens[i].line
        elif tokens[i + 1].text == "{":
            end = close_brace(tokens, i + 1)
            j = i + 2
            while j < end:
                yield error_identifier(tokens[j]), tokens[j].line
                j += 1
                if j < end:
                    if tokens[j].text != ",":
                        raise ValueError(f"line {tokens[j].line}: expected a comma in error set")
                    j += 1


def pending_names(source):
    tokens = production(lex(source))
    text = [token.text for token in tokens]
    starts = [i for i in range(len(text) - 2) if text[i:i + 3] == ["pub", "const", "pending"]]
    if not starts:
        return None
    if len(starts) != 1:
        raise ValueError("caller_error.zig: expected one pending tuple")
    start = starts[0] + 3
    if text[start:start + 3] != ["=", ".", "{"]:
        raise ValueError("caller_error.zig: pending must be a literal string tuple")
    end = close_brace(tokens, start + 2)
    entries = text[start + 3:end]
    names = []
    while entries:
        value = entries.pop(0)
        if not (value.startswith('"') and value.endswith('"')):
            raise ValueError("caller_error.zig: pending must contain literal error names")
        name = json.loads(value)
        if not name:
            raise ValueError("caller_error.zig: pending error name cannot be empty")
        names.append(name)
        if entries and entries.pop(0) != ",":
            raise ValueError("caller_error.zig: expected a comma in pending")
    if len(names) != len(set(names)):
        raise ValueError("caller_error.zig: duplicate pending error name")
    return set(names)


def mapped_names(source):
    tokens = production(lex(source))
    text = [token.text for token in tokens]
    starts = [i for i in range(len(text) - 1) if text[i:i + 2] == ["fn", "mapped"]]
    if len(starts) != 1:
        raise ValueError("caller_error.zig: expected one mapped function")
    start = text.index("{", starts[0])
    end = close_brace(tokens, start)
    body = text[start + 1:end]
    if body[:6] != ["return", "switch", "(", "err", ")", "{"] or body[-2:] != ["}", ";"]:
        raise ValueError("caller_error.zig: mapped must return switch (err)")
    arms = body[6:-2]
    names = set()
    # Only literal error.Name => .code arms count as classification. Merely
    # mentioning an error elsewhere in this function must not admit it.
    while arms:
        if arms[:3] == ["else", "=>", "null"]:
            arms = arms[3:]
            if arms == [","]:
                arms = []
            if arms:
                raise ValueError("caller_error.zig: mapped else must be null and last")
            return names
        while True:
            if len(arms) < 3 or arms[:2] != ["error", "."] or not NAME.fullmatch(arms[2]):
                raise ValueError("caller_error.zig: expected a literal mapped error arm")
            names.add(arms[2])
            arms = arms[3:]
            if arms[:2] == [",", "error"]:
                arms = arms[1:]
                continue
            break
        if len(arms) < 3 or arms[:2] != ["=>", "."] or not NAME.fullmatch(arms[2]):
            raise ValueError("caller_error.zig: mapped error needs a literal Code tag")
        arms = arms[3:]
        if arms and arms.pop(0) != ",":
            raise ValueError("caller_error.zig: expected a comma after mapped arm")
    raise ValueError("caller_error.zig: mapped must end with else => null")


def check(sources):
    catalog = sources[CATALOG]
    pending = pending_names(catalog)
    if pending is None:
        raise ValueError("caller_error.zig: missing pending tuple")
    classified = pending | mapped_names(catalog)
    failures = []
    for path, source in sorted(sources.items()):
        tokens = lex(source)
        # Ban raw rendering even in tests: strings and comments are inert.
        if caller_path(path):
            for i in range(len(tokens) - 1):
                if [token.text for token in tokens[i:i + 2]] == ["@errorName", "("]:
                    failures.append(f"{path}:{tokens[i].line}: raw @errorName is forbidden on the caller surface")
        if inventory_path(path):
            for name, line in error_sites(production(tokens)):
                if name not in classified:
                    failures.append(f"{path}:{line}: error.{name} needs a mapped code or an existing pending entry")
    return failures


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True, stderr=subprocess.PIPE).strip()


def trusted_pending(root, base):
    if not git(root, "ls-tree", "--name-only", base, "--", CATALOG):
        return None
    return pending_names(git(root, "show", f"{base}:{CATALOG}"))


def needs_bootstrap(root=ROOT):
    return trusted_pending(root, git(root, "merge-base", "HEAD", "origin/main")) is None


def zig_setting(source, name):
    """A string field in Zig's pinned manifest or `zig env` ZON output."""
    tokens = [token.text for token in lex(source)]
    values = [tokens[i + 2] for i in range(len(tokens) - 2)
              if tokens[i:i + 2] == [name, "="]]
    if len(values) != 1 or not values[0].startswith('"'):
        raise ValueError(f"expected one literal Zig {name}")
    return json.loads(values[0])


def toolchain_version(setup_source):
    """Use the existing install owner's exact archive pin, not a minimum."""
    versions = set(re.findall(r"(?m)^\s*archive=zig-\S+?-(\d+\.\d+\.\d+[^\s]*)\s*$", setup_source))
    if len(versions) != 1:
        raise ValueError("expected one exact Zig release in the trusted setup action")
    return versions.pop()


def standard_names(expected_version, environment=None):
    """Bootstrap only: inherit errors from the exact trusted Zig std sources."""
    if environment is None:
        environment = subprocess.check_output(["zig", "env"], text=True, stderr=subprocess.PIPE)
    version = zig_setting(environment, "version")
    if version != expected_version:
        raise ValueError(f"bootstrap needs pinned Zig {expected_version}, found {version}")
    std = Path(zig_setting(environment, "std_dir"))
    paths = sorted(std.rglob("*.zig"))
    if not paths:
        raise ValueError(f"bootstrap found no Zig std sources in {std}")
    return {name for path in paths for name, _ in error_sites(production(lex(path.read_text())))}


def allowance_growth(root=ROOT, bootstrap_names=None):
    """The candidate cannot bless new pending names, even on first rollout.

    Tests may inject trusted external names without requiring a compiler. The
    production path reads the installed compiler only during the first rollout;
    once main owns pending, not even a std name can enlarge that exact tuple.
    """
    base = git(root, "merge-base", "HEAD", "origin/main")
    paths = git(root, "ls-tree", "-r", "--name-only", base, "--", "src").splitlines()
    trusted = (git(root, "show", f"{base}:{path}") for path in paths if inventory_path(path))
    inventory = {name for source in trusted for name, _ in error_sites(production(lex(source)))}
    before = trusted_pending(root, base)
    if before is None:
        before = inventory
        if bootstrap_names is None:
            version = toolchain_version(git(root, "show", f"{base}:.github/actions/setup/action.yml"))
            bootstrap_names = standard_names(version)
        before |= set(bootstrap_names)
    else:
        # A formerly broader pending tuple cannot bless new CLI references to
        # errors that only appeared in Host-internal owners on trusted main.
        before &= inventory
    current = pending_names((root / CATALOG).read_text())
    if current is None:
        raise ValueError("caller_error.zig: missing pending tuple")
    return [f"{CATALOG}: pending error {name} exceeds the trusted allowance"
            for name in sorted(current - before)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bootstrap-needed", action="store_true", help="print whether trusted main predates pending")
    args = parser.parse_args()
    try:
        if args.bootstrap_needed:
            print(str(needs_bootstrap()).lower())
            return 0
        failures = check(read_sources()) + allowance_growth()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"Caller error gate failed: {error}", file=sys.stderr)
        return 1
    if failures:
        print("Caller error gate failed:\n" + "\n".join(f"  {failure}" for failure in failures), file=sys.stderr)
        return 1
    print("Caller error catalog coverage and shrink-only pending inventory passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

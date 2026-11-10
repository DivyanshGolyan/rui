"""Release bookkeeping shared by the wire and Store format checks.

The wire version moves only past a release. Store versions instead append
one format per PR (D226), enforced by test_store_schema_version.py.
"""
import re
import subprocess

SCHEMA = "src/store/schema.zig"
VERSION = re.compile(r"^pub const schema_version: u32 = (\d+);$", re.MULTILINE)
# One bootstrap_digests row of src/store/schema.zig.
ROW = re.compile(r"\.\{ \.schema_version = (\d+), \.digest = 0x([0-9a-fA-F]+) \}")
MIGRATIONS = re.compile(r"^pub const migrations = \[_\]Migration\{", re.MULTILINE)
FROM = re.compile(r"\.from\s*=\s*(\d+)")


def bump_error(name, candidate, base, released):
    """Why candidate is not an allowed value of name, or None.

    A PR may raise the number to one past the last release. Once main holds
    an unreleased number, every PR shares it: nothing may go above main's.
    """
    if candidate < base:
        return f"{name} {candidate} goes back below main's {base}"
    allowed = base if base > released else released + 1
    if candidate <= allowed:
        return None
    if base > released:
        return (f"{name} {candidate} goes past main's unreleased {base}; "
                f"the last release has {released}, so reuse {base}")
    return f"{name} {candidate} skips past {allowed}, one past the last release's {released}"


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def released_tag(root):
    """The newest release tag, v0.S.N, as release.py names them."""
    tags = [tag for tag in git(root, "tag", "--list", "v0.*", "--sort=-v:refname").split()
            if re.fullmatch(r"v0\.\d+\.\d+", tag)]
    return tags[0] if tags else None


def main_base(root):
    """The merge base with origin/main, or None in a checkout without it."""
    if subprocess.run(["git", "-C", str(root), "rev-parse", "--verify", "-q", "origin/main"],
                      capture_output=True).returncode:
        return None
    return git(root, "merge-base", "HEAD", "origin/main").strip()


def digest_rows(source):
    """schema_version -> digest of each bootstrap_digests row."""
    return {int(version): int(digest, 16) for version, digest in ROW.findall(source)}


def drifted_row_fix(version, released, current):
    """How to repair a shipped Store version whose row changed after the release."""
    return (f"schema {version} shipped with digest 0x{released:016x}, but this revision's row {version} holds "
            f"0x{current:016x}: restore row {version} to 0x{released:016x}, set schema_version to {version + 1} "
            f"and append .{{ .schema_version = {version + 1}, .digest = 0x{current:016x} }}")


def schema_version(source):
    match = VERSION.search(source)
    if match is None:
        raise AssertionError(f"{SCHEMA} declares no schema_version")
    return int(match[1])


def migration_steps(source):
    """Each step of `migrations` as its `from` and its entry's source text.

    Splits the array literal at its top-level `.{` entries, skipping string
    literals and comments, and drops whitespace outside strings so that a
    reformat is no edit. A revision without the array has no steps.
    """
    match = MIGRATIONS.search(source)
    if match is None:
        return {}
    steps, depth, entry, position = {}, 0, [], match.end()
    while True:
        char = source[position]
        if char == '"':
            end = position + 1
            while source[end] != '"':
                end += 2 if source[end] == "\\" else 1
            entry.append(source[position:end + 1])
            position = end + 1
            continue
        if source.startswith("//", position):
            position = source.index("\n", position)
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            if depth == 0:
                return steps
            depth -= 1
        if depth > 0 or char == "}":
            if not char.isspace():
                entry.append(char)
        if char == "}" and depth == 0:
            text = "".join(entry).removesuffix(",")
            steps[int(FROM.search(text)[1])] = text
            entry = []
        position += 1

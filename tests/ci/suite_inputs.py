"""Conservative, trusted declarations for retained-native acceptance only.

Process/PTY/E2E/qualification gates are deliberately not reusable. The source
walker includes test scopes; the production import-cycle walker does not.
"""
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess

from import_architecture import TOKEN


SUITES = {
    "test": {"roots": ["src/tests.zig", "tests/integration/answer_renderer_allocation.zig"],
             "executables": ["test-tests", "rui-answer-renderer-allocation-test"],
             "environment": {"RUI_TEST_EXACT_INACTIVITY": "0"}},
    "test-full": {"roots": ["src/tests.zig"],
                  "executables": ["test-tests"],
                  "environment": {"RUI_TEST_EXACT_INACTIVITY": "1"}},
    "test-logic": {"roots": ["src/logic_tests.zig", "tests/integration/answer_renderer_allocation.zig"],
                   "executables": ["test-logic_tests", "rui-answer-renderer-allocation-test"],
                   "environment": {}},
}
# These aliases are configured in build.zig, which must match trusted policy.
# Foreign generated modules and their complete package/build inputs are bound
# separately; the AnswerRenderer alias names first-party source.
ALIASES = {"AnswerRenderer": "src/AnswerRenderer.zig"}
FOREIGN = {"std", "builtin", "posix", "sqlite", "curl", "transport_options",
           "vaxis", "terminal_width", "terminal_unicode"}
# Only these reviewed lint loops expand literal file lists. Changing a loop
# requires reviewing its expansion, even after the new source reaches main.
DYNAMIC_EMBEDS = {
    "src/logic_tests.zig": "c40eaf0047dade839fc0af1c0a812b62b538a83509fb0954a9fd3b5b13f9b597",
    "src/socket_fixture.zig": "02be8f3f2defeefdca57d5aeabc992c2f8d1654f048bfc1276fd737628ab5837",
}
POLICY = ("tests/ci/suite_inputs.py", "tests/ci/import_architecture.py",
          "tests/ci/evidence.py", "tests/ci/run_selected.py", "tests/ci/build_artifact.py",
          "build.zig", "build.zig.zon", ".github/workflows/check.yml",
          ".github/actions/setup/action.yml")
# The declarations above were audited against this build graph. A new build
# graph must update/review its declarations, not silently acquire old authority
# merely because both it and the candidate manifest have reached main.
BUILD_OWNER = "e07081ff14f6cf382df1e3b601b88dad242b5d68b69bb0e104fd4043f0880bb1"


def git(*args, binary=False):
    return subprocess.check_output(["git", *args], text=not binary, stderr=subprocess.PIPE)


class Source:
    def __init__(self, revision):
        self.revision = revision
        self.entries = {}
        for entry in git("ls-tree", "-rz", revision, binary=True).split(b"\0"):
            if entry:
                metadata, path = entry.split(b"\t", 1)
                mode, kind, _ = metadata.decode().split()
                if kind != "blob" or mode not in {"100644", "100755"}:
                    raise ValueError("Suite inputs require regular tracked files")
                self.entries[path.decode()] = mode
        self.contents = {}

    def read(self, path):
        if path not in self.entries:
            raise ValueError(f"Undeclared or missing tracked input: {path}")
        if path not in self.contents:
            self.contents[path] = git("show", f"{self.revision}:{path}", binary=True)
        return self.contents[path]


def trusted_policy(source, trusted):
    for path in POLICY:
        if source.read(path) != trusted.read(path):
            raise ValueError(f"Suite policy differs from trusted main: {path}")


def source_inputs(targets, part, revision="HEAD", trusted_revision=None):
    if len(targets) != 1 or part != "all" or set(targets) - SUITES.keys():
        raise ValueError("Suite requires fresh execution; no complete retained-input declaration")
    source = Source(revision)
    trusted_revision = trusted_revision or git("merge-base", "HEAD", "origin/main").strip()
    trusted = Source(trusted_revision)
    trusted_policy(source, trusted)
    if hashlib.sha256(source.read("build.zig")).hexdigest() != BUILD_OWNER:
        raise ValueError("Build graph has no reviewed suite-input declaration")
    declared = {target: dict(SUITES[target], options={"optimize": "ReleaseSafe", "cpu": "baseline",
                                                    "target": "native", "test_filter": None})
                for target in sorted(targets)}
    # All source-side non-Zig inputs and test fixtures are conservatively included:
    # this covers bootstrap, patches, native C/includes, runner scripts, fixtures,
    # dependency pins and newly added fixture data, not just import spellings.
    files = {path for path in source.entries
             if path.startswith(("tests/", ".github/"))
             or (path.startswith("src/") and not path.endswith(".zig"))
             or path in {"build.zig", "build.zig.zon", "install.sh", ".agents/setup", ".gitattributes"}}
    pending = [(path, path) for suite in declared.values() for path in suite["roots"]]
    visited = set()
    while pending:
        path, root = pending.pop()
        if (path, root) in visited:
            continue
        visited.add((path, root))
        files.add(path)
        text = source.read(path).decode()
        tokens = [m.group() for m in TOKEN.finditer(text)
                  if not m.group().startswith(("//", "\\\\"))]
        for index, token in enumerate(tokens):
            if token not in {"@import", "@embedFile"}:
                continue
            arguments = tokens[index + 1:index + 5]
            if len(arguments) < 3 or arguments[0] != "(":
                raise ValueError(f"Unrecognized dependency syntax: {path}")
            if not arguments[1].startswith('"') or arguments[2] != ")":
                # Two existing lint loops embed their declared literal file sets.
                # Their source must itself match the reviewed trusted version;
                # any change or other computed dependency forces fresh execution.
                if (token != "@embedFile" or hashlib.sha256(source.read(path)).hexdigest() != DYNAMIC_EMBEDS.get(path)
                        or source.read(path) != trusted.read(path)):
                    raise ValueError(f"Incomplete computed dependency closure: {path}")
                for literal in tokens:
                    if literal.startswith('"') and literal.endswith('.zig"') and literal != '".zig"':
                        dependency = str(PurePosixPath(path).parent / json.loads(literal))
                        source.read(dependency)
                        files.add(dependency)
                continue
            imported = json.loads(arguments[1])
            if token == "@import" and imported in FOREIGN:
                continue
            if token == "@import" and imported == "root":
                dependency = root
            elif token == "@import" and imported in ALIASES:
                dependency = ALIASES[imported]
            elif token == "@import" and not imported.endswith(".zig"):
                raise ValueError(f"Undeclared module: {imported} in {path}")
            else:
                dependency = str(PurePosixPath(path).parent / imported)
            # Normalize relative imports, but never permit an input outside Git.
            parts = []
            for component in PurePosixPath(dependency).parts:
                if component == "..":
                    if not parts:
                        raise ValueError("Dependency escapes repository")
                    parts.pop()
                elif component not in {".", "/"}:
                    parts.append(component)
            if PurePosixPath(dependency).is_absolute():
                raise ValueError("Absolute dependency")
            dependency = "/".join(parts)
            source.read(dependency)
            files.add(dependency)
            if token == "@import":
                pending.append((dependency, root))
    if revision == "HEAD":
        for name in files:
            actual = Path(name)
            if (actual.is_symlink() or actual.read_bytes() != source.read(name)
                    or bool(actual.stat().st_mode & 0o111) != (source.entries[name] == "100755")):
                raise ValueError(f"Working input differs from committed input: {name}")
    return {"declarations": declared, "files": {
        path: {"sha256": hashlib.sha256(source.read(path)).hexdigest(), "mode": source.entries[path]}
        for path in sorted(files)}}

#!/usr/bin/env python3
"""Ratchet Session policy out of clients and into the Host (#1620).

This is a source check, not call-graph or semantic analysis. Classifier checks
cover known function names; renamed or differently expressed policy can escape.
The import inventory shares the production graph used by CI selection.
"""
import ast
from pathlib import Path
import sys

from caller_errors import close_brace, git, lex, production
from host_settings_locality import tokens_for, unquote
from select_tests import Graph, tree_graph

ROOT = Path(__file__).resolve().parents[2]
GATE = "tests/ci/client_locality.py"
MESSAGE = ("a rule every viewer must agree on belongs to the Host (#1620); "
           "serve it from the Host and read it here")
DEFAULT_IMPORT = "imports product_defaults.zig"
CLASSIFIER = "classifies Session work"
TS_DEFAULT = "hard-codes a Session default"
ORIGIN_FACT = "re-derives a Message origin or a failure class"
ISSUES = {DEFAULT_IMPORT: "#1621", CLASSIFIER: "#1622", TS_DEFAULT: "#1621", ORIGIN_FACT: "#2282"}

# Shared dependencies can be in graph.host even though these client entry points
# themselves must remain covered. Keep the requested minimum inventory together.
REQUIRED_SOURCES = (
    "src/cli.zig", "src/cli_args.zig", "src/client.zig",
    "src/configure_input.zig", "src/new_session_selection.zig", "src/Overview.zig",
    "src/overview_view.zig", "src/OverviewLines.zig", "src/SessionFrontend.zig",
    "src/SessionSubmission.zig", "src/SessionInput.zig", "src/session_view.zig",
    "src/session_keys.zig", "src/app_input.zig", "src/attention.zig", "src/Root.zig",
    "src/chat_info.zig", "src/SignIn.zig",
)

# Each pair is existing policy, with the issue responsible for removing it.
# New pairs are forbidden once this file exists at the trusted review base.
ALLOWED = {
    ("src/HostLifecycle.zig", "imports product_defaults.zig"): "#1621",
    ("src/SignIn.zig", "imports product_defaults.zig"): "#1621",
    ("src/app_settings.zig", "imports product_defaults.zig"): "#1621",
    ("src/cli.zig", "imports product_defaults.zig"): "#1621",
    ("src/cli_args.zig", "imports product_defaults.zig"): "#1621",
    ("src/new_session_selection.zig", "imports product_defaults.zig"): "#1621",
    ("src/status_page.zig", "imports product_defaults.zig"): "#1621",
}

WORK_KINDS = frozenset("idle pending working retrying bash approval stopping finished failed stopped".split())
CLASSIFIERS = frozenset(("orderClass", "needsDecision", "Status.of", "Attention.of", "stoppable"))
DEFAULT_FIELDS = frozenset(("tools", "loadedTools", "loaded_tools", "permissionMode", "permission_mode",
                            "effort", "reasoningEffort", "reasoning_effort"))


def source_graph(root):
    if root.resolve() == ROOT:
        return tree_graph()
    names = [path.relative_to(root).as_posix() for directory in ("src", "tests/integration")
             for path in (root / directory).rglob("*.zig")]
    return Graph(names, lambda name: (root / name).read_text())


def surfaces(root=ROOT):
    graph = source_graph(root)
    reached = graph.closure(graph.production, ("src/Overview.zig", "src/cli.zig"))
    names = (reached - graph.host - graph.tests) | set(REQUIRED_SOURCES)
    zig = {root / name for name in names if name.endswith(".zig")}
    ts_root = root / "clients/ts/src"
    ts = {path for path in ts_root.rglob("*") if path != ts_root / "wire.ts"}
    return sorted(path for path in zig | ts if path.is_file())


def test_file(relative):
    path = Path(relative)
    return (path.stem.endswith((".test", ".spec"))
            or bool(set(path.parts) & {"test", "tests", "__tests__"}))


def classifier_sites(tokens, typescript):
    names = [token.text for token in tokens]
    containers, stack = {}, []
    for i, name in enumerate(names):
        if names[i:i + 2] == ["const", "Attention"] or names[i:i + 2] == ["const", "Status"]:
            if names[i + 2:i + 4] in (["=", "struct"], ["=", "enum"]):
                containers[names.index("{", i + 4)] = names[i + 1]
        if name == "{":
            stack.append(containers.get(i))
        elif name == "}":
            if stack:
                stack.pop()
        elif name == ("function" if typescript else "fn") and i + 2 < len(names):
            function = names[i + 1]
            owner = next((scope for scope in reversed(stack) if scope), None)
            qualified = owner + "." + function if owner and function == "of" else function
            if qualified not in ({"modelCallCurrent"} if typescript else CLASSIFIERS):
                continue
            # These known signatures have no inline struct or error-set return
            # types, so the first brace following their parameters is the body.
            start = names.index("{", i + 2)
            end = close_brace(tokens, start)
            body = names[start + 1:end]
            local_kind = any((unquote(value) in WORK_KINDS if typescript else
                              value in WORK_KINDS and j > 0 and body[j - 1] == ".")
                             for j, value in enumerate(body))
            local_enablement = qualified == "stoppable" and "rules" in body and "stoppable" in body
            if local_kind or local_enablement:
                yield tokens[i].line, CLASSIFIER


def default_sites(tokens):
    names = [token.text for token in tokens]
    type_scopes, stack = set(), []
    for i, name in enumerate(names):
        if name in ("interface", "type") and i + 1 < len(names):
            end = next((j for j in range(i + 1, len(names)) if names[j] in ("{", ";")), None)
            if end is not None and names[end] == "{":
                type_scopes.add(end)
        # An inline object after a parameter/variable annotation is a type,
        # just like an interface body. An object property value is not.
        if name == ":" and names[i + 1:i + 2] == ["{"]:
            annotation = (bool(stack and stack[-1][0] == "(")
                          or names[max(0, i - 2):i - 1] in (["const"], ["let"], ["var"])
                          or names[i - 1:i] == [")"])
            if annotation:
                type_scopes.add(i + 1)
        if name in ("as", "satisfies") and names[i + 1:i + 2] == ["{"]:
            type_scopes.add(i + 1)
        if name in ("{", "(", "["):
            stack.append((name, i in type_scopes or bool(stack and stack[-1][1])))
        elif name in ("}", ")", "]"):
            if stack:
                stack.pop()
        if stack and stack[-1][1]:
            continue
        field = unquote(name) or name
        if field not in DEFAULT_FIELDS:
            continue
        object_field = (i > 0 and names[i - 1] in ("{", ",")
                        and bool(stack and stack[-1][0] == "{"))
        # Object fields, variable/parameter defaults and nullish/boolean
        # fallbacks. Type declarations describe accepted values, not defaults.
        j, ternary = i + 1, False
        while j < len(names) and names[j] not in (",", ";", "}"):
            conditional = (names[j] == "?" and names[j + 1:j + 2] not in (["?"], ["."])
                           and names[j - 1] != "?")
            ternary = ternary or conditional
            assignment = (names[j] == "=" and names[j - 1] not in ("=", "!", "<", ">")
                          and names[j + 1:j + 2] != ["="])
            separator = ((names[j] == ":" and (object_field or ternary)) or assignment or conditional
                         or names[j:j + 2] in (["?", "?"], ["|", "|"]))
            width = 2 if names[j:j + 2] in (["?", "?"], ["|", "|"]) else 1
            if separator and j + width < len(names):
                value = names[j + width]
                literal = unquote(value)
                array = False
                if value == "[" and field in ("tools", "loadedTools", "loaded_tools"):
                    end = next((k for k in range(j + width + 1, len(names)) if names[k] == "]"), None)
                    array = end is not None and all(part == "," or unquote(part) is not None
                                                    for part in names[j + width + 1:end])
                hardcoded = array or literal is not None or value == "null"
                if hardcoded:
                    yield tokens[i].line, TS_DEFAULT
                    break
            if names[j] in ("{", ")"):
                break
            j += 1


def origin_fact_sites(tokens):
    """Who admitted a Message is the Host's `origin`, and a failure's class is the Host's to name.

    A client that reads `source_action` rebuilds the origin from a field the wire no longer carries; one that
    calls `failure_class.of` classifies a code the Host already classified.
    """
    names = [token.text for token in tokens]
    for i, name in enumerate(names):
        if name == "source_action":
            yield tokens[i].line, ORIGIN_FACT
        elif names[i:i + 3] == ["failure_class", ".", "of"]:
            yield tokens[i].line, ORIGIN_FACT
        elif (names[i:i + 2] == ["@import", "("] and unquote(names[i + 2]) == "failure_class.zig"
              and names[i + 3:i + 6] == [")", ".", "of"]):
            yield tokens[i].line, ORIGIN_FACT


def findings(source, relative):
    ts = relative.startswith("clients/ts/src/")
    if ts and test_file(relative):
        return []
    tokens = tokens_for(source, True) if ts else production(lex(source))
    names = [token.text for token in tokens]
    found = []
    if not ts:
        for i in range(len(tokens) - 3):
            if names[i:i + 2] == ["@import", "("] and names[i + 3] == ")":
                imported = unquote(names[i + 2])
                if imported is not None and Path(imported).name == "product_defaults.zig":
                    found.append((tokens[i].line, DEFAULT_IMPORT))
    found.extend(classifier_sites(tokens, ts))
    found.extend(origin_fact_sites(tokens))
    if ts:
        found.extend(default_sites(tokens))
    return sorted(set(found))


def scan(source, relative="src/cli.zig", allowed=frozenset()):
    return [f"{relative}:{line}: {rule}: {MESSAGE}"
            for line, rule in findings(source, relative) if (relative, rule) not in allowed]


def violations(root=ROOT, allowed=ALLOWED):
    return [hit for path in surfaces(root)
            for hit in scan(path.read_text(), path.relative_to(root).as_posix(), allowed)]


def stale_allowances(root=ROOT, allowed=ALLOWED):
    actual = {(path.relative_to(root).as_posix(), rule) for path in surfaces(root)
              for _, rule in findings(path.read_text(), path.relative_to(root).as_posix())}
    return [f"{file}: remove stale allowance for {rule} ({allowed[file, rule]})"
            for file, rule in sorted(allowed.keys() - actual)]


def allowed_entries(source):
    declarations = [node.value for node in ast.parse(source).body if isinstance(node, ast.Assign)
                    and any(isinstance(target, ast.Name) and target.id == "ALLOWED" for target in node.targets)]
    if len(declarations) != 1:
        raise ValueError("client_locality.py requires one literal ALLOWED mapping")
    entries = ast.literal_eval(declarations[0])
    if not isinstance(entries, dict):
        raise ValueError("client_locality.py ALLOWED must be a mapping")
    for pair, issue in entries.items():
        if (not isinstance(pair, tuple) or len(pair) != 2 or not all(isinstance(part, str) for part in pair)
                or pair[1] not in ISSUES or issue != ISSUES[pair[1]]):
            raise ValueError(f"client_locality.py allowance needs its removal issue: {pair!r}")
    return entries


def allowance_growth(root=ROOT):
    base = git(root, "merge-base", "HEAD", "origin/main")
    current = allowed_entries((root / GATE).read_text())
    if not git(root, "ls-tree", "--name-only", base, "--", GATE):
        return []
    trusted = allowed_entries(git(root, "show", f"{base}:{GATE}"))
    return [f"{file}: {rule}: allowance exceeds the trusted review base: {MESSAGE}"
            for file, rule in sorted(current.keys() - trusted.keys())]


def main():
    found = violations() + stale_allowances() + allowance_growth()
    if found:
        print("\n".join(found), file=sys.stderr)
    return int(bool(found))


if __name__ == "__main__":
    sys.exit(main())

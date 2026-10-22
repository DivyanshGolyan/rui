#!/usr/bin/env python3
"""Reproduce pinned src inventory and lexical import graph; no runtime effects.

Run from repository root with Zig 0.17.0:
  python3 .amp/modularity/audit.py
Only .amp/modularity generated evidence is written. Compiler output is temporary.
"""
import collections
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tempfile

PIN = "068b1d0ce521b7a65fba118739fc985860cdd80f"
OUT = pathlib.Path(".amp/modularity")


def git(*args):
    return subprocess.check_output(["git", *args])


def scan(source, tokens):
    """Track test-body and comptime-block lexical scope; never infer reachability."""
    stack, pending, scopes, edges, spans = [], None, [], [], []
    for index, (tag, start, end) in enumerate(tokens):
        if tag == "keyword_test":
            pending = ("test", start)
        elif tag == "keyword_comptime" and index + 1 < len(tokens) and tokens[index + 1][0] == "l_brace":
            pending = ("comptime", start)
        elif tag == "l_brace":
            stack.append(pending)
            if pending:
                scopes.append(pending[0])
            pending = None
        elif tag == "r_brace":
            block = stack.pop()
            if block:
                scopes.pop()
                if block[0] == "test":
                    spans.append((block[1], end))
        if tag != "builtin" or source[start:end] != b"@import":
            continue
        tail = tokens[index + 1:index + 4]
        literal = len(tail) == 3 and [t[0] for t in tail] == ["l_paren", "string_literal", "r_paren"]
        name = source[tail[1][1] + 1:tail[1][2] - 1].decode() if literal else None
        # Current tree uses only unescaped literal import names; fail closed if that changes.
        if name is not None and "\\" in name:
            raise ValueError("Escaped import name requires explicit decoder")
        edges.append(dict(line=source[:start].count(b"\n") + 1, import_name=name,
                          context="test_body" if "test" in scopes else "non_test_lexical",
                          comptime_block="comptime" in scopes, dynamic=not literal))
    assert not stack
    return edges, spans


def scc(nodes, pairs):
    adjacency = {node: set() for node in nodes}
    for source, target in pairs:
        adjacency[source].add(target)
    index, low, active, seen, result = {}, {}, [], set(), []

    def visit(node):
        index[node] = low[node] = len(index)
        active.append(node)
        seen.add(node)
        for target in sorted(adjacency[node]):
            if target not in index:
                visit(target)
                low[node] = min(low[node], low[target])
            elif target in seen:
                low[node] = min(low[node], index[target])
        if low[node] == index[node]:
            group = []
            while True:
                value = active.pop()
                seen.remove(value)
                group.append(value)
                if value == node:
                    break
            if len(group) > 1 or node in adjacency[node]:
                result.append(sorted(group))
    for node in sorted(nodes):
        if node not in index:
            visit(node)
    return sorted(result)


def token_rows(binary, path):
    raw = subprocess.check_output([binary, str(path)], text=True)
    return [(tag, int(start), int(end)) for tag, start, end in (line.split("\t") for line in raw.splitlines())]


def controls(binary, temp):
    # Competing wrong extractors: regexes count the first three false imports;
    # context-blind scanners cannot separate test and comptime imports.
    source = rb'''// @import("comment.zig")
const quoted = "@import(\"quoted.zig\")";
const multiline =
    \\@import("multiline.zig")
;
const ordinary = @import("std");
test "scope" { _ = @import("test.zig"); }
comptime { _ = @import("compile.zig"); }
const selected = "std";
const computed = @import(selected);
'''
    path = pathlib.Path(temp) / "control.zig"
    path.write_bytes(source)
    edges, spans = scan(source, token_rows(binary, path))
    assert [(e["import_name"], e["context"], e["comptime_block"]) for e in edges] == [
        ("std", "non_test_lexical", False), ("test.zig", "test_body", False),
        ("compile.zig", "non_test_lexical", True), (None, "non_test_lexical", False)]
    assert edges[-1]["dynamic"]
    assert len(spans) == 1
    assert scc(["a", "b", "c"], [("a", "b"), ("b", "a"), ("c", "a")]) == [["a", "b"]]
    assert scc(["a", "b", "c"], [("a", "b"), ("b", "c")]) == []
    print("PASS: comments, quoted/multiline strings, test/comptime/dynamic context and cyclic/acyclic controls")


def proposals():
    # Evaluate the actual pinned selector, not a hand-maintained gate guess.
    for path in ("build.zig", "tests/ci/select_tests.py", "tests/ci/strict_paths.py"):
        assert pathlib.Path(path).read_bytes() == git("show", f"{PIN}:{path}")
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(pathlib.Path("tests/ci").resolve()))
    import select_tests
    from strict_paths import strict
    available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', pathlib.Path("build.zig").read_text()))
    paths = {
        "R1": ["src/model_capability.zig", "src/provider_selection.zig", "src/preferences.zig", "src/new_session_selection.zig", "src/cli.zig"],
        "R2": ["src/provider.zig"],
        "R3": ["src/named_scratch.zig", "src/platform.zig", "src/protocol.zig", "src/model_adapter.zig", "src/provider.zig", "src/server.zig", "src/bash.zig", "src/store.zig"],
        "R4": ["src/provider_output.zig", "src/output_format.zig", "src/tools.zig", "src/store.zig"],
        "R5_exploratory": ["src/request_encoding.zig", "src/model_adapter.zig"],
    }
    return {name: dict(paths=changed, strict_paths=strict(changed), **select_tests.select(changed, "review", available))
            for name, changed in paths.items()}


def main():
    # A report commit may be a descendant of PIN. Verify the actual audited
    # source rather than forcing HEAD to remain the pre-report commit.
    files = sorted(p.decode() for p in git("ls-tree", "-r", "--name-only", PIN, "src/").splitlines())
    assert sorted(str(p) for p in pathlib.Path("src").rglob("*") if p.is_file()) == files, "Source inventory differs from pin"
    inventory, imports = [], []
    with tempfile.TemporaryDirectory(prefix="rui-modularity-") as temp:
        binary = str(pathlib.Path(temp) / "tokenize")
        subprocess.run(["zig", "build-exe", str(OUT / "tokenize.zig"), "-O", "ReleaseSafe", "-femit-bin=" + binary], check=True)
        controls(binary, temp)
        for path in files:
            source = git("show", f"{PIN}:{path}")
            assert pathlib.Path(path).read_bytes() == source, f"Unpinned worktree: {path}"
            row = dict(path=path, bytes=len(source), lines=source.count(b"\n"), sha256=hashlib.sha256(source).hexdigest(),
                       extension=pathlib.Path(path).suffix, test_body_lines=0, test_declarations=0)
            if path.endswith(".zig"):
                tokens = token_rows(binary, path)
                edges, spans = scan(source, tokens)
                row["test_body_lines"] = sum(source[start:end].count(b"\n") + 1 for start, end in spans)
                row["test_declarations"] = len(spans)
                for edge in edges:
                    edge["source"] = path
                    name = edge["import_name"]
                    if name is None:
                        kind, target = "dynamic", None
                    elif name in {"std", "builtin", "root"}:
                        kind, target = name, name
                    elif name.endswith(".zig") or "/" in name:
                        target = str(pathlib.PurePosixPath(path).parent / name)
                        kind = "local" if target in files else "unresolved_local"
                    else:
                        kind, target = "package_or_generated", name
                    edge.update(kind=kind, target=target)
                    imports.append(edge)
            inventory.append(row)
    nodes = [row["path"] for row in inventory if row["extension"] == ".zig"]
    graphs = {}
    for name, edges in (("all_lexical", imports), ("outside_test_bodies", [e for e in imports if e["context"] != "test_body"])):
        pairs = sorted({(e["source"], e["target"]) for e in edges if e["kind"] == "local"})
        fanin, fanout = collections.Counter(t for s, t in pairs), collections.Counter(s for s, t in pairs)
        graphs[name] = dict(unique_local_edges=len(pairs), cycles=scc(nodes, pairs),
                            fan_in=sorted(fanin.items(), key=lambda x: (-x[1], x[0])),
                            fan_out=sorted(fanout.items(), key=lambda x: (-x[1], x[0])))
    summary = dict(pin=PIN, files=len(files), lines=sum(r["lines"] for r in inventory), bytes=sum(r["bytes"] for r in inventory),
                   extensions=dict(collections.Counter(r["extension"] for r in inventory)), imports=len(imports),
                   import_kinds=dict(collections.Counter(e["kind"] for e in imports)), graphs=graphs,
                   zig_version=subprocess.check_output(["zig", "version"], text=True).strip())
    for name, value in (("inventory.json", inventory), ("edges.json", imports), ("graph.json", summary), ("selection.json", proposals())):
        (OUT / name).write_text(json.dumps(value, indent=2) + "\n")
    lines = ["digraph src {", '  rankdir="LR";']
    for edge in imports:
        if edge["kind"] == "local":
            style = "dashed" if edge["context"] == "test_body" else "solid"
            lines.append(f'  "{edge["source"]}" -> "{edge["target"]}" [style={style}, label="{edge["line"]}"];')
    (OUT / "imports.dot").write_text("\n".join(lines + ["}", ""]))
    print(json.dumps({k: v for k, v in summary.items() if k != "graphs"}, indent=2))
    for name, graph in graphs.items():
        print(name, "edges:", graph["unique_local_edges"], "SCCs:", graph["cycles"])


if __name__ == "__main__":
    main()

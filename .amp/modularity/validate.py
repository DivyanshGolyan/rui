#!/usr/bin/env python3
"""Check the delivered map, source anchors and graph against pinned blobs."""
import collections
import hashlib
import json
import pathlib
import re
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import audit

BASE = pathlib.Path(".amp/modularity")
PIN = audit.PIN


def load(name):
    return json.loads((BASE / name).read_text())


def pinned(path):
    return subprocess.check_output(["git", "show", f"{PIN}:{path}"])


def independent_cycles(nodes, pairs):
    adjacency = {node: set() for node in nodes}
    for source, target in pairs:
        adjacency[source].add(target)
    reached = {}
    for source in nodes:
        seen, pending = set(), list(adjacency[source])
        while pending:
            target = pending.pop()
            if target not in seen:
                seen.add(target)
                pending.extend(adjacency[target])
        reached[source] = seen
    return sorted({tuple(sorted(target for target in nodes
                                if target == source or target in reached[source] and source in reached[target]))
                   for source in nodes if source in reached[source]})


def main():
    inventory, edges, graph = load("inventory.json"), load("edges.json"), load("graph.json")
    by_path = {row["path"]: row for row in inventory}
    actual_paths = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", PIN, "src/"], text=True).splitlines()
    assert sorted(by_path) == actual_paths and len(by_path) == len(inventory) == 85
    for path, row in by_path.items():
        source = pinned(path)
        assert row["bytes"] == len(source) and row["lines"] == source.count(b"\n")
        assert row["sha256"] == hashlib.sha256(source).hexdigest()
        assert pathlib.Path(path).read_bytes() == source
    assert graph["pin"] == PIN
    assert (graph["lines"], graph["bytes"]) == (sum(r["lines"] for r in inventory), sum(r["bytes"] for r in inventory))
    assert graph["extensions"] == dict(collections.Counter(r["extension"] for r in inventory))
    assert graph["imports"] == len(edges) == 425
    assert graph["import_kinds"] == dict(collections.Counter(e["kind"] for e in edges))
    assert collections.Counter(e["target"] for e in edges if e["kind"] == "package_or_generated") == {
        "posix": 12, "curl": 2, "sqlite": 1, "evaluator_native": 1,
        "transport_options": 1, "vaxis": 6, "terminal_unicode": 2, "terminal_width": 2}
    assert not any(e["dynamic"] or e["kind"] in {"root", "unresolved_local"} for e in edges)
    for edge in edges:
        line = pinned(edge["source"]).splitlines()[edge["line"] - 1]
        assert b"@import" in line and ('"' + edge["import_name"] + '"').encode() in line
        if edge["kind"] == "local":
            assert edge["target"] in by_path
    nodes = [p for p in by_path if p.endswith(".zig")]
    for name, subset in (("all_lexical", edges), ("outside_test_bodies", [e for e in edges if e["context"] != "test_body"])):
        pairs = {(e["source"], e["target"]) for e in subset if e["kind"] == "local"}
        measured = graph["graphs"][name]
        assert measured["unique_local_edges"] == len(pairs)
        assert [list(group) for group in independent_cycles(nodes, pairs)] == measured["cycles"]
        assert dict(measured["fan_in"]) == dict(collections.Counter(t for s, t in pairs))
        assert dict(measured["fan_out"]) == dict(collections.Counter(s for s, t in pairs))
    assert load("selection.json") == audit.proposals()
    report = (BASE / "REPORT.md").read_text()
    rows = re.findall(r"^\| `(src/[^`]+)` \| (\d+) \| (.+) \|$", report, re.M)
    assert len(rows) == len(by_path), "Map omitted or duplicated a file"
    assert {path: int(lines) for path, lines, description in rows} == {p: r["lines"] for p, r in by_path.items()}
    assert len({p for p, _, _ in rows}) == len(rows)
    map_sections = re.split(r"^### 2\.[1-4].*$", report, flags=re.M)[1:]
    assert [len(re.findall(r"^\| `src/", section.split("\n## ")[0], re.M)) for section in map_sections] == [62, 9, 7, 7]
    references = re.findall(r"((?:src/)?[A-Za-z_][\w/.-]*\.(?:zig|md|c|h)):(\d+(?:[–,-]\d+)*)", report)
    for path, locations in references:
        if path != "build.zig" and not path.startswith("src/") and "/" not in path and path.endswith(".zig"):
            path = "src/" + path
        line_count = len(pinned(path).splitlines())
        assert all(1 <= int(n) <= line_count for n in re.split(r"[–,-]", locations)), (path, locations)
    links = re.findall(r"\]\(([^)]+)\)", report)
    for link in links:
        if link.startswith("https://github.com/"):
            assert f"/blob/{PIN}/" in link or link.endswith("/commit/" + PIN)
            if "#L" in link:
                path, anchor = link.split(f"/blob/{PIN}/", 1)[1].split("#", 1)
                assert all(int(n) <= len(pinned(path).splitlines()) for n in re.findall(r"L(\d+)", anchor))
        else:
            assert (BASE / link).is_file(), link
    # High-consequence claims also get source-content anchors, not just valid
    # line numbers. These do not substitute for the report's ownership judgment.
    anchors = {
        ("src/provider_selection.zig", 23): b'@import("model_capability.zig").capability(readiness)',
        ("src/model_capability.zig", 3): b'@import("provider_selection.zig")',
        ("src/store.zig", 396): b'AttemptBinding = attempt.AttemptBinding',
        ("src/store.zig", 5998): b'provider_output.inspectCall',
        ("src/store.zig", 6000): b'tool_catalog.classifyCall',
        ("src/store.zig", 1409): b'@compileError("test-only Store fixture")',
        ("src/platform.zig", 254): b'"request-"',
        ("src/model_adapter.zig", 398): b'pub fn maxWindow',
        ("src/cli.zig", 891): b'TerminalEditor.readLine',
        ("src/bash.zig", 996): b'"{s}-{d}-{d}.tmp"',
        ("src/store.zig", 1262): b'testing_content_work: if (@import("builtin").is_test)',
        ("src/provider.zig", 59): b'return .init(io, file, secondary_file, name, budget, charged, removal)',
        ("src/model_adapter.zig", 334): b'return .init(io, file, secondary_file, name, budget, charged, removal)',
    }
    for (path, line), value in anchors.items():
        assert value in pinned(path).splitlines()[line - 1], (path, line)
    print("PASS: 85/85 map rows, pinned sizes/hashes, 425 import anchors, both SCC/fan graphs, selectors, references and decisive source anchors")


if __name__ == "__main__":
    main()

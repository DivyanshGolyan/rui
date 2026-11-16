#!/usr/bin/env python3
"""Require source sketches and embedded screen evidence for terminal UI changes."""
import argparse
from functools import cache
import io
import os
import re
import subprocess
import sys
import tarfile

from select_tests import Graph, STACK_FRAMES_GATE, changed_paths, tree_graph


def summary_sketch(body):
    """Whether Summary contains a nonempty, closed Markdown code fence."""
    summary, content = False, False
    fence = None
    for line in body.splitlines():
        if fence is not None:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + r"{%d,}[ \t]*" % len(fence), line):
                if summary and content:
                    return True
                fence = None
            elif line.strip():
                content = True
            continue
        if opened := re.match(r"^ {0,3}(`{3,}|~{3,})", line):
            fence, content = opened[1], False
        elif heading := re.fullmatch(r" {0,3}(#{1,2})[ \t]+(.+?)[ \t]*", line):
            summary = heading[1] == "##" and heading[2] == "Summary"
    return False


def ui_paths(graph):
    # build/product.zig builds cli.zig, whose full-screen entry is Overview.
    # Overview owns TerminalApp, Root and SessionScreen; production edges omit
    # test-only imports. Shared Host dependencies are deliberately excluded.
    return graph.closure(graph.production, ["src/Overview.zig"]) - graph.host - graph.tests


@cache
def revision_ui_paths(revision):
    """Also classify removed UI files using the base tree, through the same graph owner."""
    archive = subprocess.check_output(["git", "archive", revision, "src", "tests/integration", STACK_FRAMES_GATE])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
        sources = {entry.name: tree.extractfile(entry).read() for entry in tree if entry.isfile()}
    return ui_paths(Graph(sources, lambda name: sources[name].decode()))


def screen_evidence(body):
    # A plain link to an image is not an embed. Ignore examples in fences and
    # comments, so the reviewer actually sees the claimed evidence.
    visible = re.sub(r"<!--.*?-->", "", body, flags=re.S)
    lines, fence = [], None
    for line in visible.splitlines():
        if fence:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + r"{%d,}[ \t]*" % len(fence), line):
                fence = None
        elif opened := re.match(r"^ {0,3}(`{3,}|~{3,})", line):
            fence = opened[1]
        else:
            lines.append(line)
    visible = "\n".join(lines)
    if re.search(r"^No screen change:[ \t]*\S[^\n]*$", visible, re.M):
        return True
    return bool(re.search(r"!\[[^\]\n]*\]\(\s*[^\s)]+[^\n]*\)|!\[[^\]\n]*\]\[[^\]\n]*\]"
                          r"|<img\b|<video\b|https://github\.com/user-attachments/[^\s<>)]+",
                          visible, re.I))


def refusal(changed_paths, body, *, base=None) -> str | None:
    if any(path.startswith("src/") for path in changed_paths) and not (
            re.search(r"^##\s+Shape\s*$", body, re.M) or summary_sketch(body)):
        return "PRs changing src/ need a nonempty fenced sketch in ## Summary or a legacy ## Shape section (CODING_STANDARDS.md#shape-before-code)."
    paths = set(changed_paths)
    if not any(path.startswith("src/") for path in paths) and ".claude/skills/verify-rui/scripts/frames.json" not in paths:
        return None
    ui = ui_paths(tree_graph())
    if base is not None and any(path.startswith("src/") for path in paths):
        ui |= revision_ui_paths(base)
    if paths & (ui | {".claude/skills/verify-rui/scripts/frames.json"}) and not screen_evidence(body):
        return ("UI PRs need an embedded image or video, or a line 'No screen change: <reason>'. "
                "Run verify-rui frames HEAD --before BASE, then verify-rui publish DIR and paste its ## Screens block into the PR body.")
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", nargs="?", default=os.environ.get("BASE"))
    args = parser.parse_args()
    if not args.base:
        parser.error("provide BASE as an argument or environment variable")
    paths, base = changed_paths(args.base, "HEAD")
    reason = refusal(paths, os.environ.get("PR_BODY", ""), base=base)
    if reason:
        print(reason, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

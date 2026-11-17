#!/usr/bin/env python3
"""Check PR shape and screen evidence for terminal UI changes."""
import argparse
from functools import cache
import io
import os
import re
import subprocess
import sys
import tarfile

from conflict_alert import github


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
    from select_tests import Graph, STACK_FRAMES_GATE

    archive = subprocess.check_output(["git", "archive", revision, "src", "tests/integration", STACK_FRAMES_GATE])
    with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
        sources = {entry.name: tree.extractfile(entry).read() for entry in tree if entry.isfile()}
    return ui_paths(Graph(sources, lambda name: sources[name].decode()))


def visible_lines(body):
    """Return lines outside HTML comments and fenced code blocks."""
    lines, fence, comment = [], None, False
    for line in body.splitlines():
        if fence:
            if re.fullmatch(r" {0,3}" + re.escape(fence[0]) + r"{%d,}[ \t]*" % len(fence), line):
                fence = None
            continue
        visible, pos = "", 0
        while pos < len(line):
            if comment:
                close = line.find("-->", pos)
                if close < 0:
                    break
                comment, pos = False, close + 3
            elif len(visible) <= 3 and visible == " " * len(visible) and (
                    opened := re.match(r"(`{3,}|~{3,})", line[pos:])):
                fence = opened[1]
                break
            elif line.startswith("<!--", pos):
                comment, pos = True, pos + 4
            else:
                visible += line[pos]
                pos += 1
        if not fence:
            lines.append(visible)
    return lines


def screen_evidence(body):
    # A plain link to an image is not an embed.
    lines = visible_lines(body)
    visible = "\n".join(lines)
    if re.search(r"^No screen change:[ \t]*\S[^\n]*$", visible, re.M):
        return True
    return any(line.lstrip().startswith(("![", "<img", "<video"))
               and "https://github.com/user-attachments/" in line for line in lines)


def goal_present(body):
    issue = re.compile(r"(?<![\w/])(?:#[0-9]+|https://github\.com/[^/\s]+/[^/\s]+/issues/[0-9]+)(?![\w/])")
    for line in visible_lines(body):
        if re.match(r"^No issue:[ \t]*\S", line):
            return True
        if line.startswith("Goal:"):
            text = line[len("Goal:"):]
            for match in issue.finditer(text):
                explanation = text[:match.start()] + " " + text[match.end():]
                if len(re.findall(r"\b[^\W_]+\b", explanation)) >= 3:
                    return True
    return False


def refusal(changed_paths, body, *, base=None) -> str | None:
    if not goal_present(body):
        return ("Add a visible line 'Goal: #123 <how this change serves the issue>' "
                "(or use its full GitHub issue URL), with at least three explanation words, "
                "or 'No issue: <reason>' to the PR body. Body edits do not re-trigger the check; "
                "re-run the failed jobs of this run after editing the body; no push needed.")
    if any(path.startswith("src/") for path in changed_paths) and not (
            re.search(r"^##\s+Shape\s*$", body, re.M) or summary_sketch(body)):
        return ("PRs changing src/ need a nonempty fenced sketch in ## Summary or a legacy ## Shape section "
                "(CODING_STANDARDS.md#shape-before-code). Add a ## Shape section to the PR body, "
                "then re-run the failed jobs of this run; no push needed.")
    return None


def screens_required(changed_paths, *, base=None) -> bool:
    from select_tests import tree_graph

    paths = set(changed_paths)
    if not any(path.startswith("src/") for path in paths) and ".claude/skills/verify-rui/scripts/frames.json" not in paths:
        return False
    ui = ui_paths(tree_graph())
    if base is not None and any(path.startswith("src/") for path in paths):
        ui |= revision_ui_paths(base)
    return bool(paths & (ui | {".claude/skills/verify-rui/scripts/frames.json"}))


def screen_refusal(body) -> str | None:
    if not screen_evidence(body):
        return ("UI PRs need a visible user-attachments image/video line or a line 'No screen change: <reason>'. "
                "Run verify-rui frames HEAD --before BASE, then verify-rui publish DIR --pr PR (gh 2.104.0+ and a classic PAT or gh OAuth token with push access); re-run the failed admission job after updating the body.")
    return None


def live_body(env_body) -> str:
    body = env_body
    repo, number = os.environ.get("GITHUB_REPOSITORY"), os.environ.get("PR_NUMBER")
    if repo and number:
        try:
            result = github("GET", f"repos/{repo}/pulls/{number}")
            current = result["body"]
            if current is not None and not isinstance(current, str):
                raise ValueError("invalid PR body")
            body = current or ""
            print("Judging current PR body from GitHub.")
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError) as error:
            print(f"Could not read current PR body from GitHub ({error}); judging event payload body.")
    return body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", nargs="?", default=os.environ.get("BASE"))
    parser.add_argument("--screens", action="store_true")
    args = parser.parse_args()
    body = live_body(os.environ.get("PR_BODY", ""))
    if args.screens:
        reason = screen_refusal(body)
    else:
        if not args.base:
            parser.error("provide BASE as an argument or environment variable")
        from select_tests import changed_paths

        paths, base = changed_paths(args.base, "HEAD")
        required = screens_required(paths, base=base)
        if output := os.environ.get("GITHUB_OUTPUT"):
            with open(output, "a", encoding="utf-8") as f:
                print(f"screens_required={str(required).lower()}", file=f)
        reason = refusal(paths, body, base=base)
    if reason:
        print(reason, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

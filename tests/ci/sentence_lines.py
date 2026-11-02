#!/usr/bin/env python3
"""Keep the shared Markdown documents at one sentence per line.

Markdown renders a line break inside a paragraph as a space, so where a
paragraph's lines break changes nothing a reader sees. It changes what git
sees: two PRs that edit different sentences of one paragraph conflict when the
paragraph is a single line, and merge cleanly when each sentence has its own.

  python3 tests/ci/sentence_lines.py          # rewrite the documents in place
  python3 tests/ci/sentence_lines.py --check  # list lines holding two sentences
"""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
DOCUMENTS = ("AGENTS.md", "ARCHITECTURE.md", "CODING_STANDARDS.md", "README.md", "VERIFICATION.md",
             "docs/development.md", "docs/host-ownership-design.md", "docs/host.md", "docs/scripting.md",
             "docs/store-reset.md", "docs/using-rui.md")

# A sentence ends at . ! or ? (and any closing quotes or brackets) before a space.
END = re.compile(r"[.!?][\"')\]*_]*$")
# The next sentence starts with a capital, a digit, code, a link or emphasis.
START = re.compile(r"[A-Z0-9`\[*_(\"]")
# A line starting with one of these would open a new block instead of continuing the paragraph.
BLOCK = re.compile(r"([-+*]|\d+[.)])(\s|$)|[#>|=<]|```|~~~")
ABBREVIATIONS = ("e.g.", "i.e.", "etc.", "vs.", "cf.", "approx.", "No.", "Fig.", "St.", "Mr.", "Ms.", "Dr.")
LIST_ITEM = re.compile(r"(\s*)([-+*]|\d+[.)])\s+")


def continuation_indent(line):
    item = LIST_ITEM.match(line)
    if item:
        return " " * item.end()
    return line[:len(line) - len(line.lstrip())]


def split_sentences(text):
    """Split one line's text at sentence ends outside code spans."""
    pieces, start, code, index = [], 0, 0, 0
    while index < len(text):
        char = text[index]
        if char == "`":
            run = len(text[index:]) - len(text[index:].lstrip("`"))
            code = 0 if code == run else (run if code == 0 else code)
            index += run
            continue
        if char == " " and code == 0 and index > start:
            before = text[start:index]
            after = text[index + 1:]
            if (END.search(before) and START.match(after) and not BLOCK.match(after)
                    and not before.endswith(ABBREVIATIONS)):
                pieces.append(before)
                start = index + 1
        index += 1
    pieces.append(text[start:])
    return pieces


def reflow(source):
    out, fenced = [], False
    for line in source.split("\n"):
        stripped = line.lstrip()
        if stripped.startswith(("```", "~~~")):
            fenced = not fenced
            out.append(line)
            continue
        indent = line[:len(line) - len(stripped)]
        if fenced or not stripped or stripped.startswith(("|", "#", "<", ">")) or len(indent) >= 4:
            out.append(line)
            continue
        item = LIST_ITEM.match(line)
        head = line[:item.end()] if item else indent
        body = line[len(head):]
        pieces = split_sentences(body)
        if len(pieces) == 1 or line.endswith("  "):
            out.append(line)
            continue
        follow = continuation_indent(line)
        out.append(head + pieces[0])
        out.extend(follow + piece for piece in pieces[1:])
    return "\n".join(out)


def findings(root=ROOT):
    for name in DOCUMENTS:
        path = root / name
        source = path.read_text()
        before = source.split("\n")
        after = reflow(source).split("\n")
        if before != after:
            done = set(after)
            for number, line in enumerate(before, 1):
                if line not in done:
                    yield f"{name}:{number}: {line[:100]}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="list lines holding two sentences and fail")
    parser.add_argument("paths", nargs="*", help="documents to rewrite (default: the shared ones)")
    args = parser.parse_args()
    if args.check:
        found = list(findings())
        print("\n".join(found))
        raise SystemExit(1 if found else 0)
    for name in args.paths or DOCUMENTS:
        path = Path(name) if args.paths else ROOT / name
        source = path.read_text()
        result = reflow(source)
        if result != source:
            path.write_text(result)
            print(f"rewrote {name}")


if __name__ == "__main__":
    main()

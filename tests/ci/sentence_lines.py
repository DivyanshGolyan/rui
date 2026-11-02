#!/usr/bin/env python3
"""Keep the shared Markdown documents at one sentence per line.

Markdown renders a line break inside a paragraph as a space, so where a
paragraph's lines break changes nothing a reader sees. It changes what git
sees: two PRs that edit different sentences of one paragraph conflict when the
paragraph is a single line, and merge cleanly when each sentence has its own.

A CommonMark parser finds the paragraphs, so tables, code, HTML and headings
are never touched. A paragraph's line breaks at a sentence end only where the
paragraph still renders exactly as before, so a break can never open a list,
end a link or land inside code.

  python3 tests/ci/sentence_lines.py          # rewrite the documents in place
  python3 tests/ci/sentence_lines.py --check  # name each document to rewrite
"""
import argparse
from pathlib import Path
import re

from markdown_it import MarkdownIt

ROOT = Path(__file__).resolve().parents[2]
MARKDOWN = MarkdownIt("commonmark").enable("table")
# A sentence ends at . ! or ?, with any closing quotes or brackets, before a
# space and a word that starts with a capital, a digit, code or a link.
SENTENCE_END = re.compile(r"[.!?][\"')\]]* +(?=[A-Z0-9`\[])")
LIST_MARKER = re.compile(r"[-+*]|\d+[.)]")
# A code span on one line: a backtick run, then the same run closing it.
CODE_SPAN = re.compile(r"(`+).+?(?<!`)\1(?!`)")


def documents(root=ROOT):
    """The documents lanes edit together: the top-level ones and docs/."""
    return sorted([path for path in root.glob("*.md") if path.name != "THIRD_PARTY_NOTICES.md"]
                  + list(root.glob("docs/**/*.md")))


def rendered(text):
    return re.sub(r"\s+", " ", MARKDOWN.render(text))


def split_paragraph(lines):
    """Each line of a paragraph as its sentences, breaking only where the paragraph renders the same."""
    expected = rendered("\n".join(lines))
    pieces = [[line] for line in lines]
    for index in range(len(pieces)):
        code = [span.span() for span in CODE_SPAN.finditer(lines[index])]
        for match in reversed(list(SENTENCE_END.finditer(lines[index]))):
            if any(start < match.start() < end for start, end in code):
                continue  # Rendering joins a code span's lines again, but a reader would not.
            last, cut = pieces[index][0], match.end()
            head, tail = last[:cut].rstrip(" "), last[cut:]
            candidate = pieces[:index] + [[head, tail] + pieces[index][1:]] + pieces[index + 1:]
            if rendered("\n".join(piece for line in candidate for piece in line)) == expected:
                pieces = candidate
    return pieces


def reflow(source):
    lines = source.split("\n")
    tokens = MARKDOWN.parse(source)
    paragraphs = []
    for position, token in enumerate(tokens):
        if token.type != "paragraph_open":
            continue
        start, end = token.map
        content = tokens[position + 1].content.split("\n")
        if len(content) != end - start:
            continue
        prefixes = [line[:len(line) - len(text)] for line, text in zip(lines[start:end], content)
                    if text and line.endswith(text)]
        if len(prefixes) == len(content):
            paragraphs.append((start, end, prefixes, content))
    for start, end, prefixes, content in reversed(paragraphs):
        out = []
        for prefix, pieces in zip(prefixes, split_paragraph(content)):
            # A continuation sits under its line's text: list markers become spaces, quote markers stay.
            follow = LIST_MARKER.sub(lambda marker: " " * len(marker[0]), prefix)
            out += [prefix + pieces[0]] + [follow + piece for piece in pieces[1:]]
        lines[start:end] = out
    return "\n".join(lines)


def findings(paths):
    """Each document that is not at one sentence per line, with its first such line."""
    for path in paths:
        source = path.read_text().split("\n")
        result = reflow("\n".join(source)).split("\n")
        if result != source:
            first = next(number for number, (a, b) in enumerate(zip(source, result), 1) if a != b)
            yield f"{path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}:{first}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="name each document to rewrite, and fail if any")
    parser.add_argument("paths", nargs="*", type=Path, help="documents (default: the top-level ones and docs/)")
    args = parser.parse_args()
    paths = [path.resolve() for path in args.paths] or documents()
    if args.check:
        found = list(findings(paths))
        for finding in found:
            print(finding)
        raise SystemExit(1 if found else 0)
    for path in paths:
        source = path.read_text()
        result = reflow(source)
        if result != source:
            path.write_text(result)
            print(f"rewrote {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")


if __name__ == "__main__":
    main()

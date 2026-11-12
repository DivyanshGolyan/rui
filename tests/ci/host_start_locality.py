#!/usr/bin/env python3
"""The Host produces start failures; only its CLI door writes stdout."""
import sys
from pathlib import Path

from caller_errors import NAME, error_identifier, lex, production

ROOT = Path(__file__).resolve().parents[2]


def scan(source):
    """Inspect production tokens, excluding comments, strings and test blocks."""
    tokens = production(lex(source))
    names = [error_identifier(token) if NAME.fullmatch(token.text) or token.text.startswith('@"')
             else token.text for token in tokens]
    found = []
    for index, name in enumerate(names):
        if name == "writeRefusal":
            found.append(f"src/server.zig:{tokens[index].line}: names writeRefusal; return a start_report.Failure to the CLI")
        if names[index:index + 3] == ["File", ".", "stdout"]:
            found.append(f"src/server.zig:{tokens[index].line}: names File.stdout; the CLI owns stdout")
    return found


def violations(root=ROOT):
    return scan((root / "src/server.zig").read_text())


if __name__ == "__main__":
    found = violations()
    if found:
        print("\n".join(found), file=sys.stderr)
    sys.exit(bool(found))

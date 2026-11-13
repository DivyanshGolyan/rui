#!/usr/bin/env python3
"""The Host produces start failures; only its CLI door writes stdout."""
import json
import sys
from pathlib import Path

from caller_errors import NAME, error_identifier, lex, production

ROOT = Path(__file__).resolve().parents[2]


def scan(source, path="src/server.zig"):
    """Inspect production tokens, excluding comments, strings and test blocks."""
    tokens = production(lex(source))
    names = [error_identifier(token) if NAME.fullmatch(token.text) or token.text.startswith('@"')
             else token.text for token in tokens]
    found = []
    # Origin is not a Host capability, including in the Host's owner tests.
    all_tokens = lex(source)
    for index, token in enumerate(all_tokens):
        name = error_identifier(token) if NAME.fullmatch(token.text) or token.text.startswith('@"') else token.text
        if name == "launched":
            found.append(f"{path}:{token.line}: names launched; read the individual Prepared setting")
        if token.text == "@import" and index + 3 < len(all_tokens):
            argument = all_tokens[index + 2].text
            if (all_tokens[index + 1].text == "(" and argument.startswith('"')
                    and Path(json.loads(argument)).name == "launch_frame.zig"):
                found.append(f"{path}:{token.line}: imports launch_frame; the Host consumes Prepared settings")

    for index, name in enumerate(names):
        if name == "writeRefusal":
            found.append(f"{path}:{tokens[index].line}: names writeRefusal; return a start_report.Failure to the CLI")
        if names[index:index + 3] == ["File", ".", "stdout"]:
            found.append(f"{path}:{tokens[index].line}: names File.stdout; the CLI owns stdout")
    return found


def violations(root=ROOT):
    return [item for path in sorted((root / "src").glob("server*.zig"))
            for item in scan(path.read_text(), path.relative_to(root).as_posix())]


if __name__ == "__main__":
    found = violations()
    if found:
        print("\n".join(found), file=sys.stderr)
    sys.exit(bool(found))

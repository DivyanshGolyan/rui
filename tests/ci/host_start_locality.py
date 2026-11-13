#!/usr/bin/env python3
"""Settings replaces the retired launch owner; only the CLI publishes failures."""
import sys
from pathlib import Path

from caller_errors import NAME, error_identifier, lex, production

ROOT = Path(__file__).resolve().parents[2]


def scan(source, path="src/server.zig"):
    """Keep server I/O in production tokens; reject retired names everywhere."""
    tokens = production(lex(source))
    names = [error_identifier(token) if NAME.fullmatch(token.text) or token.text.startswith('@"')
             else token.text for token in tokens]
    found = retired_names(source, path)
    # Origin is not a Host capability, including in the Host's owner tests.
    all_tokens = lex(source)
    for token in all_tokens:
        name = error_identifier(token) if NAME.fullmatch(token.text) or token.text.startswith('@"') else token.text
        if name == "launched":
            found.append(f"{path}:{token.line}: names launched; read the individual Prepared setting")

    for index, name in enumerate(names):
        if name == "writeRefusal":
            found.append(f"{path}:{tokens[index].line}: names writeRefusal; return a start_report.Failure to the CLI")
        if names[index:index + 3] == ["File", ".", "stdout"]:
            found.append(f"{path}:{tokens[index].line}: names File.stdout; the CLI owns stdout")
    return found


def retired_names(source, path):
    """The retired source owner and CLI switch cannot survive anywhere in src."""
    return [f"{path}:{number}: names {name}; use the Host settings document"
            for number, line in enumerate(source.splitlines(), 1)
            for name in ("launch_frame", "--launch-frame") if name in line]


def violations(root=ROOT):
    found = []
    for path in sorted((root / "src").rglob("*.zig")):
        relative = path.relative_to(root).as_posix()
        inspect = scan if path.name.startswith("server") else retired_names
        found.extend(inspect(path.read_text(), relative))
        if "launch_frame" in path.name:
            found.append(f"{relative}: names the retired launch_frame source owner")
    return found


if __name__ == "__main__":
    found = violations()
    if found:
        print("\n".join(found), file=sys.stderr)
    sys.exit(bool(found))

"""Hillclimb harness: surface timing lines, then failure lines, from a step log as annotations."""
import re
import sys

title, path = sys.argv[1], sys.argv[2]
timing = re.compile(r"elapsed=|^Completed |^Executing: | (success|cached|failure)\b.* (\d+(\.\d+)?(s|m)|\d+m\d+s)\b")
failure = re.compile(r"^error|failed command|Unknown|Traceback|exit=[1-9]")
log = [line.rstrip() for line in open(path, errors="replace")]


def notice(name, lines):
    text = "\n".join(lines)[-60000:]
    text = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::notice title={name}::{text}")


notice(title, [line for line in log if timing.search(line)])
failures = [line for line in log if failure.search(line)]
if failures:
    notice(f"{title} failures", failures[:40])

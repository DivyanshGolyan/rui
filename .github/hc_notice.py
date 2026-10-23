"""Hillclimb harness: surface timing lines from a step log as one annotation."""
import re
import sys

title, path = sys.argv[1], sys.argv[2]
pattern = re.compile(r"elapsed=|error|failed|failure|Unknown|Traceback|^Completed |^Executing: | (success|cached|failure)\b.* (\d+(\.\d+)?(s|m)|\d+m\d+s)\b")
lines = [line.rstrip() for line in open(path, errors="replace") if pattern.search(line)]
text = "\n".join(lines)[-60000:]
text = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
print(f"::notice title={title}::{text}")

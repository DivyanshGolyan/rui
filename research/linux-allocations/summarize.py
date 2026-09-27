#!/usr/bin/env python3
"""Summarize disjoint allocation origins from heaptrack collapsed stacks.

Input uses heaptrack_print -m0 and disabled suppressions. Peak input must be
the global-peak export, not a sum of per-caller high-water marks. Unknown
origins are retained for inspection rather than assigned to Rui.
"""
import collections
import json
from pathlib import Path
import sys


def origin(stack):
    # Frames are root-to-leaf. Native allocation wrappers identify the library
    # that requests storage even when Rui and curl occur further up the stack.
    for frame in reversed(stack.split(";")):
        if "heaptrack" in frame or not frame.strip():
            continue
        if "(sqlite3.c)" in frame:
            return "SQLite"
        if frame.startswith(("CRYPTO_", "OPENSSL_", "ossl_")):
            return "OpenSSL"
        if frame.startswith(("Curl_", "curl_", "nghttp2_")):
            return "curl/nghttp2"
        if ".zig)" in frame:
            return "Rui/Zig"
    return "system/profiler/unresolved"


def summarize(path):
    totals = collections.Counter()
    stacks = collections.defaultdict(list)
    for line in path.read_text().splitlines():
        stack, value = line.rsplit(" ", 1)
        value = int(value)
        if not value:
            continue
        owner = origin(stack)
        totals[owner] += value
        stacks[owner].append((value, stack))
    return {"total": sum(totals.values()), "origins": dict(totals),
            "largest_stacks": {key: sorted(values, reverse=True)[:8]
                               for key, values in stacks.items()}}


if __name__ == "__main__":
    print(json.dumps({str(path): summarize(path)
                      for path in map(Path, sys.argv[1:])}, indent=2))

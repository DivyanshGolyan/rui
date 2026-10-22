#!/usr/bin/env python3
"""Pair launcher: only `host serve` is traced (strace -D keeps the Host PID as the tracee)."""
import os
import sys
binary = os.environ["PAIR_RUI"]
args = sys.argv[1:]
if args[:2] == ["host", "serve"]:
    os.execvp("strace", ["strace", "-D", "-f", "-tt", "-T", "-y", "-s", "200",
                         "-o", os.environ["PAIR_STRACE_OUTPUT"], binary, *args])
os.execv(binary, [binary, *args])

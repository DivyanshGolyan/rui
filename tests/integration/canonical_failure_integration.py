#!/usr/bin/env python3
"""Canonical invocation failure at real producers and current caller boundaries."""
import host_process
import sys
from canonical_failure_cases import main


if __name__ == "__main__":
    host_process.enter()
    main(sys.argv[2] if len(sys.argv) == 3 else "all")

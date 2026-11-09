#!/usr/bin/env python3
"""Real editor handoff, queued input and independently failed cleanup effects."""
import host_process
import sys
from terminal_restoration_cases import main


if __name__ == "__main__":
    host_process.enter()
    main(sys.argv[2] if len(sys.argv) == 3 else None)

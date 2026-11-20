"""Run one full-check case under a deadline so a hang names itself.

check.sh runs cases in the background and prints their logs only when they
finish, so a hung case is silent until the CI step limit kills the whole job.
This wrapper gives each case its own process group and deadline: on expiry it
reports the case as timed out, stops the group, and exits 124, letting
check.sh print that case's log like any other failure.
"""

import os
import signal
import subprocess
import sys


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: case_deadline.py SECONDS COMMAND...")
    seconds = float(sys.argv[1])
    # Its own group (not session) keeps any controlling terminal for serial runs.
    child = subprocess.Popen(sys.argv[2:], process_group=0)
    try:
        sys.exit(child.wait(timeout=seconds))
    except subprocess.TimeoutExpired:
        print(f"case_deadline: still running after {seconds:g}s; stopping its process group "
              f"(raise RUI_CASE_TIMEOUT_SECONDS only for a case that is slow, not hung)", file=sys.stderr, flush=True)
        for sig, grace in ((signal.SIGTERM, 10), (signal.SIGKILL, 10)):
            try:
                os.killpg(child.pid, sig)
            except ProcessLookupError:
                break
            try:
                child.wait(timeout=grace)
                break
            except subprocess.TimeoutExpired:
                continue
        sys.exit(124)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""The overview as a real terminal shows it (see overview_fixture.py).

Usage: overview_integration.py PATH_TO_RUI [GROUP]. Each group lives in its
own module and exports `cases()`; with no GROUP, every group runs.
"""
import sys

import host_process

GROUPS = ("smoke", "groups", "counts", "clicks")


def smoke():
    """The harness itself: an empty Store's overview opens and says so."""
    from overview_fixture import world
    with world("smoke") as w, w.overview() as screen:
        shown = screen.contains("No unarchived Sessions")
        assert "rui" in shown.split("\n", 1)[0], shown
    print("overview smoke: an empty Store's overview opens on a PTY", flush=True)


def main():
    selected = sys.argv[2] if len(sys.argv) > 2 else None
    assert selected in (None, *GROUPS), (selected, GROUPS)
    for group in GROUPS:
        if selected not in (None, group):
            continue
        if group == "smoke":
            smoke()
        else:
            __import__(f"overview_{group}_cases").cases()
        print(f"overview integration: {group} passed", flush=True)


if __name__ == "__main__":
    host_process.enter()
    main()

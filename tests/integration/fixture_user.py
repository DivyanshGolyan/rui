"""Refuse to launch fixtures as root, where the permission denials they assert do not deny."""

import os
import sys

INSTRUCTION = (
    "Rui fixtures must run as a non-root user. This build step is running as root "
    "(effective user ID 0), and root bypasses the file and socket permission denials "
    "that fixtures assert, so their results would be wrong. Run the same zig build "
    "command again as an ordinary user, for example a dedicated tester account that owns "
    "its own checkout, Zig caches and Python environment."
)


def main():
    if os.geteuid() == 0:
        sys.exit(INSTRUCTION)


if __name__ == "__main__":
    main()

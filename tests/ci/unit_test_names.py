#!/usr/bin/env python3
"""Read Zig test-server inventories and compare a monolith with partition roots."""
import argparse
from collections import Counter
import json
import math
import sys

import unit_test_metadata as metadata
from unit_test_metadata import MAX_BYTES, parse_metadata, parse_stream, query  # noqa: F401


def compare(before, after):
    expected, actual = Counter(before), Counter(after)
    dropped, extra = expected - actual, actual - expected
    if dropped or extra:
        raise ValueError("test inventory mismatch: " + json.dumps(
            {"dropped": dict(dropped), "extra_or_duplicate": dict(extra)}, sort_keys=True))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", help="stock monolithic test executable")
    parser.add_argument("after", nargs="*", help="partition test executables")
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--dump", action="store_true", help="dump raw names as a JSON array (all provided binaries)")
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("timeout must be positive")
    try:
        before = query(args.before, args.timeout)
        after = [name for binary in args.after for name in query(binary, args.timeout)]
        if args.dump:
            print(json.dumps(before + after, ensure_ascii=False))
        else:
            if not args.after:
                parser.error("comparison requires at least one after executable")
            compare(before, after)
            print(f"Identical inventory: {len(before)} tests across {len(args.after)} roots")
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

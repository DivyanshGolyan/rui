#!/usr/bin/env python3
"""Run the CI policy suite, excluding unchanged-input self-checks."""
import argparse
import json
import unittest


def suite(skips: list[str], start: str = "tests/ci") -> unittest.TestSuite:
    """Discover the policy tests and omit the selected module or class prefixes."""
    prefixes = tuple(unit + "." for unit in skips)

    def kept(tests):
        for test in tests:
            if isinstance(test, unittest.TestSuite):
                yield from kept(test)
            elif not test.id().startswith(prefixes):
                yield test

    return unittest.TestSuite(kept(unittest.defaultTestLoader.discover(start)))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skips", required=True, type=json.loads)
    args = parser.parse_args(argv)
    if not isinstance(args.skips, list) or not all(isinstance(item, str) for item in args.skips):
        parser.error("--skips must be a JSON list of names")
    print("Self-checks with unchanged inputs (select_tests.POLICY_SELF_CHECKS):", args.skips or "none", flush=True)
    return int(not unittest.TextTestRunner(verbosity=2).run(suite(args.skips)).wasSuccessful())


if __name__ == "__main__":
    raise SystemExit(main())

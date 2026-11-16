#!/usr/bin/env python3
import subprocess

from run_selected import TEST_TIMEOUT


def main():
    for target in ("test-logic", "test", "test-full"):
        for attempt in range(2):
            result = subprocess.run(
                ["zig", "build", target, "-Dtest-filter=TerminalText", "--seed=0", "--summary", "all",
                 "--test-timeout", TEST_TIMEOUT],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            print(result.stdout, end="", flush=True)
            if result.returncode:
                raise SystemExit(result.returncode)
            if "tests passed" not in result.stdout:
                raise SystemExit(f"{target} attempt {attempt + 1}: no fresh test execution reported")
    print("PASS: all three unit modes executed both identical warm-cache invocations")


if __name__ == "__main__":
    main()

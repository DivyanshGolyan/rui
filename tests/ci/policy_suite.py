#!/usr/bin/env python3
"""Run the CI policy suite, excluding unchanged-input self-checks.

The kept tests run across worker processes. Tasks keep shared module and class
fixtures together; timing-sensitive groups run after the workers finish.
Each task's log prints whole.
"""
import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
from concurrent.futures.process import BrokenProcessPool
import inspect
import io
import json
import multiprocessing
import os
from pathlib import Path
import sys
import time
import unittest


SERIAL_TESTS = {
    "test_store_shards.LauncherTest.test_per_test_timeout_is_independent_of_process_deadline": "asserts real per-test timeout timing",
    "test_store_shards.LauncherTest.test_per_test_deadline_survives_closed_output": "asserts real deadline timing after output closes",
}


def suite(skips: list[str], start: str = "tests/ci") -> unittest.TestSuite:
    """Discover the policy tests and omit the selected module or class prefixes."""
    prefixes = tuple(unit + "." for unit in skips)

    def kept(tests):
        for test in tests:
            if isinstance(test, unittest.TestSuite):
                yield from kept(test)
            elif not test.id().startswith(prefixes):
                yield test

    class Loader(unittest.TestLoader):
        def __init__(self):
            super().__init__()
            self.import_cleanups = {}

        def _get_module_from_name(self, name):
            cleanups = unittest.case._module_cleanups
            before = len(cleanups)
            try:
                return super()._get_module_from_name(name)
            finally:
                self.import_cleanups[name] = cleanups[before:]
                del cleanups[before:]

    loader = Loader()
    result = unittest.TestSuite(kept(loader.discover(start)))
    result.import_cleanups = loader.import_cleanups
    return result


def units(tests: unittest.TestSuite) -> list[list[unittest.TestCase]]:
    """Keep shared unittest fixtures and cleanups in the same task."""
    tests = list(tests)
    modules = {}
    for test in tests:
        module = sys.modules.get(type(test).__module__)
        if module is None or module in modules:
            continue
        try:
            source = inspect.getsource(module)
        except (OSError, TypeError):
            # Unknown module code may register a module cleanup.
            modules[module] = True
        else:
            modules[module] = (hasattr(module, "setUpModule") or hasattr(module, "tearDownModule")
                               or "addModuleCleanup" in source)

    groups = {}
    for test in tests:
        kind = type(test)
        module = sys.modules.get(kind.__module__)
        if modules.get(module, False):
            key = ("module", kind.__module__)
        else:
            shared = (kind.setUpClass.__func__ is not unittest.TestCase.setUpClass.__func__
                      or kind.tearDownClass.__func__ is not unittest.TestCase.tearDownClass.__func__)
            for base in kind.__mro__:
                if base is unittest.TestCase:
                    break
                try:
                    shared |= "addClassCleanup" in inspect.getsource(base)
                except (OSError, TypeError):
                    shared = True
            key = ("class", kind) if shared else ("test", test.id())
        groups.setdefault(key, []).append(test)
    return list(groups.values())


def run(tests, *, standins=False):
    """Run tests in this process; return their verbose log and failure details, counts and success."""
    stream = io.StringIO()
    result = unittest.TextTestResult(unittest.runner._WritelnDecorator(stream), True, 2)
    if standins:
        # Discovery stand-ins have no fixtures. Running them outside a suite
        # avoids consuming cleanups registered while discovering real modules.
        for test in tests:
            test.run(result)
    else:
        unittest.TestSuite(tests).run(result)
    result.printErrors()
    problems = (len(result.failures), len(result.errors), len(result.unexpectedSuccesses))
    return stream.getvalue(), result.testsRun, problems, len(result.skipped), result.wasSuccessful()


def run_names(start: str, names: list[str]):
    """Worker entry: load the named tests the way discovery imports them, then run them."""
    path = str(Path(start).resolve())
    if path not in sys.path:
        sys.path.insert(0, path)
    return run([unittest.defaultTestLoader.loadTestsFromName(name) for name in names])


def loadable(group) -> bool:
    """Discovery reports an unimportable module as a stand-in test that names cannot reload."""
    return all(type(test).__module__ != "unittest.loader" for test in group)


def run_parallel(tests: unittest.TestSuite, jobs: int, start: str = "tests/ci", out=sys.stderr) -> bool:
    started = time.perf_counter()
    groups = units(tests)
    total, problems, skipped, ok = 0, [0, 0, 0], 0, True

    def report(outcome):
        nonlocal total, skipped, ok
        log, ran, counts, skips, success = outcome
        out.write(log)
        out.flush()
        total += ran
        skipped += skips
        ok = ok and success
        for index, count in enumerate(counts):
            problems[index] += count

    local = [test for group in groups if not loadable(group) for test in group]
    if local:
        report(run(local, standins=True))
    serial = [group for group in groups if loadable(group)
              and any(test.id() in SERIAL_TESTS for test in group)]
    parallel = [group for group in groups if loadable(group) and group not in serial]
    with ProcessPoolExecutor(max_workers=jobs, mp_context=multiprocessing.get_context("spawn")) as pool:
        futures = {}
        for group in parallel:
            names = [test.id() for test in group]
            try:
                futures[pool.submit(run_names, start, names)] = names
            except BrokenProcessPool:
                ok = False
                problems[1] += 1
                out.write("Worker process died; these tests did not start: " + ", ".join(names) + "\n")
        for future in as_completed(futures):
            try:
                report(future.result())
            except BrokenProcessPool:
                ok = False
                problems[1] += 1
                out.write("Worker process died; these tests did not complete: "
                          + ", ".join(futures[future]) + "\n")
    for group in serial:
        module = type(group[0]).__module__
        unittest.case._module_cleanups.extend(getattr(tests, "import_cleanups", {}).pop(module, []))
        report(run(group))
    failures, errors, unexpected = problems
    out.write("-" * 70 + f"\nRan {total} tests in {time.perf_counter() - started:.3f}s across {jobs} processes\n\n")
    details = [f"{name}={count}" for name, count in
               (("failures", failures), ("errors", errors), ("skipped", skipped),
                ("unexpected successes", unexpected)) if count]
    out.write(("OK" if ok else "FAILED") + (f" ({', '.join(details)})" if details else "") + "\n")
    return ok


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skips", required=True, type=json.loads)
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1,
                        help="worker processes")
    args = parser.parse_args(argv)
    if not isinstance(args.skips, list) or not all(isinstance(item, str) for item in args.skips):
        parser.error("--skips must be a JSON list of names")
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    print("Self-checks with unchanged inputs (select_tests.POLICY_SELF_CHECKS):", args.skips or "none", flush=True)
    return int(not run_parallel(suite(args.skips), args.jobs))


if __name__ == "__main__":
    raise SystemExit(main())

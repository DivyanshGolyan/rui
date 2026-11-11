#!/usr/bin/env python3
"""Shard existing targets without changing their assertions or build graph."""
import argparse
import json


RESOURCES = (
    "measure-repeat-work", "measure-admission", "measure-message-admission",
    "measure-model-dispatch", "measure-model-output", "measure-model-retry",
    "measure-model-queue", "measure-model-control", "measure-call-classification",
    "measure-execution-service",
)
NATIVE = (
    "check-full", "test-logic", "admission-debug-integration", "dispatch-debug-integration",
    "transport-h2-integration", "codex-h2-integration", "codex-credential-integration",
    "current-facts-integration", "server-delivery-integration", "test-full",
    "measurement-check", "installer-integration",
)
# Selected Linux suites run at most this many shards, all concurrently.
LINUX_SHARDS = 10
# The gates that run for minutes (stack-frames compiles the product with
# LLVM); every other packed suite runs for seconds to two minutes.
LONG_GATES = frozenset(("check", "check-full", "test", "stack-frames"))
# Beside a long gate the short suites share this many shards: they still end
# well inside the gate's run, so more shards would only repeat setup.
SHARDS_BESIDE_LONG_GATE = 3
# Targets whose graph compiles the unit test roots (src/tests.zig). Their
# producer compiles them in parallel, separately from the remaining gates.
# build.zig refuses a split producer whose selection does not reach it.
UNIT_TARGETS = frozenset(("test", "test-native", "test-store", "check", "check-full"))


def split_build(targets):
    # A selection of the unit tests alone leaves the rest producer nothing to compile.
    return bool(UNIT_TARGETS & set(targets)) and set(targets) not in ({"test"}, {"test-native"}, {"test-store"})


def shards(targets, platform="linux", limit=LINUX_SHARDS, *, mysql_suites=None):
    # Lazy import: selection also uses this module's resource target names.
    from select_tests import mysql_provisioning, tree_graph
    if mysql_suites is None:
        mysql_suites = tree_graph().live_mysql if platform == "linux" and targets else set()
    mysql_suites = set(mysql_suites)

    def provision(rows):
        for row in rows:
            row.update(mysql_provisioning(row["targets"], row["part"], platform, mysql_suites))
        return {"include": rows}

    if platform == "macos":
        # The standard account cap is five Macs shared by all workflows. Use
        # three workers, leaving room for another PR; never queue ten compilers.
        rows = []
        if "check-full" in targets:
            rows.extend([
                dict(name="full-execution", targets=["check-full"] +
                     (["test-logic"] if "test-logic" in targets else []),
                     part="execution", resource=False, args=[]),
                dict(name="full-callers", targets=["check-full"], part="callers", resource=False, args=[]),
            ])
        remaining = [t for t in targets if t not in RESOURCES and t != "check-full"
                     and not (t == "test-logic" and "check-full" in targets)]
        if remaining:
            rows.append(dict(name="native", targets=remaining, part="all", resource=False, args=[]))
        rows.extend(shards([t for t in targets if t in RESOURCES], limit=None, mysql_suites=set())["include"])
        return provision(rows)
    rows, packed = [], []
    for target in targets:
        if target == "measure-model-output":
            # Preserve both rounds at every capacity, plus all growth/spill cases.
            # Eight minutes of offer work alone does not fit one short CI job.
            for scenario in ("growth", "1", "8", "16", "100"):
                args = ["--growth-only"] if scenario == "growth" else ["--capacity", scenario]
                rows.append(dict(name=f"{target}-{scenario}", targets=[target],
                                 part="all", resource=True, args=args))
        elif target == "check-full":
            for part in ("execution", "callers"):
                rows.append(dict(name=f"full-{part}", targets=[target], part=part, resource=False, args=[]))
        elif target in RESOURCES:
            rows.append(dict(name=target, targets=[target], part="all", resource=True, args=[]))
        else:
            packed.append(target)
    # Short Selected suites mostly pay setup, so pack them into the remaining
    # concurrent slots. A long gate runs alone: a suite packed with it would
    # only lengthen the run's longest shard. Qualification keeps one isolated
    # job per suite.
    long = [target for target in packed if target in LONG_GATES]
    short = [target for target in packed if target not in LONG_GATES]
    for target in long:
        rows.append(dict(name=target, targets=[target], part="all", resource=False, args=[]))
    if limit is None:
        count = len(short)
    else:
        slots = limit - len(rows)
        if LONG_GATES.intersection(targets):
            slots = min(slots, SHARDS_BESIDE_LONG_GATE)
        count = max(1, min(len(short), slots))
    for shard in range(count if short else 0):
        members = short[shard::count]
        rows.append(dict(name="+".join(members), targets=members, part="all", resource=False, args=[]))
    return provision(rows)


def qualification(suite, platform):
    targets = []
    if suite in ("footprint", "resources", "all"):
        resources = RESOURCES[:1] if suite == "footprint" else RESOURCES
        # These four entry points call RequireRuntime, which rejects Linux.
        macos_only = {"measure-admission", "measure-message-admission",
                      "measure-model-dispatch", "measure-model-retry"}
        targets.extend(target for target in resources
                       if platform == "macos" or target not in macos_only)
    if suite in ("native", "all"):
        targets.extend(NATIVE)
        if platform == "linux":
            # check-full replaces check here, so the Linux-only frame gate runs beside it.
            targets.extend(("login-signal-integration", "mysql-wire-integration", "stack-frames"))
    return shards(targets, platform, limit=None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--targets", help="JSON target array from select_tests.py")
    source.add_argument("--suite", choices=("footprint", "resources", "native", "all"))
    parser.add_argument("--platform", choices=("linux", "macos"), default="linux")
    args = parser.parse_args()
    result = shards(json.loads(args.targets), args.platform) if args.targets is not None else qualification(args.suite, args.platform)
    print(json.dumps(result))


if __name__ == "__main__":
    main()

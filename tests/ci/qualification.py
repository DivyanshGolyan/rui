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
LINUX_SHARDS = 10
LONG_GATES = frozenset(("check", "check-full", "test", "stack-frames", "rsql-table"))
SHARDS_BESIDE_LONG_GATE = 3
UNIT_TARGETS = frozenset(("test", "test-native", "test-store", "check", "check-full"))
FULL_PARTS = ("execution", "callers")


def matrix_name(target, part="all"):
    return f"full-{part}" if target == "check-full" and part in FULL_PARTS else target


def matrix_targets(name):
    aliases = {matrix_name("check-full", part): ("check-full", part) for part in FULL_PARTS}
    return tuple(aliases.get(member, (member, "all")) for member in name.split("+") if member)


def split_build(targets):
    return bool(UNIT_TARGETS & set(targets)) and set(targets) not in ({"test"}, {"test-native"}, {"test-store"})


def shards(targets, platform="linux", limit=LINUX_SHARDS, *, mysql_suites=None):
    from select_tests import mysql_provisioning, tree_graph
    if mysql_suites is None:
        mysql_suites = tree_graph().live_mysql if platform == "linux" and targets else set()
    mysql_suites = set(mysql_suites)

    def provision(rows):
        for row in rows:
            row.update(mysql_provisioning(row["targets"], row["part"], platform, mysql_suites))
        return {"include": rows}

    if platform == "macos":
        rows = []
        if "check-full" in targets:
            for part in FULL_PARTS:
                rows.append(dict(name=matrix_name("check-full", part), targets=["check-full"] +
                                 (["test-logic"] if part == "execution" and "test-logic" in targets else []),
                                 part=part, resource=False, args=[]))
        remaining = [t for t in targets if t not in RESOURCES and t != "check-full"
                     and not (t == "test-logic" and "check-full" in targets)]
        if remaining:
            rows.append(dict(name="native", targets=remaining, part="all", resource=False, args=[]))
        rows.extend(shards([t for t in targets if t in RESOURCES], limit=None, mysql_suites=set())["include"])
        return provision(rows)
    rows, packed = [], []
    for target in targets:
        if target == "measure-model-output":
            for scenario in ("growth", "1", "8", "16", "100"):
                args = ["--growth-only"] if scenario == "growth" else ["--capacity", scenario]
                rows.append(dict(name=f"{target}-{scenario}", targets=[target],
                                 part="all", resource=True, args=args))
        elif target == "check-full":
            for part in FULL_PARTS:
                rows.append(dict(name=matrix_name(target, part), targets=[target], part=part, resource=False, args=[]))
        elif target in RESOURCES:
            rows.append(dict(name=target, targets=[target], part="all", resource=True, args=[]))
        else:
            packed.append(target)
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
        macos_only = {"measure-admission", "measure-message-admission",
                      "measure-model-dispatch", "measure-model-retry"}
        targets.extend(target for target in resources
                       if platform == "macos" or target not in macos_only)
    if suite in ("native", "all"):
        targets.extend(NATIVE)
        if platform == "linux":
            targets.extend(("login-signal-integration", "mysql-wire-integration", "stack-frames", "rsql-table"))
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

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
    "measurement-check",
)
# Selected Linux suites run at most this many shards, all concurrently.
LINUX_SHARDS = 10
# Targets whose graph compiles the unit test binary (src/tests.zig). It takes
# minutes on one core, so a second Linux producer builds it beside the rest.
# build.zig refuses a split producer whose selection does not reach it.
UNIT_TARGETS = frozenset(("test", "check", "check-full"))


def shards(targets, platform="linux", limit=LINUX_SHARDS):
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
        rows.extend(shards([t for t in targets if t in RESOURCES], limit=None)["include"])
        return {"include": rows}
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
    # concurrent slots. Qualification keeps one isolated job per suite.
    count = len(packed) if limit is None else max(1, min(len(packed), limit - len(rows)))
    for shard in range(count if packed else 0):
        members = packed[shard::count]
        rows.append(dict(name="+".join(members), targets=members, part="all", resource=False, args=[]))
    return {"include": rows}


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
            targets.append("login-signal-integration")
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

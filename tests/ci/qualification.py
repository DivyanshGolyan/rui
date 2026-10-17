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
    "check-full", "test-logic", "admission-debug-integration",
    "transport-h2-integration", "codex-h2-integration", "codex-credential-integration",
    "current-facts-integration", "server-delivery-integration", "test-full",
    "evaluator-churn", "measurement-check",
)


def shards(targets):
    rows = []
    for target in targets:
        parts = ("execution", "callers") if target == "check-full" else ("all",)
        for part in parts:
            rows.append(dict(name=target if part == "all" else f"full-{part}",
                             targets=[target], part=part, resource=target in RESOURCES))
    return {"include": rows}


def qualification(suite, platform):
    targets = []
    if suite in ("footprint", "resources", "all"):
        targets.extend(RESOURCES[:1] if suite == "footprint" else RESOURCES)
    if suite in ("native", "all"):
        targets.extend(NATIVE)
        if platform == "linux":
            targets.append("login-signal-integration")
    return shards(targets)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--targets", help="JSON target array from select_tests.py")
    source.add_argument("--suite", choices=("footprint", "resources", "native", "all"))
    parser.add_argument("--platform", choices=("linux", "macos"), default="linux")
    args = parser.parse_args()
    result = shards(json.loads(args.targets)) if args.targets is not None else qualification(args.suite, args.platform)
    print(json.dumps(result))


if __name__ == "__main__":
    main()

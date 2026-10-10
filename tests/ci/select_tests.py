#!/usr/bin/env python3
"""Select existing build targets, not cached acceptance results."""
import argparse
import fnmatch
import json
from pathlib import Path
import re
import subprocess


# Paths sharing an owner select its maintained boundary checks. Unknown code
# selects check rather than silently declaring that no tests apply.
RULES = (
    (("src/logic_tests.zig", "src/execution_turn.zig", "src/request_encoding.zig", "src/AnswerRenderer.zig"),
     ("test-logic",), (), "Portable owner transitions and encoding"),
    (("src/cli.zig", "src/client.zig", "src/Terminal*", "src/preferences.zig", "src/provider_selection.zig"),
     ("check", "admission-debug-integration"), ("check", "admission-debug-integration"),
     "CLI selection and otherwise unnamed native terminal/caller checks"),
    (("src/store.zig",), ("check",), ("test",),
     "Store SQL owners: composed Linux caller checks and native SQLite tests"),
    (("tests/integration/proposal_*",),
     ("proposal-integration",), ("proposal-integration",), "Historical proposal fixture and typed Client"),
    (("tests/integration/activity_*",),
     ("activity-integration",), ("activity-integration",), "Session activity fixture and typed Client"),
    (("tests/integration/preference_policy*",),
     ("preference-policy-integration",), ("preference-policy-integration",),
     "Preference publication fixture and native actor"),
    (("src/server.zig", "tests/integration/admission_integration.sh"),
     ("check", "admission-debug-integration"), ("check", "admission-debug-integration"),
     "Admission/capture owner: complete Debug recovery matrix, not artifact smoke"),
    (("src/protocol.zig", "src/platform.zig",
      "src/execution.zig", "src/attempt.zig", "src/tools.zig", "src/*Scratch*",
      "src/named_scratch.zig", "src/output_retention.zig", "src/HostDiagnostics.zig"),
     ("check",), ("check",), "Shared protocol, native execution or resource ownership"),
    (("src/bash*", "tests/integration/bash*"),
     ("test", "bash-owner-integration", "bash-lifecycle-integration", "bash-recovery-integration", "bash-integration"),
     ("test", "bash-owner-integration", "bash-lifecycle-integration", "bash-recovery-integration", "bash-integration"),
     "Bash execution, direct custody and process-crash recovery"),
    (("src/provider.zig", "src/provider_output.zig", "src/model_adapter.zig", "tests/integration/dispatch*"),
     ("test", "dispatch-integration", "transport-h2-integration"),
     ("test", "dispatch-integration", "transport-h2-integration"), "Model admission and transport"),
    (("tests/integration/transport_h2*",),
     ("transport-h2-integration",), ("transport-h2-integration",),
     "Native H2 fixture and its companion transcript oracle"),
    (("src/codex*", "tests/integration/codex*"),
     ("test", "codex-integration", "codex-credential-integration", "codex-h2-integration"),
     ("test", "codex-integration", "codex-credential-integration", "codex-h2-integration"),
     "Credential mutation and synthetic managed transport"),
    (("src/evaluator*", "tests/integration/evaluator*"),
     ("workflow-check", "evaluator-host-integration", "evaluator-churn"),
     ("workflow-check", "evaluator-host-integration", "evaluator-churn"), "Evaluator lifetime, output and cleanup"),
    (("src/host_launch.c", "tests/integration/host_launch*"),
     ("test", "host-launch-integration"), ("test", "host-launch-integration"), "Native Host launch and startup failures"),
    (("src/descriptor*", "tests/integration/descriptor*"),
     ("test", "descriptor-capacity-integration"), ("test", "descriptor-capacity-integration"), "Native descriptor capacity"),
    (("tests/integration/check.sh",), ("check", "check-full"), ("check", "check-full"),
     "Shared driver: both parallel and full-check execution modes"),
    (("tests/integration/login_signal_integration.py", "build.zig"), ("login-signal-integration",), (),
     "Linux-only native login signal loader witness"),
    (("tests/integration/current_facts_integration.py", "build.zig"),
     ("current-facts-integration",), ("current-facts-integration",), "Current producer/consumer oracle"),
    (("tests/integration/server_delivery_integration.py", "build.zig"),
     ("server-delivery-integration",), ("server-delivery-integration",), "Real reply inactivity and Host drain"),
    (("tests/integration/dispatch_integration.py", "tests/integration/host_process.py",
      "tests/integration/canonical_failure_integration.py"),
     ("current-facts-integration",), ("current-facts-integration",), "Current oracle's imported fixture owners"),
    (("tests/integration/dispatch_integration.py", "tests/integration/host_process.py",
      "tests/integration/control_integration.py"),
     ("server-delivery-integration",), ("server-delivery-integration",), "Delivery oracle's imported fixture owners"),
    (("build.zig", "build.zig.zon", "src/build_*", "src/*.patch", ".agents/setup",
      ".github/actions/setup/action.yml"),
     ("check-full", "admission-debug-integration", "test-full", "evaluator-churn"),
     ("check-full", "admission-debug-integration", "test-full", "evaluator-churn"),
     "Build, dependency or bootstrap inputs"),
    (("build.zig", "build.zig.zon", "src/build_transport.sh", "src/curl*.patch", ".agents/setup",
      ".github/actions/setup/action.yml"),
     ("transport-h2-integration", "codex-h2-integration"),
     ("transport-h2-integration", "codex-h2-integration"), "Transport build and managed TLS/H2 bootstrap"),
)

CHECK_COVERS = {
    "test", "admission-integration", "dispatch-integration",
    "bash-owner-integration", "bash-lifecycle-integration", "bash-recovery-integration",
    "bash-integration", "codex-integration", "control-integration",
    "host-status-integration", "host-launch-integration", "host-stop-integration",
    "descriptor-capacity-integration", "workflow-check", "evaluator-host-integration",
    "proposal-integration", "activity-integration", "preference-policy-integration",
}


def setup_requirements(targets):
    return {"go": "measurement-check" in targets,
            "h2": bool(set(targets) & {"transport-h2-integration", "codex-h2-integration"})}


def execution_batches(targets, check_part="all"):
    # Share compilation and graph execution only among independent owner suites.
    # Composed gates and latency-sensitive/long witnesses keep isolated execution.
    if check_part != "all" and "check-full" not in targets:
        raise ValueError("A full-check part requires check-full in the selection")
    if check_part == "execution":
        return [["check-full", "-Dcheck-part=execution"]]
    if check_part not in {"all", "callers"}:
        raise ValueError(f"Unknown full-check part: {check_part}")
    isolated = {"check", "check-full", "admission-debug-integration", "test-full",
                "evaluator-churn", "host-launch-integration", "server-delivery-integration"}
    evaluator = [target for target in targets
                 if target in {"workflow-check", "evaluator-host-integration"}]
    shared = [target for target in targets if target not in isolated and target not in evaluator]
    return (([evaluator] if evaluator else []) + ([shared] if shared else [])
            + [[target, "-Dcheck-part=callers"] if target == "check-full" and check_part == "callers"
               else [target] for target in targets if target in isolated])


def select(paths, phase, available):
    targets, native_targets, reasons = set(), set(), set()
    manual_checks = set()
    linux_memory_checks = False
    for path in paths:
        if path.endswith(".md") or path.startswith(("docs/", "research/")):
            reasons.add("Documentation: references and diff whitespace, no runtime change")
            continue
        if path.startswith((".github/", "tests/ci/")) and path != ".github/actions/setup/action.yml":
            reasons.add("CI policy: selector and workflow checks")
            targets.add("test-logic")
            native_targets.add("test-logic")
            continue
        matched = False
        for patterns, checks, native_checks, reason in RULES:
            if any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns):
                targets.update(checks)
                native_targets.update(native_checks)
                reasons.add(reason)
                matched = True
        if path.startswith("tests/qualification/"):
            if path.endswith((".go", "go.mod", "go.sum")):
                targets.add("measurement-check")
                native_targets.add("measurement-check")
                reasons.add("Measurement code: pinned Go package checks")
            elif path.endswith((".py", ".c", ".sh", ".zig", ".patch")):
                targets.add("test-logic")
                linux_memory_checks |= path.startswith("tests/qualification/linux-memory/")
                manual_checks.add(f"{path}: syntax/compilation and reviewer-selected affected diagnostic when measurement claims change")
                reasons.add("Qualification executable: cheap checks do not qualify its measurement claims")
            continue
        if not matched and path.startswith("tests/integration/"):
            candidate = Path(path).stem.replace("_", "-")
            targets.add(candidate if candidate in available else "check")
            native_targets.add(candidate if candidate in available else "check")
            reasons.add("Maintained integration target or full fallback")
            matched = True
        if not matched and path.startswith("src/"):
            targets.add("check")
            native_targets.add("check")
            reasons.add("Unmapped source: full fallback")
        if path == "src/client.zig":
            targets.add("test-full")  # Response wait/inactivity owner.
            native_targets.add("test-full")
        if "evaluator_string" in path:
            targets.add("evaluator-string-sanitizer")
            native_targets.add("evaluator-string-sanitizer")
    for checks in (targets, native_targets):
        if "check-full" in checks and "tests/integration/check.sh" not in paths:
            checks.discard("check")
        if checks & {"check", "check-full"}:
            checks -= CHECK_COVERS
    if phase == "development":
        # Development does not replace final boundary/native acceptance.
        targets = {"test-logic"} if targets else set()
        native_targets = set()
    missing = (targets | native_targets) - available
    if missing:
        raise ValueError(f"Selected targets absent from build.zig: {sorted(missing)}")
    return {"phase": phase, "targets": sorted(targets),
            "native_targets": sorted(native_targets), "native_required": bool(native_targets),
            "cache_execution_checks": any(path == "build.zig" or path.startswith(".github/")
                                          or path == "tests/ci/cache_execution.py" for path in paths),
            "linux_memory_checks": linux_memory_checks, "manual_checks": sorted(manual_checks),
            "reasons": sorted(reasons), "acceptance_reused": False}


def changed_paths(base, head, fallback_base=None):
    def commit(ref):
        return subprocess.check_output(
            ["git", "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}"],
            text=True, stderr=subprocess.PIPE).strip()
    head_commit = commit(head)
    try:
        base_commit = commit(base)
    except subprocess.CalledProcessError:
        if fallback_base is None:
            raise
        # An orphaned push predecessor may not be present after fetch-depth: 0.
        # Review base failures remain errors; only pushes opt into this fallback.
        base_commit = subprocess.check_output(
            ["git", "merge-base", head_commit, commit(fallback_base)], text=True).strip()
    # No rename inference: both deleted and added owners select their checks.
    raw = subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z",
                                   base_commit, head_commit])
    return [p.decode("utf-8", "surrogateescape") for p in raw.split(b"\0") if p], base_commit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--fallback-base", help="Push-only fallback ancestor when the before commit is unavailable")
    parser.add_argument("--phase", choices=("development", "review"), default="review")
    args = parser.parse_args()
    available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', Path("build.zig").read_text()))
    paths, base = changed_paths(args.base, args.head, args.fallback_base)
    result = select(paths, args.phase, available)
    result["base"] = base
    result["head"] = subprocess.check_output(["git", "rev-parse", args.head], text=True).strip()
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

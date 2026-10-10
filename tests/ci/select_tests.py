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
    (("src/execution_turn.zig", "src/request_encoding.zig", "src/AnswerRenderer.zig"),
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
    (("build.zig", "build.zig.zon", "src/build_*", "src/*.patch", ".agents/setup"),
     ("check-full", "admission-debug-integration", "test-full", "evaluator-churn"),
     ("check-full", "admission-debug-integration", "test-full", "evaluator-churn"),
     "Build, dependency or bootstrap inputs"),
)

CHECK_COVERS = {
    "test", "test-logic", "admission-integration", "dispatch-integration",
    "bash-owner-integration", "bash-lifecycle-integration", "bash-recovery-integration",
    "bash-integration", "codex-integration", "control-integration",
    "host-status-integration", "host-launch-integration", "host-stop-integration",
    "descriptor-capacity-integration", "workflow-check", "evaluator-host-integration",
    "proposal-integration", "activity-integration", "preference-policy-integration",
}


def select(paths, phase, available):
    targets, native_targets, reasons = set(), set(), set()
    manual_checks = set()
    linux_memory_checks = False
    for path in paths:
        if path.endswith(".md") or path.startswith(("docs/", "research/")):
            reasons.add("Documentation: references and diff whitespace, no runtime change")
            continue
        if path.startswith((".github/", "tests/ci/")):
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
        if "check-full" in checks:
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
            "linux_memory_checks": linux_memory_checks, "manual_checks": sorted(manual_checks),
            "reasons": sorted(reasons), "acceptance_reused": False}


def changed_paths(base, head):
    def commit(ref):
        return subprocess.check_output(
            ["git", "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}"], text=True).strip()
    # No rename inference: both deleted and added owners select their checks.
    raw = subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z",
                                   commit(base), commit(head)])
    return [p.decode("utf-8", "surrogateescape") for p in raw.split(b"\0") if p]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--phase", choices=("development", "review"), default="review")
    args = parser.parse_args()
    available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', Path("build.zig").read_text()))
    result = select(changed_paths(args.base, args.head), args.phase, available)
    result["head"] = subprocess.check_output(["git", "rev-parse", args.head], text=True).strip()
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

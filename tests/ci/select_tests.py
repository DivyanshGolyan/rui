#!/usr/bin/env python3
"""Select existing build targets for fresh execution."""
import argparse
import fnmatch
import json
from pathlib import Path
import re
import subprocess

from platform_boundary import mac_path
from strict_paths import strict


# Renderer, terminal and frontend owners select the roots that run their unit
# tests and PTY callers, not the Store-native check, unless a strict path changes.
FRONTEND = ("src/AnswerRenderer.zig", "src/SessionFrontend.zig", "src/SessionSubmission.zig", "src/session_consent.zig", "src/ChoiceLine.zig",
            "src/session_departure.zig", "src/SessionScreen.zig", "src/SessionTerminal.zig",
            "src/session_view.zig", "src/session_history.zig", "src/session_reads.zig", "src/ClientTask.zig",
            "src/ConversationViewport.zig", "src/Terminal*", "src/session_sequence_model_test.zig", "src/overview_view.zig",
            "src/Overview.zig", "src/keymap.zig")
PTY_TARGETS = ("terminal-restoration-integration", "canonical-failure-integration")
# Nonblocking renderer harnesses; renderer-contracts.yml filters on these paths.
RENDERER_HARNESSES = ("tests/integration/session_sequence_model*", "tests/integration/input_equivalence.py",
                      "tests/integration/terminal_input_replay.py")

# Paths sharing an owner select its maintained boundary checks. Unknown code
# selects check rather than silently declaring that no tests apply.
RULES = (
    (("src/logic_tests.zig", "src/core_boundary.zig", "src/execution_turn.zig", "src/request_encoding.zig",
      "src/AnswerRenderer.zig"),
     ("test-logic",), (), "Portable owner transitions and encoding"),
    (("src/ResponseTiming.zig",), ("test-logic",), ("test-logic",),
     "Response policy values alongside native timeout consumers"),
    (("src/turn_policy.zig",), ("test-logic",), ("test-logic",),
     "Turn completion and compaction decisions over transaction facts"),
    (("src/retry_policy.zig",), ("test-logic", "check"), ("test-logic", "test"),
     "Model retry waits and maximum; Store SQL and index text derive from them"),
    (("src/bounded.zig", "src/session_work.zig"), ("test-logic", "check"), ("test-logic", "test"),
     "Shared values and the Session work derivation; Store readers and wire encoders follow"),
    (("src/change_ring.zig",), ("test-logic", "check"), ("test-logic", "test"),
     "The Session change hint; the Store records into it and list pages read it"),
    (("src/new_session_selection.zig", "src/preference_values.zig",
      "src/provider_selection.zig", "src/model_capability.zig"),
     ("test-logic",), ("test-logic",), "Prospective selection policy and owned values"),
    (("src/SessionFrontend.zig", "src/SessionSubmission.zig", "src/session_consent.zig", "src/ChoiceLine.zig", "src/session_departure.zig",
      "src/SessionScreen.zig", "src/SessionTerminal.zig", "src/session_view.zig", "src/session_history.zig",
      "src/session_reads.zig", "src/ClientTask.zig", "src/Overview.zig", "src/keymap.zig"),
     ("test-logic", "test", "admission-debug-integration", *PTY_TARGETS),
     ("test-logic", "test", "admission-debug-integration", *PTY_TARGETS),
     "Frontend value decisions and native terminal/borrower handoffs"),
    (("src/ConversationViewport.zig", "src/TerminalFrame.zig", "src/draft_layout.zig", "src/session_line.zig", "src/work_line.zig", "src/TerminalInput.zig", "src/TerminalEditor.zig", "src/keymap.zig"),
     ("test-logic", *PTY_TARGETS), ("test-logic", *PTY_TARGETS),
     "Terminal layout and input values retain their separate logic root and native wiring"),
    (("src/overview_view.zig",), ("test-logic",), ("test-logic",),
     "Overview decisions and screen over values; its shell's owner selects native checks"),
    (("src/failure_class.zig",), ("test-logic", "test"), ("test-logic", "test"),
     "What a saved failure code lets the person do; the conversation view renders it"),
    (RENDERER_HARNESSES, (), (), "Renderer harnesses: only the nonblocking renderer contracts run them"),
    (("src/session_sequence_model_test.zig",), ("test-logic",), ("test-logic",),
     "Sequence-model oracle: no gate compiles it; nonblocking renderer contracts run it"),
    (("src/Terminal*",), ("test-logic", "admission-debug-integration", *PTY_TARGETS),
     ("test-logic", "admission-debug-integration", *PTY_TARGETS), "Terminal values and native callers"),
    (("src/cli_args.zig", "src/json_ascii.zig", "src/json_scalar.zig"), ("test-logic",), ("test-logic",),
     "Portable CLI grammar, validation and terminal-safe JSON; native callers follow below"),
    (("src/cli.zig", "src/cli_args.zig", "src/json_ascii.zig", "src/client.zig", "src/protocol_reply.zig", "src/ResponseTiming.zig", "src/preferences.zig", "src/provider_selection.zig",
      "src/new_session_selection.zig", "src/preference_values.zig", "src/product_defaults.zig",
      "tests/integration/product_defaults.py"),
     ("check", "admission-debug-integration"), ("check", "admission-debug-integration"),
     "CLI selection and otherwise unnamed native caller checks"),
    (("src/store.zig",), ("check", "dispatch-debug-integration"), ("test", "dispatch-debug-integration"),
     "Store SQL owners: composed Linux caller checks, native SQLite tests and Debug failure provenance"),
    (("tests/integration/peer_integration.py",), ("check",), ("check",),
     "Peer round trip through installed Bash, runtime address and capture recovery"),
    (("tests/integration/proposal_*",),
     ("proposal-integration",), ("proposal-integration",), "Historical proposal fixture and typed Client"),
    (("tests/integration/activity_*",),
     ("activity-integration",), ("activity-integration",), "Session activity fixture and typed Client"),
    (("tests/integration/preference_policy*",),
     ("preference-policy-integration",), ("preference-policy-integration",),
     "Preference publication fixture and native actor"),
    (("src/server*.zig", "tests/integration/admission_integration.sh"),
     ("check", "admission-debug-integration"), ("check", "admission-debug-integration"),
     "Admission/capture owner: complete Debug recovery matrix, not artifact smoke"),
    (("src/protocol.zig", "src/platform.zig",
      "src/execution.zig", "src/attempt.zig", "src/tools.zig", "src/*Scratch*",
      "src/named_scratch.zig", "src/output_retention.zig", "src/HostDiagnostics.zig"),
     ("check",), ("check",), "Shared protocol, native execution or resource ownership"),
    (("src/BashLifecycle.zig", "src/deadline.zig"), ("test-logic",), ("test-logic",),
     "Portable Bash lifecycle and service-turn deadlines; native owner checks follow below"),
    (("src/SessionInput.zig", "src/tools.zig"), ("test-logic", "check"), ("test-logic", "check"),
     "Portable input and tool-parser tests; shared native owners stay in check"),
    (("src/attempt.zig", "src/descriptor_capacity.zig", "src/product_defaults.zig", "src/transport_policy.zig"), ("test-logic",), ("test-logic",),
     "Functional cores beside shared owners; their native checks follow"),
    (("src/codex_credential_policy.zig", "src/codex_token_wire.zig"), ("test-logic",), ("test-logic",),
     "Portable Codex credential decisions and token messages; native owner checks follow below"),
    (("src/bash*", "src/BashLifecycle.zig", "src/deadline.zig", "tests/integration/bash*"),
     ("test", "bash-owner-integration", "bash-lifecycle-integration", "bash-recovery-integration", "bash-integration"),
     ("test", "bash-owner-integration", "bash-lifecycle-integration", "bash-recovery-integration", "bash-integration"),
     "Bash execution, direct custody and process-crash recovery"),
    (("src/h2/*",), ("test-h2",), ("test-h2",), "The HTTP/2 client module's own tests"),
    (("src/codec_runtime*",), ("test-codec-runtime",), ("test-codec-runtime",),
     "The codec sandbox's own tests against tiny modules"),
    (("src/h2/policy.zig",), ("test-logic",), ("test-logic",), "HTTP/2 client policy core boundary"),
    (("src/history_memo.zig",), ("test-logic",), ("test-logic",), "History memo decisions and table"),
    (("src/provider.zig", "src/transport_policy.zig", "src/provider_output.zig", "src/model_adapter.zig", "src/history_memo.zig",
      "src/model_capability.zig", "src/failed_responses.zig"),
     ("test", "dispatch-integration", "transport-h2-integration"),
     ("test", "dispatch-integration", "transport-h2-integration"), "Model admission and transport"),
    (("src/model_instructions.txt",),
     ("check", "transport-h2-integration", "codex-h2-integration", "current-facts-integration",
      "server-delivery-integration", "measurement-check"),
     ("check", "transport-h2-integration", "codex-h2-integration", "current-facts-integration",
      "server-delivery-integration", "measurement-check"),
     "Shared model context prose: native encoding, fixture consumers and Go request oracles"),
    (("src/peer_message.txt",),
     ("test", "check", "dispatch-integration", "transport-h2-integration"),
     ("test", "check", "dispatch-integration", "transport-h2-integration"),
     "Shared peer facts: native request encoding and installed peer round trip"),
    (("tests/integration/dispatch_integration.py",),
     ("dispatch-integration", "dispatch-debug-integration"), ("dispatch-integration", "dispatch-debug-integration"),
     "Model scenarios, not shared fixture infrastructure"),
    (("tests/integration/transport_h2*", "tests/integration/codex_h2*",
      "tests/integration/codex_integration.py"),
     ("transport-h2-integration", "codex-h2-integration"),
     ("transport-h2-integration", "codex-h2-integration"),
     "Shared H2 fixture, managed imports and companion caller regression"),
    (("src/codex*", "tests/integration/codex*"),
     ("test", "codex-integration", "codex-credential-integration", "codex-h2-integration"),
     ("test", "codex-integration", "codex-credential-integration", "codex-h2-integration"),
     "Credential mutation and synthetic managed transport"),
    (("src/os/*",),
     ("check", "codex-credential-integration", "codex-h2-integration", "transport-h2-integration"),
     ("check", "codex-credential-integration", "codex-h2-integration", "transport-h2-integration"),
     "Platform boundary: the native owners it serves on each OS"),
    (("src/descriptor*", "src/os/descriptor_limit.zig", "src/host_launch.c", "src/server*.zig", "src/platform.zig", "src/cli.zig",
      "tests/integration/descriptor*", "tests/integration/host_launch*", "src/product_defaults.zig",
      "tests/integration/product_defaults.py"),
     ("test", "host-launch-integration", "descriptor-capacity-integration",
      "codex-h2-integration", "transport-h2-integration"),
     ("test", "host-launch-integration", "descriptor-capacity-integration",
      "codex-h2-integration", "transport-h2-integration"),
     "Startup capacity: every refusal boundary, managed transport and its companion oracle"),
    (("tests/integration/check.sh",), ("check-full",), ("check-full",),
     "Shared process inventory: native cases once, scheduling modes checked by driver tests"),
    (("tests/integration/login_signal_integration.py", "build.zig"), ("login-signal-integration",), (),
     "Linux-only native login signal loader witness"),
    (("tests/integration/current_facts_integration.py", "build.zig"),
     ("current-facts-integration",), ("current-facts-integration",), "Current producer/consumer oracle"),
    (("tests/integration/server_delivery_integration.py", "build.zig"),
     ("server-delivery-integration",), ("server-delivery-integration",), "Real reply inactivity and Host drain"),
    (("tests/integration/canonical_failure_integration.py", "tests/integration/model_fixture.py",
      "tests/integration/host_process.py", "build.zig"),
     ("canonical-failure-integration",), ("canonical-failure-integration",), "Canonical failure caller oracle"),
    (("tests/integration/control_integration.py", "tests/integration/model_fixture.py",
      "tests/integration/host_process.py"),
     ("check", "transport-h2-integration", "codex-h2-integration"),
     ("check", "transport-h2-integration", "codex-h2-integration"),
     "Shared fixture helpers retain composed callers and separately owned H2 consumers"),
    (("tests/integration/model_fixture.py", "tests/integration/host_process.py",
      "tests/integration/canonical_failure_integration.py"),
     ("current-facts-integration",), ("current-facts-integration",), "Current oracle's imported fixture owners"),
    (("tests/integration/model_fixture.py", "tests/integration/host_process.py",
      "tests/integration/control_integration.py"),
     ("server-delivery-integration",), ("server-delivery-integration",), "Delivery oracle's imported fixture owners"),
    (("build.zig", "build.zig.zon", "install.sh", "src/fetch_dependencies.sh", "src/build_*", "src/*.patch", ".agents/setup",
      ".github/actions/setup/action.yml"),
     ("check-full", "admission-debug-integration", "test-full"),
     ("check-full", "admission-debug-integration", "test-full"),
     "Build, dependency or bootstrap inputs"),
    (("build.zig", "build.zig.zon", "install.sh", "src/fetch_dependencies.sh", "src/build_transport.sh", ".agents/setup",
      ".github/actions/setup/action.yml"),
     ("transport-h2-integration", "codex-h2-integration"),
     ("transport-h2-integration", "codex-h2-integration"), "Transport build and managed TLS/H2 bootstrap"),
)

# Inputs to the Host's ReleaseSafe frames or to their gate. Frontend owners are
# client-only. check runs stack-frames; check-full does not.
STACK_FRAMES = ("src/*", "build.zig", "build.zig.zon", "tests/ci/stack_frames.py", "tests/ci/stack_frames.json")

CHECK_COVERS = {
    "test", "test-h2", "test-codec-runtime", "admission-integration", "dispatch-integration",
    "bash-owner-integration", "bash-lifecycle-integration", "bash-recovery-integration",
    "bash-integration", "codex-integration", "control-integration",
    "host-status-integration", "host-launch-integration", "host-stop-integration",
    "descriptor-capacity-integration",
    "proposal-integration", "activity-integration", "preference-policy-integration",
    "canonical-failure-integration",  # human_cli_integration.main executes all cases.
    "terminal-restoration-integration",  # Same full fixture in the human CLI gate.
}


# Files that configure or prune build caches, or the proof that they never cache acceptance.
CACHE_POLICY = {
    "build.zig", ".github/actions/setup/action.yml", ".github/scripts/prune-caches.cjs",
    ".github/workflows/cache-maintenance.yml", ".github/workflows/check.yml",
    ".github/workflows/previous-release-upgrade.yml", ".github/workflows/qualify-macos.yml",
    ".github/workflows/release.yml", "tests/ci/cache_execution.py",
}


def setup_requirements(targets):
    # Every runner installs the same fixture packages (tests/integration/requirements.txt)
    # for any target, so no fixture's import depends on a hand-kept target list.
    return {"go": "measurement-check" in targets, "python": bool(targets)}


def execution_batches(targets, check_part="all"):
    # Share compilation and graph execution only among independent owner suites.
    # Composed gates and latency-sensitive/long witnesses keep isolated execution.
    if check_part != "all" and "check-full" not in targets:
        raise ValueError("A full-check part requires check-full in the selection")
    if check_part == "execution":
        return [["check-full", "-Dcheck-part=execution"],
                *execution_batches([target for target in targets if target != "check-full"])]
    if check_part not in {"all", "callers"}:
        raise ValueError(f"Unknown full-check part: {check_part}")
    isolated = {"check", "check-full", "admission-debug-integration", "test-full",
                "host-launch-integration", "server-delivery-integration",
                "transport-h2-integration", "codex-h2-integration"}
    shared = [target for target in targets if target not in isolated]
    return (([shared] if shared else [])
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
        if (any(fnmatch.fnmatchcase(path, pattern) for pattern in STACK_FRAMES)
                and not any(fnmatch.fnmatchcase(path, pattern) for pattern in FRONTEND)):
            targets.add("stack-frames")
            reasons.add("Host stack frames: the ReleaseSafe frame gate (tests/ci/stack_frames.py)")
        if (path.startswith((".github/", "tests/ci/")) and path != ".github/actions/setup/action.yml"
                or path == "tests/integration/previous_release_upgrade.py"):
            reasons.add("CI policy: the policy job runs selector and workflow checks")
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
        if path in ("src/client.zig", "src/ResponseTiming.zig"):
            targets.add("test-full")  # Response wait/inactivity owner.
            native_targets.add("test-full")
    frontend = {path for path in paths if any(fnmatch.fnmatchcase(path, pattern) for pattern in FRONTEND)}
    others = [path for path in paths if path not in frontend
              and not (path.endswith(".md") or path.startswith(("docs/", "research/")))]
    # Only renderer-only diffs skip check. Beside other executable changes, frontend
    # owners that selected check keep it; AnswerRenderer never did unless strict.
    if frontend and (strict(paths) or others and frontend - {"src/AnswerRenderer.zig"}):
        targets.add("check")
        native_targets.add("check")
        reasons.add("Frontend change beside a strict path or other executable change keeps check")
    for checks in (targets, native_targets):
        if "check-full" in checks:
            checks.discard("check")
        if checks & {"check", "check-full"}:
            checks -= CHECK_COVERS
        if "check" in checks:
            checks.discard("stack-frames")
    # Linux predicts Mac except where code may differ by platform.
    mac_required = phase == "review" and any(mac_path(path) for path in paths)
    if mac_required:
        reasons.add("Mac-specific path: PR runs Mac Selected (tests/ci/platform_boundary.py)")
    if phase == "development":
        # Development does not replace final boundary/native acceptance.
        targets = {"test-logic"} if targets else set()
        native_targets = set()
    if "check-full" in native_targets:
        # The daily macOS workflow owns Mac check-full; the covered owners above
        # are not selected separately.
        native_targets.discard("check-full")
        reasons.add("Mac check-full: daily macOS qualification")
    cache_execution_checks = phase == "review" and any(path in CACHE_POLICY for path in paths)
    missing = (targets | native_targets) - available
    if missing:
        raise ValueError(f"Selected targets absent from build.zig: {sorted(missing)}")
    return {"phase": phase, "targets": sorted(targets),
            "native_targets": sorted(native_targets), "native_required": bool(native_targets),
            "mac_required": mac_required,
            # Store, recovery and upgrade changes fail for real; never rerun them.
            "retry": not strict(paths),
            "cache_execution_checks": cache_execution_checks,
            "linux_memory_checks": linux_memory_checks, "manual_checks": sorted(manual_checks),
            "reasons": sorted(reasons)}


def changed_paths(base, head):
    def commit(ref):
        return subprocess.check_output(
            ["git", "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}"],
            text=True, stderr=subprocess.PIPE).strip()
    head_commit, base_commit = commit(head), commit(base)
    # No rename inference: both deleted and added owners select their checks.
    raw = subprocess.check_output(["git", "diff", "--no-renames", "--name-only", "-z",
                                   base_commit, head_commit])
    return [p.decode("utf-8", "surrogateescape") for p in raw.split(b"\0") if p], base_commit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--phase", choices=("development", "review"), default="review")
    args = parser.parse_args()
    available = set(re.findall(r'b\.step\(\s*"([a-z0-9-]+)"', Path("build.zig").read_text()))
    paths, base = changed_paths(args.base, args.head)
    result = select(paths, args.phase, available)
    result["base"] = base
    result["head"] = subprocess.check_output(["git", "rev-parse", args.head], text=True).strip()
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

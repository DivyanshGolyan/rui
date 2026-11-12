# Restart coordinator custody (#1342)

## Shape

- **Values in:** restart-all is a task; activation carries the original observed
  Host, snapshot, reconstructed launch options, selected build and version.
  The worker does not substitute a fresh observation for what Upgrade checked.
- **Who decides:** `HostLifecycle.activate` retains all exact-instance,
  retirement, pinned-launch and readiness decisions. Restart-all retains its
  discovery and reporting policy. A coordinator process applies these owners.
- **Owner reused:** `host_coordinator` owns process custody for restart-all and
  activation from CLI Upgrade and `UpgradeJob`. No Host thread is added.
- **Facts derived:** no caller-Host marker, ancestry lookup or restart-last flag.
  A spawned coordinator leaves its inherited session before accepting a task.
- **Outcomes whole:** activation progress and the complete ActivationOutcome
  return over a pipe; loss of its reader cannot cancel committed activation.
  Restart receipts tolerate closed stdout and fall back to diagnostics.

## Decision

Use setsid in a fresh coordinator process (option a with an exec boundary).
Merely calling setsid in place fails when Bash has exec'd Rui as its
session/group leader. Forking a
continuation inside UpgradeJob would inherit a multithreaded runtime. Instead,
spawn a fresh image which leaves its inherited session before reading a task.
Restarting the caller last would require caller identification and still leave
a special final handoff. This needs neither identification nor special ordering,
and keeps one lifecycle implementation. The input pipe is private and carries
bounded launch configuration only in memory; it is never persisted or logged. Once handed off,
the coordinator finishes even if its caller departs. Cancellation is checked
before the handoff; abandoning a potentially stopped Host is not cancellation.

## Scope and evidence

Covers standalone and Host-Bash restart-all (including origin-first), closed
stdout, CLI Upgrade and inline Upgrade through the same activation owner.
Both installers continue invoking the selected CLI and treating restart failure
as nonfatal. Historical external installers and OS-crash recovery remain out
of scope. The native actor uses a synthetic release identity and retained-build
paths; readiness also checks the exact selected executable, not version text alone.

Verification uses focused coordinator/restart/lifecycle/UpgradeJob unit tests,
`upgrade_integration.py`'s `restart-all`, `lifecycle` and `terminal` selectors,
and each installer's selected-binary/nonfatal-restart case. No full local suite
or live provider check is required for this patch.

Removing setsid in the coordinator reproduces both failures at the native
custody assertions: the originating Host has exited and is unavailable; for
restart-all, the later Host still has its original instance. Propagating report
write failure instead of the optional diagnostic fallback fails the whole-outcome
broken-pipe unit test. Both mutations are restored before final verification.

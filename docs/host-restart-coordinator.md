# Restart coordinator custody (#1342)

## Shape

- **Values in:** a same-user HOME, optional pinned build/version, and report mode.
  Upgrade's pre-install census is warning-only; the worker discovers again after
  publication. No private launch snapshot or environment crosses the task pipe.
- **Who decides:** `host_restart_all` owns discovery, reobservation, per-Host
  activation, result categories and reporting. `HostLifecycle.activate` alone
  owns exact-instance retirement, pinned launch and readiness.
- **Owner reused:** `host_coordinator` owns only detached process custody and
  batch-result transport for standalone restart-all, CLI Upgrade and UpgradeJob.
  There is no separate single-Host activation task or added Host thread.
- **Facts derived:** no caller-Host marker, ancestry lookup or restart-last flag.
  A spawned coordinator leaves its inherited session before accepting a task.
- **Outcomes whole:** every Store's outcome and progress return over a pipe;
  selected-Store compatibility is derived from that batch, not activated again.
  Loss of the reader cannot cancel the batch or abandon its later Stores.
  Closed stdout falls back to optional stderr diagnostics. Global worker errors
  retain their original diagnostic; the receipt preserves cancellation or
  unconfirmed failure, since error sets cannot be decoded from JSON.

## Decision

Use setsid in a fresh coordinator process (option a with an exec boundary).
Merely calling setsid in place fails when Bash has exec'd Rui as its
session/group leader. Forking a
continuation inside UpgradeJob would inherit a multithreaded runtime. Instead,
spawn a fresh image which leaves its inherited session before reading a task.
Restarting the caller last would require caller identification and still leave
a special final handoff. This needs neither identification nor special ordering,
and keeps one lifecycle implementation. The input pipe is private and carries
bounded routing and the pinned target only in memory; it is never persisted. Once handed off,
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
broken-pipe unit test. These negative controls belong to the original coordinator evidence; the merged
batch path reruns the native custody matrix and broken-pipe domain test.

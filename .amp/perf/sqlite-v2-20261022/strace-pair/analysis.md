# Bash spawn→exec delay: one strace pair, candidate vs current main (2026-10-22)

Requested by the user via the coordinator: one Bash launch per arm, `strace -f -T -tt`, same command, load and build.

## Identity
- Current main 4f478c324e6c1e9b13207856a8c1e562b75f2e98 (`git archive` export), ReleaseFast, rui sha256 0b5254b7eee45f13…
- Candidate wip/sqlite-v2 2586290cf73c6342d1f86b9ddaff68732354519c (export, tree 965fe8a5, 100 ms fixture), ReleaseFast,
  rui sha256 0a826891a6dc2c79…
- Both built fresh in this orb with `zig build -Doptimize=ReleaseFast` (zig 0.17.0); logs build-main.log, build-cand.log.
  The main log retains the same transient pinned-transport "failed command" line seen in earlier builds; exit 0.
  No older binary was reused: src/, build.zig and build.zig.zon are tree-identical between d4f87000 and 4f478c32, but
  the repository has no input-identity tooling, so main was rebuilt.
- Full hashes: identity.sha256. Harness: control/same_group_control_v2.py (exact fixture command, timeout_ms=100, plus
  $EPOCHREALTIME markers), tests/integration from the candidate checkout, the same for both arms.
- Tracer: strace 6.1, `strace -D -f -tt -T -y -s 200` on `host serve` only (strace-launch.py); the Host PID is the tracee.
- Load: 4 busy loops on 2 vCPU, the same as control v2. Order: main, then candidate (run-pair.sh, log.txt).
- Result: both arms published the PID before the kill and resolved timed_out (main.log, cand.log).

## Timeline (strace -tt wall clock; clone is a complete line, so its timestamp is syscall entry)

| Step | main (Host TID 864365, child 864374) | candidate (Host TID 864402, child 864413) |
|---|---|---|
| clone entry → return (fork, SIGCHLD, no CLONE_VM) | 14.839839, 0.153 ms | 17.636884, 0.177 ms |
| Parent: closes, then `read(exec-status pipe)` entry | 14.840075 | 17.637154 |
| **No syscall from any traced TID** (clone return → child first syscall) | **5.499 ms** | **11.713 ms** |
| Child first syscall `set_robust_list` | 14.845491 | 17.648774 |
| Child chdir, 3x dup2, setpgid (pre-exec) | 0.291 ms | 0.241 ms |
| execve("/bin/bash") entry | 14.845782 (unfinished; resumed 14.847190, 1.396 ms) | 17.649015 (complete, 0.237 ms) |
| Parent read resumed (EOF = exec succeeded) | 14.846025, 5.943 ms | 17.649328, 12.167 ms |
| clone entry → execve entry | 5.943 ms | 12.131 ms (+6.188) |
| clone entry → execve return | 7.351 ms | 12.368 ms (+5.017) |

Between the parent's `read` entry and the child's `set_robust_list`, the trace has no line from any Host thread or the
child in either arm (checked mechanically: only the parent's 4 post-clone lines lie between clone and the child's first
syscall).

## Findings
- The pair reproduces the direction of the control-v2 effect: the candidate is 6.19 ms slower from clone to bash execve
  entry (control-v2 median difference about 3.5 ms).
- No syscall accounts for it. Every syscall on the launch path is within 0.05 ms between arms (clone 0.153 vs 0.177 ms;
  pre-exec 0.291 vs 0.241 ms). The bash execve is slower in main (1.396 vs 0.237 ms). The whole difference lies in the
  interval with no syscall from clone return to the child's first syscall: 5.50 vs 11.71 ms.
- strace cannot see that interval's contents. It contains ptrace auto-attach of the new child (strace -f), scheduler
  latency under 4 busy loops on 2 vCPU, and the child's user-space start in glibc fork (copy-on-write faults before
  set_robust_list). This pair cannot divide the 6.2 ms among those. It is NOT attributed to CPU, I/O or the Store.
- Store transaction on the launch path: the last Store commit before launch is Bash Attempt admission
  (`admitNextActionAttempt`, server.zig admitBashAttempt). It is the same transaction in both arms:
  main DELETE journal = 5 fsyncs + unlink, 14.834259–14.836962 (about 2.7 ms), ending 2.9 ms before clone;
  candidate WAL = 1 fsync of -wal (0.769 ms) at 17.634133, ending 1.98 ms before clone.
  Then both write and fsync the scratch script (main 0.517 ms, candidate 0.589 ms; Bash preparation, unchanged code).
  Both precede the spawn timestamp (`bash.Prepared.launch` reads `started` immediately before std.process.spawn).
- The launch itself (`withActionDispatchHandoff`) holds the Store lock and runs one read-only validation SELECT. Main:
  fcntl read lock + -journal/-wal stat probes; candidate: no file syscalls (exclusive WAL). No COMMIT and no fsync.
- Durability: Attempt admission must be durable before spawn (ARCHITECTURE: the Dispatch Permit comes only from the
  invocation committing fresh admission; recovery treats an admitted Attempt without a result as indeterminate and
  never replays Bash. A non-durable admission could be lost after launch, and recovery could then launch Bash a second
  time.) That barrier is mandatory and is not moved. The candidate makes it cheaper (1 fsync vs 5 + unlink).

## Limits
- One launch per arm, by request; the control-v2 spread (failed-trial medians 25.8 vs 37.4 ms) is larger than this
  pair's difference, so the pair shows mechanism location, not effect size.
- strace -f stops each traced thread on every syscall and on clone; it adds latency to the measured interval and
  competes for 2 vCPU with the load. -tt is wall clock (CLOCK_REALTIME), microsecond resolution.
- Order main → candidate, not counterbalanced.

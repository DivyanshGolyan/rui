# Bash supervision: accounting evidence and implementation gap

6 September 2026. Read-only production-source audit for [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68). This prices no synthetic worker and makes no integrated-footprint claim.

## Source audit before the prototype

The current Bash path is historical in-memory capture, not the accepted disk-first reactor design. Measuring it at scale would not establish the future Bash supervision cost.

- [Execution](../../src/bash_tool.zig:51) owns allocated stdout/stderr slices and frees them on deinit.
- [runBounded](../../src/bash_tool.zig:259) spawns Bash with two pipes, passes an allocator into MultiReader, and accumulates buffered output until EOF, cancellation, timeout or the historical output threshold. It does not drain captured bytes into scratch as they arrive.
- Both returned streams are truncated to the historical 64 KiB per-stream maximum. Two full returned streams therefore contain 128 KiB of output bytes. At 1,000 simultaneously retained such results that would be 125 MiB of payload alone. This is arithmetic, not measured concurrency or an allocation upper bound: capacity growth, threshold overshoot, other state and result lifetimes differ. This historical threshold is not a newly accepted V1 output cap.
- After pipe EOF the source uses an asynchronous child wait plus short sleeps. Its underlying I/O execution strategy must not be extrapolated into a per-command dedicated-thread or stack budget.
- [Lifecycle admission](../../src/lifecycle.zig:1049) calls the executor, then stores the returned result while its captured slices remain live. This is not the selected direct scratch-evidence interface.

No benchmark was run: there is no existing complete Bash supervisor matching the accepted architecture in this checkout. The README explicitly documents that implementation gap.

## Account the selected design

For H occupied Bash custodians, the needed terms are:

`H × actual per-child continuation/handle state + actual simultaneous capture windows + shared reactor/spawn state`.

Per-child state includes process/group identity, pipe/scratch ownership, EOF/exit/cancellation state and deadline information. Its exact struct size comes from implementation, not a guessed allowance. Include transient spawn argument/environment materialization and the underlying process API's actual allocations. Canonical command text remains disk-first; no payload-sized retained descriptor is justified merely for convenience.

The accepted file roles are stdout scratch, stderr scratch and input only if materialization is necessary. Both output pipes must drain without starvation. A scratch write completes or reports failure before the borrowed window is reused. If an asynchronous write retains a buffer, that buffer remains charged to its actual owner; calling it shared cannot erase concurrent borrowers. Do not create a per-command output collection, retained maximum-output reservation, permanent worker or dedicated stack.

Report model-selected Bash/descendant process memory separately. Count OnePage's actual parent supervision and any additional helper OnePage requires. Keep kernel pipe/process resources distinct from process physical footprint, while verifying both operationally.

## Representative measurement obligation

Use real pipe-producing child processes with the selected reactor/capture path, not artificial touched worker stacks. Cover silent children, concurrent stdout/stderr output, large cumulative output, exit before pipe closure, cancellation, stalled capture and scratch exhaustion. Measure parent baseline/peak/retained physical footprint, live named allocations, threads, descriptors and exact captured bytes. Verify bounded service and complete child/pipe/scratch cleanup over churn.

Vary concurrency up to the selected 1,000 target where OS process capacity permits; report process-capacity limits instead of silently reducing concurrency or changing system-wide settings. Child workload memory is observed separately, not included in the parent measurement. This experiment would qualify a narrow supervisor; Store integration, controls and whole-Host qualification remain separate evidence.

The audit identifies what must be measured and what current accumulation must be removed. It selects no new memory/window/thread limit and does not authorize a production implementation slice during Wayfinder planning.

## Follow-up prototype evidence

The user requested a representative native supervision probe after the audit. Local `codex/bash-supervision-probe`, commit `58be5e5`, captures code and raw results at `/tmp/onepage-bash-supervision/research/bash-supervision-probe/README.md`. Three 1,000-child output cohorts passed: median sampled parent physical footprint 1.563 MiB, 768.25 KiB above its own baseline, one thread, 4,004 observed descriptors at peak and three after cleanup. The owner/poll arrays total 72,000 bytes at 1,000 plus one shared 16 KiB copy window; this is a prototype shape, not the final Host ABI.

Main and large-output runs reaped 10,530 total children, including ten expected cancellations and ten forced scratch failures. Exact successful output and failed prefixes were checked; readiness barriers prove concurrent cohorts. At 100 children, increasing total output from 12.5 to 200 MiB left sampled parent footprint essentially unchanged. This supports the selected disk-first supervision topology without inventing a worker allowance.

The fixture invokes Bash, which execs a tiny producer; child workload memory is excluded. No SQLite, durable controls, large command/input materialization, full timeout/descendant/recovery semantics or final Host integration is measured. Shared writes are synchronous; async retained buffers would require additional real ownership accounting. Sampling can miss short peaks, FD spawn overlap exceeds observed samples, and churn proves cleanup rather than indefinite memory stability. Production is unchanged.

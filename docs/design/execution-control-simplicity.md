# Keep execution control simple

## Subsequent ownership amendment — 10 September 2026

The [direct transactional operation](transactional-operations.md), [independent workflow](shared-request-identity.md) and [observation](two-session-workflow-trace.md#observation-and-permission) decisions amend the earlier integrated-classifier and globally atomic Run-capture assumptions. Preserve single-owner serialization and physical custody until cleanup, while Workflow Runtime observes core status through its API. Earlier contention measurements remain evidence for their tested mechanism, not certification of the revised composition.

> **Dated decision trace, published 6 September 2026.** The [normative architecture](../../ARCHITECTURE.md) and [product contract](../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Accepted 5 September 2026 after the user reviewed the experiments and explicitly requested updates to the issues and docs. These decisions amend the proposed Host Runtime, not its implementation. Numeric budgets and production certification remain outstanding.

## Selected mechanisms

Physical Custody is one startup-sized in-memory table of content-free records. Use plain bounded table scans in V1, without a separate free list, active-record index, resident Session collection, or durable SQLite slot table. Reserve a record before Attempt admission; rollback returns the unused reservation, while successful admission permits dispatch only after its commit is observed. SQLite owns Session occupancy, Attempt/Resolution facts, cancellation and retry eligibility; it does not duplicate live handle ownership. Logical settlement does not free a record whose physical cleanup is still outstanding. Reuse requires safe resource release and rejection of stale or duplicate events by exact admitted identity. The accounting invariant is free records plus occupied records equals startup Active Capacity; it does not introduce a second credit pool.

When no runnable work or required deadline/poll is due, sleep until an existing I/O/control notification or required wake. Do not add periodic scans merely to revisit an empty custody table. The existing single bounded SQLite retry-eligibility poll remains; its cadence is a separate budget decision. This is not a whole-process prohibition on allocation after startup: library, evaluator, transport, and scratch resources retain their existing bounded ownership and accounting.

Before starting another queued inspection capture, give already-ready control commands a bounded turn through the existing Host driving path. Do not drain an inspection backlog ahead of a ready stop/cancel or other control command. A capture already in progress retains its complete committed view and is not preempted between private batches. This adds no separate scheduler, priority-queue subsystem, second reader, WAL requirement, or public snapshot mechanism. The maximum acceptable delay from one capture and sustained-load fairness remain with the existing work/resource decisions.

Workflow cancellation continues to compose ordinary Session stops, with no rule based on who submitted the selected work. The selected work's durable terminal outcome and atomic Session occupancy release define logical stop completion; physical resources remain owned and charged until safe release. These are different existing responsibilities, not two copies of workflow state.

## Why these mechanisms are sufficient

The native probes measured a 0.053 microsecond state scan and a 15.491 microsecond exploratory full completion/reuse burst at capacity 100. They did not justify a competing index. Capacity 1,000 exposed repeated-search growth and remains a sensitivity test, not a default or maximum.

Synthetic idle CPU at capacity 100 was 0.0189% of one core with an external wake, versus 0.2440% with 5 ms timed waits. Actual wake/scheduling cost matters more than scan arithmetic; this does not select the durable retry-poll cadence.

The memory/SQLite handoff fixture passed 100 safe traces and rejected all 80 deliberately unsafe controls; half ran under ASan/UBSan. Real DELETE/EXTRA SQLite commits and reopen, controlled owner exits, pipes and late callbacks exercised admission/custody boundaries. No tested trace required durable slot rows. These finite fixture traces are not production classifiers or a proof of all concurrency schedules.

For four queued 100,000-record reports, median stop acknowledgement was 227.2 ms under FIFO and 52.2 ms when the stop ran after the current capture. A wide report still imposed about 346.5 ms. This supports giving controls a turn between reports while leaving the maximum acceptable single-capture delay open. Reports were synthetic; actual status derivation, encoding, HTTP, full cancellation traversal, and sustained fairness remain to be measured.

## Evidence and owning work

The raw sources and observations are captured on local branch `codex/execution-control-experiments`, commit `4be2d74`, under `research/execution-control-experiments/README.md`. The branch is not pushed; the self-contained published evidence is linked below. Preserve those reports as historical measurements, rather than rewriting their recommendations as if they were already accepted when measured.

- [Host execution and custody evidence](https://github.com/DivyanshGolyan/onepage/issues/34#issuecomment-5553459468).
- [Capacity and idle-wakeup evidence](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5553459714).
- [Inspection and stop-delay evidence](https://github.com/DivyanshGolyan/onepage/issues/95#issuecomment-5553460241).
- [Accepted execution-control simplification](https://github.com/DivyanshGolyan/onepage/issues/68#issuecomment-5553520534) is the published coordination record; [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68) retains the numeric controls.
- [Choose SQLite storage and command-work limits](https://github.com/DivyanshGolyan/onepage/issues/95) owns single-capture work/delay and query policy.
- [Approve the minimal V1 limit matrix and removal sequence](https://github.com/DivyanshGolyan/onepage/issues/89) remains the gate before the paused relational redesign resumes.

The owning normative rules are [architecture](../../ARCHITECTURE.md), [implementation discipline](../style.md), [verification](../../VERIFICATION.md), [the disk-first runtime ADR](../adr/0021-use-a-disk-first-bounded-host-runtime.md), and [the inspection ADR](../adr/0024-capture-run-inspection-before-delivery.md). No numeric capacity, polling interval, row quota, source migration, or passing production test is selected by this amendment.

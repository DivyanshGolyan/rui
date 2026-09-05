---
status: accepted
---

# Capture Run inspection before delivery

Accepted 5 September 2026. This amends ADR-0022's inspection rules and ADR-0021's
private-scratch transaction boundary. The owning contracts are in
[ARCHITECTURE.md](../../ARCHITECTURE.md#run-interface) and
[VERIFICATION.md](../../VERIFICATION.md#run-interface); neither the HTTP interface
nor this capture path is implemented by this decision.

The sole Storage Owner captures a complete report of one Run through bounded
private batches on its existing SQLite connection, under one read transaction.
The captured revision and all report facts come from that same committed view.
Facts stream incrementally to immediately unlinked, non-authoritative scratch;
variable content remains immutable references read separately through windows.

Other database admissions and settlements wait during capture. The owner finishes
active statements and ends the transaction before delivery. Later execution
cannot invalidate the report. It describes its captured moment; exact-target
commands still check current authority and preconditions.

The Host reuses one capture workspace serially. A completed report retains only
charged scratch and bounded delivery state until completion, failure, or
abandonment. All exit paths release capture resources and reclaim scratch;
process death discards it without changing durable Run state. Delivery retains
no SQLite cursor, statement, transaction, or lock. This permits a read
transaction to span private report-scratch writes only; external effects,
uploads, and network delivery remain outside transactions.

Start with the existing connection and journaling policy. Inspection adds no
second reader, WAL requirement, per-Run database, public snapshot identifier, or
historical snapshot service. Batching bounds working memory, not total capture
time or logical collection size. Failed capture or truncated delivery is
explicitly incomplete, never a successful partial inventory.

Before starting another queued inspection capture, give already-ready controls and ordinary settlement/advancement work bounded turns through the existing Host driving path. Do not drain an inspection backlog ahead of either class, or drain either class indefinitely ahead of inspection. A capture already in progress retains its complete committed view and is not preempted between private batches. This adds no separate scheduler, priority-queue subsystem, second reader, WAL requirement, or public snapshot mechanism. The service quantum, maximum acceptable delay from one capture, and sustained-load fairness remain with the existing work/resource decisions.

The 6 September 2026 refinement extends between-capture turns to ordinary ready settlement and advancement, and requires fixed-window encoding/escaping with block writes. Permitted strings may span windows; neither the experimental buffer nor field size becomes a limit. The single read view, connection, and scratch lifetime remain unchanged. Cooperative time/byte abort policies and their report-availability tradeoff remain undecided in #95; a check between batches cannot guarantee a deadline during a blocked write.

The [accepted execution-control simplification](../design/execution-control-simplicity.md) records the supporting native contention experiment. The accepted rule concerns scheduling between captures; it does not promise a fixed response time or select a record-count limit.

Issues #68 and #95 own numerical budgets, admission/fairness, capture work,
temporary disk, descriptors, memory, and failure behavior. Completed reports for
slow clients are a separately charged population. Measure actual queries and
encoding, whole-Host command delay under repeated polling, and memory after
capture/delivery churn. No benchmark row count or batch size becomes a product
limit. Message application facts follow the normative terminal-failure contract; exact wire encoding belongs to compiled public types and golden fixtures. Remaining public behavior questions stay in the Session/client decision.

The native synthetic sweep measured batched capture medians of 1.1 ms for 1,000
records, 8.7 ms for 10,000, and 94 ms for 100,000. SQLite heap stayed around
173 KiB for those fixtures. Larger/wider reports took longer. These support the
simpler starting point, not production latency or memory guarantees. Celld's
private inspection copy provides a related lifetime precedent; its whole-cell
backup and replication machinery are not selected for OnePage.

- [Single-connection measurements](../../research/inspection-capture-proof/SINGLE_CONNECTION.md)
- [Inspection research](../research/reliable-run-inspection.md)
- [Celld source review](../research/celld-inspection-memory-lessons.md)
- [Historical Run API planning](https://github.com/DivyanshGolyan/onepage/issues/39)
- [Host budgets](https://github.com/DivyanshGolyan/onepage/issues/68)
- [SQLite work and settings](https://github.com/DivyanshGolyan/onepage/issues/95)

---
status: accepted
---

# Capture Run inspection before delivery

## Accepted amendment — Independent observations and reusable Session keys (10 September 2026)

Workflow Runtime composes its own saved Run/call records with ordinary Session core observations. Progress can briefly lag and need not come from one globally atomic cross-Session read view; this supersedes that requirement below and does not permit reading core tables. Each live evaluator instead receives a fixed set of recorded results, and cancellation completion follows saved submissions and required stops. Inspection exposes the full keys of associated durable Sessions with enough context for an agent to choose one and write that exact key into another workflow. It requires no workflow-output metadata or previous-Run lookup code and continues current Session state. Preserve bounded capture/encoding, charged scratch, cleanup, explicit incomplete reports and service for controls/settlement. The historical single-view measurements do not certify this revised composition. See [the walkthrough](../design/two-session-workflow-trace.md).

For implementation, read the consolidated [inspection contract](../architecture/workflows.md#run-interface) and [verification](../verification/workflows.md#run-interface). The record below preserves the original decision and later amendments; superseded wording is historical.

Accepted 5 September 2026. This amends ADR-0022's inspection rules and ADR-0021's
private-scratch transaction boundary. The owning contracts are in
[ARCHITECTURE.md](../architecture/workflows.md#run-interface) and
[VERIFICATION.md](../verification/workflows.md#run-interface); neither the HTTP interface
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

The 6 September 2026 refinement extends between-capture turns to ordinary ready settlement and advancement, and requires fixed-window encoding/escaping with block writes. Permitted strings may span windows; neither the experimental buffer nor field size becomes a limit. The single read view, connection, and scratch lifetime remain unchanged. The 7 September scope split moves inspection query shape, read ownership and responsiveness to [Choose inspection queries and read ownership for responsive controls](https://github.com/DivyanshGolyan/onepage/issues/115), starting from the existing complete report with no elapsed-time abort. A check between batches cannot guarantee a deadline during a blocked write; any later behavior or ownership amendment needs an explicit decision.

The [accepted execution-control simplification](../design/execution-control-simplicity.md) records the supporting native contention experiment. The accepted rule concerns scheduling between captures; it does not promise a fixed response time or select a record-count limit.

[Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68) and
[Choose SQLite storage and command-work limits](https://github.com/DivyanshGolyan/onepage/issues/95)
own Host admission/resources and SQLite settings, import and non-inspection command work.
[Choose inspection queries and read ownership for responsive controls](https://github.com/DivyanshGolyan/onepage/issues/115)
owns inspection access shape, read ownership and capture/control fairness. Completed reports for
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
- [Field-to-fact trace](../research/run-inspection-field-trace.md)
- [Native query-cost experiment](../../research/run-inspection-query-cost/README.md)
- [Inspection research](../research/reliable-run-inspection.md)
- [Celld source review](../research/celld-inspection-memory-lessons.md)
- [Historical Run API planning](https://github.com/DivyanshGolyan/onepage/issues/39)
- [Host budgets](https://github.com/DivyanshGolyan/onepage/issues/68)
- [SQLite work and settings](https://github.com/DivyanshGolyan/onepage/issues/95)
- [Choose inspection queries and read ownership for responsive controls](https://github.com/DivyanshGolyan/onepage/issues/115)

## V1 ownership resolution — 8 September 2026

The user accepted retaining the existing single Storage Owner for V1 in [Choose inspection queries and read ownership for responsive controls](https://github.com/DivyanshGolyan/onepage/issues/115). Complete capture finishes before other database work; ready controls and settlements receive service before another capture. No additional throwaway prototype is required to settle ownership.

Current-fact query measurements support avoiding resolved-history scans, but do not certify the complete classifier or sustained-load responsiveness. Integrated queries, encoding, shared admissions, competing arrivals, slow delivery and aggregate scratch remain implementation verification obligations in VERIFICATION.md. The existing p95 acknowledgement target remains a workload qualification target, not a deadline for arbitrarily large reports. Exact indexes and service quanta belong to implementation; a failure to qualify requires an explicit design review, not silent truncation, quotas or another reader. Earlier measurements and investigation notes retain their historical scope.

The [combined resource resolution](https://github.com/DivyanshGolyan/onepage/issues/89#issuecomment-5578432698) closes the earlier maximum-capture-delay question by retaining no hard capture deadline and qualifying the defined-workload p95 target. It does not leave a numerical maximum awaiting selection.

---
status: amended by ADR-0021
---

# ADR-0013: Bound orchestration memory, not model-chosen workload memory

OnePage's memory guarantee covers resources owned by the runtime: Active Credits, content-free Physical Custody records, bounded Decision Snapshots, Host Runtime metadata, SQLite, provider transport, fixed borrowed windows, the shared validation/import workspace, and the live Workflow Evaluator. Variable content is dynamically charged to immediately unlinked scratch rather than retained in per-active memory. The resident working set is a function of explicit capacities and current in-flight Operations, not total durable Sessions, Conversation length, historical opens, terminal Turns, or Blocked Workflow Runs. Terminal Turns add durable bytes, not resident per-Turn objects; a live evaluation scales only to its bounded Visibility Snapshot and retains no cumulative state from earlier evaluations.

Memory intentionally consumed by a model-requested Bash process or its descendants is workload memory. OnePage reports it separately and still owns bounded output capture, cancellation, process-group cleanup, and durable Resolution publication.

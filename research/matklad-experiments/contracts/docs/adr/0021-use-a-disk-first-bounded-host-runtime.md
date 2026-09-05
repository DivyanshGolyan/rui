---
status: accepted
---

# Use one disk-first bounded Host Runtime

Amended by [ADR-0024](0024-capture-run-inspection-before-delivery.md): an inspection read transaction may span private report-scratch writes. Network delivery and external effects remain outside transactions.

## Accepted execution-control amendment — 5 September 2026

Physical Custody is one startup-sized in-memory table of content-free records. Use plain bounded table scans in V1, without a separate free list, active-record index, resident Session collection, or durable SQLite slot table. Reserve a record before Attempt admission; rollback returns the unused reservation, while successful admission permits dispatch only after its commit is observed. SQLite owns Session occupancy, Attempt/Resolution facts, cancellation and retry eligibility; it does not duplicate live handle ownership. Logical settlement does not free a record whose physical cleanup is still outstanding. Reuse requires safe resource release and rejection of stale or duplicate events by exact admitted identity. The accounting invariant is free records plus occupied records equals startup Active Capacity; it does not introduce a second credit pool.

When no runnable work or required deadline/poll is due, sleep until an existing I/O/control notification or required wake. Do not add periodic scans merely to revisit an empty custody table. The existing single bounded SQLite retry-eligibility poll remains; its cadence is a separate budget decision. This is not a whole-process prohibition on allocation after startup: library, evaluator, transport, and scratch resources retain their existing bounded ownership and accounting.

See the [accepted simplification and evidence](../design/execution-control-simplicity.md). Numeric resource decisions remain open; prototype results are not production certification.

## Accepted server-lifetime amendment — 5 September 2026

The foreground Host/control context is the explicitly started local server, holding exclusive Store ownership through startup recovery and live execution. Clients never acquire execution custody, open SQLite, or schedule progress. Server driving continues without clients. Infrastructure stop fences dispatch promptly and performs bounded effect-aware cleanup without waiting deliberately for LLM completion; it is not Run cancellation or user-command Model Interruption. Explicit restart recovers unfinished facts under existing effect rules and remaining budgets. See [server ownership](../../ARCHITECTURE.md#server-ownership-and-local-clients) and [lifecycle verification](../../VERIFICATION.md#server-lifecycle-and-local-command-boundary).

## Original decision

OnePage uses one foreground Host/control context as the sole Storage Owner and one multiplexed I/O Reactor that observes provider streams, subprocess pipes, and temporary Action executors. Only the Storage Owner accesses SQLite or selects semantic meaning. One bounded table of content-free Physical Custody records implements Active Capacity: occupying one record is one Active Credit, not a second object or pool. There is no per-Turn driver, permanent Patch lane, retained worker, payload buffer, parser workspace, or resident Session object. Bash and Patch share one closed typed Action lifecycle and may execute concurrently without a Workspace fence or isolation guarantee.

Attempt admission reserves capacity before `BEGIN IMMEDIATE` and issues a one-shot post-commit Dispatch Permit only to the invocation that observed the commit. Exact outbound requests and inbound provider or tool bytes move through fixed borrowed windows and dynamically charged, immediately unlinked scratch. No SQLite transaction spans external I/O. Scratch is non-authoritative and nonrecoverable: loss leaves the Attempt unresolved for effect-specific recovery.

After effect-specific terminalization, the Storage Owner parses sealed evidence in one shared serial validation/import workspace. Normal content, Attempt Completion, Operation Resolution, Conversation, User Message, or permission facts, and the next semantic consequence commit in one transaction. The sole Completion-only exception is a retryable model Completion committed atomically with immutable future eligibility while its Operation remains unresolved. Each Attempt has at most one Completion; exact replay is idempotent and contradictory evidence is rejected. SQLite eligibility rows plus one bounded periodic query replace per-Turn timers, wake objects, and a second scheduler.

This decision removes ADR-0003's Workspace-quiescence assumption while retaining its external-truth and Patch-reconciliation rules. It supersedes ADR-0011's Activation Slot pool and ADR-0016's generic two-transaction Completion/Resolution protocol, and amends ADR-0010, ADR-0013, and ADR-0015. Historical buffer, scratch-replay, online-detector, driver-lease, and execution-cell designs remain research evidence only.

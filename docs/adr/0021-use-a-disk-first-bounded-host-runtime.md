---
status: accepted
---

# Use one disk-first bounded Host Runtime

OnePage uses one foreground Host/control context as the sole Storage Owner and one multiplexed I/O Reactor that observes provider streams, subprocess pipes, and temporary Action executors. Only the Storage Owner accesses SQLite or selects semantic meaning. One bounded table of content-free Physical Custody records implements Active Capacity: occupying one record is one Active Credit, not a second object or pool. There is no per-Turn driver, permanent Patch lane, retained worker, payload buffer, parser workspace, or resident Session object. Bash and Patch share one closed typed Action lifecycle and may execute concurrently without a Workspace fence or isolation guarantee.

Attempt admission reserves capacity before `BEGIN IMMEDIATE` and issues a one-shot post-commit Dispatch Permit only to the invocation that observed the commit. Exact outbound requests and inbound provider or tool bytes move through fixed borrowed windows and dynamically charged, immediately unlinked scratch. No SQLite transaction spans external I/O. Scratch is non-authoritative and nonrecoverable: loss leaves the Attempt unresolved for effect-specific recovery.

After effect-specific terminalization, the Storage Owner parses sealed evidence in one shared serial validation/import workspace. Normal content, Attempt Completion, Operation Resolution, Conversation, User Message, or permission facts, and the next semantic consequence commit in one transaction. The sole Completion-only exception is a retryable model Completion committed atomically with immutable future eligibility while its Operation remains unresolved. Each Attempt has at most one Completion; exact replay is idempotent and contradictory evidence is rejected. SQLite eligibility rows plus one bounded periodic query replace per-Turn timers, wake objects, and a second scheduler.

This decision removes ADR-0003's Workspace-quiescence assumption while retaining its external-truth and Patch-reconciliation rules. It supersedes ADR-0011's Activation Slot pool and ADR-0016's generic two-transaction Completion/Resolution protocol, and amends ADR-0010, ADR-0013, and ADR-0015. Historical buffer, scratch-replay, online-detector, driver-lease, and execution-cell designs remain research evidence only.

# ADR-0013: Bound orchestration memory, not model-chosen workload memory

Status: accepted

OnePage's memory guarantee covers resources owned by the harness: Activation Slots, live Harness state, Host Runtime metadata, SQLite, provider transport, bounded adapter capture, shared semantic-validation workspaces, and the one live Host-managed workflow evaluation. Their resident working set must be a function of explicit host and stage capacities and current in-flight work, not total durable Sessions, Conversation length, historical opens, or Blocked Workflow Runs. Terminal Jobs add durable bytes, not resident per-Job objects; a live evaluation may scale only to its bounded current Visibility Snapshot under its fixed Workflow Resource Profile and retains no cumulative state from earlier evaluations.

Memory intentionally consumed by a model-requested Bash process or its descendants is workload memory. OnePage does not constrain that computation merely to preserve a harness headline. It reports workload memory separately and still owns bounded output capture, cancellation, process-group cleanup, and durable Result publication.

The implementation follows four consequences:

- a Dormant or closed Session and a Blocked Workflow Run retain no live Harness allocation, Active Credit, thread, socket, subprocess, JavaScript heap, or Promise graph; an In-flight Session retains only its one credit and bounded admitted-adapter resources, never a Harness, Slot, or semantic-validation workspace;
- `Harness.close` consumes and destroys its handle rather than retaining a complete tombstone until Host Runtime shutdown;
- Activation Slots and adapter paths contain only storage with a current production use and avoid duplicate full-size transient copies;
- Active Credits bound active semantic work but do not preallocate a maximum parser workspace, transport connection, thread stack, and subprocess for every credit; reconstructible validation scratch is shared according to its own measured stage concurrency and never retained through provider latency;
- transport, semantic validation, SQLite, workflow evaluation, runtime stacks, allocator overhead, kernel socket memory, and subprocesses are measured as separate categories rather than hidden inside the Activation Slot claim.

This decision does not require a subprocess memory sandbox, dynamic RSS controller, pressure-triggered cancellation, or a scheduler. Those mechanisms would change what computations the model may run and are outside the V1 product contract.

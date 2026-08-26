# OnePage product contract

OnePage is a terminal-first coding-agent harness for running many durable agents through a fixed resident pool on one host. Every active Core borrows one compile-time-sized Activation Slot; Dormant Sessions retain compact Core State, immutable history, and durable effect facts in one host-wide Host Store without retaining an Activation Slot, thread, process, socket, database connection, or conversation object graph.

The memory claim is not that the complete process or a serialized agent fits in the Activation Slot. OnePage reports the actual slot separately from native stacks, host pools, transport buffers, subprocesses, durable storage, and whole-process RSS. Its architectural claim is that resident memory follows the configured active working set rather than total Session count or Conversation length.

## V1 experience

V1 accepts a task in an existing local Git worktree and runs one durable model-and-tool loop. The model may select only:

- `bash` for repository inspection, verification, and other command execution;
- `apply_patch` for one bounded regular-file mutation.

A complete non-empty assistant response with no tool call is the Final Answer. There is no finish or stop tool.

The default `ask` permission mode requests a user decision for every exact tool descriptor. Explicit `--dangerously-bypass-permissions` authorizes validated descriptors without prompting for that invocation. Bypass never disables validation, fixed bounds, durable binding, patch preimage checks, Attempt admission, or effect-specific recovery, and it must be selected again after resume.

The terminal demonstrates durable Session identity, exact Action authority, crash recovery, explicit uncertainty, patch reconciliation, executable verification, and honest resource accounting. Deterministic fixtures provide the reproducible repair and targeted crash demonstration. Live Codex transport is an opt-in compatibility path using the user's ChatGPT subscription only when an established client or provider-specific flow can supply model-only access without creating a second agent loop.

## Product guarantees

- Every Activation Slot contains only named bounded Core State and scratch, carries no sizing filler, and comes from a startup-reserved pool. Its actual compile-time size must not exceed 32 KiB in V1.
- One startup-fixed `active_capacity` bounds open Harness owners, Activation Slots, and in-flight external Attempts for V1. Capacity never grows after startup.
- Activating, advancing, suspending, and reusing a slot performs no general-purpose allocation inside Core.
- Dormant Sessions retain no resident Activation Slot or materialized Conversation graph.
- Every acknowledged semantic transition is reconstructable from its ordered Session Ledger and immutable content. Live `offer` acceptance is not acknowledgement; the CLI acknowledges an input only after the Host Store transaction commits.
- Arbitrary Bash is never claimed to be exactly once or repository-confined. An uncertain Bash Attempt is not replayed automatically.
- A one-file patch binds exact Workspace, path, preimage, expected postimage, patch, and Authorization identity before mutation and reconciles observed state before any retry.
- Output and history larger than resident bounds are streamed or spooled outside the Activation Slot.

## V1 exclusions

- More model-visible tools, a dynamic tool registry, MCP, plugins, skills, or hooks.
- A TUI, editor integration, Web UI, or embedded terminal renderer.
- Multi-file patches, arbitrary filesystem mutation adapters, or a repository reconstruction promise.
- Automatic replay of an arbitrary command whose execution is uncertain.
- Multi-host scheduling, remote Session migration, distributed coordination, or external-effect exactly-once claims.
- Production delegation, Conversation navigation, compaction behaviour, or branching UI.
- A promise that total RSS, disk usage, model cost, subprocess memory, or dormant-agent storage equals the Activation Slot size.
- A generalized scheduler, independent model/tool/completion pools, dynamic RSS controller, fairness framework, group commit, or hot capacity resizing.
- A provider registry, generalized OAuth framework, model catalog requirement, automatic model fallback, or streaming UI.
- A custom SQLite VFS campaign or a claim that OnePage re-proves SQLite pager durability.
- Host Store snapshots, export, retention, Session deletion, blob garbage collection, shrinking, or cross-version migration.

## V1 responsibility rule

Every V1 subsystem must directly support a product guarantee, an external-effect safety boundary, or evidence required for the release claim. Prefer an existing dependency or an explicit platform assumption when it can own a mechanism without receiving OnePage policy or authority. Do not add an abstraction, pool, background owner, durable representation, or extension seam for a hypothetical second consumer. A broader design requires a current use, a simpler alternative that was rejected for a stated reason, and an accepted ADR.

## Demonstration standard

The primary demonstration repairs a real deterministic fixture, terminates at the patch effect boundary, resumes the same Session without concealing or repeating the mutation, completes verification, and reports exact slot size alongside process RSS and durable bytes. A separate two-axis density run first increases dormant Sessions at fixed active capacity, then increases active capacity at fixed dormant population. It reports population-independent resident resources and population-dependent disk cost separately.

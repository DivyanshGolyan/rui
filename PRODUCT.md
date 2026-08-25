# OnePage product contract

OnePage is a terminal-first coding-agent harness for running many durable agents through a fixed resident pool on one host. Every active Core borrows one exact 64 KiB Activation Slot; sleeping agents retain compact Core State, immutable history, and durable effect facts without retaining an Activation Slot, thread, process, socket, or conversation object graph.

The memorable claim is not that the complete process or a serialized agent consumes 64 KiB. OnePage reports the exact Activation Slot separately from native stacks, host pools, transport buffers, subprocesses, durable storage, and whole-process RSS. Its architectural claim is that resident memory follows the configured active working set rather than total Session count, Conversation length, or delegation topology.

## V1 experience

V1 accepts a task in an existing local Git worktree and runs one durable model-and-tool loop. The model may select only:

- `bash` for repository inspection, verification, and other command execution;
- `apply_patch` for one bounded regular-file mutation.

A complete non-empty assistant response with no tool call is the Final Answer. There is no finish or stop tool.

The default `ask` permission mode requests a user decision for every exact tool descriptor. Explicit `--dangerously-bypass-permissions` authorizes validated descriptors without prompting for that invocation. Bypass never disables validation, fixed bounds, durable binding, patch preimage checks, Attempt admission, or effect-specific recovery, and it must be selected again after resume.

The terminal demonstrates durable Session identity, exact Action authority, crash recovery, explicit uncertainty, patch reconciliation, executable verification, and honest resource accounting. Deterministic fixtures provide the reproducible repair and crash demonstration; live OpenRouter transport is an opt-in compatibility path using the user's credential.

## Product guarantees

- Every Activation Slot is exactly 65,536 bytes and comes from a startup-reserved pool.
- Activating, advancing, suspending, and reusing a slot performs no general-purpose allocation inside Core.
- Sleeping Sessions retain no resident Activation Slot or materialized Conversation graph.
- Every acknowledged semantic transition is reconstructable from the Session WAL and immutable content. Live `offer` acceptance is not acknowledgement; the CLI acknowledges an input only after its WAL transaction commits.
- Arbitrary Bash is never claimed to be exactly once or repository-confined. An uncertain Bash Attempt is not replayed automatically.
- A one-file patch binds exact Workspace, path, preimage, patch, and Authorization identity and reconciles observed state before any retry.
- Output and history larger than resident bounds are streamed or spooled outside the Activation Slot.
- Delegation ancestry never consumes a resident caller stack. V1 does not expose delegation, but the lifecycle and scheduler do not use topology as a capacity dimension.

## V1 exclusions

- More model-visible tools, a dynamic tool registry, MCP, plugins, skills, or hooks.
- A TUI, editor integration, Web UI, or embedded terminal renderer.
- Multi-file patches, arbitrary filesystem mutation adapters, or a repository reconstruction promise.
- Automatic replay of an arbitrary command whose execution is uncertain.
- Multi-host scheduling, remote Session migration, distributed coordination, or external-effect exactly-once claims.
- Production delegation, Conversation navigation, compaction behaviour, or branching UI.
- A promise that total RSS, disk usage, model cost, subprocess memory, or dormant-agent storage is 64 KiB.

## Demonstration standard

The primary demonstration repairs a real deterministic fixture, kills the process at a meaningful durability boundary, resumes the same Session without concealing or repeating an uncertain effect, completes verification, and reports exact slot size alongside process RSS and durable bytes. A separate density run cycles a large sleeping population through a small fixed slot pool and reports both population-independent resident resources and population-dependent disk cost.

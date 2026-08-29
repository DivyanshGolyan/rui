# OnePage

A resource-bounded, crash-resumable local Run service for programmable coding-agent workflows. A Caller—person or agent—
supplies a Workflow Definition and stable Run Key through the local CLI, while one native Zig Host
Runtime owns the durable Workflow Run, keyed Jobs, and every agent Session. `User` remains a
Conversation role rather than the Caller or permission authority. Each active Core borrows one
compile-time-bounded Activation Slot from a fixed resident pool.

The current checkout implements the deterministic single-Session lifecycle, SQLite Host Store,
permissioned Bash and patch execution, and repair fixtures described below. The provider-neutral,
asynchronous Workflow Run architecture is the planned V1 destination tracked by issues #33–#39 and
#43; it is not yet implemented.

Codex is the required first live provider target. Before workflow orchestration, issue #11 must prove
that OnePage can use an existing ChatGPT subscription through the official authorization and
model-transport path, then let a real Codex model complete one controlled coding repair through the
existing capacity-one Harness. Issue #43 later carries that same adapter into durable Workflow Runs
and measured concurrency. Neither step embeds a second agent loop. Until #11 passes, this repository
does not claim that the live subscription experience is available.

The V1 CLI will expose `run`, `inspect`, `respond`, `advance`, `cancel`, and `read` over one
protocol-independent Run Service. JSON `RunSnapshot` is the complete automation contract; Markdown is
its deterministic bounded model-facing view. The CLI owns no lifecycle or permission policy. The Host
owns Run creation, evaluation generations, Job observation, advancement, cancellation, and finalization.
For each generation it launches a fresh restricted
QuickJS-ng Workflow Evaluator. The evaluator returns `Completed`, `Blocked`, or a typed failure and
exits. It never owns durable workflow state, a Session, provider, tool, permission, or recovery
decision, and no evaluator remains resident while a Workflow Run is Blocked on Jobs.
Workflow code cannot observe physical Job completion order: V1 supports deterministic joins through
`Promise.all` and `Promise.allSettled` and does not expose `Promise.race` or `Promise.any`.
The target architecture separates compact, canonically encoded Core State from transient
Activation Slot scratch. Core State's encoded size is derived from `core_state.encoded_size` and is
currently 176 bytes; authoritative semantic transactions
carry it directly. Activation decodes that state into one Host-owned slot containing only named
bounded scratch; V1 removes sizing filler and enforces a 32 KiB ceiling. Suspension scrubs the
complete slot. A fixed Host-owned pool returns closed capacity instead of allocating a
fallback slot. Native invariant traces check typed outcomes, rejection-state preservation, semantic
observations, and canonical restoration rather than slot bytes. Complete Session semantics reconstruct
from one ordered Session Ledger inside a bounded host-wide SQLite Host Store.

[`PRODUCT.md`](PRODUCT.md), [`ARCHITECTURE.md`](ARCHITECTURE.md),
[`VERIFICATION.md`](VERIFICATION.md), and the
[`RunSnapshot` V1 schema](docs/spec/run-snapshot-v1.schema.json) and
[`InteractionResponseBatch` V1 schema](docs/spec/interaction-response-batch-v1.schema.json) are normative. Historical spikes and research remain evidence,
but they do not override those documents or accepted ADRs.

[`docs/style.md`](docs/style.md) defines the scoped engineering rules and canonical compiler-backed
check for implementation work. [ADR-0010](docs/adr/0010-make-simplicity-a-v1-requirement.md)
makes architectural simplicity a V1 correctness constraint: new surfaces require a current product
obligation and may not generalize a single consumer.
[ADR-0012](docs/adr/0012-separate-model-tool-contracts-from-execution.md) keeps the model-visible
Conversation and tool data provider-neutral while leaving V1 execution closed.
[ADR-0013](docs/adr/0013-bound-orchestration-memory-not-workload-memory.md) bounds memory owned by
OnePage while treating memory intentionally used by model-requested processes as separately reported
workload memory.
[ADR-0014](docs/adr/0014-use-ephemeral-quickjs-for-workflow-evaluation.md) makes workflow control
reconstructive: exact source and arguments replay against durable keyed Job Outputs in a disposable
evaluator instead of checkpointing JavaScript continuation state.
[ADR-0015](docs/adr/0015-expose-a-protocol-independent-run-service.md) makes the durable Run Service
the public semantic seam, separates User role from authority, and keeps the CLI and future industry
protocols as adapters.
[ADR-0016](docs/adr/0016-separate-captured-output-from-semantic-admission.md) keeps provider capture
non-authoritative and shares bounded semantic-validation scratch independently of Active Capacity.

The fixed-credit harness spike established a 1.5 KiB-bounded native owner with nonblocking task,
completion, permission, cancellation, and shutdown admission; durable-before-apply ordering;
committed projections; bounded drive quanta; and crash/replay tests. Its 32-entry maximum is fixed at
compile time and does not vary with logical-agent count.

The planned V1 lifecycle opens exactly one SQLite-owning `HostRuntime` per process from a state path and passes only
that runtime to `Harness.open`. It owns the process-wide SQLite allowance, state directory, Activation
Slot pool, lifetime operating-system lock, SQLite connection, and bounded Storage Owner; lifecycle callers do not assemble or retain those
mechanics separately. `Harness.open` returns an opaque pointer-stable owner backed by one retained runtime lease. `Harness.close` consumes and
destroys that owner; the runtime does not retain complete closed handles. Projections are data-only and
reopen content through their live Harness rather than retaining internal pointers. Each Session retains exact create and resume identity, durable ownership
epochs, one replayable resident value reduced from its ordered semantic ledger, and a linear V1 conversation. Dormant Sessions
retain rows and blob references rather than SQLite connections or resident object graphs.

The memory contract applies to OnePage-owned orchestration resources. Model-requested Bash processes
may intentionally use arbitrary workload memory; that usage is reported separately rather than constrained
to preserve the harness budget. OnePage still bounds its own output capture and durable publication path.

The first agent slice now performs one real durable model turn through the product CLI. A fixture
provider validates the request reconstructed from the conversation, writes complete Captured Model
Output, and notifies a restored Harness owner. Harness-owned Semantic Admission classifies the output,
and Core applies the admitted Final Answer. The answer is then committed as an immutable conversation
entry and reproduced by exact Session resume.

```sh
zig build fixture-answer -Doptimize=ReleaseSmall
```

The permissioned Bash slice validates one bounded call, records its typed collision-resistant binding
and permission decision, syncs a consequential Attempt before execution, runs from the bound worktree
with a sanitized environment, commits the typed Result to the conversation, and lets the core
construct a second model turn. Ambiguous crash recovery records `possibly_executed` and never reruns
Bash automatically. The current synchronous fixture stops with an indeterminate projection; the
planned asynchronous V1 lifecycle will feed the already-committed Tool Result to the Agent's next
model turn rather than automatically escalating to the User or terminating the Job.

```sh
zig build fixture-bash -Doptimize=ReleaseSmall
```

The patch slice prepares one immutable durable Patch Intent before Authorization. That Intent binds
the canonical Workspace and target, tracked single-link regular-file constraints and mode, exact
patch, preimage, and expected postimage. Approval Required, Authorization, Attempt, and Result all
reference it; no parallel permission binding or derived Workspace fingerprint exists. Every Git call
uses `/usr/bin/git` with a replacement environment containing only fixed locale, path, and disabled
configuration authority. Git parses and applies the patch in a bounded private copy; `patch_tool`
writes that exact postimage through the authorized file handle and observes preimage, postimage,
divergence, or invalid target.
Lifecycle commits Authorization and Attempt before `patch_tool` may mutate, publishes adapter evidence through
the Completion Inbox, and advances Conversation from the first terminal Result.

Fresh-process fixtures terminate after Attempt admission and after Git mutation. Recovery applies an
authorized exact preimage, accepts the exact expected postimage without reapplication, and publishes
an indeterminate Result for divergence without overwriting it. Replacement, dirty overlap, symlink
substitution, missing or untracked files, special files, and wrong mode fail closed. V1 assumes the
target remains quiescent from Authorization until Result commit; it does not provide atomic
compare-and-swap protection against an uncooperative editor.

V1 keeps only `bash` and `apply_patch`. The default `ask` permission mode commits one immutable
permission Interaction Request for every exact validated tool call. The Run Snapshot exposes that
request without retaining a Harness or evaluator. A response is accepted only from a Principal whose
Authority covers its exact operation and descriptor binding. An explicit invocation-scoped bypass
mode admits validated calls without creating the request; it does not bypass validation, durability,
patch preimage checks, or recovery rules.

The model-facing representation is provider-neutral. Conversation records generic text,
tool-call, tool-result, and checkpoint entries; each model Operation binds an immutable bounded Tool
Catalog and stable Tool Keys. Provider adapters translate that house request at the edge. Harness then
maps only the two admitted V1 keys to concrete Actions, so adding a provider does not change durable
history and generic model data does not become a runtime plugin or permission system.

```sh
zig build fixture-patch-deny -Doptimize=ReleaseSmall
```

The complete deterministic repair starts from a committed Git repository whose executable test
fails. Its fixture Provider selects each response from the exact durable Conversation: the red Bash
Result authorizes one Patch Intent, the applied Patch Result authorizes verification through the same
Bash command, and only the green Result permits the Final Answer. The fixture runs both `ask` and
bypass through the production CLI and Harness; tool-specific validation and recovery remain distinct,
while lifecycle owns the one invocation-scoped Permission Mode.

```sh
zig build fixture-repair -Doptimize=ReleaseSmall
```

The canonical test graph also runs model and Bash recovery in separate processes. Missing model
evidence admits a new Attempt under the same Operation, the eighth uncertain Attempt terminalizes
without a ninth dispatch, and each replacement durably exposes the number of earlier dispatches that
may duplicate provider work or billing. Late evidence from a superseded Attempt remains audited
without a second lifecycle advancement. An uncertain Bash Attempt becomes indeterminate without replay.

Ownership epochs, Completion evidence, Session metadata, Conversation metadata, and canonical
multi-fact transactions now live behind the same serialized Storage Owner. Session supplies only a
typed transaction; storage canonically encodes it and derives every relational write. SQLite assigns
Completion Inbox identity, and the transaction that publishes a terminal Result associates its
immutable evidence. Only pending relevant evidence consumes the enforced 4,096-row per-Session Inbox bound; consumed evidence is excluded from recovery. Per-Session WAL,
Inbox, Conversation, checkpoint, and manifest files are no longer production storage paths.

Implemented authoritative descriptor, Patch Intent, preimage, expected-postimage,
Result, Completion, immutable-blob, and ledger-record bytes use distinct versioned SHA-256 binding
types. Bash persists one descriptor binding its canonical Workspace and working directory, fixed
environment authority, timeout, command, Operation identity, and generation. Patch preparation uses Git
in a private scratch copy to prepare the expected postimage without mutating the Workspace, then stores
the complete Intent before Authorization. Preparation, observation, and application each admit at most
1 MiB of target or expected-postimage work. The all-zero value remains valid data; absence is represented
separately.
These unkeyed bindings detect accidental corruption and resist collisions but do not make locally
rewritable storage tamper-proof.

## Requirements

- macOS on Apple Silicon
- Zig 0.16.0
- the system Git at `/usr/bin/git`

## Run the spike

```sh
zig build check
zig build test -Doptimize=ReleaseSafe
zig build native-core -Doptimize=ReleaseSafe
```

`native-core` reports the current exact slot, the two fixed Host scratch-stage resource ledgers, compact Dormant
Session state bytes, process RSS, and 32 randomized native invariant traces through canonical suspend and
poisoned-slot restore.

See the spike notes for architecture, measurements, caveats, and next questions:

- [`docs/spikes/0001-memory-model.md`](docs/spikes/0001-memory-model.md)
- [`docs/spikes/0002-checkpoint-format.md`](docs/spikes/0002-checkpoint-format.md)
- [`docs/spikes/0003-operation-lifecycle.md`](docs/spikes/0003-operation-lifecycle.md)
- [`docs/spikes/0004-fixed-credit-harness.md`](docs/spikes/0004-fixed-credit-harness.md)
- [`docs/spikes/0005-owner-crash-recovery.md`](docs/spikes/0005-owner-crash-recovery.md)
- [`docs/spikes/0006-atomic-checkpoint-publication.md`](docs/spikes/0006-atomic-checkpoint-publication.md)
- [`docs/spikes/0007-durable-session.md`](docs/spikes/0007-durable-session.md)
- [`docs/spikes/0008-fixture-model-final-answer.md`](docs/spikes/0008-fixture-model-final-answer.md)
- [`docs/spikes/0009-permissioned-bash.md`](docs/spikes/0009-permissioned-bash.md)
- [`docs/spikes/0010-apply-patch-permission.md`](docs/spikes/0010-apply-patch-permission.md)
- [`docs/spikes/0011-native-core-image.md`](docs/spikes/0011-native-core-image.md)

Source audits that informed the architecture:

- [`docs/research/ghostty-lessons.md`](docs/research/ghostty-lessons.md)
- [`docs/research/deepseek-harness-lessons.md`](docs/research/deepseek-harness-lessons.md)
- [`docs/research/fx-pi-harness-lessons.md`](docs/research/fx-pi-harness-lessons.md)
- [`docs/research/codex-cli-session-lessons.md`](docs/research/codex-cli-session-lessons.md)
- [`docs/research/cursor-origin-wal-lessons.md`](docs/research/cursor-origin-wal-lessons.md)
- [`docs/research/opencode-sqlite-v2-lessons.md`](docs/research/opencode-sqlite-v2-lessons.md)
- [`docs/research/sqlite-host-store-practices.md`](docs/research/sqlite-host-store-practices.md)
- [`docs/research/linting-typechecking-setup.md`](docs/research/linting-typechecking-setup.md)
- [`docs/research/future-architecture-options.md`](docs/research/future-architecture-options.md)
- [`docs/research/claude-code-dynamic-workflows.md`](docs/research/claude-code-dynamic-workflows.md)
- [`docs/research/model-transport-memory-budget.md`](docs/research/model-transport-memory-budget.md)
- [`docs/research/quickjs-workflow-runtime-consultation.md`](docs/research/quickjs-workflow-runtime-consultation.md)

Historical design records:

- [`docs/design/0001-first-real-harness.md`](docs/design/0001-first-real-harness.md)

Canonical domain language:

- [`CONTEXT.md`](CONTEXT.md)

Architectural decisions:

- [`docs/adr/0001-append-only-conversation-tree.md`](docs/adr/0001-append-only-conversation-tree.md)
- [`docs/adr/0002-compose-agents-through-durable-delegation.md`](docs/adr/0002-compose-agents-through-durable-delegation.md)
- [`docs/adr/0003-treat-user-worktrees-as-external-truth.md`](docs/adr/0003-treat-user-worktrees-as-external-truth.md)
- [`docs/adr/0004-reconcile-uncertain-effect-attempts.md`](docs/adr/0004-reconcile-uncertain-effect-attempts.md)
- [`docs/adr/0005-use-two-tools-and-final-assistant-text.md`](docs/adr/0005-use-two-tools-and-final-assistant-text.md)
- [`docs/adr/0006-separate-core-state-from-activation-slot.md`](docs/adr/0006-separate-core-state-from-activation-slot.md)
- [`docs/adr/0007-use-one-session-wal-as-semantic-authority.md`](docs/adr/0007-use-one-session-wal-as-semantic-authority.md)
- [`docs/adr/0008-keep-v1-core-native-only.md`](docs/adr/0008-keep-v1-core-native-only.md)
- [`docs/adr/0009-use-one-host-store-with-session-ledgers.md`](docs/adr/0009-use-one-host-store-with-session-ledgers.md)
- [`docs/adr/0010-make-simplicity-a-v1-requirement.md`](docs/adr/0010-make-simplicity-a-v1-requirement.md)
- [`docs/adr/0011-size-the-activation-slot-from-bounded-needs.md`](docs/adr/0011-size-the-activation-slot-from-bounded-needs.md)
- [`docs/adr/0012-separate-model-tool-contracts-from-execution.md`](docs/adr/0012-separate-model-tool-contracts-from-execution.md)
- [`docs/adr/0013-bound-orchestration-memory-not-workload-memory.md`](docs/adr/0013-bound-orchestration-memory-not-workload-memory.md)
- [`docs/adr/0014-use-ephemeral-quickjs-for-workflow-evaluation.md`](docs/adr/0014-use-ephemeral-quickjs-for-workflow-evaluation.md)
- [`docs/adr/0015-expose-a-protocol-independent-run-service.md`](docs/adr/0015-expose-a-protocol-independent-run-service.md)
- [`docs/adr/0016-separate-captured-output-from-semantic-admission.md`](docs/adr/0016-separate-captured-output-from-semantic-admission.md)

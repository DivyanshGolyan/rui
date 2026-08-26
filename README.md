# OnePage

A single-host coding-agent architecture in which every active Core borrows one exact 64 KiB
Activation Slot from a fixed resident pool.

The production CLI executes a Zig reducer natively and has no embedded language or secondary runtime.
The target architecture separates compact, canonically encoded Core State from transient
Activation Slot scratch. Core State is currently 160 bytes; authoritative semantic transactions
carry it directly. Activation decodes that state into one caller-owned 65,536-byte slot, and
suspension scrubs the complete slot. A fixed caller-owned pool returns closed capacity instead of allocating a
fallback slot. Native invariant traces check typed outcomes, rejection-state preservation, semantic
observations, and canonical restoration rather than slot bytes. Complete Session semantics reconstruct
from one ordered Session Ledger inside a bounded host-wide SQLite Host Store.

[`PRODUCT.md`](PRODUCT.md), [`ARCHITECTURE.md`](ARCHITECTURE.md), and
[`VERIFICATION.md`](VERIFICATION.md) are normative. Historical spikes and research remain evidence,
but they do not override those documents or accepted ADRs.

[`docs/style.md`](docs/style.md) defines the scoped engineering rules and canonical compiler-backed
check for implementation work.

The fixed-credit harness spike established a 1.5 KiB-bounded native owner with nonblocking task,
completion, permission, cancellation, and shutdown admission; durable-before-apply ordering;
committed projections; bounded drive quanta; and crash/replay tests. Its 32-entry maximum is fixed at
compile time and does not vary with logical-agent count.

One Host Runtime holds a lifetime operating-system lock and routes every durable read and write through
one bounded Storage Owner. Each Session retains exact create and resume identity, durable ownership
epochs, an ordered semantic ledger, and an append-only parent-linked conversation. Sleeping Sessions
retain rows and blob references rather than SQLite connections or resident object graphs.

The first agent slice now performs one real durable model turn through the product CLI. A fixture
provider validates the request reconstructed from the conversation, writes a complete response spool,
and wakes a restored Core. Core alone classifies the response as a Final Answer, which is
then committed as an immutable conversation entry and reproduced by exact Session resume.

```sh
zig build fixture-answer -Doptimize=ReleaseSmall
```

The permissioned Bash slice validates one bounded call, records its exact digest and permission
decision, syncs a consequential Attempt before execution, runs from the bound worktree with a
sanitized environment, commits the typed Result to the conversation, and lets the core construct a
second model turn. Ambiguous crash recovery records `possibly_executed` and never reruns Bash.

```sh
zig build fixture-bash -Doptimize=ReleaseSmall
```

The patch-permission slice validates one exact, tracked, regular-file diff, binds its preimage and
permission evidence durably, and can regenerate an approval-required prompt after a restart. The
deterministic fixture denies the call, gives the typed result to turn two, and leaves the worktree
unchanged.

V1 keeps only `bash` and `apply_patch`. The default `ask` permission mode prompts for every exact
tool call. An explicit invocation-scoped bypass mode will admit validated calls without prompting;
it does not bypass validation, durability, patch preimage checks, or recovery rules, and resume must
select it again.

```sh
zig build fixture-patch-deny -Doptimize=ReleaseSmall
```

Ownership epochs, Completion evidence, Session metadata, Conversation metadata, and canonical
multi-fact transactions now live behind the same Storage Owner. The SQLite transaction that
publishes a terminal Result also associates its immutable Completion evidence. Per-Session WAL,
Inbox, Conversation, checkpoint, and manifest files are no longer production storage paths.

## Requirements

- macOS on Apple Silicon
- Zig 0.16.0

## Run the spike

```sh
zig build check
zig build test -Doptimize=ReleaseSafe
zig build native-core -Doptimize=ReleaseSafe
```

`native-core` reports the exact slot, compact sleeping-state bytes, process RSS, and 32 randomized
native invariant traces through canonical suspend and poisoned-slot restore.

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

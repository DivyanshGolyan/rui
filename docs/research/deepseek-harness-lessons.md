# Lessons from DeepSeek Harness for OnePage

Research date: 2026-08-24
DeepSeek Harness revision: [`b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`](https://github.com/deepseek-ai/deepseek-harness/tree/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e)

## Decision

DeepSeek Harness is not a memory-efficiency template for OnePage. It is a large TypeScript/Cordis system optimized for dynamic composition, replay fidelity, rich sessions, and multiple user interfaces. Its live agents retain promises, abort controllers, inbox arrays, plugin scopes, dispatchers, full session logs, and derived-message caches.

Its value is semantic rather than mechanical. It demonstrates where an agent harness needs explicit commit points, reconstruction rules, ownership, and bounded concurrency.

The strongest transferable rule is:

> Persist intent before an irreversible effect, persist its result before advancing state, and make every model-visible value reconstructable from durable records.

OnePage can enforce that rule inside a fixed-memory `Harness` module without adopting a plugin engine or a resident object graph per logical agent.

## What to adopt

### 1. Semantic durability checkpoints around effects

DeepSeek Harness flushes the logged request before model dispatch, flushes a top-level tool call before tool execution, and flushes results before the next model step. A failed checkpoint prevents the following side effect ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/session/session-checkpoint-policy/src/index.ts#L20-L82)).

OnePage should make the corresponding ordering an invariant of `Harness.drive()`:

```text
request intent + sync  -> dispatch model request
tool intent + sync     -> start tool process or mutation
result + sync          -> advance agent state and form the next request
```

This is more important than whether completion delivery uses a ring, pipe, or callback. Those are implementation details; the durable-before-effect relationship is part of the module's interface.

The claim should remain precise. This does not make arbitrary external effects exactly once. Stable operation identities, provider idempotency, reconciliation, and explicit uncertainty are still necessary after a crash between dispatch and observing the result.

### 2. “Model-visible means logged” as an executable invariant

DeepSeek constructs requests from its session surface and records changing request headers and runtime context before dispatch ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/agent-loop/src/agent.ts#L422-L513)). It also has a runtime invariant that compares the dispatched request with the reconstruction from recorded state ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/agent-loop/src/invariant.ts#L19-L54)).

OnePage should add this debug/CI oracle:

```text
encode_request(replay(log, request_boundary)) == bytes_sent_to_provider
```

This cleanly separates durable truth from the 64 KiB page. The page is a bounded execution cache; it is not the only record of what the model saw.

### 3. Commit authoritative facts before publishing projections

DeepSeek validates and freezes a session event, validates its projection transition, appends it to the authoritative log, and only then notifies observers. Observer failures are contained after the commit ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/session/src/index.ts#L569-L655)).

OnePage should follow the same rule for terminal output, progress, metrics, and future UI updates:

- durable event first;
- derived projection second;
- subscriber failure never rewrites the committed result;
- replay produces the same externally meaningful state.

The UI is therefore a consumer of durable events, not part of an agent's resident state.

### 4. Durable inbox facts instead of a resident per-agent queue

DeepSeek records normalized inbox mutations and rebuilds pending work from them on replay ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/agent/src/inbox.ts#L128-L219)). Its general splice model is broader than OnePage needs, but the authoritative-log principle transfers.

OnePage needs only compact operations such as:

```text
message_queued
message_claimed
message_cancelled
```

A sleeping logical agent can then be represented by durable identity and record offsets. It does not need a resident inbox object.

### 5. Bounded overlap with ordered commit

DeepSeek overlaps only tools declared parallel-safe, keeps a configured bound on the rolling in-flight pool, treats exclusive tools as barriers, and commits results in model order even when execution finishes out of order. Cancellation stops new starts and drains already-started calls ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/agent-loop/src/tool-calls.ts#L112-L245)).

For OnePage v1, one active effect per slot is simpler. If concurrency is later added:

- spend from a fixed host-wide in-flight table;
- keep logical call order separate from completion order;
- do not store promises, futures, or callbacks in the agent page;
- stop replenishing on cancellation or scheduler failure;
- drain already-started work to a known disposition before releasing ownership.

### 6. Spend disk to bound tool-output memory

DeepSeek's subprocess collector keeps a byte-capped tail in memory and can spill the complete stream to a private file ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/subprocess/subprocess-local/src/spawn.ts#L84-L150)).

This is an excellent trade for OnePage. Arbitrary output can be represented in a slot by fixed metadata:

```text
total_bytes
tail_length
spill_reference
checksum
truncated
```

The terminal can receive a volatile stream while the durable log records the final bounded result and spill reference.

### 7. Process ownership ends at whole-tree quiescence

DeepSeek's subprocess interface requires tree-scoped termination, escalation from graceful termination to force, awaited whole-tree exit, and disposal that joins every live managed process ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/subprocess/subprocess/src/index.ts#L74-L100)).

OnePage should adopt that lifecycle rule, while keeping the process table host-wide and bounded. The 64 KiB page should retain only the stable operation identity and intended disposition.

### 8. Fail closed when confinement is unavailable

DeepSeek separates sandbox policy from execution and refuses to run unconfined when no required platform backend is available ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/sandbox/sandbox-local/src/index.ts#L1-L20), [source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/sandbox/sandbox-local/src/index.ts#L305-L332)).

OnePage should use one small host-side adapter in v1:

```zig
confine(argv, policy) -> ConfinedArgv | unavailable
```

The adapter should be resolved once at startup. Sandbox configuration, argv rewriting, process ownership, and structured denial stay outside the core page.

## What to adapt

### 1. Append-only truth plus replace projections

DeepSeek preserves the canonical append-only session log while a separate surface identifies the model-visible events. Compaction appends a replacement with provenance instead of deleting the original history ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/session/src/surface.ts#L320-L459)).

OnePage should use compact fixed records:

```text
append message/result
append checkpoint replacing [start_sequence, end_sequence]
```

The page needs only a checkpoint reference and a bounded recent window. It must not carry an array of every visible event sequence.

### 2. Compaction as a bracketed durable operation

DeepSeek appends `compaction/start`, performs asynchronous summarization, validates that the selected surface did not change, commits the replacement, and attempts exactly one `compaction/end`. An unmatched start remains detectable after failure ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/compaction/compaction-basic/src/region.ts#L136-L253)).

In OnePage, summarization should happen while the agent owns no resident slot:

1. Select bounded region metadata.
2. Persist compaction intent.
3. Release the slot and wait for the model.
4. Reacquire any slot when the completion arrives.
5. Revalidate agent generation and the selected record span.
6. Persist the replacement and close the bracket.

This turns a long context operation into another suspendable effect.

### 3. Stream fidelity should be selective

DeepSeek records every raw assistant chunk for exact UI replay and later packs compatible consecutive chunk events into fewer physical storage rows without changing logical events ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/agent-loop/src/agent.ts#L332-L409), [source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/session/src/chunk-rows.ts#L1-L16)).

For v1, OnePage should prefer:

- volatile chunks to the terminal;
- a durable `response_started` marker;
- optionally coalesced progress;
- one durable final assistant message.

Exact token-timing replay is not worth the write amplification or recovery complexity for the first demo. Streaming does not require retaining the agent page while waiting for the next network chunk.

### 4. Write-behind only outside semantic commit points

DeepSeek batches event persistence behind an in-memory per-session queue, retains a failed batch in order, and provides an explicit flush-to-quiescence barrier ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/session/session-persistence/src/write-behind.ts#L18-L158)).

OnePage can adapt batching for disposable telemetry or already-safe event groups, but must not use per-agent arrays and timers. Use a fixed host-wide buffer per storage shard. Model dispatch, tool dispatch, and logical completion advance cross explicit synchronous durability barriers.

### 5. Capability seams should be static and scarce

DeepSeek requires a service definition, provider, and consumer for a complete capability seam. This provides strong locality but its runtime plugin graph is intentionally expansive ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/docs/architecture.md#L83-L126)).

OnePage should introduce seams only where two real adapters exist or isolation matters:

- model transport;
- durable storage;
- tool execution/confinement;
- output sink.

Resolve them once in `Harness.open()` into a fixed capability table. Avoid per-agent registries, listener maps, plugin contexts, and scoped object graphs.

DeepSeek also demonstrates that capabilities sharing an execution world should share one owner. Its E2B filesystem and subprocess adapters await the same sandbox handle ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/e2b/e2b/src/index.ts#L1-L4), [source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/e2b/e2b/src/index.ts#L69-L137)). OnePage should similarly prevent filesystem and subprocess adapters from accidentally referring to different sandboxes or working trees.

### 6. UI state is a bounded projection

DeepSeek's client fetches a bounded message-tail page and derives presentation outside the agent loop ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/client/runtime/src/client/sessions/session.ts#L31-L72)).

OnePage's terminal renderer should consume a bounded durable-event tail and fall back to a generic text representation for every event. It should not retain terminal models, message trees, or presentation objects per sleeping agent.

## What not to copy

- **Resident full-session logs.** `Session` owns the complete event array, surface projection, cached derived messages, and context folds ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/session/src/index.ts#L417-L472), [source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/session/src/index.ts#L701-L747)). This is deliberately incompatible with OnePage's density goal.
- **One live object graph per sleeping agent.** DeepSeek's live agent carries phase state, abort controllers, promises, inboxes, scope/context objects, dispatchers, and runtime projections ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/agent-loop/src/agent.ts#L38-L97)).
- **A resident session map as the catalogue.** The session store keeps live `Session` entries in a `Map` ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/core/session/src/index.ts#L786-L840)). OnePage should discover sleeping agents from durable storage without loading them.
- **General-purpose plugin and waterfall dispatch on the hot path.** Cordis is appropriate for DeepSeek's extensibility goal, but fixed discriminants and direct dispatch are more credible for a one-page core.
- **General splice semantics.** OnePage needs queue, claim, and cancel—not arbitrary insertion/replacement coordinates.
- **Unbounded cloned write-behind arrays.** DeepSeek's persistence queue is per live session and grows as events are enqueued. OnePage needs host-wide fixed credits.
- **A full browser client inside the measured harness.** Presentation stays outside the harness memory claim and consumes bounded projections.

## Effect on the proposed OnePage interface

The external seam remains:

```zig
CoreContract.verify(wasm)
Harness.open(config)
Harness.offer(completion)
Harness.drive()
```

DeepSeek changes the hidden obligations of `Harness.drive()`, not the number of methods:

- reconstruct only the bounded state required for the next transition;
- verify agent and operation generations before mutation;
- persist intent before model or tool dispatch;
- persist completion before advancing state;
- publish UI events only after commit;
- release the slot while waiting on network, process, approval, or compaction;
- bound every queue, in-flight effect record, output tail, and replay window;
- reconstruct and compare every provider request in verification builds.

## Recommended next spike

The next spike should combine the fixed-credit owner loop with semantic effect checkpoints:

1. Add the `CoreContract` and `Harness` seams.
2. Admit completions through a fixed nonblocking ring.
3. Inject crashes at every record-write, sync, dispatch, result, checkpoint, and slot-release boundary around one model operation.
4. Repeat for a tool operation with a visible filesystem effect.
5. Recover in a fresh process and prove:
   - no side effect occurs without a durable intent;
   - no completion advances state without a durable result;
   - committed transitions apply exactly once to logical state;
   - uncertain external effects are detected and reconciled rather than silently repeated;
   - resident memory remains constant across agent count and repeated recovery.

That proof is more valuable to OnePage than a generic plugin system. It connects the 64 KiB claim to trustworthy real agent behavior.

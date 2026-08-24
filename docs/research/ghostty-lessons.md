# Lessons from Ghostty for OnePage

Research date: 2026-08-24
Ghostty revision: [`6a508fd5e34c7e222c052a6d00bb3891ff3feace`](https://github.com/ghostty-org/ghostty/tree/6a508fd5e34c7e222c052a6d00bb3891ff3feace)

## Decision

Ghostty is more valuable to OnePage as architectural evidence than as a v1 dependency.

For the terminal-first demo, OnePage should print restrained, append-only records to the terminal's primary screen and let Ghostty own rendering, scrollback, selection, fonts, and the platform UI. We should not embed the full Ghostty application, and we should only consider a feature-trimmed `libghostty-vt` adapter if we later need to interpret arbitrary subprocess VT output into an offscreen terminal model.

The most important transferable lesson is this:

> Bound the reusable execution machinery, transfer ownership explicitly, and keep suspended logical state outside the resident runtime.

That reinforces OnePage's current shape: a fixed number of resident execution slots multiplex durable agents, rather than one runtime, thread, queue, or terminal per agent.

## What to adopt

### 1. Make the resident unit a compile-time contract

Ghostty's Wasm page pool checks that every pooled item is a non-zero multiple of the 64 KiB Wasm page, constrains alignment, and derives the required `memory.grow` count at compile time ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/datastruct/wasm_page_pool.zig#L31-L60)).

OnePage should make equivalent facts mechanically unavoidable:

- the core imports or declares exactly one 64 KiB, non-growable page;
- every fixed region and ABI offset fits within it;
- the stack, static data, mutable state, and scratch space are counted together;
- no build mode silently changes the initial or maximum page count;
- thousands of slot reuse cycles leave `memory.buffer.byteLength` unchanged.

Ghostty's pool grows by an exact item when empty, but it still grows without a hard ceiling ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/datastruct/wasm_page_pool.zig#L98-L123)). OnePage must improve on this: exhausting resident credits is an admission-control outcome, never a reason to call `memory.grow`.

### 2. Share reusable capacity, not resident state per logical agent

Ghostty uses a module-wide free list so pages released by one terminal can be reused by another; per-terminal allocator composition had caused retained Wasm memory to multiply ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/datastruct/wasm_page_pool.zig#L6-L28)).

The OnePage analogue is a scheduler-owned fixed slot pool shared across every logical agent on the host. A sleeping agent owns a durable checkpoint and journal position, not a Wasm instance, callback, queue, thread, or in-memory object graph.

This is the credible reason memory need not grow linearly with agent count. Logical agents scale on disk; only concurrently executing work consumes the bounded resident pool.

### 3. Pair address reuse with explicit ownership and generations

Ghostty records whether a page is pool-owned instead of inferring ownership from its shape, because a wrong guess corrupts the pool ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/PageList.zig#L42-L55)). Recycled pages also use generation/epoch checks so a stale reference does not become valid merely because an address was reused ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/PageList.zig#L374-L392)).

OnePage should keep its current generation-safe completion design and extend the rule across every boundary:

- a completion names `{slot, generation, operation}`;
- only the slot owner may mutate the restored page;
- stale completions are rejected before mutation;
- slot ownership is explicit state, not inferred from bytes or pointer identity;
- recycled pages are scrubbed, including allocator or intrusive-list metadata.

### 4. Prepare fallible work, then publish in a no-fail phase

Ghostty prepares and validates detached terminal pages before linking them into live state, making publication effectively infallible ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/PageList.zig#L4347-L4457)).

This is the right transaction shape for OnePage:

1. Validate input and capacity.
2. Materialize the next record/checkpoint in bounded scratch.
3. Durably append and sync the accepted operation.
4. Publish the new state with no remaining allocation or validation failure.

The same shape should govern completion and cancellation. A model/tool callback must not directly mutate a live page before its durable fact is accepted.

### 5. Use fixed credits and ownership transfer through the I/O pipeline

Ghostty's POSIX reader uses four fixed 64 KiB buffers. Each stage owns a buffer exclusively; the producer stops when all four are in flight, so backpressure reaches the kernel/child instead of accumulating in an unbounded middle queue ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/Exec.zig#L1293-L1408), [source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/Exec.zig#L1477-L1562)).

For OnePage, every stage should spend from one host-level credit budget:

```text
network completion -> mailbox -> active slot -> journal/checkpoint -> response
```

A bounded ingress queue alone is insufficient if draining it allocates unbounded downstream request objects. Credits must cover items and bytes across the complete path, including runtime callbacks and kernel buffers under our control.

When credits run out, OnePage should return overload, defer admission, or durably spill. It should not block a shard forever.

### 6. Publish, then notify once

Ghostty separates mailbox publication from wakeup so producers can enqueue a batch and notify once. The consumer drains all available messages and triggers one redraw afterward ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/mailbox.zig#L57-L108), [source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/Thread.zig#L289-L368)).

OnePage should use one owner loop per shard:

- arbitrary callback threads publish compact immutable facts;
- an empty-to-nonempty transition wakes the owner;
- the owner drains a bounded batch and alone mutates live slots;
- it yields between batches so one busy agent cannot starve the host;
- suspended agents have no waiter and consume no wakeup object.

Semantic coalescing is useful only for disposable state such as progress or telemetry. Accepted operations, completions, and cancellation facts must never be dropped or coalesced.

### 7. Pool async state whose address must remain stable

Ghostty's PTY writes combine the request and its 64-byte buffer in a pooled object because both must remain pointer-stable until the async completion; the callback returns it to the pool ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/Exec.zig#L403-L489), [source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/Exec.zig#L492-L525)).

OnePage should preallocate a fixed number of host-side in-flight operation records per shard. The record should carry only routing identity, generation, bounded buffer references, and cancellation state. The model response body itself may stream or spill to disk; it should not force a large per-operation resident allocation.

### 8. Make bounded failure normal in fuzzing

Ghostty's stream fuzzer uses one fixed buffer allocator, resets it for each input, and treats exhaustion as a handled outcome rather than expanding the heap ([allocator](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/test/fuzz-libghostty/src/mem.zig#L1-L26), [fuzzer](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/test/fuzz-libghostty/src/fuzz_stream.zig#L8-L64)).

OnePage should use the production fixed allocator in recovery and operation fuzz tests. Each test case should reset the same page, fuzz both whole-buffer and byte/chunk-at-a-time paths, and classify capacity exhaustion as a deterministic result. The oracle should include the host-observed Wasm page count, not just allocator counters inside the module.

### 9. Recover from validated record streams, not opaque dumps alone

Ghostty snapshots are ordered, independently CRC-protected records. A `READY` marker means enough state exists to render, while later history can be restored incrementally before `FINISH` ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/snapshot.h#L23-L110), [source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/snapshot.h#L423-L477)).

OnePage should retain the exact-page checkpoint for fast restoration, but treat its journal as the authoritative recovery source. A future checkpoint format can use:

- a small versioned header;
- independently checksummed records;
- a clearly defined resumable prefix;
- strict length and ordering validation before publication;
- incremental replay without loading an agent's entire history into RAM.

Ghostty's caller-owned fixed-buffer serialization and exact size query are also a useful ABI model ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/c/snapshot.zig#L549-L600)).

### 10. Implement the narrow interface, not the generic stack

Ghostty introduced `TinyIo` because Zig's general threaded I/O implementation adds roughly 100–200 KiB of binary and about 300 KiB at runtime. `TinyIo` implements only the blocking syscalls the library needs and explicitly gives up cancellation and concurrent operations ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/lib/TinyIo.zig#L1-L18)).

This is an important nights-and-weekends lesson: keep a familiar interface shape where helpful, but implement only the capabilities OnePage actually promises. Unsupported behavior should fail explicitly. Do not pull in a generic async runtime, HTTP stack, terminal model, or allocator merely because its API is convenient.

## Physical memory: promising, but a separate claim

Ghostty can retain a virtual address range while telling the OS to discard its physical pages, then recommit the same range later. Its API carefully distinguishes a zero-on-next-access guarantee from strict physical reclamation, and support is platform-specific ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/mem.zig#L1-L66), [source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/mem.zig#L69-L171)).

This could strengthen OnePage's story: reserve a bounded slot pool once, discard the physical backing of idle slots, and fault pages back only when work resumes. But the current macOS host uses JavaScriptCore-owned WebAssembly memories. OnePage must not call `madvise` on that storage unless JavaScriptCore's ownership and invariants make it safe.

Therefore this is a measurement spike, not a v1 architectural assumption:

1. Measure RSS, physical footprint, compressed memory, and virtual size separately.
2. Create a fixed number of JSC Wasm slots, dirty every page, then leave them idle.
3. Determine whether JSC/macOS already reclaims their physical backing.
4. If not, investigate a runtime with host-owned linear memory before attempting explicit decommit.

The honest public metrics should remain separate:

- core linear memory per resident slot;
- number of resident slots;
- host/runtime baseline;
- in-flight network and tool buffers;
- logical agents on disk;
- process and model memory excluded from the harness claim;
- physical footprint versus reserved virtual address space.

## Terminal and UI decision

### v1: run inside Ghostty; do not embed it

If OnePage writes to stdout, Ghostty already supplies the valuable UI infrastructure at no incremental harness memory cost: text shaping, GPU rendering, selection, accessibility, native scrollback, links, and platform integration.

The demo should stay on the primary screen and append compact, newline-terminated records. Avoid an alternate-screen TUI: alternate screens intentionally have no scrollback ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/terminal.h#L218-L240)). Restraint also makes the memory result legible rather than hiding it behind a dashboard.

A strong demo layout can be only:

```text
onepage  1 x 64 KiB resident slot  |  1,000 durable agents  |  1 active

agent 0421  resumed       checkpoint 64 KiB       0.7 ms
agent 0421  model waiting  slot released           disk only
agent 0788  resumed       generation 19           0.6 ms
agent 0421  completed     stale generation 18     rejected
```

The terminal scrollback itself becomes the visible trace.

### Later: narrowly feature-gated `libghostty-vt`

Embedding becomes useful only if OnePage must ingest arbitrary ANSI/VT output and then expose a custom plain-text, HTML, or drawn viewport. Ghostty's parser retains state across chunks and safely handles escape sequences split across writes ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/terminal/c/terminal.zig#L2894-L2913)). Malformed input is treated as untrusted input that must not corrupt or crash terminal state, and side-effect sequences are ignored unless callbacks are enabled ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/terminal.h#L55-L103), [source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/include/ghostty/vt/terminal.h#L1946-L1959)).

If this path is needed:

- pin Ghostty behind a thin OnePage adapter because the API is still unstable;
- compile out selection, input, graphics, snapshot, and grid APIs unless required;
- keep effect callbacks disabled by default;
- bound scrollback explicitly;
- preserve raw tool output in the durable journal;
- treat the terminal's plain projection as display state, not the audit record.

Do not call raw escape-code deletion “sanitization.” Cursor movement and erase operations change the visual result; faithful terminal emulation followed by a plain projection is a different operation from preserving a transcript.

## What not to copy

- **Per-session threads and buffers.** Ghostty appropriately creates several threads and a 256 KiB input ring for an active terminal surface. OnePage cannot attach that topology to thousands of sleeping agents ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/Exec.zig#L1304-L1317), [source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/Exec.zig#L1434-L1472)).
- **Unbounded `memory.grow`.** Exact growth is still growth; OnePage must fail closed at its configured slot ceiling.
- **Blocking forever on a full mailbox.** Ghostty's UI-oriented mailbox eventually waits forever after waking its consumer ([source](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/mailbox.zig#L69-L96)). A durable service needs overload, cancellation, or spill semantics.
- **A queue-size-only memory claim.** Ghostty's drained PTY writes create pooled nodes that remain live until async completion. End-to-end credits are the correct bound.
- **Full Ghostty embedding.** The application brings platform windows, fonts, GPU rendering, PTYs, and per-surface lifecycle machinery. The user already has those through the terminal.
- **A Ghostty snapshot as OnePage truth.** Ghostty marks that format/API as work in progress. OnePage's journal should remain authoritative.

## Recommended next spikes

In order:

1. **Mechanical memory contract in CI.** Assert one initial and maximum Wasm page, ABI offsets, stack/static budget, no growth across 10,000 reuse cycles, deterministic exhaustion, and complete scrubbing.
2. **Fixed-credit owner loop.** Build one bounded mailbox plus a preallocated in-flight record pool. Feed completions from arbitrary threads, reject stale generations, and prove the byte/item high-water marks remain flat.
3. **Crash/recovery fuzzing.** Use a resettable fixed allocator; inject truncation, bit flips, duplicate/stale completions, cancellation races, process death at every durability boundary, and OOM at every allocation point.
4. **Physical-footprint experiment.** Measure idle JavaScriptCore Wasm memories before considering explicit decommit or a different runtime.
5. **Primary-screen demo renderer.** Add a no-allocation or fixed-buffer line formatter with conservative SGR, no cursor-addressing, and a `NO_COLOR`/plain mode. Show resident slots, logical agents, durable transitions, and stale-completion rejection live.

The first two are architectural prerequisites. The fifth creates the employment-funnel “wow”: a visibly capable agent system whose live memory stays flat as logical agent count grows.

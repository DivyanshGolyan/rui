# Native Core image

## Question

Can OnePage keep the one-page state invariant without paying for a WebAssembly runtime in the
production path, while retaining an independently compiled target that catches layout and semantic
drift?

## Decision

Yes. The production Core is a target-neutral Zig reducer over a caller-owned `CoreImage` whose
compile-time size is exactly 65,536 bytes. The CLI calls it natively. The same reducer is compiled to
`wasm32-freestanding` only for contract and differential testing.

This is a stronger boundary than “the Wasm linear memory is one page”:

- `CoreImage` is the complete persistent policy-state and core-scratch allocation.
- It contains no pointers and can be checkpointed as exact bytes.
- State begins at 8 KiB; the prefix reserves the Wasm stack and linker-owned static data.
- The bounded model-response window begins at 12 KiB.
- The native call stack, allocator metadata, executable text, host buffers, and operating-system
  pages are measured separately and are not included in the one-page claim.

The production binary neither loads JavaScriptCore nor reads a `.wasm` artifact. The Wasm artifact
remains valuable because it is a separately compiled representation of the same reducer, not because
it makes the demonstration easier.

## Mechanical invariants

Compile-time assertions require:

- `@sizeOf(CoreImage) == 65_536`;
- the payload begins at byte 8,192;
- the response window begins at byte 12,288;
- state alignment is at most eight bytes; and
- the payload fills the remainder of the image exactly.

The Wasm verifier independently requires one initial and maximum memory page, no imports, no
`memory.grow`, no exported or used table, no mutable-state globals beyond the linker stack pointer,
and no active data segment crossing the 8 KiB state boundary. This last check prevents the layout
collision found during the conversion: the linker emitted 19 bytes of static data immediately after
the 4 KiB stack, so placing state at byte 4,096 was not safe.

## Differential trace

`zig build native-core -Doptimize=ReleaseSafe` executes the following trace through both native Zig
and the Wasm conformance build:

1. initialize and deliver an event;
2. start a task and accept a model operation;
3. classify a bounded Bash tool call;
4. commit the tool result and begin a second model operation;
5. classify and commit the Final Answer.

After every semantic boundary, all bytes from the state boundary to the end of the image must match.
The spike also checkpoints and restores 1,000 logical agents through one reused native image.

## Measurement

One representative Apple Silicon macOS run with Zig 0.16.0 and `ReleaseSafe`:

| Measurement | Resident bytes |
| --- | ---: |
| Process before Core allocation | 1,359,872 |
| First initialized Core image | 1,458,176 |
| After 1,000 checkpoint round trips | 1,540,096 |
| 2 initialized images | 1,638,400 |
| 4 initialized images | 1,769,472 |
| 8 initialized images | 2,031,616 |

The logical allocation is exactly 64 KiB per resident image. RSS changes use operating-system and
allocator granularity, so they are evidence about the whole process rather than a promise that every
allocation changes RSS by exactly 64 KiB. From one to eight resident images, measured RSS grew by
491,520 bytes, about 68.6 KiB per additional image.

The earlier JavaScriptCore spike measured roughly 8 MiB before the first slot and about 96 KiB per
additional Wasm instance. Native execution removes that shared runtime floor and keeps the marginal
allocation close to the actual image size.

## Consequence

“One page” now describes a language-level native state image, not a runtime implementation detail.
It supports the intended single-host shape: sleeping agents are checkpoints and durable records;
active agents borrow bounded images; and topology or total logical-agent count does not require a
resident object graph. Wasm remains useful as a portability and conformance oracle, but it is not on
the user path.

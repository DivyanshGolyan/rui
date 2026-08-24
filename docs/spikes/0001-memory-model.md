# Memory-model spike

## Question

Can one system JavaScriptCore process execute many durable logical agents while keeping resident core
memory bounded by a fixed execution-slot count rather than total task count?

This spike isolates that question from model inference, repository tools, approvals, and the final
terminal experience.

## Shape

```text
one macOS process
  one JavaScriptCore context
    one compiled WebAssembly.Module
      fixed pool of WebAssembly.Instance execution slots
        exactly one non-growable 64 KiB memory per slot

1,000 logical agent page images on disk
```

A logical agent owns neither a process nor a permanently resident Wasm instance. The host overwrites
one execution page from a verified image, runs the core to a quiescent boundary, and writes the page
back to disk.

## Enforced contract

The Zig linker sets both initial and maximum Wasm memory to 65,536 bytes. The native inspector rejects
modules that do not declare exactly one exported memory with minimum and maximum equal to one page.
The current ReleaseSmall module reports:

```text
linear memory       65,536 B
imports             0
table               funcref min=1 max=1, unexported, unused
mutable global      i32 init=4096, unexported, unused
function exports    6
data section        0 B
```

The sole mutable global's initial value matches the configured 4 KiB Zig stack boundary. The module
does not export it, and the current function bodies contain no global reads or writes. The one-entry
table is likewise unexported; the code contains no table access or indirect calls. The inspector also
rejects any `memory.grow` instruction. These are build-breaking invariants for the spike rather than
manual observations.

The host dynamically loads JavaScriptCore from the macOS system framework. It does not invoke the
private `jsc` helper and does not embed another Wasm runtime.

## First measurements

Measured on the initial development machine on 2026-08-24 using Zig 0.16.0 and ReleaseSmall. RSS is
reported by macOS `proc_pidinfo`; figures are observations, not stable budgets.

| Boundary | RSS |
| --- | ---: |
| JavaScriptCore context | 7,815,168 B |
| Compiled module | 8,126,464 B |
| First initialized slot | 8,486,912 B |
| After 1,000 sequential logical agents | 8,486,912 B |
| Two resident slots | 8,683,520 B |
| Four resident slots | 8,830,976 B |
| Eight resident slots | 9,158,656 B |

The 1,000 logical agents produced exactly 65,536,000 bytes of page-image payload and 65,600,000 bytes
including checkpoint headers. Their run took 355 ms with existing local files and filesystem caches.
This path closes each file but does not yet issue an explicit durability barrier, so the timing must
not be presented as crash-durable journal throughput.

Across the one-to-eight-slot interval, measured RSS increased by 671,744 bytes, or approximately
96.0 KiB per additional slot. That average includes each 64 KiB linear-memory page, JavaScriptCore
instance metadata, allocation granularity, and measurement noise.

## Hidden linear growth found and removed

The first implementation generated two unique JavaScript programs per logical agent and allocated
their source through a process-lifetime arena. RSS increased from 8,404,992 bytes after the first slot
to 13,762,560 bytes after 1,000 agents.

The corrected implementation compiles one bridge function and invokes it repeatedly through the
JavaScriptCore C API with numeric arguments. After that change, RSS was identical before and after
the 1,000-agent loop. This is the main value of the spike: it found host-side per-agent growth that
the one-page core alone could not prevent.

## Verified behavior

- The emitted module declares exactly one initial and maximum memory page.
- JavaScriptCore exposes exactly 65,536 bytes for the instance memory.
- The complete page can be copied to disk and restored without reconstructing an object graph.
- The restored task preserves its agent ID, event count, accumulator, and quiescent state.
- A slot is zeroed before initialization for another agent.
- Pattern-based tests detect residual bytes from the previous slot occupant.
- Sample agents 1, 500, and 1,000 restore with the expected identity.
- One compiled `WebAssembly.Module` is reused to construct all measured resident instances.
- Checkpoint headers and payloads are checksummed independently and reject stale identity or
  generation metadata before restoration.

## Next questions

1. Measure process physical footprint in addition to RSS and repeat samples across fresh processes.
2. Define and test the submitted, accepted, and completed operation boundaries before a slot can be
   reused.
3. Replace one-file-per-agent output with an atomic publication protocol and the minimal journal.
4. Add explicit crash points around checkpoint and operation publication and verify recovery from
   every valid prefix used by the spike.
5. Measure restore latency and slot scheduling independently from filesystem cache effects.
6. Decide the initial execution-slot default only after measuring one, two, four, and eight slots on
   representative machines.

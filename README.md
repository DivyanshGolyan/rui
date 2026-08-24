# OnePage

A single-host coding-agent architecture whose persistent mutable agent state and core-owned buffers
fit in one fixed, non-growable 64 KiB WebAssembly linear-memory page.

The first memory-model spike is now executable on macOS Apple Silicon. It compiles a Zig core to
`wasm32-freestanding`, loads it through the system JavaScriptCore framework, mechanically verifies
the one-page contract, snapshots and restores the complete page, scrubs reused slots, and multiplexes
1,000 checksummed durable simulated agents through one resident execution slot.

The operation-lifecycle spike uses four separate host processes to submit, durably accept, complete,
recover, and replay 1,000 operations while their agents are absent from memory. Both recovery
processes restore every page through the same slot without building a resident per-agent index.

The fixed-credit harness spike extracts the compiled Wasm contract into one verifier and adds a
1.5 KiB-bounded native owner with nonblocking completion admission, durable-before-apply ordering,
stale and duplicate rejection, bounded drive quanta, and crash/replay tests. Its 32-entry maximum is
fixed at compile time and does not vary with logical-agent count.

The owner crash-recovery spike connects that harness to the real operation journal and JavaScriptCore
slot. A child process exits after the completion record is synced but before slot mutation; two fresh
recovery processes then prove one application followed by one duplicate. The fixed native control
metadata is 1,528 bytes, excluding the runtime, one-page core, and checkpoint staging buffer.

The atomic checkpoint spike publishes through temporary write, file sync, same-directory rename,
and parent-directory sync. Sixteen fresh child processes terminate at each boundary and recover only
the old or new canonical page while keeping the journal unchanged.

## Requirements

- macOS on Apple Silicon
- Zig 0.16.0

## Run the spike

```sh
zig build test -Doptimize=ReleaseSafe
zig build run -Doptimize=ReleaseSmall
zig build lifecycle -Doptimize=ReleaseSmall
```

Generated page snapshots are written under `snapshots/` and ignored by Git.

See the spike notes for architecture, measurements, caveats, and next questions:

- [`docs/spikes/0001-memory-model.md`](docs/spikes/0001-memory-model.md)
- [`docs/spikes/0002-checkpoint-format.md`](docs/spikes/0002-checkpoint-format.md)
- [`docs/spikes/0003-operation-lifecycle.md`](docs/spikes/0003-operation-lifecycle.md)
- [`docs/spikes/0004-fixed-credit-harness.md`](docs/spikes/0004-fixed-credit-harness.md)
- [`docs/spikes/0005-owner-crash-recovery.md`](docs/spikes/0005-owner-crash-recovery.md)
- [`docs/spikes/0006-atomic-checkpoint-publication.md`](docs/spikes/0006-atomic-checkpoint-publication.md)

Source audits that informed the architecture:

- [`docs/research/ghostty-lessons.md`](docs/research/ghostty-lessons.md)
- [`docs/research/deepseek-harness-lessons.md`](docs/research/deepseek-harness-lessons.md)
- [`docs/research/fx-pi-harness-lessons.md`](docs/research/fx-pi-harness-lessons.md)

Accepted designs:

- [`docs/design/0001-first-real-harness.md`](docs/design/0001-first-real-harness.md)

Canonical domain language:

- [`CONTEXT.md`](CONTEXT.md)

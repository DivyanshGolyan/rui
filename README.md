# OnePage

A single-host coding-agent architecture whose persistent mutable agent state and core-owned buffers
fit in one fixed, non-growable 64 KiB WebAssembly linear-memory page.

The first memory-model spike is now executable on macOS Apple Silicon. It compiles a Zig core to
`wasm32-freestanding`, loads it through the system JavaScriptCore framework, mechanically verifies
the one-page contract, snapshots and restores the complete page, scrubs reused slots, and multiplexes
1,000 checksummed durable simulated agents through one resident execution slot.

## Requirements

- macOS on Apple Silicon
- Zig 0.16.0

## Run the spike

```sh
zig build test -Doptimize=ReleaseSafe
zig build run -Doptimize=ReleaseSmall
```

Generated page snapshots are written under `snapshots/` and ignored by Git.

See the spike notes for architecture, measurements, caveats, and next questions:

- [`docs/spikes/0001-memory-model.md`](docs/spikes/0001-memory-model.md)
- [`docs/spikes/0002-checkpoint-format.md`](docs/spikes/0002-checkpoint-format.md)
- [`docs/spikes/0003-operation-lifecycle.md`](docs/spikes/0003-operation-lifecycle.md)

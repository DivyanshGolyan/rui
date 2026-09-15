# Host memory evidence checkpoint

Describe memory before judging it: allocation origins and lifetimes, fixed field sizes and population, and whole-process accounting. This is a small local experiment, not the production measurement gate or a replacement for it. [Results](results.md) and the [interactive explanation](index.html) record the September 15 trial; they do not refresh automatically when collecting a new run.

## Reproduce

On macOS with Zig 0.16, the repository build prerequisites, and full Xcode selected and initialized, run from the repository root:

```sh
python3 research/memory-trial/collect.py --output /tmp/latifa-memory-evidence-new --instruments
```

Use a new output directory: existing evidence is never overwritten. Omit `--instruments` for native heap/history/VM snapshots only. The command builds ReleaseSafe, copies the executable and matching debug information, records source/build provenance, then runs without and with allocation logging. With Instruments it signs only a disposable executable copy to allow debugger attachment and records a third run. No live provider, credentials or production source changes are involved. The fixture server runs in a separate process from the measured Host (inside the Python driver).

The workload configures one Session, waits with one provider request active, returns exactly 100,000 ASCII answer bytes, reads the saved answer, and checks zero occupied custody and charged scratch before retained-idle observations. It allocates eight execution slots. End-of-trial termination is not graceful-shutdown evidence.

Output contains executable, dSYM, type layout, provenance, per-run manifests, raw tool output, lifecycle/SQLite diagnostics and optionally an Instruments trace. Keep these bulky, machine-specific bundles outside Git. The source and any uncommitted diff identified in provenance must remain available to reproduce a dirty-checkout experiment. Prefer a clean checkout for shared evidence.

Open `instruments/host.trace` in Instruments. Allocations describes retained versus transient allocations; VM Tracker and native VM snapshots describe regions. Attach-mode recording begins after startup, so startup origins come from the separate malloc-logging run. A saved trace file alone is not success: the driver checks final recording diagnostics. OS permissions or unsupported tooling are failures, not zero usage.

## Interpret and refresh

- Never add heap bytes, SQLite counters and footprint: they overlap. Requested bytes, allocator size classes, virtual reservations and resident pages are different quantities.
- Allocation backtraces establish origin; semantic ownership and release conditions require owning code. Compiler type layout reveals inline fields; union variants overlap.
- Observe cleanup separately from footprint reduction: an allocator or library may retain memory after an object is freed.
- This workload does not qualify 1,000 requests, TLS, history growth, repeated churn or Linux. Keep unanswered ownership questions explicit.

When an implementation changes allocation, buffers, threads or resource lifetimes, use the owning verification requirements and refresh the affected evidence and explanation. Do not impose a threshold or a full profiling campaign on unrelated changes. [VERIFICATION.md](../../VERIFICATION.md) owns required evidence; this directory documents collection and recorded observations only.

### Recorded chart provenance

`recorded-heap.json` preserves the native heap summary rows (not payloads) from retained-idle logged3 with the raw report SHA-256. `heap-groups.json` groups those rows in order: `instantiateVariable` → thread-local; `sqlite` → SQLite; `CRYPTO_` → OpenSSL; `Curl_` or `thrdpool` → curl; `c_allocator_impl` → Zig allocator; everything else → other. The grouped sum equals 1,315,968 bytes. These categories describe allocation origin, not exclusive semantic ownership. The HTML is a fixed explanation of that recorded sample; it is not a live dashboard.

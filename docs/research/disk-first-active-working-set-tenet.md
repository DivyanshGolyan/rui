# Disk-first custody for a memory-bounded agent harness

Date: 2026-09-02

Status: research input for the Host Runtime Wayfinder. This note is not a
normative contract and does not change issue #52 or issue #66.

## Conclusion

OnePage should adopt a disk-first tenet, with two qualifications: “disk-backed”
does not mean “absent from RAM,” because ordinary file I/O uses the kernel page
cache; and SQLite should receive completed semantic facts, not every streaming
fragment.

Recommended wording:

> **RAM is for the bounded active working set, not the duration or size of
> custody. Content-sized sequential bytes default to disk-backed streaming;
> CPU work borrows bounded windows and releases them promptly. Canonical facts
> enter SQLite only at semantic boundaries. Count file-cache, writeback, and
> kernel buffers in the whole-machine budget.**

This is more precise than “memory is for data that needs to be fed to the CPU
fast.” The CPU ultimately operates on data in registers/cache/DRAM, including
file data supplied through the page cache. The design question is whether the
*entire value* must remain process-owned and resident, or whether the CPU can
consume one bounded window at a time. One-pass, sequential, content-sized data
normally needs the latter.

## Orders of magnitude

These figures are napkin-math scales, not OnePage limits.

| Access path | Representative scale | What the number means |
| --- | ---: | --- |
| L1 cache hit | a few CPU cycles, roughly 1–2 ns | Illustrative cache-hit latency. Intel documents common L1 load latency in the 4–7-cycle range on a representative Core microarchitecture; the exact Apple M1 Pro value is not public in the sources used here. [Intel optimization manual](https://cdrdv2-public.intel.com/821614/356477-Optimization-Reference-Manual-V2-050.pdf) |
| DRAM | roughly 80–100 ns for a dependent random access | A useful architectural order, not measured on the OnePage host. It is tens to hundreds of times slower than an L1 hit but still sub-microsecond. |
| Modern NVMe, 4 KiB at queue depth 1 | about 45 microseconds/read and 12.5 microseconds/write | Derived from Samsung's published 22k read and 80k write IOPS: `1 / IOPS`. Vendor best-case results include its test system and cache policy. [Samsung 990 Pro data sheet](https://download.semiconductor.samsung.com/resources/data-sheet/Samsung_NVMe_SSD_990_PRO_Datasheet_Rev.1.0_10129514072296.pdf) |
| Modern NVMe, sequential | up to 7.45 GB/s read and 6.9 GB/s write | Representative PCIe 4.0 device ceiling, not a measurement of this Mac's internal SSD. [Samsung 990 Pro data sheet](https://download.semiconductor.samsung.com/resources/data-sheet/Samsung_NVMe_SSD_990_PRO_Datasheet_Rev.1.0_10129514072296.pdf) |
| OnePage measurement host memory | up to 200 GB/s | The measured host identifies as an M1 Pro MacBook Pro; Apple publishes up to 200 GB/s unified-memory bandwidth for M1 Pro. Bandwidth is not single-load latency. [Apple M1 Pro announcement](https://www.apple.com/newsroom/2021/10/apple-unveils-game-changing-macbook-pro/) |

The useful comparison is therefore:

- a cold, small random NVMe access is roughly **hundreds of times slower than
  DRAM** and tens of thousands of times slower than a cache hit;
- peak sequential M1 Pro memory bandwidth is roughly **27–29 times** the cited
  NVMe sequential bandwidth; but
- a sequential 100 KiB value has only about **14–15 microseconds** of media
  transfer time at 6.9–7.45 GB/s, and 1 MiB about **0.14–0.15 milliseconds**.
  Filesystem, syscall, scheduling, and queueing overhead make real elapsed time
  higher, especially for cold or fragmented I/O, but the payload transfer is
  tiny beside a multi-second model response.

The cold-disk number is often not the path OnePage will observe. A response that
was just written normally remains in the OS page cache, so a validation read is
usually memory-backed. Apple documents both cached file I/O and `F_NOCACHE` for
applications that deliberately disable caching. Linux describes the same model:
file data enters the address-space/page cache, dirty pages are later written
back, and clean pages may be reclaimed under pressure. [Apple file-system
performance guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/FileSystem/Articles/FilePerformance.html),
[Linux VFS documentation](https://docs.kernel.org/filesystems/vfs.html#the-address-space-object)

Thus disk-backed custody primarily removes content-sized process heap ownership,
per-Agent buffers, and retention coupled to custody duration. It does **not**
prove that the same number of bytes immediately disappears from whole-machine
physical memory. File-backed clean pages are reclaimable; dirty pages consume
memory and create writeback pressure until flushed.

## LLM-rate napkin math

The workload assumption under discussion is 50–100 output tokens/s and 3–4
semantic characters/token:

```text
one call       = 150–400 semantic bytes/s
100 calls      = 15,000–40,000 semantic bytes/s
one 100 KiB response at 400 B/s = about 256 seconds of generation
```

This is consistent with OpenAI's first-party description of previous flagship
Responses API models at roughly 65 tokens/s. Providers expose incremental SSE
events while the response is generated; event boundaries and wire bytes are not
the same as semantic tokens or characters. [OpenAI on Responses API
throughput](https://openai.com/index/speeding-up-agentic-workflows-with-websockets/),
[OpenAI streaming reference](https://platform.openai.com/docs/api-reference/responses-streaming/response/refusal)

At 100 calls, even the upper semantic rate is only 0.00058% of the cited
6.9 GB/s NVMe write ceiling. Protocol framing can dominate those semantic bytes,
so the measured OnePage transport result is more useful than that theoretical
ratio.

The capacity-100 reactor control drove 100 separate TLS/SSE connections at 100
token-events/s each. It observed a median 9,802 receive callbacks/s and about
1.225 MB/s of wire bytes while writing each borrowed libcurl chunk directly to
an unlinked spool. Median client CPU was 0.225 of one core and active physical
delta was 4.719 MiB. The one-minute soak processed 42.6 MB without duration-
dependent resident growth; the spools occupied 46.3 MB on the filesystem. Cached
write p99 was at most 16.384 microseconds in clean runs, although individual
tails reached 8.41 ms and one soak write reached 29.96 ms. [Capacity-100 reactor
artifact](https://github.com/DivyanshGolyan/onepage/blob/2b2664141375415b9c9b787c8dff9d281804d266/research/host-runtime/reactor-capacity-100/README.md)

Against the representative 6.9 GB/s NVMe ceiling, the measured 1.225 MB/s wire
rate has roughly **5,600 times bandwidth headroom**. That does not guarantee
tail-free service under disk pressure, but it demonstrates that aggregate
throughput is not the reason to retain whole responses in RAM.

## What should be disk-backed

The following content can be streamed to transient disk or read from canonical
SQLite without a tangible addition to an LLM-scale end-to-end latency, provided
all paths remain bounded and the capacity-100 terminal burst is measured:

| Data | Recommended custody | Why |
| --- | --- | --- |
| Incomplete model response wire bytes | Secure, immediately unlinked transient spool | Nothing semantic can consume the complete response until transport ends and validation succeeds. Stream borrowed network chunks directly; retain no whole SSE event or response. |
| Bash stdout and stderr | Secure unlinked transient spool with a hard aggregate quota | The model receives the Tool Result after the Action settles. Pipes must continue draining even after retention overflows, but output need not accumulate in process memory. |
| Provider request body | Canonical inputs in SQLite; serialize through bounded windows, optionally into transient scratch when the provider API requires a known physical representation | Custody may last minutes, but each byte is generally uploaded once. A complete prompt-sized heap copy adds no semantic value. |
| Sealed candidate during parsing/validation | Read the raw spool through a shared bounded parser workspace; write canonical candidate bytes to a second transient spool only when transformation requires it | Validation is one-pass work after the response ends. A full raw buffer, JSON tree, and canonical copy would multiply content memory by Active Capacity. |
| Accepted Conversation and Tool Result content | Canonical immutable content in SQLite, read through bounded windows | It must survive restart, and SQLite is already the sole recoverable authority. Do not keep a resident Session graph or content cache merely because a future request may need it. |
| Retry eligibility and runnable backlog | Indexed scalar rows in SQLite | A one-second bounded poll is trivial compared with minute-scale retries and removes sleeping per-Turn timers and queues. |
| Patch intent and bounded evidence | Canonical rows/content in SQLite; bounded streaming/hash windows during application and reconciliation | Patch needs exact provenance and observations, not a resident content copy for the duration of scheduling or custody. |

The terminal path should therefore look like:

```text
provider/Bash borrowed bytes
        -> unlinked spool (sequential, incomplete, non-authoritative)
        -> seal
        -> bounded shared parse/validation windows
        -> one semantic SQLite transaction
        -> release spool and borrowed workspace
```

The transient spool is not a second recoverable authority. A Host crash may lose
it; the committed Attempt remains unresolved and follows effect-specific
recovery. SQLite contains only facts OnePage has admitted semantically.

## What must remain resident

Disk-first is not “zero RAM.” The minimum live working set is:

- the reactor and provider-library connection/TLS state that is unavoidable
  while sockets are live;
- kernel socket/pipe queues, measured separately from process RSS;
- a small bounded physical-custody record per active effect: Attempt identity,
  owned handles/descriptors, deadlines, byte counters, cancellation/interruption
  flags, and publication state—but no content payload;
- bounded credentials, headers, and request-serialization state required by the
  live transport;
- borrowed transfer windows supplied by the I/O library, not copied into
  retained per-call buffers;
- one bounded shared validation/import workspace and parser stack/state;
- SQLite's explicitly bounded page cache, prepared statements, the current
  bounded Decision Snapshot, and small Host-control structures; and
- actually touched thread stacks and allocator/library high water.

OnePage already measured a 4 KiB SQLite import window while importing a 98,372
byte transient response, and 208 bytes of transient metadata per live Harness
(20,800 bytes at capacity 100). The same fixture's SQLite heap high water was
318,336 bytes for that response. These measurements support windowing, but they
describe the superseded implementation's structures and are not permission to
carry them into the new relational engine unchanged. [Host Store measurement](../measurements/2026-08-31-host-store-single-store.md#transient-capture)

## SQLite is the semantic boundary, not the stream spool

Writing every token or SSE event into SQLite would be both mechanically and
semantically wrong:

1. SQLite permits only one writer at a time. Per-token updates across 100 streams
   would turn provider event frequency into Store command frequency and writer
   contention.
2. Every SQL write runs inside a transaction; an implicit transaction commits
   when its statement finishes. At 100 streams × 100 token-events/s, that is up
   to 10,000 tiny transactions/s if implemented naively. [SQLite transaction
   documentation](https://sqlite.org/lang_transaction.html)
3. With WAL and `synchronous=FULL`, SQLite syncs the WAL at every transaction
   commit. With `NORMAL`, most commits omit that sync but sacrifice recent
   power-loss durability. OnePage should choose durability at semantic admission
   boundaries, not weaken it to make transient token writes affordable. [SQLite
   WAL documentation](https://www.sqlite.org/wal.html#performance_considerations),
   [SQLite synchronous documentation](https://sqlite.org/pragma.html#pragma_synchronous)
4. An incomplete stream is not yet canonical model output. Making partial bytes
   durable would require lifecycle, recovery, truncation, validation, and replay
   semantics for data the model may never complete.

The current Host Store fixture provides a useful local scale for actual semantic
commits: with 4 KiB pages and `synchronous=EXTRA`, the single-store path measured
0.771 ms p50, 1.031 ms p95, and 1.113 ms p99 at the 100-Session population point.
Those are single-run fixture results, not a production latency guarantee. They
show why one millisecond-class commit at a semantic boundary is reasonable and
why thousands of commits per second are not free. [Host Store measurement](../measurements/2026-08-31-host-store-single-store.md#latency-throughput-and-process-memory)

A simultaneous 100-response terminal burst may serialize validation and durable
commits into tens or hundreds of milliseconds. That remains small beside model
generation, but it is not automatically negligible for time-to-next-request. It
must be measured in the capacity-100 proof rather than hidden by 100 parser
arenas or parallel SQLite writers.

## Backpressure and failure caveats

Disk-first moves pressure; it does not abolish it.

- Charge actual spool growth against one aggregate Host scratch-byte budget and
  a descriptor budget. Capacity must not silently scale as maximum response size
  multiplied by every possible Turn.
- If the scratch filesystem is full, the quota is exhausted, or a write fails,
  stop retaining bytes, continue only the bounded drainage/termination needed
  for liveness, and settle through the effect-specific failure contract. Never
  fall back to an unbounded RAM buffer.
- Ordinary cached writes can dirty page-cache pages faster than storage writes
  them back. Account for spool allocation, file-backed/dirty pages, and observed
  writeback tails in the whole-machine budget. The reactor experiment explicitly
  could not attribute its global page-cache delta on a concurrently used Mac;
  it proves process-footprint shape, not zero machine-memory cost.
- Do not call `fsync` for every transient spool fragment. Scratch content is
  intentionally disposable on Host loss. Canonical SQLite commits retain the
  configured durability contract. Kernel documentation explains that buffered
  writes may report success before writeback and later surface errors at
  `fsync`; durability barriers are materially different from cached writes.
  [Linux VFS writeback documentation](https://docs.kernel.org/filesystems/vfs.html#the-address-space-object),
  [Linux block writeback-cache documentation](https://kernel.org/doc/html/latest/block/writeback_cache_control.html)
- Do not adopt direct or no-cache I/O merely from theory. `F_NOCACHE`, larger
  coalesced writes, or another cache policy may reduce cache pressure but can
  worsen latency and complicate alignment/partial-write handling. Compare them
  under the measured 100-stream workload before adding machinery. The direct
  cached-write baseline already met the narrow reactor service test.

## Decision test

For every proposed resident allocation, ask:

1. Will the CPU repeatedly or randomly access these bytes before the current
   operation ends, or can it consume them sequentially once?
2. Must these bytes survive restart? If yes, why are they not canonical SQLite
   content? If no, why are they not transient disk-backed custody?
3. Does the value need to be resident for its entire custody duration, or only a
   bounded window while one CPU step transforms it?
4. Is the allocation control state whose size is independent of content, or is
   it content scaled by Active Capacity?
5. Have process RSS, kernel buffers, file-cache/writeback pages, scratch
   allocation, and I/O tails been measured separately at capacity 100?

An allocation passes the tenet only when there is a concrete latency, random-
access, protocol, or liveness reason for residency. Convenience or “the limit is
bounded” is not enough.

## Recommended use in the Wayfinder

Adopt the refined tenet as a design constraint for issues #67–#69, not as a claim
that all disk I/O is free. The capacity proof should verify:

- no prompt-, response-, Tool Result-, or Conversation-sized resident buffer per
  active call;
- bounded process RSS slope and separately bounded kernel/file-cache pressure;
- scratch quota and disk-full behavior at 100 long-running calls;
- one shared validation/import workspace under a synchronized terminal burst;
- no SQLite writes before a semantic admission boundary; and
- time-to-next-model-request tails, not just total throughput.

The tenet's central claim is justified: for an agent harness whose dominant
effects last seconds or minutes, moving one-pass content custody to disk can save
memory proportional to Active Capacity while adding no tangible model-scale
latency. The exceptions should be proven, not assumed.

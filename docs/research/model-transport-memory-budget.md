# Model transport memory budget

Date: 2026-08-27

## Capacity-one implementation evidence (2026-08-29)

The issue #11 adapter now has the following capacity-one bounds. These are classified by evidence source so compile-time limits are not presented as measured resident memory.

| Component | Evidence | Capacity-one value or bound |
| --- | --- | ---: |
| Provider-neutral request window | compile-time source bound | 4,096 bytes |
| Canonical decoded candidate | compile-time source bound | 98,372 bytes |
| SSE wire event | compile-time work/compatibility bound | 598,424 bytes counted; the pre-refactor adapter also allocates this amount per call |
| Total SSE response | compile-time source bound | 2,393,696 bytes cumulatively; not retained |
| JSON parser | pre-refactor compile-time source bound | one in-place cursor over the complete event, depth 32; no payload-sized arena |
| HTTP response transfer window | compile-time source bound | 64 bytes on the Codex success path |
| HTTP rejection diagnostic body | compile-time source bound | 4,097 bytes read, at most 4,096 accepted |
| HTTPS connection byte buffers | Zig 0.16 source-derived | 59,151 bytes before structs and allocator rounding |
| HTTP content decoding | implementation observation | identity encoding only; no decompression window |
| TCP send and receive defaults | measured with `sysctl` on the development host, 2026-08-29 | 131,072 bytes each |
| TCP autotuning maxima | measured with `sysctl` on the development host, 2026-08-29 | 4,194,304 bytes each |
| Async task stack reservation | Zig 0.16 source-derived | 4 MiB virtual minimum per Kqueue task; resident pages unmeasured |
| Retained connection state | implementation observation | zero idle Codex connections; each request uses `keep_alive = false` and deinitializes its client |

The capacity-one implementation initially compacted SSE `data:` lines in one 598,424-byte frame and decoded JSON strings in place. That avoided duplicate payloads but made the maximum wire spelling a per-call resident allocation. The replacement keeps the same wire-event and total-stream limits as counted work bounds, parses through a small transfer window, and retains only potentially authoritative decoded values in capped buffers that grow with actual content. It retains no complete event, JSON DOM, complete canonical result buffer, or second payload-sized copy. The whole-call deadline independently limits elapsed time.

The opt-in `zig build codex-live-repair` command now writes the raw capacity-one observation to
`.zig-cache/codex-live-capacity-one.json`. The report separates exact compiled structures and declared
windows from whole-process RSS, macOS physical footprint, virtual size, thread count, whole-process
stack reservation sampled while TCP is active, observed TCP queues, and configured socket high-water
limits. It also records that
the adapter has no idle connection pool. The report rejects a successful live repair when any required
dynamic measurement was missed.

This capacity-one observation does not establish a per-call slope. RSS and physical footprint include
the complete Harness process, the phase-to-phase RSS increase is only an upper bound on transport
growth, and macOS `netstat` exposes queued bytes and high-water limits rather than complete allocated
kernel socket memory. Issue #43 must still run the production-shaped 1, 10, 50, and 100 call matrix
before OnePage claims a supported concurrency.

## Decision

Updated 2026-08-30: V1 replaces the per-call Zig `std.http.Client` with blocking
system libcurl easy on the population-bounded executor. The Zig byte-buffer and
trust-bundle analysis below remains historical evidence for rejecting the old
transport; it is not the selected libcurl allocation model. At capacity 100,
the controlled spike measured blocking easy at about 8.4 MiB active and 10.0 MiB
post-churn physical footprint, versus about 4.8 MiB active and 4.9 MiB post-churn
for multi. The single-digit-MiB saving does not justify a second asynchronous
transfer lifecycle in V1. Production evidence must still include libcurl-owned
TLS and request state, cold resolver threads, descriptors, kernel sockets,
worker stacks, cancellation latency, idle wakeups, and graceful shutdown.

Do not size the V1 transport lane from the largest legal SSE spelling. The selected adapter reports
its source-level fixed structures directly: a 10,928-byte resumable request reader containing its
4 KiB content window, a 5,880-byte Capture containing its 4 KiB projection window, and a 16,516-byte
credential. The model-call frame also has bounded authorization-header, endpoint, account-header,
and 4,097-byte diagnostic storage. A conservative sum is roughly **55 KiB of OnePage-owned fixed
state per live call**, before compiler stack-slot reuse. This is not a measured RSS floor: stack
pages are committed on touch, libcurl owns additional heap and TLS state, and its header list copies
the authorization value.

Before the concurrency gate, use these analytical ranges rather than one false per-call constant:

| Transport component | Per active call | 100 active calls |
| --- | ---: | ---: |
| OnePage-owned fixed request, capture, credential, header, and diagnostic state | conservatively about 55 KiB | about 5.4 MiB |
| libcurl, TLS, resolver, and connection state | measured, not structurally byte-bounded by OnePage | measured |
| Typical decoded candidate | actual content, normally well below 20 KiB | workload-dependent |
| Pathological simultaneous text plus arguments | at most about 118 KiB before allocator slack | about 11.5 MiB |
| Kernel sockets and touched task stacks | measured separately | measured separately |

These figures exclude the Activation Slot, QuickJS, SQLite, durable prompt and result storage,
subprocesses, and shared host baseline. They are analytical components, not a proved RSS ceiling.
Issue #43 must measure their aggregate effect at 1, 10, 50, and 100 concurrent transports before
OnePage declares a supported capacity.

Subprocesses intentionally launched by a model are workload memory under ADR-0013, not part of this
OnePage-owned transport budget. Provider transport and its kernel socket memory remain orchestration
memory because OnePage creates and owns them.

The most useful napkin formula is:

```text
process RSS transport ~= shared transport baseline
                      + C * (about 55 KiB OnePage fixed state
                             + actual bounded decoded candidate
                             + measured libcurl/TLS/resolver state
                             + committed worker-stack pages
                             + allocator slack)

whole-machine transport ~= process RSS transport
                         + C * actual kernel socket memory
                         + transport-attributable file-cache/writeback pages
```

`C` is concurrently active HTTPS connections. With the selected HTTP/1.1 easy handles, 100 concurrent
requests mean approximately 100 TCP/TLS connections, not 100 multiplexed streams on one connection.

## Historical rejected Zig transport: 58 KiB of TLS buffers per connection

The earlier Zig 0.16.0 `std.http` design's HTTPS connection allocation
matches the current upstream implementation: the client defaults to an 8,192-byte HTTP read buffer,
a 1,024-byte write buffer, and a TLS buffer sized to the maximum ciphertext record. The HTTPS
allocation contains three TLS-sized regions plus those HTTP buffers. See Zig's
[`std.http.Client`](https://github.com/ziglang/zig/blob/master/lib/std/http/Client.zig) and
[`std.crypto.tls.Client`](https://github.com/ziglang/zig/blob/master/lib/std/crypto/tls/Client.zig).

[TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446.html#section-5.1) limits plaintext fragments to
2^14 bytes, while [TLSCiphertext](https://www.rfc-editor.org/rfc/rfc8446.html#section-5.2) may contain
at most 2^14 + 256 bytes, plus its 5-byte record header. Zig consequently uses 16,645 bytes for the
minimum TLS buffer; its constants are in
[`std.crypto.tls`](https://github.com/ziglang/zig/blob/master/lib/std/crypto/tls.zig).

```text
3 * 16,645 + 8,192 + 1,024 = 59,151 bytes = 57.8 KiB
```

That was byte-buffer storage only. It excluded the TLS and connection structs, hostname, allocator
rounding, request object, caller-supplied body transfer buffer, SSE/JSON parsing state, and transient
handshake stack use. **64 KiB per live connection is therefore a reasonable rounded fixed
user-space floor for the rejected transport, not a complete per-connection budget.**

That result motivated the windowed adapter but is not part of the selected libcurl allocation model.

## OnePage avoids prompt and canonical-result-sized transport buffers

The provider contract reads an
immutable request through a caller-provided window and appends a response into a predetermined
durable writer. [`model_operation.zig`](../../src/model_operation.zig) fixes the request window at
4 KiB. [`blob_store.zig`](../../src/blob_store.zig) bounds each durable blob at 1 MiB and writes it
incrementally. [`model_protocol.zig`](../../src/model_protocol.zig) bounds the canonical response at
16 KiB.

Those bounds do not automatically carry through a provider adapter. The adapter must preserve them
when converting the durable house format to provider JSON and when converting SSE events back to the
canonical response. In particular, it must not build a second in-memory copy of a nearly 1 MiB
request merely to learn `Content-Length`.

OpenAI documents that `stream: true` emits server-sent events. Delta events are incremental, but
terminal events such as `response.output_text.done`, `response.content_part.done`, and the completed
response can contain complete text or output objects; see the official
[Responses streaming event reference](https://platform.openai.com/docs/api-reference/responses-streaming/response/content_part).
Therefore, "SSE" alone is not a memory bound. A parser that buffers one whole event can transiently
retain the whole answer and may duplicate text already spooled from deltas. V1 needs an explicit
maximum SSE line/event size or an incremental JSON parser that discards repeated terminal text after
validating it.

## Kernel socket memory is separate and occupancy-dependent

Socket buffer settings are capacities, not proof that all those bytes are resident. The relevant
quantity is current queued/accounted memory under the actual workload.

On the current macOS development host, read-only `sysctl` inspection reports:

```text
net.inet.tcp.sendspace: 131072
net.inet.tcp.recvspace: 131072
net.inet.tcp.autosndbufmax: 4194304
net.inet.tcp.autorcvbufmax: 4194304
```

Apple's current XNU source likewise initializes both `tcp_sendspace` and `tcp_recvspace` to 128 KiB
and reserves those high-water marks when creating a TCP socket; see
[`tcp_usrreq.c`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/tcp_usrreq.c).
XNU's [`sockbuf`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/socketvar.h)
separately tracks actual queued characters (`sb_cc`), the high-water mark (`sb_hiwat`), and mbuf
memory (`sb_mbcnt`). Its
[`sbreserve`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/uipc_socket2.c)
sets limits; it does not justify charging every idle or promptly drained connection as though both
queues were full.

Linux has the same important distinction but different defaults. Current kernel documentation gives
an initial TCP receive buffer of 131,072 bytes, an initial send buffer of 16 KiB, and enabled receive
autotuning whose maximum depends on host RAM; see the official
[`tcp_rmem`, `tcp_wmem`, and `tcp_moderate_rcvbuf` documentation](https://docs.kernel.org/networking/ip-sysctl.html#tcp-variables).
Linux [`socket(7)`](https://man7.org/linux/man-pages/man7/socket.7.html) also states that explicitly
configured `SO_RCVBUF` and `SO_SNDBUF` values are doubled to allow bookkeeping overhead. On Linux,
[`sock_diag(7)`](https://man7.org/linux/man-pages/man7/sock_diag.7.html) exposes actual receive,
send, forward-allocation, and queued-memory counters separately from configured limits.

For a streamed model response that OnePage drains immediately, the send queue should be nearly empty
after the prompt is uploaded and the receive queue should normally contain only a small number of
records. Charging the full platform high-water marks is useful as guarded headroom, not as a
steady-state prediction. Conversely, leaving autotuning unbounded means no userspace-derived per-call
figure is a whole-machine ceiling: a slow consumer or high-bandwidth/high-latency path can grow the
queues into MiBs per socket.

## Threads, fibers, virtual memory, and RSS

The transport should use readiness-driven I/O or a population-bounded worker pool, never an
unbounded thread population. V1 deliberately chooses the latter: one blocking worker per active
model Attempt, bounded by Active Credits. A native thread's reserved stack inflates virtual size;
only touched stack pages become resident, so multiplying the configured stack reservation by 100
overstates RSS but correctly warns about address-space consumption.

There is also a Zig-specific trap. On macOS, Zig 0.16's
[`std.Io.Kqueue`](https://github.com/ziglang/zig/blob/master/lib/std/Io/Kqueue.zig) currently allocates
a fiber region with a 4 MiB minimum stack for each concurrent task. One hundred request fibers can
therefore reserve roughly **400 MiB of virtual address space**, even though untouched pages need not
be resident. Apple explains the general distinction: reserving a virtual region does not allocate
physical pages until they are touched; see
[Viewing Virtual Memory Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/ManagingMemory/Articles/VMPages.html).

This does not add 400 MiB to the RSS estimate, but it makes fiber stack high-water a mandatory
measurement. A 32 KiB touched-stack slope adds 3.1 MiB across 100 calls; 64 KiB adds 6.25 MiB. If
virtual-size simplicity itself matters, use an explicit socket state machine rather than one
`Io.concurrent` fiber per request.

RSS is process-resident anonymous, file-backed, and shared memory. Kernel TCP queues are not pages in
the process address space and therefore are not represented by the process RSS. Linux documents both
the RSS components and the need for subsystem-specific measures such as socket statistics in
[`/proc`](https://www.kernel.org/doc/html/latest/filesystems/proc.html). Report both numbers:

- **process RSS delta**, for user-space connection buffers, parser state, and touched stacks;
- **kernel/socket delta**, for queued TCP data and networking metadata;
- optionally **whole-machine delta**, which also captures file cache and writeback from spooling.

Virtual size is useful for catching runaway stack/fiber reservation, but is not a substitute for
resident or physical-footprint measurements.

## Assumptions behind the estimate

The fixed estimate assumes the prompt has been sent, the response is immediately drained through a
4 KiB window, parsing is incremental, and the event loop has no native thread per call. Decoded
candidate buffers are a separate variable component: ordinary text usually allocates only its actual
size, while arbitrary JSON field order permits assistant text and function arguments to coexist until
the discriminator is known. Kernel socket memory remains a separately reported whole-machine slope
because platform autotuning can exceed every user-space estimate here.

Handshake bursts, DNS resolver behavior, the shared certificate bundle, connection-pool metadata,
and allocator fragmentation remain unmeasured. The certificate bundle and event-loop workers should
primarily be a shared baseline rather than a per-call slope. This implementation disables keep-alive
and deinitializes its client after each call, so it retains no idle Codex connections.

## Best way to turn the estimate into a contract

Build the smallest real adapter before lowering the budget. Run the same executable with 1, 10, 50,
and 100 concurrent calls and measure these phases separately:

1. connections established and streaming but nearly idle;
2. all TLS handshakes occurring together;
3. prompt upload;
4. normal SSE generation with an immediate consumer;
5. fast producer with an intentionally slow consumer;
6. completion and the retained idle connection pool.

For each phase, record process RSS/physical footprint, virtual size, allocator live bytes, touched
fiber-stack high-water if available, and target-OS socket counters. Use the slope of memory against
concurrency, not `RSS(100) / 100`, so shared CA, DNS, executable, and event-loop costs remain in the
intercept. Record steady p50, steady p95, and peak-handshake slopes over repeated runs.

Acceptance gates for a 100-call V1 lane should be:

- no 598,424-byte or other maximum-wire-event-sized resident allocation per call;
- fixed transport and parser windows, decoded-candidate current/high-water occupancy, allocator slack,
  task-stack residency, and kernel socket memory reported as separate components;
- no whole-request JSON copy and no whole-response/SSE-event accumulation;
- fixed request, transfer and parser windows plus distinct decoded-candidate, event-work, total-stream,
  depth, and time bounds;
- socket send/receive limits set and verified with `getsockopt` on each supported OS, or an explicit
  measured justification for autotuning;
- no unbounded thread creation; record the bounded worker high-water and virtual-stack reservation;
- idle connection retention included in baseline measurements.

Until that spike passes, the defensible statement is: **the windowed design removes the 57 MiB
100-call frame-array floor; its remaining slope is analytical but not yet a measured Host contract.**

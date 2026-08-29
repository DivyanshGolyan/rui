# Model transport memory budget

Date: 2026-08-27

## Capacity-one implementation evidence (2026-08-29)

The issue #11 adapter now has the following capacity-one bounds. These are classified by evidence source so compile-time limits are not presented as measured resident memory.

| Component | Evidence | Capacity-one value or bound |
| --- | --- | ---: |
| Provider-neutral request window | compile-time source bound | 4,096 bytes |
| Canonical decoded candidate | compile-time source bound | 98,372 bytes |
| SSE wire frame | compile-time source bound | 106,564 bytes |
| Total SSE response | compile-time source bound | 426,256 bytes |
| SSE event count | compile-time source bound | 128 events |
| HTTP response transfer window | compile-time source bound | 64 bytes on the Codex success path |
| HTTP rejection diagnostic body | compile-time source bound | 4,097 bytes read, at most 4,096 accepted |
| HTTPS connection byte buffers | Zig 0.16 source-derived | 59,151 bytes before structs and allocator rounding |
| TCP send and receive defaults | measured with `sysctl` on the development host, 2026-08-29 | 131,072 bytes each |
| TCP autotuning maxima | measured with `sysctl` on the development host, 2026-08-29 | 4,194,304 bytes each |
| Async task stack reservation | Zig 0.16 source-derived | 4 MiB virtual minimum per Kqueue task; resident pages unmeasured |
| Retained connection state | implementation observation | zero idle Codex connections; each request uses `keep_alive = false` and deinitializes its client |

The adapter compacts SSE `data:` lines in its one frame and writes the provider-neutral candidate directly to Host-owned provisional storage. It no longer retains a complete canonical result buffer or a second payload-sized SSE copy. The current JSON object parser still uses a fixed DOM arena for the outer frame and a smaller fixed arena for nested `input_request` arguments. Therefore, this report does not claim the issue's final non-DOM parser target yet.

No live provider call was made for this update, and no real credential was read. Process RSS, physical footprint, touched async-stack pages, TLS handshake peak, allocator live bytes, and actual per-socket queued memory remain unmeasured for the capacity-one live path. The source and OS figures above are bounds or configuration evidence, not a measured whole-process slope. A later opt-in run must report those observations before this document can replace the existing planning estimate with a measured capacity-one result.

## Decision

For a V1 lane of 100 concurrent HTTPS model calls, use **256 KiB per active call as the planning
estimate** and **512 KiB per active call as provisional guarded headroom**:

| Transport-only budget | Per active call | 100 active calls |
| --- | ---: | ---: |
| Low, measured target | 128 KiB | 12.5 MiB |
| Planning estimate | 256 KiB | 25 MiB |
| Provisional guarded headroom | 512 KiB | 50 MiB |

These figures include process-resident transport state and an allowance for kernel socket memory.
They exclude the Activation Slot, QuickJS, SQLite, durable prompt and result storage, subprocesses,
and shared host baseline. The 512 KiB figure is not yet a proved hard ceiling. It becomes defensible
only if OnePage incrementally parses streaming events, bounds transient frames, controls socket
autotuning, and does not create one native thread per call.

Subprocesses intentionally launched by a model are workload memory under ADR-0013, not part of this
OnePage-owned transport budget. Provider transport and its kernel socket memory remain orchestration
memory because OnePage creates and owns them.

The most useful napkin formula is:

```text
process RSS transport ~= shared transport baseline
                      + C * (59,151
                             + connection/request metadata
                             + transfer and SSE parser windows
                             + resident stack or fiber pages
                             + allocator slack)

whole-machine transport ~= process RSS transport
                         + C * actual kernel socket memory
                         + transport-attributable file-cache/writeback pages
```

`C` is concurrently active HTTPS connections. With Zig's current HTTP/1.1 client, 100 concurrent
requests mean approximately 100 TCP/TLS connections, not 100 multiplexed streams on one connection.

## The fixed user-space floor is about 58 KiB per connection

OnePage currently requires Zig 0.16.0. Its installed standard library's HTTPS connection allocation
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

That is byte-buffer storage only. It excludes the TLS and connection structs, hostname, allocator
rounding, request object, caller-supplied body transfer buffer, SSE/JSON parsing state, and transient
handshake stack use. **64 KiB per live connection is therefore a reasonable rounded fixed
user-space floor, not a complete per-connection budget.**

Zig's response-body API makes the caller supply its transfer buffer. That is a useful design lever:
OnePage can select a fixed 4-16 KiB window and consume it into a bounded incremental parser rather
than accumulating the response body.

## OnePage already avoids prompt and result-sized transport buffers

There is no live provider transport in the repository yet. The current provider contract reads an
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
steady-state prediction. Conversely, leaving autotuning unbounded means neither 256 nor 512 KiB is a
hard per-call ceiling: a slow consumer or high-bandwidth/high-latency path can grow the queues into
MiBs per socket.

## Threads, fibers, virtual memory, and RSS

The transport should use readiness-driven I/O or a bounded worker pool, not one native thread per
request. A native thread's reserved stack inflates virtual size; only touched stack pages become
resident, so multiplying the configured stack reservation by 100 overstates RSS but correctly warns
about address-space consumption.

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

## Assumptions behind the three estimates

| Component per live call | 128 KiB low | 256 KiB planning | 512 KiB guarded |
| --- | ---: | ---: | ---: |
| Zig fixed HTTPS allocation | 64 KiB | 64 KiB | 64 KiB |
| Transfer/SSE/request metadata and allocator slack | 16-32 KiB | 32-64 KiB | 96-128 KiB |
| Resident stack/fiber pages | small/shared | 16-32 KiB | 32-64 KiB |
| Actual kernel socket memory allowance | 32-48 KiB | 96-144 KiB | about 256 KiB |
| Interpretation | stretch target | expected planning slope | provisional headroom |

The rows are intentionally rounded and are not independent maxima. The low figure assumes the prompt
has been sent, the response is slow and immediately drained, parsing is incremental, and the event
loop has no per-call native thread. The planning figure permits realistic allocator and queue
occupancy. The guarded figure approximately charges the current macOS 128 KiB send plus 128 KiB
receive high-water marks and leaves about another 256 KiB for all user-space state.

Handshake bursts, DNS resolver behavior, the shared certificate bundle, connection-pool metadata,
and allocator fragmentation remain unmeasured. The certificate bundle and event-loop workers should
primarily be a shared baseline rather than a per-call slope. Zig's connection pool also retains up to
32 idle connections by default, so V1 should set an intentional idle-pool limit or include those
roughly 64 KiB user-space allocations in the post-burst baseline.

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

- process-RSS slope no greater than 256 KiB per active transport in normal streaming;
- process plus measured kernel/socket slope no greater than 512 KiB per active transport during the
  slow-consumer and simultaneous-handshake tests;
- no whole-request JSON copy and no whole-response/SSE-event accumulation;
- fixed request, transfer, parser, canonical response, and maximum-frame bounds;
- socket send/receive limits set and verified with `getsockopt` on each supported OS, or an explicit
  measured justification for autotuning;
- no native thread per call and a recorded virtual-stack/fiber reservation;
- idle connection retention included in baseline measurements.

Until that spike passes, the defensible capacity statement is: **100 active model transports add
about 25 MiB under the intended streaming design; reserve 50 MiB for the lane, and keep the host's
larger 256 MiB safety limit because transport, handshake, and socket peaks have not yet been measured.**

# Throwaway local HTTP memory probe

> **Historical evidence published 6 September 2026.** The observations and recommendations below retain their investigation context. Subsequent accepted decisions and retired implementation tickets do not change the measured results; this publication makes no production-certification claim.

Question: does a small native local HTTP interface introduce material memory
overhead before OnePage chooses its client-server transport?

This is measurement evidence, not production code or an accepted transport
decision. No Host, SQLite, workflow evaluator, or model calls run in this probe.

## Reproduce

On macOS with Zig 0.16.0, Apple Clang, and Python 3:

```sh
python3 research/http-memory-probe/run.py
```

The driver builds a temporary executable and object under `/tmp`, binds ephemeral
loopback TCP ports, starts and stops its own processes, validates transfers, and
writes `results.json` next to this file. No external services are contacted.

The C harness uses nonblocking sockets and one `poll` loop. Header parsing calls
the installed Zig standard library's `std.http.Server.Request.Head.parse` through
a small exported function. It does not integrate the complete Zig HTTP server
I/O lifecycle. Responses are fixed, Content-Length framed, and close after one
request. Unsupported encodings and oversized headers are rejected. This is not
a complete or hardened HTTP implementation.

Each admitted connection gets an 8 KiB input and an 8 KiB output window, both
touched on acceptance. The experimental cap is 100 connections. These values
are experimental controls, not proposed OnePage budgets. The reuse variant
retains each slot's windows after disconnect for its next client. The ordinary
variant frees windows after disconnect. Both run on one thread.

## Measurements on 5 September 2026

MacBookPro18,1, 16 GiB RAM, macOS 15.7.7 (24G720), 16 KiB pages;
Zig 0.16.0 ReleaseFast, Apple Clang 17.0.0 with `-O2`.

`proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint` measures the server PID's
physical footprint; `proc_pidinfo(PROC_PIDTASKINFO)` also records RSS and thread
count. The Python load generator is a separate process and excluded. Socket
memory outside the process accounting is not independently measured: these are
not total-system RAM costs. RSS is not interchangeable with physical footprint.

Five fresh-process cases were rotated through five orders. Each case warms the
measurement path and takes eight samples 50 ms apart after the expected clients
are admitted. Connected clients hold incomplete headers, so these cases measure
resident, touched connection buffers, not completed request throughput.

| Case | Median process footprint | Range of case medians |
|---|---:|---:|
| Same binary, no listener | 832.6 KiB | 784.5–928.6 KiB |
| Idle TCP listener | 784.5 KiB | 784.5–848.5 KiB |
| One connected client | 848.6 KiB | 816.5–976.6 KiB |
| 16 connected clients | 1,168.6 KiB | 1,088.5–1,264.6 KiB |
| 100 connected clients | 2,576.6 KiB | 2,544.6–2,624.6 KiB |

Using within-rotation differences from the no-listener baseline, median extra
footprint was about 352 KiB at 16 clients and 1,744 KiB at 100 clients. Idle and
single-client deltas were unresolved within fresh-process noise; negative
differences do not mean a listener saves memory. The same binary and fixed
connection metadata exist in the baseline, so subtraction does not isolate
every byte of HTTP code or metadata that a production build would add.

Three fresh runs each exercised 2,000 short status requests, 16 simultaneous
32 MiB uploads, and 16 simultaneous 32 MiB downloads. Transfers use 8 KiB client
chunks and a 0.5 ms delay per chunk to keep them active. The server discards
uploads and generates downloads without retaining the body. Sampled peaks:

- Short-request runs: up to 3,024.7 KiB, with retained footprint after clients left.
- Uploads: up to 1,232.6 KiB for 512 MiB transferred per run.
- Downloads: up to 1,280.6 KiB for 512 MiB transferred per run.

The churn observation justified a follow-up: ten batches of 2,000 requests in
each of two long-lived processes, with up to 16 client workers. The malloc/free
variant reached and retained 3,504.7 KiB; reusing windows reached and retained
1,216.6 KiB. This supports buffer reuse in this harness. It does not prove a
specific allocator mechanism, a long-term leak, or stability over an unlimited
process lifetime. Churn variants were run once each, sequentially.

Every observed server sample reported one thread. The driver verified response
status, Content-Length, every body byte and total length, successful completion
counts, rejection of the 101st held connection, and the header-size cap. All
checks passed. Stress samples are taken roughly every 20 ms and can miss shorter
peaks; they are not hardware-enforced maximum-memory bounds.

## Implication for the decision

A bounded native HTTP interface remains plausible on memory grounds. The useful
cost scales with connected clients and buffer ownership, not workflow count or
transferred body size. Reusing buffers matters for repeated polling.

This is not a final Host budget. Full routing, authentication, JSON processing,
client memory, database interactions, TLS if chosen, full HTTP I/O integration,
and socket memory outside process accounting remain unmeasured. The existing
Host event loop would also need integration verification. This experiment does
not compare Unix sockets or establish which transport is preferable overall.

Preserve a small connection cap, bounded header/body processing, and streamed
content if HTTP is chosen; measure the integrated Host before accepting its
numeric resource budget. The owning decision remains
[Choose live Host ownership and cross-process command semantics](https://github.com/DivyanshGolyan/onepage/issues/100).

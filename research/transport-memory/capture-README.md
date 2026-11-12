# Capture responsiveness and connection reuse

On this Mac, a bounded capture worker preserved fast local control replies during slow writes, but its queue size did not bound libcurl's memory. Writing between reactor calls improved the constant-delay case yet still blocked controls during a single three-second write. Keeping 1,000 HTTP/1.1 connections improved repeated-burst throughput substantially at a large retained-memory cost. These are experimental results, not an accepted threading design or Host qualification.

The experiment uses the same **curl 8.22.0 / OpenSSL 3.6.3 / nghttp2 1.70.0** pins and machine as the [baseline report](README.md). [Primary source interpretation](capture-sources.md) explains synchronous callback servicing, borrowed callback bytes, pause credit and TLS ticket reuse. No production source or architecture changes accompany this evidence.

## Method and ownership

[capture.c](capture.c) compares three strategies with equivalent verified TLS requests and complete response capture:

- **Callback:** write synchronously inside the libcurl body callback.
- **Between calls:** copy into a bounded queue, then write one queued chunk on the reactor thread between library calls.
- **Worker:** use the same queue, with one dedicated capture writer. A full queue returns `CURL_WRITEFUNC_PAUSE` without accepting that callback's bytes. Only the reactor uses easy/multi handles, apart from the documented cross-thread `curl_multi_wakeup` operation.

The default queue has 16 slots, each containing at most 16,384 body bytes plus 16 bytes of metadata: 262,400 allocated bytes total. Its occupied slot remains owned during a pending write; no mutex is held across disk I/O. Per-transfer records and request/capture descriptors remain alive through their consumers. Easy cleanup precedes request release; capture completion, worker join and byte validation precede capture-file/record release. Successful network completion does not imply successful capture. The injected sink failure marks one capture failed, checks the remaining captures and drains/releases resources without fabricating success.

The server waits for all requests before releasing bodies: HTTP/1.1 uses 1,000 connections and HTTP/2 uses 1,000 streams on one connection. Requests contain 1 KiB; ordinary responses contain 64 KiB each (62.5 MiB total at capacity). Writes use real temporary files plus a specified synthetic delay or stall. This isolates blocking occupancy; it does not reproduce a specific storage device. The repeated-burst cases use 100 microseconds per write; the slow cases use 1 millisecond. Burst spacing includes a 200 ms post-capture hold, validation and one second of serviced idle. Captures are not held across bursts.

An independent process sends local datagram probes every 20 ms. The reactor echoes them between servicing steps. Both processes use `CLOCK_MONOTONIC`; the report takes nearest-rank p95 over probes sent from transfer start through completed capture, including delayed replies after completion. Every send must receive exactly one reply, with zero send errors. This measures control-owner availability, **not durable control acknowledgements**: there is no core, SQLite, admission or settlement. Callback, entire perform/unpause call, sink write, process CPU, exact captured lengths/content and memory are recorded separately.

Byte checks verify every captured byte equals the fixture's `x` and each successful file has the exact expected length. They detect corruption and length loss/duplication, but equal-length reordering of identical bytes is not observable. The fixture validates complete request bodies. This is not a provider/SSE grammar or recovery test.

## Slow writes and first-write stalls

All rows below use 1,000 simultaneous transfers, a 16-slot queue where applicable and an idle-connection cap of 16. Physical memory is the process high-water, including the capture worker; it excludes the fixture/control generator. CPU is average client cores during transfer and capture.

| Protocol / strategy | 1 ms writes: control p95 / max (ms) | Verified MiB/s | Physical peak (MiB) | Average cores | 3 s first write: control p95 / max (ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| HTTP/1.1 callback | 4821 / 5176 | 8.27 | 189.58 | 0.22 | 2912 / 3127 |
| HTTP/1.1 between calls | 24.62 / 259.58 | 6.86 | 215.16 | 0.35 | 2762 / 2999 |
| HTTP/1.1 worker | 73.61 / 305.26 | 9.33 | 217.56 | 0.53 | 219.60 / 353.64 |
| HTTP/2 callback | 2581 / 2845 | 5.51 | 40.99 | 0.06 | 2842 / 2995 |
| HTTP/2 between calls | 1.41 / 10.60 | 8.50 | 87.27 | 0.25 | 2792 / 2988 |
| HTTP/2 worker | 0.41 / 25.48 | 11.90 | 139.75 | 0.44 | 1.44 / 7.33 |

A short individual callback did not ensure prompt control service: in the constant-delay callback cases, the longest complete perform call lasted 5,192 ms on HTTP/1.1 and 2,870 ms on HTTP/2. Moving writes between calls shortened callbacks, but the three-second write still occupied the same control owner. Moving that write to the worker removed this particular blocking interval. HTTP/1.1 still showed hundreds of milliseconds of cold-burst reactor occupancy. No strategy here proves the production one-second durable-ack target.

The 100-transfer first-write controls show the same mechanism: callback/between-call p95 was 2.83–2.87 seconds; worker p95 was 1.56 ms for HTTP/1.1 and 0.23 ms for HTTP/2. At 1,000 transfers, varying worker slots from 2 to 16 to 64 gave HTTP/2 physical peaks of 141.91, 139.75 and 137.30 MiB, with throughput 12.09, 11.90 and 11.85 MiB/s. HTTP/1.1 peaks were 216.63, 217.56 and 217.00 MiB. Shrinking the queue alone did not proportionally shrink transport footprint; this single-run variation does not establish an optimal queue size.

## Larger bodies and a stall after every stream has progressed

Four additional cases use 384 KiB per response (375 MiB total). The server delivers 128 KiB on every stream, holds the remainder for one second, then continues. In the late-stall cases, the writer stalls for three seconds only after every capture has written at least 128 KiB. Raw events confirm **all 1,000 transfers remained active and every file contained exactly 131,072 bytes** at stall entry. This avoids mistaking a first-callback pause for a pause after flow.

| Protocol / worker case | Control p95 / max (ms) | Verified MiB/s | Physical high-water (MiB) | curl allocation peak (MiB) |
| --- | ---: | ---: | ---: | ---: |
| HTTP/1.1 large control | 107.65 / 241.59 | 125.37 | 205.25 | 25.83 |
| HTTP/1.1 late stall | 46.77 / 249.48 | 66.03 | 212.44 | 36.76 |
| HTTP/2 large control | 8.76 / 21.75 | 127.32 | 248.41 | 241.88 |
| HTTP/2 late stall | 3.38 / 22.40 | 66.69 | 233.31 | 236.95 |

The HTTP/2 late stall itself settled around 54.63 MiB of curl live allocations and 92 MiB physical while captures remained at 125 MiB written; its higher peak came during resumed delivery. The no-stall case also grew substantially. Therefore these results do **not** show that the late stall alone caused the full peak, or that every stream consumed its theoretical maximum credit. They show that the same 256 KiB payload queue can coexist with more than 230 MiB of curl allocations while larger responses progress. Pause/unpause scheduling, per-stream buffers and advertised credit still matter. The public API does not promise a queue-sized receive-memory bound; accepting a chunk and explicitly pausing is not a source-backed way to guarantee one.

The 248.41 MiB transport-prototype physical high-water leaves almost no margin against the whole-Host 256 MiB target before core, workflow and other owners are added. It is evidence of an unresolved integration budget, not a measured Host failure or a new universal response/window limit.

## Repeated bursts and retained connections

Each case has three bursts of 1,000 requests, with the same multi retained and fresh easy handles. The TLS server logs actual session resumption. The idle cap limits retained connections, not active transfer population.

| Protocol / idle cap | Warm new connections per burst | Full / resumed among new | Warm verified MiB/s | Warm control p95 (ms) | Serviced idle physical across bursts (MiB) |
| --- | ---: | ---: | ---: | ---: | ---: |
| HTTP/1.1 / 1 | 999 | 997 / 2 | 31.04–33.55 | 155.64–159.00 | 61.77–68.83 |
| HTTP/1.1 / 16 | 984 | 982 / 2 | 30.45–31.74 | 177.12–212.07 | 52.67–67.66 |
| HTTP/1.1 / 1000 | 0 | 0 / 0 | 74.17–74.66 | 8.45–24.14 | 199.86–211.28 |
| HTTP/2 / 1 | 0 | 0 / 0 | 71.04–72.52 | 2.48–2.86 | 50.35–67.24 |
| HTTP/2 / 16 | 0 | 0 / 0 | 65.67–70.69 | 0.81–5.38 | 51.52–74.27 |
| HTTP/2 / 1000 | 0 | 0 / 0 | 70.85–71.86 | 0.97–5.35 | 51.38–68.72 |

HTTP/1.1 cold throughput was 30.92–32.05 MiB/s for these cases. Retaining all connections eliminated reconnects and roughly doubled warm useful throughput; caps 1 and 16 repeated almost all TLS work. Mean new-connection TLS-phase time (`APPCONNECT - CONNECT`, including scheduling/server contention) stayed about 387–412 ms for those warm reconnect bursts. This is not isolated cryptographic CPU time. The pinned multi cache retains two TLS 1.3 sessions per peer; the measured two resumptions are consistent with a simultaneous reconnect burst consuming those tickets before replenishment, not a general two-resumption ceiling. The server records accepted resumption but does not separately log the negotiated TLS version, so the ticket explanation remains an inference from the pins and source.

HTTP/2 retained its one connection with every cap, so none of these cases distinguishes a larger HTTP/2 cache's benefit. Client idle descriptor counts were 9, 24 and 1008 for HTTP/1.1 caps 1, 16 and 1000, and 9 for every HTTP/2 case; these include instrumentation/control overhead. All cases ended with three standard descriptors and zero tracked curl/TLS/application/scratch bytes after global cleanup. Physical retention and allocator release are different observations.

## Reproduce and inspect

Build dependencies with `python3 research/transport-memory/build.py`, then run the complete matrix into an empty directory:

```sh
python3 research/transport-memory/capture_run.py --output /tmp/new-capture-results
python3 research/transport-memory/capture_summarize.py --groups /tmp/new-capture-results --output /tmp/new-capture-summary.csv
python3 research/transport-memory/capture_run.py --sanitize --match 'worker-error|worker-stall$' --output /tmp/new-capture-sanitizer
```

`--quick` selects two eight-transfer smoke cases. `--match` filters names. The runner serializes benchmark execution with `/tmp/onepage-memory-experiments.lock`, bounds client lifetime with an independent watchdog and cleans up fixture processes. The build/pin paths are Mac-specific. A nonempty output directory is refused.

Committed evidence is split by collection stage: [main runs](capture-results/summary.jsonl), [1,000-transfer stalls and queue sizes](capture-boundary-results/summary.jsonl), [larger-body runs](capture-large-results/summary.jsonl), and [sanitizer runs](capture-sanitizer-results/summary.jsonl). Each directory contains raw client/server/control records, OS snapshots, exact source snapshots, hashes and build/environment metadata. The main and boundary snapshots precede the optional late-stall fixture; ordinary cases retain their original evidence. [capture-summary.csv](capture-summary.csv) derives 34 measured cases / 46 bursts, with 3,841,327,104 successful bytes verified. Four additional ASan/UBSan cases cover both protocols' worker stalls and sink failures; dependency libraries themselves were not sanitizer rebuilt.

The summarizer verifies source hashes, raw/summary equality, complete controls, fixture populations, file totals, queue bounds and final cleanup before deriving results. Its outputs are per-burst; physical high-water is process-cumulative across bursts, while curl/TLS allocation peaks reset each burst. Do not add independently occurring peaks or count allocation bytes as physical memory. OS counters are host-global snapshots; they do not attribute kernel/socket/cache memory to this process.

Single samples on a shared Mac establish mechanisms and candidate tradeoffs, not stable performance distributions. Synthetic files, uniform payloads, local TLS, simple echoes and incomplete Host ownership are material limits. Linux, real storage stalls/disk-full/cancellation, durable control acknowledgements, integrated sustained SSE/mixed workloads, allocator failures and recovery still need their owning qualification cases. The source-backed takeaway is to test capture scheduling, transport memory and reuse costs together, without adopting a worker pool or permanent cache cap from these numbers alone.

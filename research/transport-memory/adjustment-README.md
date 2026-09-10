# Transport adjustments under paced output and large uploads

These Mac-only experiments support continuing with libcurl, with a 16 KiB upload buffer as the clearest measured improvement. Receive-rate limits reduce worst-case HTTP/2 retention in these fixtures but can delay fast output and terminal snapshots. Neither a universal receive rate nor a complete transport-memory bound is established. The capture worker remains provisional; this research changes no production implementation or architecture decision.

The [source review](adjustment-sources.md) explains the pinned curl 8.22.0 behavior, public controls and provider output-rate examples. The earlier [capture experiment](capture-README.md) supplies the callback/worker comparison and the [baseline](README.md) supplies dependency builds and allocation-accounting limits.

## Workloads and evidence

Successful capacity cases retain **1,000 simultaneously admitted requests**, verified at the server barrier, and capture every expected byte. HTTP/2 partitioning also verifies each connection's occupancy. Merely attaching 1,000 easy handles does not satisfy the barrier. TLS is verified locally; the fixture certificate is ephemeral. No live provider or private account payload is involved.

Three related harnesses isolate different costs:

- `adjustment.c` receives independently generated, ordered 256-byte SSE records and a terminal event. It varies receive rate/buffer, stream partitioning, peer limits, unknown length, late arrival, capture stalls and connection reuse.
- `paced.c` receives unpadded SSE JSON at a configured synthetic token cadence. An event carries one or more four-byte `text` tokens; the terminal event repeats the complete text. Its independent C byte oracle checks ordering, framing and full completion. Four bytes per token is an explicit modeling assumption, not a tokenizer or provider guarantee.
- `asymmetric.c` streams a complete JSON request to a temporary file, verifies it by rereading, rewinds and uploads through bounded reads. The server independently checks each request's complete hash/length and identity. The response is 60 events over three seconds plus a full terminal snapshot: 300 synthetic tokens, 1,200 content bytes and 9,493 SSE bytes. Request size varies independently of this response.

The bounded worker has 16 capture slots of at most 16 KiB each. Every successful capture is reread and checked before release. Request files survive their easy handles; pending writes finish before capture release. Logical scratch is capped at 2 GiB in the asymmetric fixture. File handles and staged bytes scale with concurrency; memory windows do not hide that population. This is synthetic staging, not the production provider lowering path, encrypted continuation, compaction or crash recovery.

Client physical footprint includes its worker, but excludes the fixture server, relay and local control generator. libcurl/OpenSSL allocation hooks, client physical footprint, RSS, scratch and OS socket snapshots are separate observations; do not add independently timed peaks. Allocation-hook peaks do not include all native/OS memory. Local control probes are datagram echoes every 20 ms, not SQLite commits or durable acknowledgements.

## Calibrating output speed

Provider examples in the source review span hundreds to more than 1,000 output tokens/s. Actual model, batching and framing matter. The main matrix offers ten seconds of output followed by the full text snapshot:

| Synthetic tokens/s | Tokens/event × events/s | Content B/s/stream | SSE B/s/stream before terminal |
| --- | --- | --- | --- |
| 50 | 5 × 10 | 200 | 1,360 |
| 100 | 5 × 20 | 400 | 2,720 |
| 1,000, batched | 50 × 20 | 4,000 | 6,320 |
| 1,000, fine events | 10 × 100 | 4,000 | 15,600 |
| 2,000 | 20 × 100 | 8,000 | 19,600 |

Thus 100 events/s is not equivalent to 100 tokens/s. Tables also record total TLS ciphertext handed to TCP after handshake. That excludes TCP/IP headers and retransmissions; it is not packet-level network accounting. The fixture is Responses-shaped synthetic JSON, not an exhaustive provider grammar qualification.

Selected results from [paced-summary.csv](paced-summary.csv) and [follow-ups](paced-followup-summary.csv): physical figures are cumulative client high-water; terminal lag is p95 capture completion after the fixture offers its final bytes.

| Profile | Receive rate/stream | Physical MiB | Terminal lag ms |
| --- | --- | --- | --- |
| 100 tokens/s | unlimited / 8 / 32 KiB/s | 44.5 / 44.2 / 43.8 | 67 / 67 / 73 |
| 1,000, batched | unlimited / 8 / 32 KiB/s | 83.1 / 48.9 / 74.3 | 188 / 3,971 / 981 |
| 1,000, fine | unlimited / 8 / 32 KiB/s | 56.4 / 50.4 / 89.1 | 120 / 7,474 / 1,003 |
| 2,000 | unlimited / 8 / 32 / 128 KiB/s | 114.8 / 54.1 / 93.5 / 56.9 | 275 / 19,223 / 1,204 / 147 |
| 100 tokens/s, three-second sink stall | 8 KiB/s | 52.4 | 62 |
| 1,000 fine, three-second sink stall | 32 KiB/s | 98.6 | 1,026 |
| 100 tokens/s, ten connections × 100 streams | 32 KiB/s | 36.6 | 38 |
| 1,000 fine, ten connections × 100 streams | 32 KiB/s | 47.2 | 1,023 |

All paced cases completed with local control p95 below 2 ms and average client CPU below 1.3 cores. These are finite runs, not the full Host CPU/control gates. Repeated fast stalled runs reached 98.6, 70.6 and 56.3 MiB: scheduling/allocator variation is material, so do not select the smallest observation. Streaming-gap fields sample the worst stream's captured event count against offered events; they are not precise per-event latency distributions. At 8 KiB/s the fine-event 1,000-token profile fell hundreds of events behind before the terminal burst.

## Bulk/stalled-output guardrails

[Unknown-length results](adjustment-unknown-summary.csv) and [slow-write results](adjustment-slow-summary.csv) explain why the best normal-cadence setting is not automatically a worst-case bound:

| Fixture, 1,000 streams | Unlimited | 32 KiB/s | 128 KiB/s |
| --- | --- | --- | --- |
| 384 KiB/stream, late arrival | 123.9 MiB | 89.6 MiB | 103.9 MiB |
| 1.5 MiB/stream, late arrival | 190.9 MiB, 6.6 s | 100.1 MiB, 50.3 s | 118.3 MiB, 14.6 s |
| 384 KiB/stream, 1 ms per sink write | 311.1 MiB, 36.2 s | 119.8 MiB, 34.9 s | 289.8 MiB, 35.5 s |

A 128 KiB/s rate helps fast terminal delivery but loses much of the slow-sink retention benefit. A smaller shared receive buffer barely addresses the dominant per-stream costs. Rate limiting is not capture-driven credit: curl's pinned limiter has a 32 KiB burst floor and changes state on pause/unpause, so nominal rate alone does not prove actual throughput or a strict memory ceiling.

Ten connections with aligned local/peer 100-stream caps admitted all 1,000 requests. A peer-only cap of 100 with local cap 1,000 failed the all-active barrier and timed out; it is excluded from successful performance summaries. Source inspection suggests cold connection assignment precedes the peer SETTINGS reduction, leaving queued requests on one connection; no packet trace establishes that mechanism here. Set capacity from both limits and verify actual admission.

For ten-connection repeated bulk bursts, retaining one idle connection required nine warm reconnects; retaining ten required none. Both measured about 0.9 seconds per bulk burst and roughly 118–119 MiB physical peak. This does not erase setup cost or establish that a cache of one is preferable. Early adjustment runs used an uncached fixture generator; compare their timings within that cohort, not against later cached generation.

## Large uploads and growing contexts

[asymmetric-summary.csv](asymmetric-summary.csv) compares 16 and 64 KiB upload buffers. The shaped relay has a shared aggregate bandwidth budget in each direction, 40 ms one-way delivery delay, and independent queues so request uploads and responses overlap. It relays TLS bytes unchanged. The server's HTTP/2 receive window is 16 MiB per connection and 65,535 bytes per stream.

| Request/profile | Upload buffer | Physical MiB | Curl allocation peak MiB | Achieved aggregate upload MiB/s |
| --- | --- | --- | --- | --- |
| 128 KiB each, 8 MiB/s uplink | 16 / 64 KiB | 90.4 / 152.2 | 82.9 / 129.8 | 7.84 / 7.84 |
| 1 MiB each, 32 MiB/s uplink | 16 / 64 KiB | 90.5 / 152.7 | 82.9 / 129.8 | 31.38 / 31.20 |
| 1 MiB each, local relay | 16 / 64 KiB | 90.7 / 152.8 | 82.7 / 129.8 | 249.7 / 254.8 |
| Alternating 1 MiB/16 KiB requests, sink stall | 16 / 64 KiB | 69.0 / 130.5 | 61.4 / 107.7 | 30.5 / 30.2 |

At 1 MiB each the input/output ratio is **110.46×**, an illustrative ratio rather than a protocol rule. Buffer reduction saves approximately 46.9 MiB in curl allocation peaks with essentially equal shaped-link throughput. The unshaped pair differs by about 2%; a single pair cannot establish a throughput regression or equivalence there.

For 1 MiB shaped uploads, p95 full request arrival was 31.39 seconds and p95 first SSE was 31.68 seconds with 16 KiB buffers. The long wait is primarily transfer time; fixture think time plus response delivery adds about 293 ms per request at p95. The CSV separates curl's final upload timing, server completion and first captured response byte. Upload and response traffic overlapped for 27.6 seconds; alternating sizes plus a three-second sink stall also completed, with 16.1 seconds of overlap. The response starts only after that request's full body is validated, and the first response waits until all 1,000 request headers have arrived.

Repeated request sizes of **64 → 256 → 1,024 → 256 KiB** represent a context growing and then shrinking after hypothetical compaction. With 16 KiB buffers, cumulative physical high-water was **90.6 → 92.0 → 96.3 → 96.3 MiB**; with 64 KiB it was **152.9 → 152.9 → 167.9 → 167.9 MiB**. The final high-water cannot fall by definition; use serviced-idle samples for retained memory. The shape demonstrates streamed request-size scaling, not real compaction correctness. Provider cache discounts do not imply omission of serialized input; the fixture transmits every staged byte each burst.

One 1 MiB × 1,000 burst writes 1,048,576,000 request bytes, reads them once for integrity and once for upload, and writes 9,493,000 capture bytes. Logical file reads additionally include complete capture validation. Reported OS disk bytes differ substantially because of caching and delayed writeback; they do not replace these logical volumes or qualify a particular disk. Staging control latency and staging duration are separate CSV fields.

The relay terminates TCP on each side and acknowledges locally. Its delays and byte budgets are controlled application-delivery conditions, **not real WAN RTT, congestion control, packet loss or kernel socket-memory qualification**. Its own resources are separately owned: 16 KiB chunks, 256 shared queued chunks per direction, plus per-connection pending reads and asyncio transport buffering. They are excluded from client memory and cannot be treated as a whole-system bound.

## Failed and incomplete probes

- `adjustment-results/h2-peer100-burst`: failed capacity barrier; successful summaries explicitly exclude it.
- `asymmetric-small-window-interrupted`: stopped after the default 65,535-byte connection window constrained delayed uploads far below the configured relay rate. Preserved as interrupted, not passing evidence.
- `asymmetric-initial-results`: a complete HTTP/2 case had a relay EOF diagnostic; HTTP/1.1 then aborted on incomplete upload. The relay cleanup was corrected and HTTP/2 was rerun in `asymmetric-h2-results`.
- `asymmetric-h1-diagnostic-results`, `asymmetric-h1-error-results` and `asymmetric-socket-results`: 1,000 large HTTP/1.1 uploads failed with curl send error 55; detailed runs also recorded OS error 55, “No buffer space available.” Request-completion assertions then aborted the fail-fast research harness. A requested 16 KiB `SO_SNDBUF` did not resolve it. These failures do not qualify cleanup, throughput or a socket-buffer remedy. The socket matrix stopped on its first failed case; its remaining comparisons did not run.

Small eight-transfer HTTP/1.1 and HTTP/2 upload/capture smoke cases passed with AddressSanitizer/UndefinedBehaviorSanitizer, as did a paced stalled-capture case. Only the harness was sanitizer-instrumented, not every dependency. There is no passing 1,000-transfer large-upload HTTP/1.1 result here.

The successful evidence validators passed for 55 capacity cases across 65 bursts, plus three sanitizer smoke cases. Independent JSON parsing checked representative complete SSE streams, terminal text/sequence agreement and staged request grammar/hash; all frozen source hashes matched. `git diff --check` reports three trailing spaces in frozen `adjustment_server.py` source snapshots. They are retained to preserve the exact measured source hashes; the current source and authored documents pass the whitespace check.

## Reproduction and review boundary

Build the pinned dependencies using the baseline instructions. Runners require empty output directories, snapshot sources/hashes and acquire the shared OS lock to avoid overlapping load tests. For example:

```sh
python3 research/transport-memory/adjustment_run.py --output /tmp/adjustments
python3 research/transport-memory/paced_run.py --output /tmp/paced
python3 research/transport-memory/asymmetric_run.py --match 'h2-(wan1024|local1024|growing|overlap)' --output /tmp/uploads
python3 research/transport-memory/asymmetric_run.py --quick --sanitize --output /tmp/upload-smoke
python3 research/transport-memory/paced_run.py --quick --sanitize --output /tmp/paced-smoke
```

Use each family's `*_summarize.py --groups GROUP... --output FILE.csv` to validate source hashes, completed bytes, controls, admission, errors and released allocations before deriving performance rows. The initial adjustment group requires `--expected-failures h2-peer100-burst`; failed upload groups are diagnostic-only and excluded. Frozen source snapshots retain their original bytes and hashes even where the current harness has since gained diagnostics or additional cases.

[phase-summary.csv](phase-summary.csv), generated by `phase_summarize.py`, separates sampled live allocations/physical memory from cumulative high-water at cold, staging boundaries, active transfer/capture, delayed validation, released captures, serviced idle and teardown. An active phase includes stalls/resumption; raw timestamped capture progress gives that finer timeline. Samples cannot establish exact within-phase peaks, and cumulative peaks in later phases may have occurred earlier.

The measured candidates are smaller upload buffers, explicit active/idle connection capacities and receive limits chosen with both streaming delay and sink stalls visible. Their combination still needs a joint production test. Linux, real WAN/socket pressure, complete provider lowering, durable control acknowledgement, restart/replay, storage failure and aggregate Host qualification remain open. No replay or retry was added to turn an incomplete upload into a successful result.

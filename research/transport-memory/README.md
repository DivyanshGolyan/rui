# Pinned transport memory experiment

Measured on an Apple M1 Pro / 16 GiB Mac, Darwin 24.6.0, with disk-backed APFS scratch. **The smallest demonstrated improvement is `CURLOPT_UPLOAD_BUFFERSIZE=16384`: approximately 49,152,000 fewer requested-live peak bytes at 1,000 transfers, without reducing transfer concurrency, staging, or captured output.** Release completed easy handles before delayed validation, and explicitly bound idle connections while servicing their shutdown. HTTP/2 multiplexing saves TLS connections but does not make paused responses cheap.

These are prototype results, not Rui production qualification. At revision `b1d25138f70e6a7b4c1d27523d5b051f6de34d7a`, [build.zig](../../build.zig) links system curl and [codex_native.zig](../../src/codex_native.zig) creates an easy handle for the earlier transport path. The redesigned runtime and its bundled transport are not implemented. The accepted contract selects pinned libcurl/OpenSSL without selecting version numbers. This experiment pins **curl 8.22.0, OpenSSL 3.6.3 and nghttp2 1.70.0**; it does not make a production dependency decision or modify the architecture.

## Reproduce

Requires this Mac toolchain: Apple Clang, Python 3.12+ (recorded 3.14.6), and exact OpenSSL 3.6.3 at `/opt/homebrew/Cellar/openssl@3/3.6.3`. The builder verifies curl/nghttp2 archive SHA-256 values and builds a separate static libcurl with HTTP/2, threaded asynchronous DNS and Apple SecTrust. The server dependencies are h2 4.3.0, hpack 4.2.0 and hyperframe 6.1.0. TLS certificate and hostname verification stay enabled with a generated local CA certificate. No provider, credentials or external request traffic is used.

```sh
python3 research/transport-memory/build.py
python3 research/transport-memory/run.py --output /tmp/new-transport-results
python3 research/transport-memory/run.py --match 'h2-(pause|control)-16777216|h[12]-upload16k|h[12]-cache16|h[12]-request1048576-items1' --repeat 3 --output /tmp/new-transport-repeats
python3 research/transport-memory/run.py --sanitize --match 'sink-error|h2-pause-16777216|h[12]-n1$' --output /tmp/new-transport-sanitizers
python3 research/transport-memory/summarize.py
```

The last command checks the recorded repository groups and regenerates [summary.csv](summary.csv). To check a new run, use `python3 research/transport-memory/summarize.py --groups /tmp/new-transport-results --output /tmp/new-transport-summary.csv`. The runner refuses nonempty output directories before changing evidence. The summary verifier checks source hashes, raw-file agreement, integrity, completion and cleanup. Future runs also record per-run dependency/binary hashes and UTC start time; the original binary hash file was recorded after its runs, not as a per-run assertion. Benchmark cases hold `fcntl.flock` on `/tmp/rui-memory-experiments.lock` throughout server/client execution. Each client has a 120-second emergency test deadline; the runner kills/reaps timed-out clients and stops/reaps servers. Scratch files are immediately unlinked, bounded to ≤256 MiB logical aggregate by the current harness, and closed on completion/process exit. This is a fixture bound, not a new product limit.

[Raw main results](results/summary.jsonl) contain 32 cases; [follow-ups](followup-results/summary.jsonl) add 14 controls/stalls/upload comparisons; [repeats](repeat-results/summary.jsonl) contain 30 runs; [sanitizers](sanitizer-results/summary.jsonl) contain five ownership/error checks. Every group stores its exact source snapshot, machine/compiler/linkage metadata, phase measurements, server integrity counts and global OS counters. Later source snapshots add the upload option, large-allocation counters and runner hardening. [Dependency binary hashes](dependency-binaries.json), [derived tables](summary.csv), [verification output](verification.txt) and [primary dependency evidence](sources.md) complete the provenance. All 81 runs passed their terminal checks; sanitizer runs are excluded from memory comparisons. Sanitizers instrument the harness, not the separately built libraries.

## Measurements

Numbers below are **bytes**, not MiB. Peak columns are independent maxima and must not be added as simultaneous live usage. Baseline: 1,024-byte staged request, 65,536-byte capture per transfer, default upload buffer/cache, one shared multi handle.

| Protocol / transfers | curl-hook peak | OpenSSL-hook peak | Process physical peak | Cold physical | Physical after full cleanup + 250 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| HTTP/1.1 / 1 | 102,257 | 710,459 | 3,671,040 | 1,770,112 | 3,671,040 |
| HTTP/1.1 / 100 | 7,141,680 | 16,060,211 | 33,605,120 | 1,458,752 | 20,350,464 |
| HTTP/1.1 / 1,000 | 71,150,284 | 155,603,411 | 283,232,064 | 1,458,752 | 48,957,248 |
| HTTP/2 / 1 | 159,405 | 710,454 | 3,671,232 | 1,475,200 | 3,671,232 |
| HTTP/2 / 100 | 7,705,188 | 710,454 | 13,272,576 | 1,606,272 | 11,961,856 |
| HTTP/2 / 1,000 | 85,822,638 | 710,454 | 107,759,296 | 1,606,272 | 30,852,800 |

All application/curl/OpenSSL tracked allocations and owned scratch reach zero; final descriptors return to three. Physical retention therefore cannot be equated with live transport allocations. The HTTP/1.1 baseline exceeds 268,435,456 bytes, but this instrumented transport-only result neither qualifies nor rejects an implemented whole Host.

The server accepts all staged requests before releasing responses: HTTP/1.1 observes 1/100/1,000 simultaneous connections; HTTP/2 observes the same stream populations on one connection. Its advertised 1,000-stream capability is a controlled fixture, not evidence that Codex permits that many streams per connection. HTTP/3 is absent from the built feature set and untested.

## Which changes earned their cost?

**Upload window.** Three-repeat medians, cache limit 16, same request/capture counts:

| 1,000 transfers | Default upload: curl peak | 16 KiB upload: curl peak | Default: physical peak | 16 KiB: physical peak |
| --- | ---: | ---: | ---: | ---: |
| HTTP/1.1 | 71,150,285 | 21,998,286 | 270,665,344 | 191,449,088 |
| HTTP/2 | 85,822,655 | 36,670,638 | 107,677,056 | 42,730,688 |

The source owns a 65,536-byte upload chunk per easy handle; 16,384 is the supported minimum. Differences closely match **49,152 × transfer count**, with small incidental allocation variation. For 100 complete 1 MiB requests, median transfer time was 0.564→0.577 seconds on HTTP/1.1 and 0.928→0.895 on HTTP/2. Three local samples do not establish remote throughput equivalence, but no material local penalty or lost output was demonstrated. Request integrity is verified before dispatch and again independently by the server.

**Lifetime.** At 1,000 completed transfers, cleaning easy handles while retaining every capture and its custody record released 69,336,000 curl-hook bytes on HTTP/1.1 and about 69,422,853 on HTTP/2 with default upload sizing. Completion notifications are consumed and handles removed from multi before cleanup; callback state survives cleanup. Validation still happens afterward from the complete retained files. This saves overlap with validation, not the earlier active-transfer peak.

**Idle cache.** After easy cleanup and one second of continued multi-loop service:

| HTTP/1.1 cache limit, 1,000 transfers | curl live | OpenSSL live | FDs including 1,000 captures |
| --- | ---: | ---: | ---: |
| Adaptive default | 1,729,924 | 131,364,674 | 2,007 |
| 16 | 67,949 | 2,635,970 | 1,023 |
| 1 | 42,613 | 673,496 | 1,008 |

All variants first execute 1,000 concurrent transfers. Eviction can leave sockets/TLS state in the shutdown queue until the reactor services it; the earlier idle snapshot is not a settled cache count. Cache zero means adaptive default, not no caching. A smaller cache necessarily offers fewer reusable connections; next-burst handshake latency was not measured, so this does not select 1 or 16 as the production optimum. With one HTTP/2 connection, those limits cannot remove its retained internal chunk pool: about 10.6 million curl-hook bytes remained after the 1,000-stream burst until multi cleanup.

**Shared receive window.** Raising the requested receive buffer from 1,024 to 1,048,576 bytes at 100 transfers increased curl peak by roughly 1.05 million bytes, not 100 times that. It does not remove per-easy upload or paused-output allocations. Independently changing request bytes from 1 KiB to 1 MiB and item count from 1 to 4,096 kept application custody at 4,800 bytes for 100 transfers. HTTP/2 retained more connection-pool memory after larger requests; the CSV exposes this. The fixture's line-item count does not test a JSON/SSE parser or provider lowering.

**Backpressure.** Eight HTTP/2 streams each deliver 16 MiB. Pausing four for 500 ms after at least 128 KiB has flowed raised median curl peak from **649,935 to 67,615,648**, and median physical peak from **4,293,632 to 54,576,576**. There were four simultaneous allocations ≥8 MiB; the largest request was **16,769,024** bytes. Receive credit describes transferable data, not exact allocated buffer capacity. All 134,217,728 response bytes were subsequently captured and verified. The corresponding HTTP/1.1 pause peak was 666,721 versus 601,032 unpaused.

At 1,000 HTTP/2 streams with 64 KiB responses, half-stream pausing reached 131,652,524 curl-hook peak / 166,643,072 physical peak; repeated sink pauses reached 108,840,650 / 146,491,008. Separate 100-transfer tests add 100 µs before each synchronous write or pause delivery for 500 ms between chunks. Blocking writes hold the sole reactor during that callback; these experiments do not establish acceptable control latency. Do not infer a safe 1,000-large-paused-stream configuration from the small-response case or reduce concurrency/drop output to conceal this cost.

## Ownership, accounting and limits

| Owner/population | Bound and release | Failure behavior / observable scope |
| --- | --- | --- |
| Application custody | 48 bytes × transfers; one 16 KiB copy window; two unlinked files/FDs × transfers during upload/capture, one while awaiting validation | Hash/read/write/setup failure fails the fixture, never a successful truncated result. Requests close after easy cleanup; captures close after digest validation. No durable core or credit integration. |
| curl hooks | Requested-live/peak and allocation counts, including nghttp2 session allocations; buffers/cache multiply differently | Allocation failures return NULL through hooks. Errors are observed from `CURLMSG_DONE`. One injected sink failure returns `CURLE_WRITE_ERROR`; other streams finish intact. Exhaustion injection/cancellation/crash recovery are not qualified. |
| OpenSSL hooks | Installed before initialization; TLS connections plus global/session state | Separately counted; full library cleanup releases all tracked allocations. Missing capabilities or TLS verification fail. Global cleanup is shutdown evidence, not a required idle policy. |
| Instrumentation / allocator | 16-byte header per currently hooked allocation; fixed 65,536-byte FD measurement array; stack, atomics and output overhead | Physical/RSS include instrumentation. Requested-byte counters omit allocator rounding/metadata; realloc uses native realloc rather than artificial allocate-copy overlap. Allocator-reserved bytes and all other library allocations are not fully measured. |
| OS/file/socket | Process physical lifetime high-water, phase physical/RSS, sampled RSS/FD high-water and per-socket readable-byte maximum; global `vm_stat` and `netstat -m` before/after | Global filesystem/cache/network counters are shared with other applications and cannot be assigned exactly to this client. Socket readable bytes are not total kernel allocation; server memory is excluded. Never subtract hook totals from footprint to invent an OS breakdown. |

No Linux binary/run was produced: allocation APIs and protocol behavior have source support, but Linux allocator retention, private-dirty/PSS, socket memory, filesystem cache/writeback and CA integration remain unexecuted. The C metrics currently require macOS. No live provider, complete production request grammar, decompression, permission/core recovery, scratch exhaustion, control-latency SLO, CPU qualification, repeated warm connection reuse, or power-loss claim follows. The 256 MiB ceiling is neither a minimality test nor established whole-Host headroom.

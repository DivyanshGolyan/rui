# Execution lifetime measurements

The smallest supported improvement is earlier release under the existing effect owner. At 1,000 completed local HTTP captures, removing and cleaning up each easy handle and closing request scratch released **69,371,000 tracked libcurl bytes** before validation. All 1,000 credits, immutable capture sources and Operation/Attempt identifiers remained occupied. For synchronous Bash/Edit service turns, reusing the already-required 16 KiB validation/copy window instead of retaining another window per execution removed **16,384,000 application bytes**. Neither comparison changes the bytes captured or copied.

These are **native prototypes**, not the redesigned production Host. No architecture or production source was changed. [Raw matrix](results.json), [production/fault checks](checks.json) and [source/environment manifest](manifest.json) distinguish these scopes.

## Reproduce

On this Mac, using the sibling transport experiment's existing read-only dependency build:

```sh
CURL_BUILD=/tmp/onepage-transport-memory-build python3 research/execution-lifetimes/run.py
python3 research/execution-lifetimes/check.py
python3 research/execution-lifetimes/summarize.py --output /tmp/execution-lifetimes-rerun-audit.json
```

For a fresh dependency build, with OpenSSL **3.6.3** installed at the exact Homebrew path checked by the script:

```sh
python3 research/execution-lifetimes/prepare.py --build /tmp/onepage-execution-lifetimes-deps
CURL_BUILD=/tmp/onepage-execution-lifetimes-deps python3 research/execution-lifetimes/run.py
python3 research/execution-lifetimes/check.py
python3 research/execution-lifetimes/summarize.py --output /tmp/execution-lifetimes-rerun-audit.json
```

To audit the checked-in evidence without executing a benchmark or changing its historical manifest:

```sh
python3 research/execution-lifetimes/summarize.py
python3 research/execution-lifetimes/audit_test.py
```

Reproduction overwrites local `results.json` and `checks.json`; use the separate audit output shown above for those new samples. The default audit checks the original raw hashes, all 30 distinct matrix combinations, required lifecycle snapshots and named fault controls. It never replaces historical machine or volume metadata. The manifest preserves the original artifact snapshot; the audit helper has since been hardened without changing the recorded benchmark inputs or numeric evidence. Hardware and volume observations were collected when that original manifest was written, rather than within each measured process.

`run.py --smoke` uses one execution per effect/variant. Compilation uses Apple Clang 17; production probes use Zig 0.16.0 ReleaseSafe. `prepare.py` pins source archive hashes for curl 8.22.0 and nghttp2 1.70.0. Matrix output records the static library hash (the legacy field is named `curl_archive_sha256`), configure/link command, runtime library versions, source hashes and revision. That hash identifies the built static library, not its downloaded source archive; source archive hashes are pinned in `prepare.py`. Production/fault output has no independent per-run source/command manifest; the original artifact hashes and build commands in `check.py` are its available provenance. The matrix was run on revision `b1d25138f70e6a7b4c1d27523d5b051f6de34d7a`, Apple M1 Pro / MacBookPro18,1, 16 GiB RAM, Darwin 24.6.0, Python 3.14.6, with disk scratch on the Data volume.

Every benchmark runner holds `/tmp/onepage-memory-experiments.lock` with `fcntl.flock`. The matrix runs one measured process at a time; its HTTP fixture runs outside that process. Each cell has a 120-second external timeout, and the runner kills the process group on failure/timeout. Successful runs reap every child and close every owned descriptor; scratch is immediately unlinked. No provider credentials or live providers are used. Bash receives only PATH and LC_ALL. Preparation does not take the benchmark lock.

## What was executed

Thirty fresh-process cells: model/Bash/Edit × baseline/early × 1/100/1,000 executions at 4,096 bytes, plus 100 executions at independently varied 1,024 and 1,048,576 bytes. Each cell captures cold, fixed custody, loaded, sealed waiting, delayed validation, retained idle and final closure. Model also records all response headers received while bodies are held back. This is one burst-to-idle cycle per cell, not sustained churn or a latency distribution.

- **Model:** 128-byte POST request in private scratch; one multi handle and N concurrent loopback HTTP/1.1 transfers. The server waits for every request before returning headers, delays bodies, then streams deterministic bytes. The client captures complete bodies in unlinked files. It validates every byte after the delayed-validation snapshot. Baseline retains easy handles, headers and request scratch until validation. Early mode removes/cleans each transfer and closes request scratch first. Response scratch and custody survive unchanged. No TLS, provider grammar, authentication, SSE interpretation or durable import is simulated.
- **Bash:** N independently spawned Bash invocations exec a controlled native workload. Each writes the full configured byte count to **both** stdout and stderr, then waits on stdin. Host drains both pipes into separate unlinked files. Baseline retains one 16 KiB copy window and child/pipe resources until validation. Early mode shares a window during non-overlapping synchronous reads, then signals the fixture exit gate, reaps the children and closes pipes before validation. Both modes validate both full captures. `sealed_waiting` observes every workload after output is captured, before release; subprocess memory is recorded separately. Capture completion here follows the fixture’s known exact output length, not an arbitrary process EOF. This tests pipe/capture lifetimes, not arbitrary shell completion, descendants or process-group containment.
- **Edit:** N independent existing files contain deterministic whole lines. One exact first-line replacement (`a\n` → `b\n`) is validated while building complete output scratch, with round-robin 16 KiB windows across all active executions. After the snapshot, every output is checked, copied through the same target descriptor, truncated to its final length, flushed and independently checked again. Both target and output handles remain private. This deliberately covers one non-overlapping replacement, not the entire accepted Edit language, permissions, concurrent writers or failures during mutation.

The native fixture uses a fixed 1,000-record array in **every** cell. Its 64-byte custody records cost 64,000 bytes even when only one record is occupied. That array is a concrete prototype layout, not a proposed public handle or the production type. An existing shared 16,384-byte window brings fixed application allocation to 80,384 bytes. Each active effect adds a 64-byte private record. Bash/Edit baseline additionally retains 16,384 bytes per execution; early mode does not.

## Allocation results

Bytes at `sealed_waiting`, at the 4,096-byte point. Application counts include fixed custody and the shared window. Bash and Edit have identical explicit allocation populations; their OS footprints differ.

| Active executions | Model application live | Model libcurl live, baseline | Bash/Edit application live, baseline | Bash/Edit application live, shared |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 80,448 | 97,189 | 96,832 | 80,448 |
| 100 | 86,784 | 6,967,366 | 1,725,184 | 86,784 |
| 1,000 | 144,384 | 69,411,362 | 16,528,384 | 144,384 |

Within the 1,000-model early cell, libcurl live allocation falls from **69,409,346 to 38,346 bytes**, while all 1,000 sources/credits remain occupied. Request cleanup also releases 1,000 descriptors and 128,000 logical scratch bytes. Connections already close on normal transfer completion in this fixture; this is primarily an easy-handle/request lifetime result, not a retained connection-cache measurement. The remaining multi allocation is **not zero** and is finally released when the multi/global owner closes.

At 100 early-mode executions, increasing each payload from 1,024 to 1,048,576 bytes leaves application peak at **86,784 bytes** for all three effects. Model libcurl peak changes from 7,104,525 to 7,105,113 bytes. Scratch grows with bytes: model 115,200 → 104,870,400 logical bytes; Bash/Edit 204,800 → 209,715,200 bytes. Bash counts two streams; Edit counts the existing target plus staged output. This tests content bytes, not provider item cardinality or arbitrary Edit-list counts.

## Physical footprint, children and filesystem costs

Actual process physical bytes for the 1,000-execution cells; these are snapshots, **not allocator-live counts**. Per-process lifetime physical peaks, RSS and malloc-zone statistics are also in raw results.

| Effect / variant | Cold physical | Sealed physical | Retained-idle physical | Retained-idle application live |
| --- | ---: | ---: | ---: | ---: |
| Model baseline | 1,491,584 | 92,358,144 | 20,596,224 | 80,384 |
| Model early | 1,622,656 | 91,882,880 | 13,567,360 | 80,384 |
| Bash baseline | 1,475,136 | 19,301,120 | 19,301,120 | 80,384 |
| Bash shared/early | 1,688,192 | 2,360,256 | 2,360,256 | 80,384 |
| Edit baseline | 1,491,584 | 19,120,960 | 19,120,960 | 80,384 |
| Edit shared | 1,475,136 | 1,966,720 | 1,966,720 | 80,384 |

The 1,000 Bash workloads separately account for **2,822,513,728 / 2,814,783,232 summed child physical bytes** in baseline/early mode before reaping. Those are native fixture workloads, not OnePage helpers or Host allocation, and not a unique-machine-memory sum. Both modes have all 1,000 children alive at that snapshot. This cost must not be hidden by reducing actual subprocess concurrency.

Model records 3,007 total descriptors during transport, 2,007 after capture, then 1,007 after early request/transport cleanup. Bash records 5,003 before cleanup and 2,003 with only sealed captures retained. Edit retains 2,003. Counts include standard/library descriptors; `owned_fds` separately counts fixture-owned files/pipes. Every final `closed` sample has zero tracked allocation and zero fixture-owned descriptors.

At 1,000 × 4,096 bytes, model request+capture files occupy **4,224,000 logical / 8,192,000 filesystem-block bytes**; Bash captures and Edit target+output each occupy **8,192,000 / 8,192,000 bytes**. Blocks come from `fstat(st_blocks*512)`, not a RAM counter. The Edit target is fixture workload storage, not all charged Host scratch; raw `scratch_logical` includes it explicitly. All files are unlinked and have no retention index.

Malloc-zone `size_in_use` includes libc/dependency/instrumentation allocation beyond tracked application/libcurl bytes. `size_allocated` is allocator-reserved address space, not resident RAM. Released windows can leave substantial physical allocator retention. Per-file cache, dirty/writeback pages and socket/pipe kernel bytes were **not attributable with the recorded Mac process counters**; they are unavailable here, not zero and not inferred from logical scratch. Filesystem metadata, cache eviction and system-wide memory pressure remain separate qualification gaps. No ≤256 MiB or minimality claim follows from this narrow fixture.

## Private state and release boundaries

| Owner / population | Must survive service turns | Release point / failure behavior |
| --- | --- | --- |
| Fixed custody, 64 × 1,000 bytes | Operation/Attempt provenance, occupied/sealed/fenced/publication/pending flags, source handle, byte/offset state and effect pointer | Record is reusable only after all physical cleanup; array lasts through Host lifetime. |
| Effect record, 64 × occupied executions | Curl handle/header/request reader; or subprocess identity/control/pipe handles; or same Edit target descriptor and progress | Request/transport can end before source validation; Edit target must survive build/copyback/flush. Construction or I/O failure aborts this fixture; the external runner destroys its process group and unlinked resources. This is not a production typed-error implementation. |
| Capture/target files, up to 2 × executions in selected cells | Complete bytes and immutable source identity; no in-memory payload collection | Source through final validation; target through copyback/flush; then close. Filesystem/descriptor failure must fail, never truncate success. The fixture asserts syscall success except explicit fault tests. |
| Shared 16 KiB window, one Host | Nothing between completed synchronous service turns | Reuse only after read/write/callback returns. The fixture's calls do not overlap; this does not prove asynchronous Edit workers can share their pending buffers. |
| Pending-I/O window, one per genuinely pending reference | Buffer bytes plus callback/handle context | Keep private until completion is joined/drained, even after cancellation or saved outcome. `cleanup` returns EBUSY in the fault fixture until then. No generic pool is justified by these data. |

The callback fault fixture holds a real scratch write behind a gate. Cancellation fences publication while cleanup refuses to return the credit. After delivery, it joins the callback, then frees the buffer and closes its file. A second case retains credit after a modeled saved result, suppresses duplicate publication and verifies no write to sealed source. A real EBADF write verifies that incomplete capture is not sealed/published. The deliberately broken early-release variant must fail under AddressSanitizer with `heap-use-after-free`. These test local ownership, not Store transactions, crash recovery, disk-full or power loss. A modeled saved flag is not durable evidence.

## Existing production paths

Source inspection confirms `src/host_runtime.zig` still limits capacity to 100; `src/lifecycle.zig` has the older activation/credit pools; `src/bash_tool.zig` retains bounded stdout/stderr and `src/codex_provider.zig` parses before publication. Native exact Edit is not implemented. The redesigned results above cannot be labeled production performance.

`check.py` compiles wrappers against unchanged production code. Actual Bash captures 65,536 output bytes: allocator peak **84,144**, held **65,536**, after `Execution.deinit` **0**. Actual Codex `Capture` parser objects are **5,880 bytes** each; one / 100 objects holding 4,096-byte answers retain **13,830 / 1,383,000 tracked bytes**; deinit releases all. Parser-only measurements omit transport, canonical publication and the rest of Host. The production probes' physical snapshots are in `checks.json`, and should not be multiplied into a redesigned estimate.

## Dependency evidence and limits

Official sources checked 2026-09-10/11:

- [libcurl cleanup](https://curl.se/libcurl/c/curl_easy_cleanup.html) requires removal from multi before easy cleanup and permits callbacks during cleanup for some protocols. Context therefore survives the entire cleanup call.
- [Multi removal](https://curl.se/libcurl/c/curl_multi_remove_handle.html) may halt a transfer, must occur outside callbacks, and need not destroy cached connections. The prototype removes only after complete capture, outside callbacks.
- [Memory callbacks](https://curl.se/libcurl/c/curl_global_init_mem.html) must be thread-safe, including threaded resolvers. The fixture uses atomic counters. Hooks measure libcurl requests, not every OpenSSL/system allocation.
- [Upload buffers](https://curl.se/libcurl/c/CURLOPT_UPLOAD_BUFFERSIZE.html) default to 65,536 bytes and allocate on demand. This makes a large per-upload cost plausible, but this experiment attributes its 69,371-byte release to the whole easy/request lifetime; it does not isolate each internal allocation.
- [curl release](https://curl.se/download.html) identifies 8.22.0; experimental pins do not change production dependencies.

An initial system-libcurl 8.7.1 attempt failed at 1,000 transfers. [Saved failed run](system-curl-failed.json) preserves the incomplete samples; it is not a valid 1,000-execution result or a proven root-cause diagnosis. Final results use the pinned experimental build and its ordinary multi wait. System-library allocator instrumentation also initially needed correction for resolver-thread concurrency; those invalid counters were discarded.

Instrumentation adds one allocation header and malloc rounding per tracked allocation. Its realloc shim can temporarily allocate a replacement before freeing the old block. Physical/peak results include this observer overhead, native libraries, stack and OS accounting. There is one sample per matrix cell, no statistical confidence bound, no request cache benchmark, no full provider/Edit semantic validation, no SQLite admission/import/recovery, no evaluator, no retained spillover, and no host-control latency qualification. Linux is **unexecuted**; the metric collector and exact dependency recipe are Mac-specific. Linux process creation, descriptor scaling, cache/writeback, allocator retention and safe asynchronous cleanup still need execution evidence. Portable-looking calls do not establish those results.

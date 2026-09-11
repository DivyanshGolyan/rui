# Native-to-QuickJS decoding memory experiment

This is evidence for the accepted on-demand decoding direction, not an implementation of Workflow Runtime or a new input-format contract. The smallest supported improvement is to avoid a complete resident serialized result while constructing its final JS value. Keep separate mutable objects per invocation and one resolved identity per Promise. A decoded-answer cache is neither needed nor tested.

The [UTF-8 reader follow-up](string-reader/README.md) qualifies an explicit interface, broader string/object/key cases and complete backing-allocation overlap against a public-API baseline. It does not expand the claims of these earlier measurements.

## Reproduce

From the repository root:

```sh
python3 research/evaluator-memory/run.py
python3 research/evaluator-memory/run.py --sanitize --output research/evaluator-memory/sanitizer-results.json
python3 research/evaluator-memory/production.py
python3 research/evaluator-memory/summarize.py
git diff --check
```

Python 3, Clang and network access to the pinned public QuickJS archive are needed; the production probe also needs Zig 0.16.0 and the repository's build dependencies. `--source /path/to/extracted/quickjs` supports offline reruns; review recorded source hashes when using it. The default download checks its SHA-256. No provider or credential access occurs. Runners take `flock` on `/tmp/onepage-memory-experiments.lock` across compilation and measurements, serializing sibling experiments. Each child has a five-second timeout; native CPU has a one-second soft/two-second kernel hard limit. Temporary dependencies, executable and scratch are removed on normal/error exit; subprocess timeout kills and reaps the direct child. There are no child-spawn capabilities in fixture JS.

[Raw matrix](results.json), [sanitizer records](sanitizer-results.json), [production records](production-results.json) and [derived tables](measurements.md) retain concrete numbers. Provenance includes OnePage revision `b1d25138f70e6a7b4c1d27523d5b051f6de34d7a`, QuickJS pin/source hashes, compiler, Python, Mac model and OS. Measurements ran on an ARM64 MacBookPro18,1 with 17,179,869,184 bytes of RAM. These are short shared-machine samples, not statistical latency estimates.

## Actual source versus prototype

The production [`decodeData`](../../src/workflow_evaluator.zig) recursively creates final JS strings/arrays/objects from a cursor. It does **not** first build a native object tree or call JSON.parse. However, [`workflow_evaluator_main.zig`](../../src/workflow_evaluator_main.zig) allocates the whole 786,432-byte input region, 524,288-byte output region and 2,097,152-byte bridge arena. They remain owned until evaluation returns (3,407,872 requested bytes combined, before JS). Input slices remain resident while final JS values exist; source and descriptor storage consume additional arena capacity, not another arena-sized allocation. The old bridge deep-freezes results and retains old entry/byte limits. It is not the selected mutable, prepared-descriptor bridge.

`production.py` builds unchanged source with `zig build -Doptimize=ReleaseSmall -j2` into disposable installation scratch. Three real evaluator requests decode 65,536/262,144 payload bytes and independently vary 262,144 bytes across 1/1,024 strings. It checks the exact completed protocol result. macOS `time -l` records maximum RSS and peak physical footprint separately. It does not instrument production allocation lifetimes, and its earlier semantics are not used as the comparison's behavioral oracle.

The research C translation unit includes the exact pinned engine source and uses `js_alloc_string` to allocate the final string, filling it in at most 16,384-byte reads. Final arrays are populated directly. Both modes use identical code, data, heap/CPU limits, mutable arrays and Promise behavior; the sole difference is whether one complete result is first read into native staging. Neither mode builds a native object tree or a full serialized JS string. This controlled comparison isolates the overlapping source copy; it is not a measurement of a public-API JSON parser.

The public `JS_NewStringLen` API takes a contiguous string input. The direct path therefore needs a small engine-internal constructor seam (or another proven representation/API), not just replacing the parent read loop. This experiment does not select a production dependency patch. The private fixture format is arrays of length-prefixed Latin-1 or UTF-16LE strings; an explicit supplementary-character/non-ASCII check passes. It is **not** a complete strict-data decoder: objects, keys, numbers, duplicate-key rules, deep nesting, arbitrary UTF-8 validation and variable-sized-record indexing remain production work. The fixed-size result stride removes the need for a resident index only in this fixture.

## Findings

- With a 4,194,304-byte string, direct native scratch is 16,384 bytes versus 4,194,316 bytes staged. Both modes have the same 4,426,128-byte engine allocator peak. This removes 4,177,932 overlapping requested native bytes while preserving the final value. Physical measurements corroborate overlap but vary with allocator retention; see the tables rather than inferring physical bytes from allocation bytes.
- Holding payload bytes at 1,048,576 while increasing strings from 1 to 16,384 raises the engine peak from 1,280,400 to 2,525,584 bytes. Native direct scratch stays 16,384 bytes. Final strings, their headers and array storage have a real item-count cost; removing them would change the returned value.
- Selective decoding reads 1,048,840 bytes from a 33,562,880-byte prepared file containing 32 results. A separate 1/32/1,024-saved-result sweep holds each result at 65,536 payload bytes: engine peak remains 297,360 and one lookup reads 65,548 bytes, with one prepared descriptor. Parent scratch grows to 67,121,152 bytes; preparation's Python peak stays about 50 KiB. This tests stride-addressed fixtures, not general key lookup cost.
- Forty separate invocations perform forty decodes. Mutation and inequality assertions verify fresh arrays. Reawaiting one Promise 10,000 times performs one decode and preserves identity. Four author-retained results raise engine peak to 4,526,480 bytes; this is user retention, not a bridge cache.
- Three four-result burst/release cycles keep the same engine peak. Live allocations fall after release; some 4,096 bytes of engine capacity remain above cold in these runs. Every runtime teardown reaches zero instrumented engine/native live bytes. Process physical footprint can remain high even after that; process exit, not a GC claim, ends this disposable evaluator's ownership. Do not choose a pooling strategy from these noisy retained-footprint samples.
- The 16 MiB runtime limit rejects a fourth 4 MiB retained result with `engine_exhaustion`; already constructed values unwind. Lowering the independent native budget to 8,192 rejects the required 16,384-byte window with `native_exhaustion`. Short input, malformed width and impossible declared length produce explicit failure and zero tracked allocations after teardown. The failure path never emits a completed outcome. These are graceful local failures, not crash/recovery or publication proofs.

## Accounting and ownership

| Population | Owner, bound and release | What is measured |
| --- | --- | --- |
| Final values, Promise jobs, engine metadata | One child runtime; 16,777,216-byte engine limit; author references release values, runtime teardown releases the remainder | Custom backing-allocator live/peak usable bytes; QuickJS allocation accounting and structural memory estimate separately |
| Decoder staging | One synchronous native lookup; 16,384 bytes direct, one selected result staged; research native budget 8 MiB, allocation rejection explicit; freed before Promise handoff and on failure | Requested native live/peak; backing allocator rounding and libc caches are not included in this counter |
| Input metadata, cursor, string-fill loop | Fixed scalar metadata and stack, no native tree or per-item list; loop frame expires on return | Source audit; not separately instrumented stack bytes |
| Prepared file | Parent; complete writes, fsync and streamed hash verification before read-only handoff; one file/descriptor independent of saved count; unlink after child reaped | Logical bytes, filesystem allocated bytes, input bytes read |
| Parent preparation | Python runner; at most 16 KiB payload chunks plus hash/read chunks; closes writer before reader handoff | tracemalloc preparation current/peak, parent physical footprint at cold/prepared/released checkpoints; this includes Python/harness overhead, not production Host memory |
| OS and allocator retention | Kernel/libc ownership outlives useful allocations; child exit and scratch close/unlink end application ownership | macOS `TASK_VM_INFO.phys_footprint`; child sampled peak and retained idle; macOS `ru_maxrss` in bytes separately. File-cache residency, filesystem metadata and handle kernel bytes are not individually attributable here |

The custom allocator covers engine runtime/native allocations as well as JS values. `JS_ComputeMemoryUsage` is a structural estimate, not a second independent heap to add to it. Do not sum those counters. Peaks from separate processes/checkpoints are not simultaneous whole-Host peaks. Realloc's transient internal copy and libc's retained arenas are outside callback-live accounting. `vm_stat` snapshots provide system-wide file-backed/dirty/purgeable-page context only; they cannot establish per-file cache cost. No cache purge or privileged machine intervention was used.

## Validation

All 40 normal measurement cases passed their expected success/failure, exact failure classification and zero-live-at-teardown assertions. The review tightened success to require a fulfilled root Promise, checks sanitizer stderr, records harness hashes, and gives sanitizer reruns their own default result path. All 14 focused AddressSanitizer + UndefinedBehaviorSanitizer cases passed with no sanitizer diagnostics. Three unchanged-production fixtures passed exact output checks, and its ReleaseSmall build succeeded. Research-only changes do not claim the production `check` or `workflow-check` gates; those full suites were not run. The default source/ABI probe, sanitizer probe and production build were serialized through the shared lock.

## Evidence boundary

One child lifecycle runs at a time, with only its prepared descriptor explicitly inherited alongside stdio; JS has no native path/open API. Both comparison modes run the same trusted fixture scripts. The prototype does not install production's complete hardened realm, wire validator, publication path, cancellation/generation fence or recovery protocol, and makes no capability-security qualification claim. It does not remove any of those accepted requirements. Preparation errors occur before spawn; deliberate post-verification corruption is fault injection. Repetition uses fresh processes for each case and same-runtime bursts within a case.

Linux was not run. The C probe has conditional allocation-size support there but deliberately returns zero for unavailable macOS-style physical footprint; that zero means **unmeasured**, not zero memory. UTF-16LE filling assumes the selected little-endian targets. Linux resident/PSS/private-dirty, cgroup file/kernel charges, process containment and cleanup need separate execution. Arbitrary UTF-8/string-width promotion, dynamic key metadata, full strict-data decoding, cancellation during input preparation/decoding, actual publication fencing, abrupt crash and power loss remain unqualified on both systems. This research does not establish whole-Host ≤256 MiB qualification or memory minimality.

Primary sources checked for this experiment: [QuickJS-NG C API memory/ownership guide](https://quickjs-ng.github.io/quickjs/developer-guide/intro/), [exact engine source](https://github.com/quickjs-ng/quickjs/blob/1ab8676f4b6d6d669baeb5f21790fb9734636a20/quickjs.c) (`js_alloc_string`, `JS_NewStringLen`, allocator accounting; extracted source hashes in raw results), and [Apple task information definitions](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/task_info.h) (also checked against the local SDK header). Accepted behavior remains in [ARCHITECTURE.md](../../ARCHITECTURE.md#owning-evaluator-input-and-output); required integration proof remains in [VERIFICATION.md](../../VERIFICATION.md#evaluator-lifecycle-and-limit-replacement).

# Linux allocation origins

At 100 concurrent synthetic H2 requests, retained requested heap is effectively
equal after 2 and 20 waves. SQLite page-cache warmup explains the increase from
wave 1 to wave 2. Networking dominates the busy heap peak, not retained growth.
This does not establish a leak-free runtime or bound every provider workload.

## Measured composition

[Recorded results](results.json) contain allocation origins, largest stacks,
binary/tool hashes, environment, per-wave process samples and behavioral verdicts.
All MB below are decimal. These are requested live heap bytes, not RSS:

| Allocation origin | After wave 1 | After wave 2 | After wave 20 | At the 20-wave global heap peak |
| --- | ---: | ---: | ---: | ---: |
| SQLite | 0.839 MB | 1.228 MB | 1.228 MB | 1.353 MB |
| OpenSSL | 0.661 MB | 0.661 MB | 0.661 MB | 0.661 MB |
| curl and nghttp2 | 0.107 MB | 0.107 MB | 0.107 MB | 4.111 MB |
| Rui and Zig heap | 0.246 MB | 0.247 MB | 0.247 MB | 0.247 MB |
| System, profiler or unresolved | 0.074 MB | 0.074 MB | 0.074 MB | 0.074 MB |
| Total | 1.927 MB | 2.317 MB | 2.316 MB | 6.446 MB |

The peak column is one simultaneous process-wide heap snapshot, not a sum of
each caller's separate maximum. The three final snapshots come from separate
processes. The 20-wave run passes 2,000 exact responses and complete accumulated
request histories, with one H2 connection and 13 drained descriptors every wave
(including instrumentation). No live provider or Bash workload ran here.

SQLite retains exactly 1,228,104 requested bytes after both 2 and 20 waves.
Of these, 1,086,792 originate in `pcache1` page-cache paths; the other 141,312
bytes include connection/schema storage. The production cache suggestion is
1,024 KiB, not a total SQLite heap ceiling. Rui's lifetime allocations include
169,600 bytes for execution slots. This table excludes stack-resident storage:
for example, the capture writer has 16 roughly 16-KiB entries on its owner stack.

The same symbolized binary without Heaptrack passed 20 waves. Sampled peak RSS
was 15,966,208 bytes; peak PSS was 14,781,440 bytes. At that PSS sample,
8,626,176 bytes were anonymous and 6,155,264 file-backed, with no swap.
Final idle PSS was 12,794,880 bytes. File-backed pages are not leaked objects.
Anonymous pages include live allocations, free allocator pages, stacks and
other mappings. This experiment does not attribute all anonymous pages.
Do not subtract the instrumented heap peak from the control's anonymous peak:
they are different processes and moments.

Heaptrack materially perturbs scheduling and cost: the instrumented 20-wave
run used 185.42 Host CPU seconds between initial and final observations versus
22.80 in the control, and peaked at 20.64 MB RSS. These are diagnostic workload
totals, not throughput or CPU-regression qualifications. The Linux RSS/PSS
observations do not substitute for macOS physical-footprint qualification.

## Follow-up experiments

[Experiment records](experiments.json) preserve 4 matched SQLite pairs, 3 matched
capture-queue pairs and a separate allocation profile. All use 100 Sessions and
20 waves, except the 2-wave allocation comparison. Those runs used disposable
variants; the production change now adopts only the SQLite flag correction.
These are Linux ARM64 diagnostic runs, not macOS or fleet evidence.

### Removing the persistent hint reduced CPU, not retained memory

The baseline `store.prepare` passed `SQLITE_PREPARE_PERSISTENT`, although callers finalize
statements after use. [SQLite documents](https://sqlite.org/c3ref/c_prepare_dont_log.html)
that this hint avoids lookaside storage. The disposable variant changes only
that flag to `0`, beyond the shared profiling build settings.

| Pair | Baseline Host CPU | Flags 0 Host CPU | Baseline peak RSS | Flags 0 peak RSS |
| --- | ---: | ---: | ---: | ---: |
| 1 | 21.48 s | 19.30 s | 15.495 MB | 15.245 MB |
| 2 | 21.83 s | 18.85 s | 15.241 MB | 15.294 MB |
| 3 | 21.34 s | 20.36 s | 16.056 MB | 15.626 MB |
| 4, reversed order | 21.14 s | 19.31 s | 15.372 MB | 15.622 MB |

Mean Host CPU fell about 9.3%, with a reduction in every pair. Elapsed time did
not consistently improve: the baseline runs took 27.64–30.25 s; flags 0 took
28.37–32.88 s. RSS differences are small and inconsistent.

In separate 2-wave Heaptrack runs, allocation calls fell from 2,190,017 to
688,969. SQLite calls fell from 2,156,131 to 655,282. SQLite retained requested
bytes stayed exactly 1,228,104. This supports reusing existing lookaside storage
rather than reducing the retained working set. Whole-heap peaks occurred at
different scheduling points and are not isolated SQLite savings.

The production change adopts the one-line correction without adding a statement
cache. The full Linux H2 integration suite passed on flags 0, including
pause/resume, cancellation and retry/recovery. A read-only independent source
review found no statement-lifetime or durable-semantics reason to retain the hint.
The existing SQLite heap limit and rollback/fencing paths remain unchanged.

### The macOS comparison supports the CPU result, with gate limits

[macOS records](macos-results.json) retain one matched pair using production
ReleaseSmall builds, the existing 100-Session/20-wave H2 oracle and Host CPU
from `/bin/ps`. CPU fell from 40.94 to 37.73 seconds, about 7.8%. Both runs
validated all 2,000 responses, complete histories, one connection and drainage.
One pair supports the Linux result but does not establish general latency gains.

Reproduce with Python `h2==4.3.0` and [macos.py](macos.py):

```sh
python3 research/linux-allocations/macos.py /absolute/path/to/rui /absolute/path/to/new-result.json
```

The canonical Go repeat-work gate first failed on the unchanged baseline:
`footprint` reported current 5,169 KiB but lifetime peak 4,865 KiB. Its strict
parser correctly refused qualification. The separate H2 CPU comparison does not
relax that parser or replace its gate. Reported peaks of 9,634,560 and 9,077,568
bytes remain diagnostic, not accepted memory qualification. `lsof` also emitted
mounted-filesystem warnings; relative FD observations are not an exhaustive leak
proof. The failed baseline result is retained alongside the successful CPU runs.

### A larger capture queue did not reduce total memory

Both capture variants use flags 0 and the same disposable counters. Increasing
the queue from 16 to 64 entries adds roughly 0.79 MB of fixed stack storage.
Counters record offers, rejected callback pauses, queue occupancy and cumulative
completed pause duration; they emit one short record per 100 transfer teardowns.
Pause time is summed across transfers, not elapsed wall time.

| Pair | 16-entry RSS | 64-entry RSS | 16-entry CPU | 64-entry CPU | Pauses, 16 → 64 | Paused-agent seconds, 16 → 64 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 15.245 MB | 15.663 MB | 19.00 s | 19.29 s | 983 → 504 | 186.02 → 78.11 |
| 2 | 15.806 MB | 15.659 MB | 20.03 s | 19.61 s | 1118 → 571 | 159.12 → 105.64 |
| 3 | 14.856 MB | 15.311 MB | 20.29 s | 18.83 s | 977 → 476 | 165.58 → 81.98 |

Both queues filled. The larger queue roughly halves pause count, but RSS is
about 0.24 MB higher on average. CPU and elapsed time do not consistently improve.
Recommendation: keep 16 entries. Fewer pauses alone is not the optimization goal.
The counters perturb layout and add infrequent logging under the writer lock;
these runs do not prove performance under sustained provider or disk saturation.

Leave Linux allocator defaults and the transport implementation unchanged on this
evidence. TLS retention is stable; idle curl/H2 storage is small. Reducing SQLite
cache would be a memory-versus-I/O experiment, not a leak fix. Do not add a general
statement cache or easy-handle pool without evidence that their state is needed.

Source inspection confirms Rui already sets `CURLOPT_UPLOAD_BUFFERSIZE=16384`,
curl's documented minimum. It is not a newly available optimization.
In pinned curl 8.22.0, [request send queues](https://github.com/curl/curl/blob/curl-8_22_0/lib/request.c#L76-L87)
are per easy handle and use a soft chunk limit. [Paused response buffers](https://github.com/curl/curl/blob/curl-8_22_0/lib/cw-out.c#L346-L369)
are also per transfer; replay/cleanup frees them. `CURLOPT_BUFFERSIZE` does not
cap either population. [Multiplexed pause documentation](https://github.com/curl/curl/blob/curl-8_22_0/docs/libcurl/curl_easy_pause.md)
warns that data for paused streams can still arrive on the shared connection.
The observed peak is not a worst-case network-memory bound.

## Reproduce the attribution

The allocation-attribution baseline is [this merged revision](https://github.com/DivyanshGolyan/rui/commit/2b60daec180365220b43dedc3284b2a4bad6292a).
Apply [profiling-build.patch](profiling-build.patch) only in a disposable checkout:
it retains symbols, unwind tables and frame pointers. Build with Zig 0.16.0:

```sh
git apply /path/to/profiling-build.patch
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSmall --prefix /tmp/rui-symbols
```

Environment: OrbStack Linux ARM64 on this Mac, Ubuntu 24.04.5, glibc 2.39,
kernel `7.0.14-orbstack-00380-ga7e0a2dc9535`. The container has an ancestor
two-core quota and 1.5-GiB memory limit. Cgroup diagnostics are ancestor/system
scope, not Host-only. Other VM services were left running. This does not
qualify x86-64, musl, bare metal or every Linux distribution.

Ubuntu's packaged Heaptrack 1.5.0/libunwind 1.6.2 produced no usable stacks,
including for an independent C canary. Build pristine Heaptrack tag v1.5.0,
[commit b54e92e](https://github.com/KDE/heaptrack/commit/b54e92e88b0895f910a5b107f499d1155a086b80), with its alternative unwinder:

```sh
cmake -S heaptrack-src -B heaptrack-build -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DHEAPTRACK_BUILD_GUI=OFF -DHEAPTRACK_USE_LIBUNWIND=OFF -DBUILD_TESTING=OFF \
  -DCMAKE_INSTALL_PREFIX="$HOME/heaptrack-local"
cmake --build heaptrack-build -j2
cmake --install heaptrack-build
cc -g -O0 -fno-omit-frame-pointer research/linux-allocations/canary.c -ldl -o /tmp/canary
cc -shared -fPIC -pthread -g -Wall -Wextra -Werror \
  research/linux-allocations/stop_profiler.c -ldl -o research/linux-allocations/stop_profiler.so
export HEAPTRACK_PRELOAD="$HOME/heaptrack-local/lib/heaptrack/libheaptrack_preload.so"
LD_PRELOAD="$HEAPTRACK_PRELOAD" DUMP_HEAPTRACK_OUTPUT=/tmp/canary.raw /tmp/canary
```

The canary must identify the retained 257- and 4,099-byte allocations and exclude
the freed 8,193-byte allocation from final live memory. An additional 73,728-byte
allocation comes from the profiler's libstdc++ dependency. Install Python
`h2==4.3.0` in the workload environment. For each wave count 1, 2 and 20, use a
fresh output directory:

```sh
OUT=/absolute/path/to/new-capture
python3 research/linux-allocations/profile.py /tmp/rui-symbols/bin/rui \
  --capacity 100 --rounds 20 --output "$OUT"
"$HOME/heaptrack-local/lib/heaptrack/libexec/heaptrack_interpret" \
  < "$OUT/heaptrack.raw" > "$OUT/heaptrack.txt"
for cost in leaked peak allocations; do
  "$HOME/heaptrack-local/bin/heaptrack_print" -f "$OUT/heaptrack.txt" \
    -m0 -l1 -n12 --disable-builtin-suppressions --disable-embedded-suppressions \
    --flamegraph-cost-type="$cost" -F "$OUT/$cost.stacks" > "$OUT/report-$cost.txt"
done
python3 research/linux-allocations/summarize.py "$OUT/"*.stacks
python3 tests/qualification/linux-memory/run.py /tmp/rui-symbols/bin/rui \
  --capacity 100 --rounds 20 --output /absolute/path/to/new-control
```

The collector stops and flushes through a dedicated diagnostic thread after
the final drained observation, before the fixture kills the Host. Heaptrack's
`leaked` label means live at that point, not a leak verdict. The extra thread,
library mappings and allocation tracking are instrumentation, not production.
Classification uses the nearest recognized allocation origin. Unknown/system
frames remain explicit. Heaptrack does not account for all mmap/stack memory,
allocator metadata or free retained pages. Each run's summary includes hashes
of the collapsed input stacks; raw traces remain in the local audit VM.

To reproduce the follow-up, apply [sqlite-flags-zero.patch](sqlite-flags-zero.patch)
on top of the symbolized baseline and build to a separate prefix. Alternate
fresh 100-capacity/20-wave `run.py` invocations against the baseline and variant;
the fourth pair runs the variant first. Neither uses Heaptrack. Run `profile.py`
separately for 2 waves to compare allocation counts, never its CPU against the
uninstrumented runs.

For capture comparisons, also apply [capture-counters.patch](capture-counters.patch).
Build once with `CaptureWriter.capacity = 16`, then change only that constant
to `64` and build to another prefix. Use the [capture wrapper](capture.py):

```sh
python3 research/linux-allocations/capture.py /absolute/path/to/variant/rui \
  --capacity 100 --rounds 20 --output /absolute/path/to/new-capture-run
```

Run a 2-wave pilot before the three matched pairs. The wrapper saves the short
counter records from Host stderr during fixture disposal and requires every
100-transfer record through completion. `capture.json` counters are cumulative;
subtract adjacent rows for per-wave values. Completed pause intervals omit any
unresumed pause on failed/cancelled transfers; the measured workload requires
successful responses. The disposable variants and their instrumentation are
not production changes. Binary hashes and patch hashes are in the records.

## Failures and verification

Preserved failed runs exposed two measurement races, not evidence of production
leaks. After custody was observed at zero, a second inspection could see the
temporary reserve-before-no-work check. Separately, a completed inspection
reply can precede release of its report file and accepted socket, adding 2 FDs.
The fixture checks custody and scratch in one observation. After PR review,
it also waits for that inspection's socket EOF before sampling any wave,
including the first baseline: the server releases the report before closing
the socket. Later samples must return to the lowest previously observed
population. EOF proves cleanup of this inspection, not all earlier independent
callers or absence of every retained resource. No production protocol or
descriptor allowance changed.

A deterministic reply-before-cleanup counterexample starts with 10 steady
and 2 transient inspection FDs. Removing the EOF wait makes its first-baseline
assertion fail; that inflated baseline would otherwise accept 2 retained FDs
on the next wave. The full Linux H2 suite passed with the corrected oracle.
The macOS size-shaped suite also passed, including both stalled-capture cases;
its descriptor listing still warns about an unrelated mounted filesystem.
Earlier experiment hashes and results retain their original fixture;
the review correction does not retrospectively qualify those measurements.

The original counterexample fails at the second-read assertion. The corrected
predicate accepts that interleaving; a persistent FD increase still times out.
The successful 20-wave run recorded 13 FDs each wave; the control recorded 10.
Earlier failed traces and logs remain under the VM's `~/rui/audit/` and local
`.amp/in/artifacts/`, rather than being relabelled as passes. Python compilation,
classification precedence/sum checks and diff hygiene passed. The complete
`transport_h2_integration.py` suite also passed on the symbolized Linux binary,
including stalled capture, pause/resume, cancellation and connection recovery.
For the production change, `zig build check-full` passed 276 native tests with
one platform skip, then stopped in the unchanged standalone QuickJS evaluator.
It exits 3 because macOS rejects its 1-MiB `RLIMIT_STACK`; an independent Python
resource-limit probe reproduces the rejection before any SQLite work.

Running the remaining process suites directly passed admission, dispatch, Bash
owner/journey/lifecycle/recovery, human CLI, Codex and control. The descriptor
fixture then failed because it expects 72 required FDs but observes 73 with 4
inherited; the unchanged baseline reproduces that exact failure. Debug admission,
Host process and allocator startup suites passed individually afterward. These
failures are not waived or reported as a green `check-full` gate. No production
evaluator, descriptor or memory-counter behavior was changed to bypass them.

Capture counters, queue sizing and platform allocator defaults remain unchanged.

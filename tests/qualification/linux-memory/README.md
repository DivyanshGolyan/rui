# Linux allocator measurements

This diagnostic runs the production Host against the existing larger-event TLS/H2 fixture: 100 simultaneous requests per wave, 20 waves on the same Sessions, complete growing request histories, exact results, one connection, and custody/scratch release. It does not contact a live model provider. Production Linux allocator defaults are unchanged.

## Reproduce

Use Linux with glibc, Python with `h2==4.3.0`, OpenSSL and a C compiler. Build the production executable with Zig 0.16.0 in ReleaseSmall. Run from the repository root:

```sh
python3 tests/qualification/linux-memory/run.py /absolute/path/to/rui --output /tmp/new-default
python3 tests/qualification/linux-memory/run.py /absolute/path/to/rui --output /tmp/new-arena2 --tunables glibc.malloc.arena_max=2
python3 tests/qualification/linux-memory/run.py /absolute/path/to/rui --output /tmp/new-arena1 --tunables glibc.malloc.arena_max=1
python3 tests/qualification/linux-memory/run.py /absolute/path/to/rui --output /tmp/new-nocache --tunables glibc.malloc.arena_max=1:glibc.malloc.tcache_count=0
```

Use new output directories; failed runs must not be overwritten. Repeat promising comparisons in reverse order. The setting applies only to the Host, not the provider fixture or CLI.

For a separate allocator diagnostic:

```sh
cc -shared -fPIC -pthread -Wall -Wextra -Werror tests/qualification/linux-memory/malloc_probe.c -o /tmp/rui-malloc-probe.so
python3 tests/qualification/linux-memory/run.py /absolute/path/to/rui --output /tmp/new-probe --probe /tmp/rui-malloc-probe.so --trim-after
```

The probe adds a thread, FIFO, stack and allocations. Its `mallinfo2` and `malloc_info` snapshots report glibc accounting, not semantic live data, allocation-origin attribution or isolated tcache usage. They overlap RSS/PSS and must not be added to them. The final one-off `malloc_trim` tests reclaimability; it is not a proposed production cleanup timer.

Run sustained output and protected-control measurements separately with the existing Go runners:

```sh
RUI_MEASURE_GLIBC_TUNABLES='' go -C tests/qualification run ./model-output --capacity 100 --output /tmp/output-default.json /absolute/path/to/rui
RUI_MEASURE_GLIBC_TUNABLES='' go -C tests/qualification run ./model-control --output /tmp/control-default.json /absolute/path/to/rui
```

Repeat with the candidate setting. Output preserves exact result audits and the conservative 40-second CPU bracket within each 60-second offered workload. On Linux its aggregate verdict remains `incomplete` and exit status is 1 because the accepted macOS physical-footprint counter is unavailable. Inspect individual behavior, CPU and memory evidence; this expected absence must not conceal an actual error.

## Meaning and limits

- RSS counts resident pages fully; PSS apportions shared pages. `Pss_Anon`, `Pss_File` and `Pss_Shmem` describe backing, not Rui ownership. File-backed code and libraries are not allocator waste.
- Peaks from the 100 ms sampler are sampled peaks, not guaranteed lifetime maxima. Raw per-wave `status` files also retain approximate Linux `VmHWM`; there is no kernel lifetime PSS maximum. Neither metric equals macOS physical footprint.
- Mounted-root cgroup counters describe the ancestor/system scope, including fixture work; they are not Host-only memory or CPU. Record the actual cgroup path, limits, throttling, swap and pressure availability. Global VM pressure can also affect timing and file-backed residency.
- Requested `GLIBC_TUNABLES` is provenance, not proof every setting took effect. Probe XML verifies observed arena counts. See the [glibc 2.39 tunables documentation](https://sourceware.org/glibc/manual/2.39/html_node/Memory-Allocation-Tunables.html): `arena_max` limits arenas; `tcache_count=0` disables per-thread caches. These are glibc-specific, not generic Linux controls.
- A finite repeated-work test neither proves absence of all leaks nor qualifies Linux x86-64, musl, other glibc versions, a live-provider journey, tools or the complete 1,000-operation workload. Do not change networking libraries or allocators based on these counters alone.

## Recorded experiment

The local 2026-09-27 experiment uses the unchanged production source at [4991401](https://github.com/DivyanshGolyan/rui/commit/499140169e8d7864160aba183152eeec7fcac4cd), cross-built for aarch64-linux-gnu in ReleaseSmall. The source export has no Git metadata; the Go runner honestly records that absence. The uncommitted measurement overlay, raw results and hashes are retained locally under `.amp/in/artifacts/linux-audit/`; the compact derived measurements are in [results.json](results.json) beside this file. The full comparisons preceded the final metadata-only collector changes; the final two-agent/two-wave instrumented pilot verifies those additions. Earlier raw status snapshots supply the derived RSS high-water values.

Environment: isolated OrbStack Ubuntu 24.04.5, glibc 2.39-0ubuntu8.9, ARM64 kernel 7.0.14-orbstack-00380-ga7e0a2dc9535, ancestor CPU quota two cores and memory limit 1.5 GiB. This is real Linux execution on the Mac, not native macOS or x86 emulation. An unrelated container shares the underlying VM; it was left untouched. Pressure-stall information is unavailable on this kernel. The first pilot stopped before workload launch because it required that unavailable counter; subsequent runs explicitly record its absence.

The first four 2,000-request runs all passed behavior checks. Sampled RSS peaks were 16.19 MB default, 15.98 MB with two arenas, 15.76 MB with one, and 15.71 MB with one arena and no tcache. The reverse-order default repeat reached only 15.27 MB: run-to-run variation exceeds the apparent first-pair saving. Keep Linux defaults unless a deployment-specific workload demonstrates a material repeatable benefit.

At the first default run's maximum sampled PSS, 15.02 MB divides into 8.77 MB anonymous pages and 6.25 MB file-backed pages; shared-memory PSS and process swap were zero. This explains backing, not the split between networking, SQLite and Rui objects. After the last wave, a separate default probe reported 2.49 MB nominal in-use arena allocations and 2.58 MB free arena space, plus 0.17 MB mmap allocation; observed arena count was four versus one with the limit. One-off trimming reduced PSS by 1.65 MB. Nominal in-use bytes increased by 0.45 MB from wave one to twenty, so these counters do not attribute all retained growth to free pages or prove absence of a leak. Further attribution would require allocation-site/lifetime evidence, not a networking rewrite.

The default and no-tcache sustained runs each completed two 600,000-event rounds, exact result audits and cleanup. Conservative average CPU was 0.489–0.503 cores with defaults and 0.492–0.503 with the candidate; complete-work CPU was 33.48/33.73 and 34.14/33.52 seconds respectively. Both control suites passed. Default Session-stop p95 was 1.632 ms versus 3.725 ms with the candidate; these small shared-VM samples are not a general tail-latency comparison. Both output aggregate verdicts correctly remain incomplete solely because physical footprint is unavailable. The repeated-work runs recorded no increase in ancestor throttling or memory-event counters and no ancestor/process swap; global VM pressure remains a separate possible influence.

Verification: the canonical `zig build measurement-check`, all Go package tests, native Linux `/proc` parser/snapshot tests, native Linux Host allocator-startup fixture, Python compilation and diff hygiene passed. An unfixed-path counterexample established that missing physical footprint previously could qualify falsely; the regression now rejects it. Independent read-only review prompted explicit cgroup scope, sampled-versus-high-water distinctions and source/probe provenance. The claimed duplicate-environment override defect was rejected against Go's documented last-value-wins `exec.Cmd.Env` behavior. No production source changed; full native/product gates and live-provider tests were not rerun for this measurement-only overlay.
